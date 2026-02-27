const std = @import("std");
const args = @import("args");

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
            if (capture_cmd.time_ms != null) return error.UnexpectedTimeSetting;
            if (capture_cmd.op_mode != .stream) return error.UnexpectedOperationMode;
            if (capture_cmd.samplerate_hz != 24_000_000) return error.UnexpectedSamplerate;
        },
        else => return error.ExpectedCaptureCommand,
    }

    const time_argv = [_][]const u8{ "pxlobster", "--stdout", "--time", "100", "--samplerate", "10000000" };
    var time_cmd = try args.parseArgsFromSlice(&time_argv, std.heap.page_allocator);
    defer args.deinitCommand(&time_cmd, std.heap.page_allocator);
    switch (time_cmd) {
        .capture => |capture_cmd| {
            if (capture_cmd.time_ms == null or capture_cmd.time_ms.? != 100) return error.UnexpectedTimeValue;
            if (capture_cmd.sample_bytes != 0) return error.UnexpectedSampleBytes;
            if (capture_cmd.samplerate_hz != 10_000_000) return error.UnexpectedSamplerate;
        },
        else => return error.ExpectedCaptureCommand,
    }

    const time_samples_conflict_argv = [_][]const u8{ "pxlobster", "--stdout", "--time", "10", "--samples", "4096" };
    const time_samples_conflict = args.parseArgsFromSlice(&time_samples_conflict_argv, std.heap.page_allocator);
    if (time_samples_conflict) |_| {
        return error.ExpectedInvalidArgument;
    } else |err| {
        if (err != error.InvalidArgument) return err;
    }

    const time_loop_conflict_argv = [_][]const u8{ "pxlobster", "--stdout", "--time", "10", "--op-mode", "loop" };
    const time_loop_conflict = args.parseArgsFromSlice(&time_loop_conflict_argv, std.heap.page_allocator);
    if (time_loop_conflict) |_| {
        return error.ExpectedInvalidArgument;
    } else |err| {
        if (err != error.InvalidArgument) return err;
    }

    const conflict_argv = [_][]const u8{ "pxlobster", "--scan", "--stdout" };
    const conflict_result = args.parseArgsFromSlice(&conflict_argv, std.heap.page_allocator);
    if (conflict_result) |_| {
        return error.ExpectedInvalidArgument;
    } else |err| {
        if (err != error.InvalidArgument) return err;
    }
}
