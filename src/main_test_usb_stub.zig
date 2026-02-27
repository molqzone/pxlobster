pub const DEFAULT_CAPTURE_SAMPLERATE_HZ: u64 = 250_000_000;
pub const DEFAULT_REGISTER_TIMEOUT_MS: u32 = 1000;
pub const REG_LOGIC_MODE: u32 = 0;

pub const OperationMode = enum {
    buffer,
    stream,
    loop,
};

pub fn isSupportedSamplerate(samplerate_hz: u64) bool {
    return switch (samplerate_hz) {
        1_000_000_000,
        800_000_000,
        500_000_000,
        400_000_000,
        250_000_000,
        200_000_000,
        125_000_000,
        100_000_000,
        50_000_000,
        25_000_000,
        24_000_000,
        20_000_000,
        10_000_000,
        5_000_000,
        4_000_000,
        2_000_000,
        1_000_000,
        500_000,
        400_000,
        200_000,
        100_000,
        50_000,
        40_000,
        20_000,
        10_000,
        5_000,
        2_000,
        => true,
        else => false,
    };
}

pub fn readRegister(_: anytype, _: u32, _: u32) !u32 {
    return error.UnsupportedInMainUnitTests;
}
