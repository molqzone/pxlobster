const std = @import("std");
const args = @import("args.zig");

pub fn main() !void {
    var cmd = try args.parseArgsFromSlice(&[_][]const u8{
        "pxlobster",
        "--stdout",
        "--samples",
        "65536",
        "--op-mode",
        "stream",
        "--samplerate",
        "24000000",
    }, std.heap.page_allocator);
    defer args.deinitCommand(&cmd, std.heap.page_allocator);

    switch (cmd) {
        .capture => |capture_cmd| {
            switch (capture_cmd.output_target) {
                .stdout => {},
                else => return error.ExpectedStdoutTarget,
            }
            if (capture_cmd.sample_bytes != 65_536) return error.UnexpectedSampleBytes;
            if (capture_cmd.op_mode != .stream) return error.UnexpectedOperationMode;
            if (capture_cmd.samplerate_hz != 24_000_000) return error.UnexpectedSamplerate;
        },
        else => return error.ExpectedCaptureCommand,
    }

    const conflict_argv = [_][]const u8{ "pxlobster", "--scan", "--stdout" };
    const conflict_result = args.parseArgsFromSlice(&conflict_argv, std.heap.page_allocator);
    if (conflict_result) |_| {
        return error.ExpectedInvalidArgument;
    } else |err| {
        if (err != error.InvalidArgument) return err;
    }
}
