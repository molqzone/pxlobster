const std = @import("std");

pub const default_capture_samplerate_hz: u64 = 250_000_000;

pub const GpioTiming = struct {
    mode: u32,
    div: u32,
};

pub fn isSupportedSamplerate(samplerate_hz: u64) bool {
    _ = gpioTimingForSamplerate(samplerate_hz) catch return false;
    return true;
}

pub fn gpioTimingForSamplerate(samplerate_hz: u64) !GpioTiming {
    return switch (samplerate_hz) {
        1_000_000_000 => .{ .mode = 0, .div = 0 },
        500_000_000 => .{ .mode = 1, .div = 0 },
        250_000_000 => .{ .mode = 2, .div = 0 },
        125_000_000 => .{ .mode = 3, .div = 0 },
        800_000_000 => .{ .mode = 4, .div = 0 },
        400_000_000 => .{ .mode = 5, .div = 0 },
        200_000_000 => .{ .mode = 6, .div = 0 },
        100_000_000 => .{ .mode = 7, .div = 0 },
        else => .{
            .mode = 7,
            .div = switch (samplerate_hz) {
                50_000_000 => 1,
                25_000_000 => 3,
                // 24 MHz is accepted for CLI compatibility and mapped to the nearest
                // PXView-supported divider profile.
                24_000_000 => 3,
                20_000_000 => 4,
                10_000_000 => 9,
                5_000_000 => 19,
                4_000_000 => 24,
                2_000_000 => 49,
                1_000_000 => 99,
                500_000 => 199,
                400_000 => 249,
                200_000 => 499,
                100_000 => 999,
                50_000 => 1_999,
                40_000 => 2_499,
                20_000 => 4_999,
                10_000 => 9_999,
                5_000 => 19_999,
                2_000 => 49_999,
                else => return error.InvalidSamplerate,
            },
        },
    };
}

test "gpioTimingForSamplerate matches pxview table" {
    try std.testing.expectEqualDeep(GpioTiming{ .mode = 2, .div = 0 }, try gpioTimingForSamplerate(250_000_000));
    try std.testing.expectEqualDeep(GpioTiming{ .mode = 7, .div = 9 }, try gpioTimingForSamplerate(10_000_000));
    try std.testing.expectEqualDeep(GpioTiming{ .mode = 7, .div = 3 }, try gpioTimingForSamplerate(24_000_000));
    try std.testing.expectEqualDeep(GpioTiming{ .mode = 7, .div = 49_999 }, try gpioTimingForSamplerate(2_000));
    try std.testing.expectError(error.InvalidSamplerate, gpioTimingForSamplerate(12_345));
}

test "isSupportedSamplerate accepts only pxview rates" {
    try std.testing.expect(isSupportedSamplerate(250_000_000));
    try std.testing.expect(isSupportedSamplerate(10_000_000));
    try std.testing.expect(isSupportedSamplerate(24_000_000));
    try std.testing.expect(!isSupportedSamplerate(0));
    try std.testing.expect(!isSupportedSamplerate(12_345));
}
