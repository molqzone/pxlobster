const std = @import("std");
const ringbuffer = @import("../ringbuffer.zig");

pub const writer_chunk_bytes: usize = 64 * 1024;
const max_supported_channels: usize = 32;
const max_cross_stripe_bytes: usize = max_supported_channels * @sizeOf(u64);

pub const RawWriterContext = struct {
    ring: *ringbuffer.RingBuffer,
    file: std.fs.File,
    target_bytes: usize,
    continuous: bool = false,
    decode_cross: bool = false,
    channel_count: u32 = 16,
    producer_done: *std.atomic.Value(bool),
    stop_requested: *std.atomic.Value(bool),
    bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub fn runRawWriter(ctx: *RawWriterContext) void {
    if (ctx.decode_cross) {
        runDecodedCrossWriter(ctx);
        return;
    }

    runPassthroughWriter(ctx);
}

fn runPassthroughWriter(ctx: *RawWriterContext) void {
    var scratch: [writer_chunk_bytes]u8 = undefined;
    var written: usize = 0;

    while (ctx.continuous or written < ctx.target_bytes) {
        const want = if (ctx.continuous)
            scratch.len
        else blk: {
            const remaining = ctx.target_bytes - written;
            break :blk @min(remaining, scratch.len);
        };
        const got = ctx.ring.pop(scratch[0..want]);
        if (got == 0) {
            if (ctx.producer_done.load(.acquire)) break;
            if (ctx.stop_requested.load(.acquire) and ctx.ring.available() == 0) break;
            std.Thread.sleep(1 * std.time.ns_per_ms);
            continue;
        }

        ctx.file.writeAll(scratch[0..got]) catch {
            ctx.failed.store(true, .release);
            ctx.stop_requested.store(true, .release);
            break;
        };
        written += got;
        ctx.bytes_written.store(@intCast(written), .release);
    }

    ctx.bytes_written.store(@intCast(written), .release);
    if (!ctx.continuous and written >= ctx.target_bytes) {
        ctx.stop_requested.store(true, .release);
    }

    ctx.file.sync() catch {
        ctx.failed.store(true, .release);
        ctx.stop_requested.store(true, .release);
    };
}

fn runDecodedCrossWriter(ctx: *RawWriterContext) void {
    const stripe_bytes = crossStripeBytes(ctx.channel_count) catch {
        ctx.failed.store(true, .release);
        ctx.stop_requested.store(true, .release);
        return;
    };

    if (!ctx.continuous and ctx.target_bytes % stripe_bytes != 0) {
        ctx.failed.store(true, .release);
        ctx.stop_requested.store(true, .release);
        return;
    }

    var scratch: [writer_chunk_bytes]u8 = undefined;
    var merged: [writer_chunk_bytes + max_cross_stripe_bytes]u8 = undefined;
    var decoded: [writer_chunk_bytes + max_cross_stripe_bytes]u8 = undefined;
    var carry: [max_cross_stripe_bytes]u8 = undefined;
    var carry_len: usize = 0;
    var written: usize = 0;

    while (ctx.continuous or written < ctx.target_bytes) {
        const want = if (ctx.continuous)
            scratch.len
        else blk: {
            const remaining = ctx.target_bytes - written;
            break :blk @min(remaining, scratch.len);
        };
        const got = ctx.ring.pop(scratch[0..want]);
        if (got == 0) {
            if (ctx.producer_done.load(.acquire)) break;
            if (ctx.stop_requested.load(.acquire) and ctx.ring.available() == 0) break;
            std.Thread.sleep(1 * std.time.ns_per_ms);
            continue;
        }

        if (carry_len > 0) {
            @memcpy(merged[0..carry_len], carry[0..carry_len]);
        }
        @memcpy(merged[carry_len .. carry_len + got], scratch[0..got]);

        const total = carry_len + got;
        const aligned_total = total - (total % stripe_bytes);
        if (aligned_total > 0) {
            const produced = decodeCrossDataChunk(ctx.channel_count, merged[0..aligned_total], decoded[0..aligned_total]) catch {
                ctx.failed.store(true, .release);
                ctx.stop_requested.store(true, .release);
                break;
            };
            ctx.file.writeAll(decoded[0..produced]) catch {
                ctx.failed.store(true, .release);
                ctx.stop_requested.store(true, .release);
                break;
            };
            written += produced;
            ctx.bytes_written.store(@intCast(written), .release);
        }

        carry_len = total - aligned_total;
        if (carry_len > 0) {
            @memcpy(carry[0..carry_len], merged[aligned_total..total]);
        }
    }

    if (!ctx.failed.load(.acquire) and !ctx.continuous and carry_len != 0) {
        ctx.failed.store(true, .release);
        ctx.stop_requested.store(true, .release);
    }

    ctx.bytes_written.store(@intCast(written), .release);
    if (!ctx.continuous and written >= ctx.target_bytes) {
        ctx.stop_requested.store(true, .release);
    }

    ctx.file.sync() catch {
        ctx.failed.store(true, .release);
        ctx.stop_requested.store(true, .release);
    };
}

fn crossStripeBytes(channel_count: u32) !usize {
    return switch (channel_count) {
        16, 32 => @as(usize, @intCast(channel_count)) * @sizeOf(u64),
        else => error.InvalidChannelCount,
    };
}

fn decodeCrossDataChunk(channel_count: u32, input: []const u8, output: []u8) !usize {
    const stripe_bytes = try crossStripeBytes(channel_count);
    if (input.len % stripe_bytes != 0) return error.InvalidCrossChunkSize;
    if (output.len < input.len) return error.OutputBufferTooSmall;

    const channels: usize = @intCast(channel_count);
    var words: [max_supported_channels]u64 = [_]u64{0} ** max_supported_channels;
    var in_offset: usize = 0;
    var out_offset: usize = 0;

    while (in_offset < input.len) {
        var ch: usize = 0;
        while (ch < channels) : (ch += 1) {
            const src = input[in_offset + ch * @sizeOf(u64) ..][0..@sizeOf(u64)];
            words[ch] = readLeU64(src);
        }
        in_offset += stripe_bytes;

        var bit_index: usize = 0;
        while (bit_index < 64) : (bit_index += 1) {
            var sample_word: u32 = 0;
            ch = 0;
            while (ch < channels) : (ch += 1) {
                const bit_value: u32 = @intCast((words[ch] >> @as(u6, @intCast(bit_index))) & 0x1);
                sample_word |= bit_value << @as(u5, @intCast(ch));
            }

            if (channels == 16) {
                writeLeU16(output[out_offset .. out_offset + 2], @intCast(sample_word));
                out_offset += 2;
            } else {
                writeLeU32(output[out_offset .. out_offset + 4], sample_word);
                out_offset += 4;
            }
        }
    }

    return out_offset;
}

fn readLeU64(bytes: []const u8) u64 {
    var value: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        value |= @as(u64, bytes[i]) << @as(u6, @intCast(i * 8));
    }
    return value;
}

