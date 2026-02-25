const std = @import("std");
const ringbuffer = @import("../ringbuffer.zig");

pub const writer_chunk_bytes: usize = 64 * 1024;

pub const RawWriterContext = struct {
    ring: *ringbuffer.RingBuffer,
    file: std.fs.File,
    target_bytes: usize,
    producer_done: *std.atomic.Value(bool),
    stop_requested: *std.atomic.Value(bool),
    bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub fn runRawWriter(ctx: *RawWriterContext) void {
    var scratch: [writer_chunk_bytes]u8 = undefined;
    var written: usize = 0;

    while (written < ctx.target_bytes) {
        const remaining = ctx.target_bytes - written;
        const want = @min(remaining, scratch.len);
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
    if (written >= ctx.target_bytes) {
        ctx.stop_requested.store(true, .release);
    }

    ctx.file.sync() catch {
        ctx.failed.store(true, .release);
        ctx.stop_requested.store(true, .release);
    };
}
