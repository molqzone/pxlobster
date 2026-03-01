const std = @import("std");
const caps = @import("caps.zig");
const clap = @import("clap");

/// 默认采集字节数（当 `--samples` 与 `--time` 都未设置时使用） / Default capture size used when neither `--samples` nor `--time` is set.
pub const default_capture_samples_bytes: usize = 8 * 1024 * 1024;
const default_capture_samplerate_hz: u64 = caps.default_capture_samplerate_hz;

/// 调用方显式选择的输出编码 / Output encoding chosen by the caller.
pub const OutputFormat = enum {
    bin,
    sr,
};

/// 采集数据输出目标位置 / Capture sink location.
pub const OutputTarget = union(enum) {
    file_path: []const u8,
    stdout,
};

const OperationMode = caps.OperationMode;

pub const TriggerMasks = struct {
    trigger_zero: u32 = 0,
    trigger_one: u32 = 0,
    trigger_rise: u32 = 0,
    trigger_fall: u32 = 0,
};

/// 供运行时采集逻辑直接消费的完整命令结构 / Fully resolved capture command consumed by runtime capture logic.
pub const CaptureCommand = struct {
    output_target: OutputTarget,
    output_format: OutputFormat = .bin,
    sample_bytes: usize = default_capture_samples_bytes,
    time_ms: ?u64 = null,
    decode_cross: bool = false,
    op_mode: OperationMode = .buffer,
    samplerate_hz: u64 = default_capture_samplerate_hz,
    trigger_zero: u32 = 0,
    trigger_one: u32 = 0,
    trigger_rise: u32 = 0,
    trigger_fall: u32 = 0,
    triggers_specified: bool = false,
    owns_output_path: bool = false,
};

/// 命令解析结果包装，携带选中的子命令与全局标志 / Parse result wrapper carrying the selected command and global flags.
pub const ParsedCommand = struct {
    command: Command,
    verbose: bool = false,
};

/// 顶层 CLI 子命令选择 / Top-level CLI command selection.
pub const Command = union(enum) {
    scan,
    prime_fw,
    stop,
    capture: CaptureCommand,
};

const clap_params = clap.parseParamsComptime(
    \\-h, --help
    \\-v, --verbose
    \\    --scan
    \\    --prime-fw
    \\    --stop
    \\-o, --output-file <str>...
    \\    --stdout
    \\    --format <str>...
    \\    --samples <usize>...
    \\    --time <u64>...
    \\    --decode-cross
    \\    --mode <str>...
    \\-t, --triggers <str>...
    \\    --samplerate <u64>...
    \\
);

pub fn parseArgs() !ParsedCommand {
    var diag = clap.Diagnostic{};
    var result = clap.parse(clap.Help, &clap_params, clap.parsers.default, .{
        .allocator = std.heap.page_allocator,
        .diagnostic = &diag,
    }) catch return error.InvalidArgument;
    defer result.deinit();

    var parsed = try commandFromParsedArgs(result.args);
    try detachOutputPathIfNeeded(&parsed.command, std.heap.page_allocator);
    return parsed;
}

