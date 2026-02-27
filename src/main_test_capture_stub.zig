const std = @import("std");
const usb = @import("main_test_usb_stub.zig");

pub const OutputFormat = enum {
    bin,
    sr,
};

pub const CaptureOutputTarget = union(enum) {
    file_path: []const u8,
    stdout,
};

pub const CaptureSessionStats = struct {
    bytes_out: u64 = 0,
    bytes_in: u64 = 0,
    dropped: u64 = 0,
    elapsed_ms: u64 = 0,
};

pub const CaptureProfile = struct {
    op_mode: usb.OperationMode = .buffer,
    samplerate_hz: u64 = usb.DEFAULT_CAPTURE_SAMPLERATE_HZ,
};

pub const CaptureOptions = struct {
    output_target: CaptureOutputTarget,
    sample_bytes: usize,
    output_format: OutputFormat = .bin,
    decode_cross: bool = false,
    capture_profile: CaptureProfile = .{},
};

pub fn runCapture(_: std.mem.Allocator, _: anytype, _: CaptureOptions) !CaptureSessionStats {
    return .{};
}
