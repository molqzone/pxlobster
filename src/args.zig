const std = @import("std");
const builtin = @import("builtin");
const caps = @import("caps.zig");

const clap = if (builtin.is_test) struct {} else @import("clap");

pub const default_capture_samples_bytes: usize = 8 * 1024 * 1024;
pub const default_capture_samplerate_hz: u64 = caps.default_capture_samplerate_hz;

pub const OutputFormat = enum {
    bin,
    sr,
};

pub const OutputTarget = union(enum) {
    file_path: []const u8,
    stdout,
};

pub const OperationMode = enum {
    buffer,
    stream,
    loop,
};

pub const TriggerMasks = struct {
    trigger_zero: u32 = 0,
    trigger_one: u32 = 0,
    trigger_rise: u32 = 0,
    trigger_fall: u32 = 0,
};

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

pub const ParsedCommand = struct {
    command: Command,
    verbose: bool = false,
};

pub const Command = union(enum) {
    scan,
    prime_fw,
    capture: CaptureCommand,
};

const clap_params = if (builtin.is_test) 0 else clap.parseParamsComptime(
    \\-h, --help
    \\-v, --verbose
    \\    --scan
    \\    --prime-fw
    \\-o, --output-file <str>...
    \\    --stdout
    \\-c, --config <str>...
    \\    --samples <usize>...
    \\    --time <u64>...
    \\    --decode-cross
    \\    --mode <str>...
    \\-t, --triggers <str>...
    \\    --samplerate <u64>...
    \\
);

const ParsedArgsView = struct {
    help: usize,
    verbose: usize,
    scan: usize,
    @"prime-fw": usize,
    @"output-file": []const []const u8,
    stdout: usize,
    config: []const []const u8,
    samples: []const usize,
    time: []const u64,
    @"decode-cross": usize,
    mode: []const []const u8,
    triggers: []const []const u8,
    samplerate: []const u64,
};

const ParsedArgsOwned = struct {
    help: usize = 0,
    verbose: usize = 0,
    scan: usize = 0,
    @"prime-fw": usize = 0,
    @"output-file": std.ArrayListUnmanaged([]const u8) = .{},
    stdout: usize = 0,
    config: std.ArrayListUnmanaged([]const u8) = .{},
    samples: std.ArrayListUnmanaged(usize) = .{},
    time: std.ArrayListUnmanaged(u64) = .{},
    @"decode-cross": usize = 0,
    mode: std.ArrayListUnmanaged([]const u8) = .{},
    triggers: std.ArrayListUnmanaged([]const u8) = .{},
    samplerate: std.ArrayListUnmanaged(u64) = .{},

    fn deinit(self: *ParsedArgsOwned, allocator: std.mem.Allocator) void {
        self.@"output-file".deinit(allocator);
        self.config.deinit(allocator);
        self.samples.deinit(allocator);
        self.time.deinit(allocator);
        self.mode.deinit(allocator);
        self.triggers.deinit(allocator);
        self.samplerate.deinit(allocator);
    }

    fn view(self: *const ParsedArgsOwned) ParsedArgsView {
        return .{
            .help = self.help,
            .verbose = self.verbose,
            .scan = self.scan,
            .@"prime-fw" = self.@"prime-fw",
            .@"output-file" = self.@"output-file".items,
            .stdout = self.stdout,
            .config = self.config.items,
            .samples = self.samples.items,
            .time = self.time.items,
            .@"decode-cross" = self.@"decode-cross",
            .mode = self.mode.items,
            .triggers = self.triggers.items,
            .samplerate = self.samplerate.items,
        };
    }
};

pub fn parseArgs() !ParsedCommand {
    return parseArgsWithClap();
}