fn writeLeU16(dst: []u8, value: u16) void {
    dst[0] = @intCast(value & 0x00FF);
    dst[1] = @intCast((value >> 8) & 0x00FF);
}

fn writeLeU32(dst: []u8, value: u32) void {
    dst[0] = @intCast(value & 0x000000FF);
    dst[1] = @intCast((value >> 8) & 0x000000FF);
    dst[2] = @intCast((value >> 16) & 0x000000FF);
    dst[3] = @intCast((value >> 24) & 0x000000FF);
}

fn readLeU16(src: []const u8) u16 {
    return @as(u16, src[0]) | (@as(u16, src[1]) << 8);
}

fn readLeU32(src: []const u8) u32 {
    return @as(u32, src[0]) |
        (@as(u32, src[1]) << 8) |
        (@as(u32, src[2]) << 16) |
        (@as(u32, src[3]) << 24);
}

test "runRawWriter continuous mode ignores target_bytes limit" {
    var rb = try ringbuffer.RingBuffer.init(std.testing.allocator, 32);
    defer rb.deinit();

    const payload = [_]u8{ 0x10, 0x20, 0x30, 0x40, 0x50 };
    _ = rb.push(payload[0..]);

    var producer_done = std.atomic.Value(bool).init(true);
    var stop_requested = std.atomic.Value(bool).init(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("loop.bin", .{ .read = true });
    defer file.close();

    var writer_ctx = RawWriterContext{
        .ring = &rb,
        .file = file,
        .target_bytes = 1,
        .continuous = true,
        .producer_done = &producer_done,
        .stop_requested = &stop_requested,
    };
    runRawWriter(&writer_ctx);

    try std.testing.expect(!writer_ctx.failed.load(.acquire));
    try std.testing.expectEqual(@as(u64, payload.len), writer_ctx.bytes_written.load(.acquire));

    try file.seekTo(0);
    var written: [payload.len]u8 = undefined;
    const read_len = try file.readAll(written[0..]);
    try std.testing.expectEqual(payload.len, read_len);
    try std.testing.expectEqualSlices(u8, payload[0..], written[0..]);
}

test "decodeCrossDataChunk decodes 16-channel stripes into packed samples" {
    var input: [16 * 8]u8 = [_]u8{0} ** (16 * 8);
    var output: [16 * 8]u8 = [_]u8{0} ** (16 * 8);

    // CH0: 0101..., CH1..CH15: 0
    const ch0_word: u64 = 0xAAAA_AAAA_AAAA_AAAA;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        input[i] = @intCast((ch0_word >> @as(u6, @intCast(i * 8))) & 0xFF);
    }

    const produced = try decodeCrossDataChunk(16, input[0..], output[0..]);
    try std.testing.expectEqual(@as(usize, input.len), produced);

    var sample_index: usize = 0;
    while (sample_index < 64) : (sample_index += 1) {
        const sample = readLeU16(output[sample_index * 2 .. sample_index * 2 + 2]);
        const expected: u16 = if (sample_index % 2 == 0) 0 else 1;
        try std.testing.expectEqual(expected, sample);
    }
}

