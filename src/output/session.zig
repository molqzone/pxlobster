const std = @import("std");

pub const OutputFormat = enum {
    bin,
    sr,
};

pub const CaptureSessionStats = struct {
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    dropped: u64 = 0,
    elapsed_ms: u64 = 0,
    channel_count: u32 = 16,
};

pub const SessionMetadata = struct {
    samplerate_hz: u64,
    channel_count: u32,
    unitsize: u32,
    capturefile: []const u8 = "logic-1",
    sigrok_version: []const u8 = "0.5.2",
    probe_labels: ?[]const []const u8 = null,
};

pub fn versionFileContent() []const u8 {
    return "2";
}

pub fn unitsizeForChannelCount(channel_count: u32) !u32 {
    return switch (channel_count) {
        16 => 2,
        32 => 4,
        else => error.InvalidChannelCount,
    };
}

pub fn initMetadata(samplerate_hz: u64, channel_count: u32) !SessionMetadata {
    return .{
        .samplerate_hz = samplerate_hz,
        .channel_count = channel_count,
        .unitsize = try unitsizeForChannelCount(channel_count),
    };
}

pub fn renderMetadata(allocator: std.mem.Allocator, metadata: SessionMetadata) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "[global]\n");
    try appendFmtLine(allocator, &buffer, "sigrok version={s}\n", .{metadata.sigrok_version});
    try buffer.appendSlice(allocator, "\n[device 1]\n");
    try appendFmtLine(allocator, &buffer, "capturefile={s}\n", .{metadata.capturefile});
    try appendFmtLine(allocator, &buffer, "total probes={d}\n", .{metadata.channel_count});
    try appendFmtLine(allocator, &buffer, "samplerate={d}\n", .{metadata.samplerate_hz});
    try appendFmtLine(allocator, &buffer, "unitsize={d}\n", .{metadata.unitsize});

    var probe_index: u32 = 0;
    while (probe_index < metadata.channel_count) : (probe_index += 1) {
        const label = probeLabel(metadata, probe_index);
        try appendFmtLine(allocator, &buffer, "probe{d}={s}\n", .{ probe_index + 1, label });
    }

    return buffer.toOwnedSlice(allocator);
}

fn probeLabel(metadata: SessionMetadata, probe_index: u32) []const u8 {
    if (metadata.probe_labels) |labels| {
        if (probe_index < labels.len and labels[probe_index].len > 0) {
            return labels[probe_index];
        }
    }

    return switch (probe_index) {
        inline 0...31 => |value| blk: {
            const labels = [_][]const u8{
                "D0",  "D1",  "D2",  "D3",  "D4",  "D5",  "D6",  "D7",
                "D8",  "D9",  "D10", "D11", "D12", "D13", "D14", "D15",
                "D16", "D17", "D18", "D19", "D20", "D21", "D22", "D23",
                "D24", "D25", "D26", "D27", "D28", "D29", "D30", "D31",
            };
            break :blk labels[value];
        },
        else => "D?",
    };
}

fn appendFmtLine(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var line: [128]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&line, fmt, args);
    try buffer.appendSlice(allocator, rendered);
}

test "unitsizeForChannelCount supports 16 and 32 channels" {
    try std.testing.expectEqual(@as(u32, 2), try unitsizeForChannelCount(16));
    try std.testing.expectEqual(@as(u32, 4), try unitsizeForChannelCount(32));
    try std.testing.expectError(error.InvalidChannelCount, unitsizeForChannelCount(8));
}

test "renderMetadata emits required sigrok session fields" {
    const meta = try initMetadata(24_000_000, 16);
    const rendered = try renderMetadata(std.testing.allocator, meta);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "capturefile=logic-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "samplerate=24000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "total probes=16") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "unitsize=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "probe1=D0") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "probe16=D15") != null);
}

test "versionFileContent returns sigrok session version marker" {
    try std.testing.expectEqualStrings("2", versionFileContent());
}