pub fn parseArgsFromSlice(args: []const []const u8, allocator: std.mem.Allocator) !ParsedCommand {
    if (comptime builtin.is_test) {
        return parseArgsFromSliceWithoutClap(args, allocator);
    }

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

pub fn deinitParsedCommand(parsed: *ParsedCommand, allocator: std.mem.Allocator) void {
    deinitCommand(&parsed.command, allocator);
}

pub fn deinitCommand(cmd: *Command, allocator: std.mem.Allocator) void {
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

fn parseArgsWithClap() !ParsedCommand {
    if (comptime builtin.is_test) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const argv = try std.process.argsAlloc(arena.allocator());
        var parsed = try parseArgsFromSliceWithoutClap(argv, std.heap.page_allocator);
        try detachOutputPathIfNeeded(&parsed.command, std.heap.page_allocator);
        return parsed;
    }

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

fn parseArgsFromSliceWithoutClap(args: []const []const u8, allocator: std.mem.Allocator) !ParsedCommand {
    const cli_args = if (args.len > 0) args[1..] else args;
    var parsed: ParsedArgsOwned = .{};
    defer parsed.deinit(allocator);

    var i: usize = 0;
    while (i < cli_args.len) : (i += 1) {
        const arg = cli_args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            parsed.help += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            parsed.verbose += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--scan")) {
            parsed.scan += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--prime-fw")) {
            parsed.@"prime-fw" += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--stdout")) {
            parsed.stdout += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--decode-cross")) {
            parsed.@"decode-cross" += 1;
            continue;
        }

        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output-file")) {
            i += 1;
            if (i >= cli_args.len) return error.InvalidArgument;
            try parsed.@"output-file".append(allocator, cli_args[i]);
            continue;
        }

        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= cli_args.len) return error.InvalidArgument;
            try parsed.config.append(allocator, cli_args[i]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--samples")) {
            i += 1;
            if (i >= cli_args.len) return error.InvalidArgument;
            const sample_value = std.fmt.parseInt(usize, cli_args[i], 10) catch return error.InvalidArgument;
            try parsed.samples.append(allocator, sample_value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--time")) {
            i += 1;
            if (i >= cli_args.len) return error.InvalidArgument;
            const time_value = std.fmt.parseInt(u64, cli_args[i], 10) catch return error.InvalidArgument;
            try parsed.time.append(allocator, time_value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= cli_args.len) return error.InvalidArgument;
            try parsed.mode.append(allocator, cli_args[i]);
            continue;
        }

        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--triggers")) {
            i += 1;
            if (i >= cli_args.len) return error.InvalidArgument;
            try parsed.triggers.append(allocator, cli_args[i]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--samplerate")) {
            i += 1;
            if (i >= cli_args.len) return error.InvalidArgument;
            const samplerate_value = std.fmt.parseInt(u64, cli_args[i], 10) catch return error.InvalidArgument;
            try parsed.samplerate.append(allocator, samplerate_value);
            continue;
        }

        return error.InvalidArgument;
    }

    return commandFromParsedArgs(parsed.view());
}