test "decodeCrossDataChunk decodes 32-channel stripes into packed samples" {
    var input: [32 * 8]u8 = [_]u8{0} ** (32 * 8);
    var output: [32 * 8]u8 = [_]u8{0} ** (32 * 8);

    const ch0_word: u64 = 0xAAAA_AAAA_AAAA_AAAA;
    const ch31_word: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        input[i] = @intCast((ch0_word >> @as(u6, @intCast(i * 8))) & 0xFF);
        input[31 * 8 + i] = @intCast((ch31_word >> @as(u6, @intCast(i * 8))) & 0xFF);
    }

    const produced = try decodeCrossDataChunk(32, input[0..], output[0..]);
    try std.testing.expectEqual(@as(usize, input.len), produced);

    var sample_index: usize = 0;
    while (sample_index < 64) : (sample_index += 1) {
        const sample = readLeU32(output[sample_index * 4 .. sample_index * 4 + 4]);
        const low_bit: u32 = if (sample_index % 2 == 0) 0 else 1;
        const expected: u32 = 0x8000_0000 | low_bit;
        try std.testing.expectEqual(expected, sample);
    }
}

const DecodeCarryProducer = struct {
    ring: *ringbuffer.RingBuffer,
    producer_done: *std.atomic.Value(bool),
    first_chunk: []const u8,
    second_chunk: []const u8,

    fn run(ctx: *DecodeCarryProducer) void {
        _ = ctx.ring.push(ctx.first_chunk);
        std.Thread.sleep(2 * std.time.ns_per_ms);
        _ = ctx.ring.push(ctx.second_chunk);
        ctx.producer_done.store(true, .release);
    }
};

test "runRawWriter decodes cross data across split chunks" {
    var rb = try ringbuffer.RingBuffer.init(std.testing.allocator, 512);
    defer rb.deinit();

    var input: [16 * 8 * 2]u8 = [_]u8{0} ** (16 * 8 * 2);
    const stripe_size = 16 * 8;

    const stripe_a: u64 = 0xAAAA_AAAA_AAAA_AAAA;
    const stripe_b: u64 = 0x5555_5555_5555_5555;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        input[i] = @intCast((stripe_a >> @as(u6, @intCast(i * 8))) & 0xFF);
        input[stripe_size + i] = @intCast((stripe_b >> @as(u6, @intCast(i * 8))) & 0xFF);
    }

    var producer_done = std.atomic.Value(bool).init(false);
    var stop_requested = std.atomic.Value(bool).init(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("decoded.bin", .{ .read = true });
    defer file.close();

    var writer_ctx = RawWriterContext{
        .ring = &rb,
        .file = file,
        .target_bytes = input.len,
        .decode_cross = true,
        .channel_count = 16,
        .producer_done = &producer_done,
        .stop_requested = &stop_requested,
    };

    var producer_ctx = DecodeCarryProducer{
        .ring = &rb,
        .producer_done = &producer_done,
        .first_chunk = input[0..192],
        .second_chunk = input[192..],
    };
    const producer_thread = try std.Thread.spawn(.{}, DecodeCarryProducer.run, .{&producer_ctx});
    defer producer_thread.join();

    runRawWriter(&writer_ctx);

    try std.testing.expect(!writer_ctx.failed.load(.acquire));
    try std.testing.expectEqual(@as(u64, input.len), writer_ctx.bytes_written.load(.acquire));

    try file.seekTo(0);
    var decoded: [16 * 8 * 2]u8 = undefined;
    const read_len = try file.readAll(decoded[0..]);
    try std.testing.expectEqual(decoded.len, read_len);

    var sample_index: usize = 0;
    while (sample_index < 64) : (sample_index += 1) {
        const sample = readLeU16(decoded[sample_index * 2 .. sample_index * 2 + 2]);
        const expected: u16 = if (sample_index % 2 == 0) 0 else 1;
        try std.testing.expectEqual(expected, sample);
    }

    sample_index = 0;
    while (sample_index < 64) : (sample_index += 1) {
        const offset = stripe_size + sample_index * 2;
        const sample = readLeU16(decoded[offset .. offset + 2]);
        const expected: u16 = if (sample_index % 2 == 0) 1 else 0;
        try std.testing.expectEqual(expected, sample);
    }
}

test "decodeCrossDataChunk rejects unsupported channel counts" {
    var input: [16]u8 = [_]u8{0} ** 16;
    var output: [16]u8 = [_]u8{0} ** 16;
    try std.testing.expectError(error.InvalidChannelCount, decodeCrossDataChunk(8, input[0..], output[0..]));
}