/// 测试/辅助解析入口：接收显式 argv 切片和分配器 / Test/helper parser that accepts an explicit argv slice and allocator.
pub fn parseArgsFromSlice(args: []const []const u8, allocator: std.mem.Allocator) !ParsedCommand {
    const clap_args = if (args.len > 0) args[1..] else args;
    var iter = clap.args.SliceIterator{ .args = clap_args };
    var diag = clap.Diagnostic{};
    var result = clap.parseEx(clap.Help, &clap_params, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch return error.InvalidArgument;
    defer result.deinit();

    var parsed = try commandFromParsedArgs(result.args);
    try detachOutputPathIfNeeded(&parsed.command, allocator);
    return parsed;
}

/// 释放解析结果中由堆分配并归当前命令持有的字段 / Releases heap-owned fields inside a parsed command.
pub fn deinitParsedCommand(parsed: *ParsedCommand, allocator: std.mem.Allocator) void {
    deinitCommand(&parsed.command, allocator);
}

fn deinitCommand(cmd: *Command, allocator: std.mem.Allocator) void {
    switch (cmd.*) {
        .capture => |*capture_cmd| {
            if (!capture_cmd.owns_output_path) return;
            switch (capture_cmd.output_target) {
                .file_path => |path| allocator.free(path),
                .stdout => {},
            }
            capture_cmd.owns_output_path = false;
        },
        else => {},
    }
}

fn commandFromParsedArgs(parsed_args: anytype) !ParsedCommand {
    if (@field(parsed_args, "help") > 0) return error.ShowHelp;
    const verbose = @field(parsed_args, "verbose") > 0;

    const scan_count = @field(parsed_args, "scan");
    const prime_fw_count = @field(parsed_args, "prime-fw");
    const stop_count = @field(parsed_args, "stop");
    if (scan_count + prime_fw_count + stop_count > 1) return error.InvalidArgument;

    var requested_read_only: ?enum { scan, prime_fw, stop } = null;
    if (scan_count > 0) requested_read_only = .scan;
    if (prime_fw_count > 0) requested_read_only = .prime_fw;
    if (stop_count > 0) requested_read_only = .stop;

    const output_paths: []const []const u8 = @field(parsed_args, "output-file");
    const output_path = lastValue([]const u8, output_paths);
    if (output_path != null and output_path.?.len == 0) return error.InvalidArgument;
    const output_stdout = @field(parsed_args, "stdout") > 0;

    var output_format: ?OutputFormat = null;
    var output_format_set = false;
    const format_values: []const []const u8 = @field(parsed_args, "format");
    if (lastValue([]const u8, format_values)) |value| {
        output_format = parseOutputFormat(value) orelse return error.InvalidArgument;
        output_format_set = true;
    }

    var samplerate_hz: u64 = default_capture_samplerate_hz;
    var samplerate_set = false;

    var sample_bytes: usize = default_capture_samples_bytes;
    var samples_set = false;
    const sample_values: []const usize = @field(parsed_args, "samples");
    if (lastValue(usize, sample_values)) |value| {
        if (value == 0) return error.InvalidArgument;
        sample_bytes = value;
        samples_set = true;
    }

    var time_ms: ?u64 = null;
    var time_set = false;
    const time_values: []const u64 = @field(parsed_args, "time");
    if (lastValue(u64, time_values)) |value| {
        if (value == 0) return error.InvalidArgument;
        time_ms = value;
        time_set = true;
    }
    if (samples_set and time_set) return error.InvalidArgument;
    if (time_set) sample_bytes = 0;

    const decode_cross = @field(parsed_args, "decode-cross") > 0;

    var op_mode: OperationMode = .buffer;
    var op_mode_set = false;
    const op_mode_values: []const []const u8 = @field(parsed_args, "mode");
    if (lastValue([]const u8, op_mode_values)) |value| {
        op_mode = parseOpMode(value) orelse return error.InvalidArgument;
        op_mode_set = true;
    }
    if (time_set and op_mode == .loop) return error.InvalidArgument;

    const samplerate_values: []const u64 = @field(parsed_args, "samplerate");
    if (lastValue(u64, samplerate_values)) |value| {
        samplerate_hz = parseSamplerateValue(value) orelse return error.InvalidArgument;
        samplerate_set = true;
    }

    var trigger_masks: TriggerMasks = .{};
    var triggers_set = false;
    const trigger_values: []const []const u8 = @field(parsed_args, "triggers");
    if (lastValue([]const u8, trigger_values)) |value| {
        trigger_masks = parseTriggerSpec(value) orelse return error.InvalidArgument;
        triggers_set = true;
    }

    const capture_requested = output_path != null or output_stdout or output_format_set or samples_set or time_set or decode_cross or op_mode_set or samplerate_set or triggers_set;
    if (requested_read_only != null and capture_requested) return error.InvalidArgument;

    if (requested_read_only) |command| {
        return .{
            .command = switch (command) {
                .scan => .scan,
                .prime_fw => .prime_fw,
                .stop => .stop,
            },
            .verbose = verbose,
        };
    }

    return .{
        .command = .{ .capture = try buildCaptureCommand(
            output_path,
            output_stdout,
            output_format,
            sample_bytes,
            time_ms,
            decode_cross,
            op_mode,
            samplerate_hz,
            trigger_masks,
            triggers_set,
        ) },
        .verbose = verbose,
    };
}

/// 对可重复参数返回最后一次出现的值 / Returns the last parsed value for options that may be repeated.
fn lastValue(comptime T: type, values: []const T) ?T {
    if (values.len == 0) return null;
    return values[values.len - 1];
}

/// 将采集相关参数归一化并校验后构建 `CaptureCommand` / Normalizes capture-related flags into a validated `CaptureCommand`.
fn buildCaptureCommand(
    output_path: ?[]const u8,
    output_stdout: bool,
    output_format: ?OutputFormat,
    sample_bytes: usize,
    time_ms: ?u64,
    decode_cross: bool,
    op_mode: OperationMode,
    samplerate_hz: u64,
    trigger_masks: TriggerMasks,
    triggers_specified: bool,
) !CaptureCommand {
    if (output_stdout and output_path != null) return error.InvalidArgument;
    const selected_output_format = output_format orelse return error.InvalidArgument;

    if (output_stdout) {
        if (selected_output_format == .sr) return error.InvalidArgument;
        return .{
            .output_target = .stdout,
            .output_format = selected_output_format,
            .sample_bytes = sample_bytes,
            .time_ms = time_ms,
            .decode_cross = decode_cross,
            .op_mode = op_mode,
            .samplerate_hz = samplerate_hz,
            .trigger_zero = trigger_masks.trigger_zero,
            .trigger_one = trigger_masks.trigger_one,
            .trigger_rise = trigger_masks.trigger_rise,
            .trigger_fall = trigger_masks.trigger_fall,
            .triggers_specified = triggers_specified,
        };
    }

    if (output_path) |path| {
        return .{
            .output_target = .{ .file_path = path },
            .output_format = selected_output_format,
            .sample_bytes = sample_bytes,
            .time_ms = time_ms,
            .decode_cross = if (selected_output_format == .sr) true else decode_cross,
            .op_mode = op_mode,
            .samplerate_hz = samplerate_hz,
            .trigger_zero = trigger_masks.trigger_zero,
            .trigger_one = trigger_masks.trigger_one,
            .trigger_rise = trigger_masks.trigger_rise,
            .trigger_fall = trigger_masks.trigger_fall,
            .triggers_specified = triggers_specified,
        };
    }

    return error.InvalidArgument;
}

/// 复制文件路径输出目标，使其由调用方分配器统一持有与释放 / Duplicates any file-path output target so caller-controlled allocator owns it.
fn detachOutputPathIfNeeded(cmd: *Command, allocator: std.mem.Allocator) !void {
    switch (cmd.*) {
        .capture => |*capture_cmd| switch (capture_cmd.output_target) {
            .file_path => |path| {
                const owned = try allocator.dupe(u8, path);
                capture_cmd.output_target = .{ .file_path = owned };
                capture_cmd.owns_output_path = true;
            },
            .stdout => {},
        },
        else => {},
    }
}

/// 解析 `--mode` 选项值 / Parses `--mode` option values.
fn parseOpMode(value: []const u8) ?OperationMode {
    if (std.mem.eql(u8, value, "buffer")) return .buffer;
    if (std.mem.eql(u8, value, "stream")) return .stream;
    if (std.mem.eql(u8, value, "loop")) return .loop;
    return null;
}

/// 解析 `--format` 选项值 / Parses `--format` option values.
fn parseOutputFormat(value: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, value, "bin")) return .bin;
    if (std.mem.eql(u8, value, "sr")) return .sr;
    return null;
}

