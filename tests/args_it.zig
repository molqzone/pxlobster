const std = @import("std");
const args = @import("args");

pub fn main() !void {
    var cmd = try args.parseArgsFromSlice(&[_][]const u8{
        "pxlobster",
        "--stdout",
        "--samples",
        "65536",
        "--mode",
        "stream",
        "--triggers",
        "0=1,1=r",
        "--samplerate",
        "25000000",
    }, std.heap.page_allocator);
    defer args.deinitParsedCommand(&cmd, std.heap.page_allocator);

    switch (cmd.command) {
        .capture => |capture_cmd| {
            switch (capture_cmd.output_target) {
                .stdout => {},
                else => return error.ExpectedStdoutTarget,
            }
            if (capture_cmd.sample_bytes != 65_536) return error.UnexpectedSampleBytes;
            if (capture_cmd.time_ms != null) return error.UnexpectedTimeSetting;
            if (capture_cmd.op_mode != .stream) return error.UnexpectedOperationMode;
            if (capture_cmd.samplerate_hz != 25_000_000) return error.UnexpectedSamplerate;
            if (capture_cmd.trigger_one != 0x1) return error.UnexpectedTriggerOneMask;
            if (capture_cmd.trigger_rise != 0x2) return error.UnexpectedTriggerRiseMask;
            if (!capture_cmd.triggers_specified) return error.ExpectedTriggersSpecified;
        },
        else => return error.ExpectedCaptureCommand,
    }

    const short_trigger_argv = [_][]const u8{ "pxlobster", "--stdout", "-t", "2=f,3=0", "-v" };
    var short_trigger_result = try args.parseArgsFromSlice(&short_trigger_argv, std.heap.page_allocator);
    defer args.deinitParsedCommand(&short_trigger_result, std.heap.page_allocator);
    if (!short_trigger_result.verbose) return error.ExpectedVerbose;
    switch (short_trigger_result.command) {
        .capture => |capture_cmd| {
            if (capture_cmd.trigger_fall != (1 << 2)) return error.UnexpectedTriggerFallMask;
            if (capture_cmd.trigger_zero != (1 << 3)) return error.UnexpectedTriggerZeroMask;
            if (!capture_cmd.triggers_specified) return error.ExpectedTriggersSpecified;
        },
        else => return error.ExpectedCaptureCommand,
    }

    const time_argv = [_][]const u8{ "pxlobster", "--stdout", "--time", "100", "--samplerate", "10000000" };
    var time_cmd = try args.parseArgsFromSlice(&time_argv, std.heap.page_allocator);
    defer args.deinitParsedCommand(&time_cmd, std.heap.page_allocator);
    switch (time_cmd.command) {
        .capture => |capture_cmd| {
            if (capture_cmd.time_ms == null or capture_cmd.time_ms.? != 100) return error.UnexpectedTimeValue;
            if (capture_cmd.sample_bytes != 0) return error.UnexpectedSampleBytes;
            if (capture_cmd.samplerate_hz != 10_000_000) return error.UnexpectedSamplerate;
            if (capture_cmd.triggers_specified) return error.UnexpectedTriggersSpecified;
        },
        else => return error.ExpectedCaptureCommand,
    }

    const scan_verbose_argv = [_][]const u8{ "pxlobster", "--scan", "--verbose" };
    var scan_verbose_result = try args.parseArgsFromSlice(&scan_verbose_argv, std.heap.page_allocator);
    defer args.deinitParsedCommand(&scan_verbose_result, std.heap.page_allocator);
    if (!scan_verbose_result.verbose) return error.ExpectedVerbose;
    switch (scan_verbose_result.command) {
        .scan => {},
        else => return error.ExpectedScanCommand,
    }

    const prime_verbose_argv = [_][]const u8{ "pxlobster", "--prime-fw", "-v" };
    var prime_verbose_result = try args.parseArgsFromSlice(&prime_verbose_argv, std.heap.page_allocator);
    defer args.deinitParsedCommand(&prime_verbose_result, std.heap.page_allocator);
    if (!prime_verbose_result.verbose) return error.ExpectedVerbose;
    switch (prime_verbose_result.command) {
        .prime_fw => {},
        else => return error.ExpectedPrimeFwCommand,
    }

    const time_samples_conflict_argv = [_][]const u8{ "pxlobster", "--stdout", "--time", "10", "--samples", "4096" };
    const time_samples_conflict = args.parseArgsFromSlice(&time_samples_conflict_argv, std.heap.page_allocator);
    if (time_samples_conflict) |_| {
        return error.ExpectedInvalidArgument;
    } else |err| {
        if (err != error.InvalidArgument) return err;
    }

    const time_loop_conflict_argv = [_][]const u8{ "pxlobster", "--stdout", "--time", "10", "--mode", "loop" };
    const time_loop_conflict = args.parseArgsFromSlice(&time_loop_conflict_argv, std.heap.page_allocator);
    if (time_loop_conflict) |_| {
        return error.ExpectedInvalidArgument;
    } else |err| {
        if (err != error.InvalidArgument) return err;
    }

    const invalid_trigger_argv = [_][]const u8{ "pxlobster", "--stdout", "--triggers", "0=x" };
    const invalid_trigger = args.parseArgsFromSlice(&invalid_trigger_argv, std.heap.page_allocator);
    if (invalid_trigger) |_| {
        return error.ExpectedInvalidArgument;
    } else |err| {
        if (err != error.InvalidArgument) return err;
    }

    const removed_config_argv = [_][]const u8{ "pxlobster", "--stdout", "--config", "samplerate=25000000" };
    const removed_config = args.parseArgsFromSlice(&removed_config_argv, std.heap.page_allocator);
    if (removed_config) |_| {
        return error.ExpectedInvalidArgument;
    } else |err| {
        if (err != error.InvalidArgument) return err;
    }

    const legacy_samplerate_argv = [_][]const u8{ "pxlobster", "--stdout", "--samplerate", "24000000" };
    const legacy_samplerate = args.parseArgsFromSlice(&legacy_samplerate_argv, std.heap.page_allocator);
    if (legacy_samplerate) |_| {
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