fn commandFromParsedArgs(parsed_args: anytype) !ParsedCommand {
    if (@field(parsed_args, "help") > 0) return error.ShowHelp;
    const verbose = @field(parsed_args, "verbose") > 0;

    const scan_count = @field(parsed_args, "scan");
    const prime_fw_count = @field(parsed_args, "prime-fw");
    if (scan_count > 0 and prime_fw_count > 0) return error.InvalidArgument;

    var requested_read_only: ?enum { scan, prime_fw } = null;
    if (scan_count > 0) requested_read_only = .scan;
    if (prime_fw_count > 0) requested_read_only = .prime_fw;

    const output_paths: []const []const u8 = @field(parsed_args, "output-file");
    const output_path = lastValue([]const u8, output_paths);
    if (output_path != null and output_path.?.len == 0) return error.InvalidArgument;
    const output_stdout = @field(parsed_args, "stdout") > 0;

    var samplerate_hz: u64 = default_capture_samplerate_hz;
    var samplerate_set = false;
    const config_values: []const []const u8 = @field(parsed_args, "config");
    for (config_values) |value| {
        applyConfigKV(value, &samplerate_hz, &samplerate_set) catch return error.InvalidArgument;
    }

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

    const capture_requested = output_path != null or output_stdout or samples_set or time_set or decode_cross or op_mode_set or samplerate_set or triggers_set;
    if (requested_read_only != null and capture_requested) return error.InvalidArgument;

    if (requested_read_only) |command| {
        return .{
            .command = switch (command) {
                .scan => .scan,
                .prime_fw => .prime_fw,
            },
            .verbose = verbose,
        };
    }

    return .{
        .command = .{ .capture = try buildCaptureCommand(
            output_path,
            output_stdout,
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

fn lastValue(comptime T: type, values: []const T) ?T {
    if (values.len == 0) return null;
    return values[values.len - 1];
}

fn buildCaptureCommand(
    output_path: ?[]const u8,
    output_stdout: bool,
    sample_bytes: usize,
    time_ms: ?u64,
    decode_cross: bool,
    op_mode: OperationMode,
    samplerate_hz: u64,
    trigger_masks: TriggerMasks,
    triggers_specified: bool,
) !CaptureCommand {
    if (output_stdout and output_path != null) return error.InvalidArgument;

    if (output_stdout) {
        return .{
            .output_target = .stdout,
            .output_format = .bin,
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
        const output_format = inferOutputFormat(path);
        return .{
            .output_target = .{ .file_path = path },
            .output_format = output_format,
            .sample_bytes = sample_bytes,
            .time_ms = time_ms,
            .decode_cross = if (output_format == .sr) true else decode_cross,
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

fn parseOpMode(value: []const u8) ?OperationMode {
    if (std.mem.eql(u8, value, "buffer")) return .buffer;
    if (std.mem.eql(u8, value, "stream")) return .stream;
    if (std.mem.eql(u8, value, "loop")) return .loop;
    return null;
}

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

fn parseSamplerate(value: []const u8) ?u64 {
    const samplerate = std.fmt.parseInt(u64, value, 10) catch return null;
    return parseSamplerateValue(samplerate);
}

fn parseSamplerateValue(samplerate: u64) ?u64 {
    if (!caps.isSupportedSamplerate(samplerate)) return null;
    return samplerate;
}

fn parseSamplerateWithUnits(value: []const u8) ?u64 {
    if (parseSamplerate(value)) |samplerate| return samplerate;

    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 32) return null;

    var lowercase_storage: [32]u8 = undefined;
    for (trimmed, 0..) |ch, i| lowercase_storage[i] = std.ascii.toLower(ch);
    var token = lowercase_storage[0..trimmed.len];

    if (std.mem.endsWith(u8, token, "hz")) {
        token = token[0 .. token.len - 2];
    }
    if (token.len == 0) return null;

    var multiplier: u64 = 1;
    const suffix = token[token.len - 1];
    if (suffix == 'k' or suffix == 'm' or suffix == 'g') {
        multiplier = switch (suffix) {
            'k' => 1_000,
            'm' => 1_000_000,
            'g' => 1_000_000_000,
            else => unreachable,
        };
        token = token[0 .. token.len - 1];
    }
    if (token.len == 0) return null;

    const base = std.fmt.parseInt(u64, token, 10) catch return null;
    const samplerate = std.math.mul(u64, base, multiplier) catch return null;
    if (!caps.isSupportedSamplerate(samplerate)) return null;
    return samplerate;
}

fn applyConfigKV(kv: []const u8, samplerate_hz: *u64, samplerate_set: *bool) !void {
    const separator = std.mem.indexOfScalar(u8, kv, '=') orelse return error.InvalidArgument;
    const key = std.mem.trim(u8, kv[0..separator], " \t\r\n");
    const value = std.mem.trim(u8, kv[separator + 1 ..], " \t\r\n");
    if (key.len == 0 or value.len == 0) return error.InvalidArgument;

    if (std.mem.eql(u8, key, "samplerate")) {
        samplerate_hz.* = parseSamplerateWithUnits(value) orelse return error.InvalidArgument;
        samplerate_set.* = true;
        return;
    }

    return error.InvalidArgument;
}

fn inferOutputFormat(path: []const u8) OutputFormat {
    if (path.len >= 3 and std.ascii.eqlIgnoreCase(path[path.len - 3 ..], ".sr")) {
        return .sr;
    }
    return .bin;
}

test "parseArgsFromSlice parses stdout capture options" {
    const argv = [_][]const u8{
        "pxlobster",
        "--stdout",
        "--samples",
        "65536",
        "--mode",
        "stream",
        "--triggers",
        "0=1,1=r,2=f,3=0",
        "--samplerate",
        "24000000",
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
            try std.testing.expectEqual(@as(u64, 24_000_000), capture_cmd.samplerate_hz);
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
    const argv = [_][]const u8{ "pxlobster", "--stdout", "-t", "2=f,3=0" };
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
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--samples", "1024" };
    const parsed = try parseArgsFromSlice(&argv, std.testing.allocator);
    switch (parsed.command) {
        .capture => |capture_cmd| {
            try std.testing.expect(!capture_cmd.triggers_specified);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parseArgsFromSlice enables verbose for capture and scan commands" {
    const capture_argv = [_][]const u8{ "pxlobster", "--stdout", "--samples", "1024", "-v" };
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

test "parseArgsFromSlice rejects stdout and output-file conflict" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "-o", "capture.bin" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects missing option values" {
    const missing_output = [_][]const u8{ "pxlobster", "-o" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&missing_output, std.testing.allocator));

    const missing_samples = [_][]const u8{ "pxlobster", "--stdout", "--samples" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&missing_samples, std.testing.allocator));
}

test "parseArgsFromSlice returns ShowHelp for --help" {
    const argv = [_][]const u8{ "pxlobster", "--help" };
    try std.testing.expectError(error.ShowHelp, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice accepts samplerate from -c" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "-c", "samplerate=24M" };
    const parsed = try parseArgsFromSlice(&argv, std.testing.allocator);
    switch (parsed.command) {
        .capture => |capture_cmd| try std.testing.expectEqual(@as(u64, 24_000_000), capture_cmd.samplerate_hz),
        else => return error.TestExpectedEqual,
    }
}

test "parseArgsFromSlice rejects invalid mode" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--mode", "invalid" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects invalid trigger spec" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--triggers", "0=x" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects unsupported samplerate" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--samplerate", "123456789" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice accepts capture time in milliseconds" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--time", "250", "--samplerate", "10000000" };
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
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--samples", "4096", "--time", "10" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects zero time" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--time", "0" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects loop mode with time" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--time", "10", "--mode", "loop" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice keeps scan and capture mutually exclusive" {
    const argv = [_][]const u8{ "pxlobster", "--scan", "--stdout" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseOpMode accepts supported values" {
    try std.testing.expectEqual(OperationMode.buffer, parseOpMode("buffer").?);
    try std.testing.expectEqual(OperationMode.stream, parseOpMode("stream").?);
    try std.testing.expectEqual(OperationMode.loop, parseOpMode("loop").?);
    try std.testing.expect(parseOpMode("invalid") == null);
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
    try std.testing.expectEqual(@as(u64, 24_000_000), parseSamplerate("24000000").?);
    try std.testing.expectEqual(@as(u64, 10_000_000), parseSamplerate("10000000").?);
    try std.testing.expect(parseSamplerate("123456789") == null);
    try std.testing.expect(parseSamplerate("0") == null);
    try std.testing.expect(parseSamplerate("abc") == null);
}

test "parseSamplerateWithUnits accepts supported unit suffixes" {
    try std.testing.expectEqual(@as(u64, 24_000_000), parseSamplerateWithUnits("24M").?);
    try std.testing.expectEqual(@as(u64, 25_000_000), parseSamplerateWithUnits("25M").?);
    try std.testing.expectEqual(@as(u64, 10_000_000), parseSamplerateWithUnits("10mhz").?);
    try std.testing.expectEqual(@as(u64, 500_000), parseSamplerateWithUnits("500k").?);
    try std.testing.expect(parseSamplerateWithUnits("abc") == null);
}

test "applyConfigKV parses samplerate key" {
    var samplerate_hz: u64 = default_capture_samplerate_hz;
    var samplerate_set = false;

    try applyConfigKV("samplerate=24M", &samplerate_hz, &samplerate_set);
    try std.testing.expect(samplerate_set);
    try std.testing.expectEqual(@as(u64, 24_000_000), samplerate_hz);
    try std.testing.expectError(error.InvalidArgument, applyConfigKV("samplerate=24X", &samplerate_hz, &samplerate_set));
    try std.testing.expectError(error.InvalidArgument, applyConfigKV("unknown=1", &samplerate_hz, &samplerate_set));
}

test "inferOutputFormat auto-detects sr extension" {
    try std.testing.expectEqual(OutputFormat.sr, inferOutputFormat("capture.sr"));
    try std.testing.expectEqual(OutputFormat.sr, inferOutputFormat("CAPTURE.SR"));
    try std.testing.expectEqual(OutputFormat.bin, inferOutputFormat("capture.bin"));
}

test "buildCaptureCommand selects stdout raw output" {
    const cmd = try buildCaptureCommand(null, true, 4096, null, true, .stream, 24_000_000, .{
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
    try std.testing.expectEqual(@as(u64, 24_000_000), cmd.samplerate_hz);
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
        buildCaptureCommand("capture.bin", true, 1024, null, false, .buffer, default_capture_samplerate_hz, .{}, false),
    );
}

test "buildCaptureCommand enables decode-cross for sr file output" {
    const cmd = try buildCaptureCommand("capture.sr", false, 2048, null, false, .buffer, default_capture_samplerate_hz, .{}, false);
    try std.testing.expectEqual(OutputFormat.sr, cmd.output_format);
    try std.testing.expect(cmd.decode_cross);
    try std.testing.expect(!cmd.triggers_specified);
    switch (cmd.output_target) {
        .file_path => |path| try std.testing.expectEqualStrings("capture.sr", path),
        else => return error.TestExpectedEqual,
    }
}

test "buildCaptureCommand preserves time option" {
    const cmd = try buildCaptureCommand("capture.bin", false, 0, 150, false, .buffer, 24_000_000, .{}, false);
    try std.testing.expectEqual(@as(?u64, 150), cmd.time_ms);
    try std.testing.expectEqual(@as(usize, 0), cmd.sample_bytes);
}