/// 解析 `-t/--triggers` 规则串，格式为 `channel=state` 条目 / Parses `-t/--triggers` spec in the form `channel=state` entries.
fn parseTriggerSpec(value: []const u8) ?TriggerMasks {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;

    var masks: TriggerMasks = .{};
    var entries = std.mem.splitScalar(u8, trimmed, ',');
    var has_entry = false;
    while (entries.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " \t\r\n");
        if (entry.len == 0) return null;

        const separator = std.mem.indexOfScalar(u8, entry, '=') orelse return null;
        const channel_text = std.mem.trim(u8, entry[0..separator], " \t\r\n");
        const state_text = std.mem.trim(u8, entry[separator + 1 ..], " \t\r\n");
        if (channel_text.len == 0 or state_text.len != 1) return null;

        const channel_index = std.fmt.parseInt(u6, channel_text, 10) catch return null;
        if (channel_index >= 32) return null;
        const shift: u5 = @intCast(channel_index);
        const bit: u32 = @as(u32, 1) << shift;

        masks.trigger_zero &= ~bit;
        masks.trigger_one &= ~bit;
        masks.trigger_rise &= ~bit;
        masks.trigger_fall &= ~bit;

        switch (std.ascii.toLower(state_text[0])) {
            '0' => masks.trigger_zero |= bit,
            '1' => masks.trigger_one |= bit,
            'r' => masks.trigger_rise |= bit,
            'f' => masks.trigger_fall |= bit,
            else => return null,
        }

        has_entry = true;
    }

    if (!has_entry) return null;
    return masks;
}

/// 解析采样率并强制为受支持的离散值 / Parses samplerate string and enforces supported discrete values.
fn parseSamplerate(value: []const u8) ?u64 {
    const samplerate = std.fmt.parseInt(u64, value, 10) catch return null;
    return parseSamplerateValue(samplerate);
}

/// 按 PXView 兼容离散集合校验采样率 / Validates samplerate against PXView-compatible discrete set.
fn parseSamplerateValue(samplerate: u64) ?u64 {
    if (!caps.isSupportedSamplerate(samplerate)) return null;
    return samplerate;
}

test "parseArgsFromSlice parses stdout capture options" {
    const argv = [_][]const u8{
        "pxlobster",
        "--stdout",
        "--format",
        "bin",
        "--samples",
        "65536",
        "--mode",
        "stream",
        "--triggers",
        "0=1,1=r,2=f,3=0",
        "--samplerate",
        "25000000",
    };

    const parsed = try parseArgsFromSlice(&argv, std.testing.allocator);
    switch (parsed.command) {
        .capture => |capture_cmd| {
            switch (capture_cmd.output_target) {
                .stdout => {},
                else => return error.TestExpectedEqual,
            }
            try std.testing.expectEqual(OutputFormat.bin, capture_cmd.output_format);
            try std.testing.expectEqual(@as(usize, 65_536), capture_cmd.sample_bytes);
            try std.testing.expect(capture_cmd.time_ms == null);
            try std.testing.expectEqual(OperationMode.stream, capture_cmd.op_mode);
            try std.testing.expectEqual(@as(u64, 25_000_000), capture_cmd.samplerate_hz);
            try std.testing.expectEqual(@as(u32, 1 << 3), capture_cmd.trigger_zero);
            try std.testing.expectEqual(@as(u32, 1 << 0), capture_cmd.trigger_one);
            try std.testing.expectEqual(@as(u32, 1 << 1), capture_cmd.trigger_rise);
            try std.testing.expectEqual(@as(u32, 1 << 2), capture_cmd.trigger_fall);
            try std.testing.expect(capture_cmd.triggers_specified);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parseArgsFromSlice accepts short -t trigger option" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "-t", "2=f,3=0" };
    const parsed = try parseArgsFromSlice(&argv, std.testing.allocator);
    switch (parsed.command) {
        .capture => |capture_cmd| {
            try std.testing.expectEqual(@as(u32, 1 << 2), capture_cmd.trigger_fall);
            try std.testing.expectEqual(@as(u32, 1 << 3), capture_cmd.trigger_zero);
            try std.testing.expect(capture_cmd.triggers_specified);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parseArgsFromSlice leaves triggers_specified false by default" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "--samples", "1024" };
    const parsed = try parseArgsFromSlice(&argv, std.testing.allocator);
    switch (parsed.command) {
        .capture => |capture_cmd| {
            try std.testing.expect(!capture_cmd.triggers_specified);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parseArgsFromSlice enables verbose for capture and scan commands" {
    const capture_argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "--samples", "1024", "-v" };
    const capture_result = try parseArgsFromSlice(&capture_argv, std.testing.allocator);
    switch (capture_result.command) {
        .capture => {},
        else => return error.TestExpectedEqual,
    }
    try std.testing.expect(capture_result.verbose);

    const scan_argv = [_][]const u8{ "pxlobster", "--scan", "--verbose" };
    const scan_result = try parseArgsFromSlice(&scan_argv, std.testing.allocator);
    switch (scan_result.command) {
        .scan => {},
        else => return error.TestExpectedEqual,
    }
    try std.testing.expect(scan_result.verbose);
}

test "parseArgsFromSlice parses stop command with verbose" {
    const stop_argv = [_][]const u8{ "pxlobster", "--stop", "--verbose" };
    const stop_result = try parseArgsFromSlice(&stop_argv, std.testing.allocator);
    switch (stop_result.command) {
        .stop => {},
        else => return error.TestExpectedEqual,
    }
    try std.testing.expect(stop_result.verbose);
}

test "parseArgsFromSlice rejects stdout and output-file conflict" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "-o", "capture.bin" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects missing option values" {
    const missing_output = [_][]const u8{ "pxlobster", "-o" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&missing_output, std.testing.allocator));

    const missing_samples = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "--samples" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&missing_samples, std.testing.allocator));
}

test "parseArgsFromSlice returns ShowHelp for --help" {
    const argv = [_][]const u8{ "pxlobster", "--help" };
    try std.testing.expectError(error.ShowHelp, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice accepts samplerate from --samplerate" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "--samplerate", "25000000" };
    const parsed = try parseArgsFromSlice(&argv, std.testing.allocator);
    switch (parsed.command) {
        .capture => |capture_cmd| try std.testing.expectEqual(@as(u64, 25_000_000), capture_cmd.samplerate_hz),
        else => return error.TestExpectedEqual,
    }
}

test "parseArgsFromSlice rejects invalid mode" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "--mode", "invalid" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects invalid trigger spec" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "--triggers", "0=x" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects unsupported samplerate" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "--samplerate", "123456789" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
    const legacy_argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "--samplerate", "24000000" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&legacy_argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects removed --config option" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "--config", "samplerate=25000000" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice accepts capture time in milliseconds" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "--time", "250", "--samplerate", "10000000" };
    const parsed = try parseArgsFromSlice(&argv, std.testing.allocator);
    switch (parsed.command) {
        .capture => |capture_cmd| {
            try std.testing.expectEqual(@as(?u64, 250), capture_cmd.time_ms);
            try std.testing.expectEqual(@as(usize, 0), capture_cmd.sample_bytes);
            try std.testing.expectEqual(@as(u64, 10_000_000), capture_cmd.samplerate_hz);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parseArgsFromSlice rejects time and samples together" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "--samples", "4096", "--time", "10" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects zero time" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "--time", "0" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects loop mode with time" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "bin", "--time", "10", "--mode", "loop" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice keeps scan and capture mutually exclusive" {
    const argv = [_][]const u8{ "pxlobster", "--scan", "--stdout" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice keeps stop mutually exclusive with other command groups" {
    const scan_stop = [_][]const u8{ "pxlobster", "--scan", "--stop" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&scan_stop, std.testing.allocator));

    const stop_capture = [_][]const u8{ "pxlobster", "--stop", "--stdout", "--format", "bin" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&stop_capture, std.testing.allocator));
}

test "parseOpMode accepts supported values" {
    try std.testing.expectEqual(OperationMode.buffer, parseOpMode("buffer").?);
    try std.testing.expectEqual(OperationMode.stream, parseOpMode("stream").?);
    try std.testing.expectEqual(OperationMode.loop, parseOpMode("loop").?);
    try std.testing.expect(parseOpMode("invalid") == null);
}

test "parseOutputFormat accepts supported values" {
    try std.testing.expectEqual(OutputFormat.bin, parseOutputFormat("bin").?);
    try std.testing.expectEqual(OutputFormat.sr, parseOutputFormat("sr").?);
    try std.testing.expect(parseOutputFormat("json") == null);
}

test "parseArgsFromSlice requires explicit output format for capture" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--samples", "1024" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice requires explicit output format for output-file target" {
    const argv = [_][]const u8{ "pxlobster", "-o", "capture.bin", "--samples", "1024" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects invalid output format value" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "json", "--samples", "1024" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects sr format with stdout target" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--format", "sr", "--samples", "1024" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice uses explicit format regardless of output-file extension" {
    const argv = [_][]const u8{ "pxlobster", "-o", "capture.sr", "--format", "bin", "--samples", "2048" };
    var parsed = try parseArgsFromSlice(&argv, std.testing.allocator);
    defer deinitParsedCommand(&parsed, std.testing.allocator);
    switch (parsed.command) {
        .capture => |capture_cmd| {
            try std.testing.expectEqual(OutputFormat.bin, capture_cmd.output_format);
            try std.testing.expect(!capture_cmd.decode_cross);
            switch (capture_cmd.output_target) {
                .file_path => |path| try std.testing.expectEqualStrings("capture.sr", path),
                else => return error.TestExpectedEqual,
            }
        },
        else => return error.TestExpectedEqual,
    }
}

test "parseTriggerSpec accepts level and edge mappings" {
    const masks = parseTriggerSpec("0=1, 1=r, 2=f, 3=0").?;
    try std.testing.expectEqual(@as(u32, 1 << 3), masks.trigger_zero);
    try std.testing.expectEqual(@as(u32, 1 << 0), masks.trigger_one);
    try std.testing.expectEqual(@as(u32, 1 << 1), masks.trigger_rise);
    try std.testing.expectEqual(@as(u32, 1 << 2), masks.trigger_fall);
}

test "parseTriggerSpec keeps last assignment for duplicate channels" {
    const masks = parseTriggerSpec("0=1,0=f").?;
    try std.testing.expectEqual(@as(u32, 0), masks.trigger_zero);
    try std.testing.expectEqual(@as(u32, 0), masks.trigger_one);
    try std.testing.expectEqual(@as(u32, 0), masks.trigger_rise);
    try std.testing.expectEqual(@as(u32, 1), masks.trigger_fall);
}

test "parseTriggerSpec rejects malformed values" {
    try std.testing.expect(parseTriggerSpec("") == null);
    try std.testing.expect(parseTriggerSpec("0=x") == null);
    try std.testing.expect(parseTriggerSpec("32=1") == null);
    try std.testing.expect(parseTriggerSpec("a=1") == null);
    try std.testing.expect(parseTriggerSpec("0=1,") == null);
    try std.testing.expect(parseTriggerSpec("0=1=2") == null);
}

test "parseSamplerate accepts only supported discrete values" {
    try std.testing.expectEqual(@as(u64, 250_000_000), parseSamplerate("250000000").?);
    try std.testing.expectEqual(@as(u64, 25_000_000), parseSamplerate("25000000").?);
    try std.testing.expectEqual(@as(u64, 10_000_000), parseSamplerate("10000000").?);
    try std.testing.expect(parseSamplerate("24000000") == null);
    try std.testing.expect(parseSamplerate("123456789") == null);
    try std.testing.expect(parseSamplerate("0") == null);
    try std.testing.expect(parseSamplerate("abc") == null);
}

test "buildCaptureCommand selects stdout raw output" {
    const cmd = try buildCaptureCommand(null, true, .bin, 4096, null, true, .stream, 25_000_000, .{
        .trigger_zero = 0xA,
        .trigger_one = 0xB,
        .trigger_rise = 0xC,
        .trigger_fall = 0xD,
    }, true);
    try std.testing.expectEqual(OutputFormat.bin, cmd.output_format);
    try std.testing.expectEqual(@as(usize, 4096), cmd.sample_bytes);
    try std.testing.expectEqual(@as(?u64, null), cmd.time_ms);
    try std.testing.expectEqual(true, cmd.decode_cross);
    try std.testing.expectEqual(OperationMode.stream, cmd.op_mode);
    try std.testing.expectEqual(@as(u64, 25_000_000), cmd.samplerate_hz);
    try std.testing.expectEqual(@as(u32, 0xA), cmd.trigger_zero);
    try std.testing.expectEqual(@as(u32, 0xB), cmd.trigger_one);
    try std.testing.expectEqual(@as(u32, 0xC), cmd.trigger_rise);
    try std.testing.expectEqual(@as(u32, 0xD), cmd.trigger_fall);
    try std.testing.expect(cmd.triggers_specified);
    switch (cmd.output_target) {
        .stdout => {},
        else => return error.TestExpectedEqual,
    }
}

test "buildCaptureCommand rejects stdout and output-file conflict" {
    try std.testing.expectError(
        error.InvalidArgument,
        buildCaptureCommand("capture.bin", true, .bin, 1024, null, false, .buffer, default_capture_samplerate_hz, .{}, false),
    );
}

test "buildCaptureCommand rejects missing output format" {
    try std.testing.expectError(
        error.InvalidArgument,
        buildCaptureCommand("capture.bin", false, null, 1024, null, false, .buffer, default_capture_samplerate_hz, .{}, false),
    );
}

test "buildCaptureCommand rejects sr format for stdout target" {
    try std.testing.expectError(
        error.InvalidArgument,
        buildCaptureCommand(null, true, .sr, 1024, null, false, .buffer, default_capture_samplerate_hz, .{}, false),
    );
}

test "buildCaptureCommand uses explicit sr format regardless of file extension" {
    const cmd = try buildCaptureCommand("capture.bin", false, .sr, 2048, null, false, .buffer, default_capture_samplerate_hz, .{}, false);
    try std.testing.expectEqual(OutputFormat.sr, cmd.output_format);
    try std.testing.expect(cmd.decode_cross);
    try std.testing.expect(!cmd.triggers_specified);
    switch (cmd.output_target) {
        .file_path => |path| try std.testing.expectEqualStrings("capture.bin", path),
        else => return error.TestExpectedEqual,
    }
}

test "buildCaptureCommand preserves time option" {
    const cmd = try buildCaptureCommand("capture.bin", false, .bin, 0, 150, false, .buffer, 25_000_000, .{}, false);
    try std.testing.expectEqual(@as(?u64, 150), cmd.time_ms);
    try std.testing.expectEqual(@as(usize, 0), cmd.sample_bytes);
}
