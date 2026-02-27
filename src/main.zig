const std = @import("std");
const builtin = @import("builtin");
const clap = blk: {
    if (builtin.is_test) break :blk @import("clap_test_stub.zig");
    break :blk @import("clap");
};
const capture = blk: {
    if (builtin.is_test) break :blk @import("main_test_capture_stub.zig");
    break :blk @import("capture.zig");
};
const device = blk: {
    if (builtin.is_test) break :blk @import("main_test_device_stub.zig");
    break :blk @import("device.zig");
};
const usb = blk: {
    if (builtin.is_test) break :blk @import("main_test_usb_stub.zig");
    break :blk @import("usb.zig");
};

const TestLibUsb = struct {
    pub const LIBUSB_SPEED_HIGH: c_int = 3;
    pub const LIBUSB_SPEED_SUPER: c_int = 4;
    pub const libusb_context = opaque {};
    pub const libusb_device = opaque {};
    pub const libusb_device_handle = opaque {};
};

const c = if (builtin.is_test) TestLibUsb else @import("pxlobster").libusb;

pub fn main() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var cmd = parseArgs() catch |err| switch (err) {
        error.ShowHelp => return,
        error.InvalidArgument => {
            try printUsage(stderr);
            std.process.exit(2);
        },
        else => return err,
    };
    defer deinitCommand(&cmd, std.heap.page_allocator);

    switch (cmd) {
        .scan => try scanUsbDevices(stdout),
        .prime_fw => try primeFirmware(stdout),
        .capture => |options| try runCapture(options, stdout, stderr),
    }
}

const default_capture_samples_bytes: usize = 8 * 1024 * 1024;

const CaptureCommand = struct {
    output_target: capture.CaptureOutputTarget,
    output_format: capture.OutputFormat = .bin,
    sample_bytes: usize = default_capture_samples_bytes,
    decode_cross: bool = false,
    op_mode: usb.OperationMode = .buffer,
    samplerate_hz: u64 = usb.DEFAULT_CAPTURE_SAMPLERATE_HZ,
    owns_output_path: bool = false,
};

const Command = union(enum) {
    scan,
    prime_fw,
    capture: CaptureCommand,
};

const LogicModeProbe = union(enum) {
    value: u32,
    busy,
    unavailable,
};

const clap_params = if (builtin.is_test) 0 else clap.parseParamsComptime(
    \\-h, --help
    \\    --scan
    \\    --prime-fw
    \\-o, --output-file <str>...
    \\    --stdout
    \\-c, --config <str>...
    \\    --samples <usize>...
    \\    --decode-cross
    \\    --op-mode <str>...
    \\    --samplerate <u64>...
    \\
);

const ParsedArgsView = struct {
    help: usize,
    scan: usize,
    @"prime-fw": usize,
    @"output-file": []const []const u8,
    stdout: usize,
    config: []const []const u8,
    samples: []const usize,
    @"decode-cross": usize,
    @"op-mode": []const []const u8,
    samplerate: []const u64,
};

const ParsedArgsOwned = struct {
    help: usize = 0,
    scan: usize = 0,
    @"prime-fw": usize = 0,
    @"output-file": std.ArrayListUnmanaged([]const u8) = .{},
    stdout: usize = 0,
    config: std.ArrayListUnmanaged([]const u8) = .{},
    samples: std.ArrayListUnmanaged(usize) = .{},
    @"decode-cross": usize = 0,
    @"op-mode": std.ArrayListUnmanaged([]const u8) = .{},
    samplerate: std.ArrayListUnmanaged(u64) = .{},

    fn deinit(self: *ParsedArgsOwned, allocator: std.mem.Allocator) void {
        self.@"output-file".deinit(allocator);
        self.config.deinit(allocator);
        self.samples.deinit(allocator);
        self.@"op-mode".deinit(allocator);
        self.samplerate.deinit(allocator);
    }

    fn view(self: *const ParsedArgsOwned) ParsedArgsView {
        return .{
            .help = self.help,
            .scan = self.scan,
            .@"prime-fw" = self.@"prime-fw",
            .@"output-file" = self.@"output-file".items,
            .stdout = self.stdout,
            .config = self.config.items,
            .samples = self.samples.items,
            .@"decode-cross" = self.@"decode-cross",
            .@"op-mode" = self.@"op-mode".items,
            .samplerate = self.samplerate.items,
        };
    }
};

fn parseArgs() !Command {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    return parseArgsWithClap() catch |err| switch (err) {
        error.ShowHelp => {
            try printUsage(stdout);
            return error.ShowHelp;
        },
        else => return err,
    };
}

fn parseArgsWithClap() !Command {
    if (comptime builtin.is_test) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const args = try std.process.argsAlloc(arena.allocator());
        var cmd = try parseArgsFromSlice(args, arena.allocator());
        try detachOutputPathIfNeeded(&cmd, std.heap.page_allocator);
        return cmd;
    }

    var diag = clap.Diagnostic{};
    var result = clap.parse(clap.Help, &clap_params, clap.parsers.default, .{
        .allocator = std.heap.page_allocator,
        .diagnostic = &diag,
    }) catch return error.InvalidArgument;
    defer result.deinit();

    var cmd = try commandFromParsedArgs(result.args);
    try detachOutputPathIfNeeded(&cmd, std.heap.page_allocator);
    return cmd;
}

fn parseArgsFromSlice(args: []const []const u8, allocator: std.mem.Allocator) !Command {
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

    return commandFromParsedArgs(result.args);
}

fn parseArgsFromSliceWithoutClap(args: []const []const u8, allocator: std.mem.Allocator) !Command {
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

        if (std.mem.eql(u8, arg, "--op-mode")) {
            i += 1;
            if (i >= cli_args.len) return error.InvalidArgument;
            try parsed.@"op-mode".append(allocator, cli_args[i]);
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

fn commandFromParsedArgs(parsed_args: anytype) !Command {
    if (@field(parsed_args, "help") > 0) return error.ShowHelp;

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

    var samplerate_hz: u64 = usb.DEFAULT_CAPTURE_SAMPLERATE_HZ;
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

    const decode_cross = @field(parsed_args, "decode-cross") > 0;

    var op_mode: usb.OperationMode = .buffer;
    var op_mode_set = false;
    const op_mode_values: []const []const u8 = @field(parsed_args, "op-mode");
    if (lastValue([]const u8, op_mode_values)) |value| {
        op_mode = parseOpMode(value) orelse return error.InvalidArgument;
        op_mode_set = true;
    }

    const samplerate_values: []const u64 = @field(parsed_args, "samplerate");
    if (lastValue(u64, samplerate_values)) |value| {
        samplerate_hz = parseSamplerateValue(value) orelse return error.InvalidArgument;
        samplerate_set = true;
    }

    const capture_requested = output_path != null or output_stdout or samples_set or decode_cross or op_mode_set or samplerate_set;
    if (requested_read_only != null and capture_requested) return error.InvalidArgument;

    if (requested_read_only) |command| {
        return switch (command) {
            .scan => .scan,
            .prime_fw => .prime_fw,
        };
    }

    return .{ .capture = try buildCaptureCommand(
        output_path,
        output_stdout,
        sample_bytes,
        decode_cross,
        op_mode,
        samplerate_hz,
    ) };
}

fn lastValue(comptime T: type, values: []const T) ?T {
    if (values.len == 0) return null;
    return values[values.len - 1];
}

fn buildCaptureCommand(
    output_path: ?[]const u8,
    output_stdout: bool,
    sample_bytes: usize,
    decode_cross: bool,
    op_mode: usb.OperationMode,
    samplerate_hz: u64,
) !CaptureCommand {
    if (output_stdout and output_path != null) return error.InvalidArgument;

    if (output_stdout) {
        return .{
            .output_target = .stdout,
            .output_format = .bin,
            .sample_bytes = sample_bytes,
            .decode_cross = decode_cross,
            .op_mode = op_mode,
            .samplerate_hz = samplerate_hz,
        };
    }

    if (output_path) |path| {
        const output_format = inferOutputFormat(path);
        return .{
            .output_target = .{ .file_path = path },
            .output_format = output_format,
            .sample_bytes = sample_bytes,
            .decode_cross = if (output_format == .sr) true else decode_cross,
            .op_mode = op_mode,
            .samplerate_hz = samplerate_hz,
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

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage:
        \\  pxlobster --scan
        \\  pxlobster --prime-fw
        \\  pxlobster -o <path> [-c <key=value>] [--samples <bytes>] [--decode-cross] [--op-mode <buffer|stream|loop>] [--samplerate <hz>]
        \\  pxlobster --stdout [-c <key=value>] [--samples <bytes>] [--decode-cross] [--op-mode <buffer|stream|loop>] [--samplerate <hz>]
        \\
        \\Options:
        \\  --scan               Read-only scan for supported PX Logic devices.
        \\  --prime-fw           Inject firmware to detected PX Logic devices.
        \\  -o, --output-file    Output file (.sr => Sigrok session, others => raw binary).
        \\  --stdout             Stream raw binary capture to stdout (pipe-friendly).
        \\  -c, --config         Capture config key-value (e.g. samplerate=24M).
        \\  --samples            Capture bytes target for buffer/stream (default: 8388608).
        \\  --decode-cross       Decode PXView LA_CROSS_DATA into packed channel samples.
        \\  --op-mode            Capture operation mode: buffer | stream | loop (default: buffer).
        \\  --samplerate         Capture sample rate in Hz (must be a PXView-supported discrete value).
        \\  -h, --help           Show this help.
        \\
        \\Notes:
        \\  --scan, --prime-fw, and capture mode are mutually exclusive.
        \\  loop mode runs continuously until Ctrl+C.
        \\
    );
}

fn scanUsbDevices(writer: anytype) !void {
    if (comptime builtin.is_test) {
        return;
    } else {
        var ctx: ?*c.libusb_context = null;
        const init_rc = c.libusb_init(&ctx);
        if (init_rc != 0 or ctx == null) return error.LibusbInitFailed;
        defer c.libusb_exit(ctx);

        const active_ctx = ctx.?;

        var device_list: [*c]?*c.libusb_device = undefined;
        const count = c.libusb_get_device_list(active_ctx, &device_list);
        if (count < 0) return error.LibusbGetDeviceListFailed;
        defer c.libusb_free_device_list(device_list, 1);

        var found_supported = false;
        const count_usize: usize = @intCast(count);
        const device_slice = @as([*]?*c.libusb_device, @ptrCast(device_list))[0..count_usize];
        for (device_slice) |dev_opt| {
            if (dev_opt == null) continue;

            var desc: c.libusb_device_descriptor = undefined;
            if (c.libusb_get_device_descriptor(dev_opt.?, &desc) != 0) continue;

            const vid: u16 = @intCast(desc.idVendor);
            const pid: u16 = @intCast(desc.idProduct);
            const tag = detectTag(dev_opt.?, vid, pid);
            if (tag) |label| {
                found_supported = true;
                try writer.print("{X:0>4}:{X:0>4}  {s}\n", .{ vid, pid, label });
            }
        }

        if (!found_supported) {
            try writer.writeAll("No supported devices found.\n");
        }
    }
}

fn primeFirmware(writer: anytype) !void {
    if (comptime builtin.is_test) {
        return;
    } else {
        var ctx: ?*c.libusb_context = null;
        const init_rc = c.libusb_init(&ctx);
        if (init_rc != 0 or ctx == null) return error.LibusbInitFailed;
        defer c.libusb_exit(ctx);

        const active_ctx = ctx.?;

        var device_list: [*c]?*c.libusb_device = undefined;
        const count = c.libusb_get_device_list(active_ctx, &device_list);
        if (count < 0) return error.LibusbGetDeviceListFailed;
        defer c.libusb_free_device_list(device_list, 1);

        var found_supported = false;
        const count_usize: usize = @intCast(count);
        const device_slice = @as([*]?*c.libusb_device, @ptrCast(device_list))[0..count_usize];
        for (device_slice) |dev_opt| {
            if (dev_opt == null) continue;

            var desc: c.libusb_device_descriptor = undefined;
            if (c.libusb_get_device_descriptor(dev_opt.?, &desc) != 0) continue;

            const vid: u16 = @intCast(desc.idVendor);
            const pid: u16 = @intCast(desc.idProduct);
            if (!device.isSupportedPxLogic(vid, pid)) continue;
            found_supported = true;

            const state = device.preparePxLogicDevice(dev_opt.?, .{});
            switch (state) {
                .ready => {
                    const label = detectTag(dev_opt.?, vid, pid) orelse "PX-Logic (ready)";
                    try writer.print("{X:0>4}:{X:0>4}  {s}  [fw loaded]\n", .{ vid, pid, label });
                },
                .busy => try writer.print("{X:0>4}:{X:0>4}  PX-Logic (Busy)\n", .{ vid, pid }),
                .failed => try writer.print("{X:0>4}:{X:0>4}  PX-Logic (firmware load failed)\n", .{ vid, pid }),
            }
        }

        if (!found_supported) {
            try writer.writeAll("No supported devices found.\n");
        }
    }
}

fn runCapture(cmd: CaptureCommand, stdout: anytype, stderr: anytype) !void {
    if (comptime builtin.is_test) {
        return;
    } else {
        var ctx: ?*c.libusb_context = null;
        const init_rc = c.libusb_init(&ctx);
        if (init_rc != 0 or ctx == null) return error.LibusbInitFailed;
        defer c.libusb_exit(ctx);

        const stats = capture.runCapture(std.heap.page_allocator, ctx.?, .{
            .output_target = cmd.output_target,
            .output_format = cmd.output_format,
            .sample_bytes = cmd.sample_bytes,
            .decode_cross = cmd.decode_cross,
            .capture_profile = .{
                .op_mode = cmd.op_mode,
                .samplerate_hz = cmd.samplerate_hz,
            },
        }) catch |err| {
            try stderr.print("capture failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };

        switch (cmd.output_target) {
            .file_path => |path| {
                try stdout.print(
                    "capture complete: file={s} bytes_out={d} bytes_in={d} dropped={d} elapsed_ms={d}\n",
                    .{ path, stats.bytes_out, stats.bytes_in, stats.dropped, stats.elapsed_ms },
                );
            },
            .stdout => {
                try stderr.print(
                    "capture complete: output=stdout bytes_out={d} bytes_in={d} dropped={d} elapsed_ms={d}\n",
                    .{ stats.bytes_out, stats.bytes_in, stats.dropped, stats.elapsed_ms },
                );
            },
        }
    }
}

fn parseOpMode(value: []const u8) ?usb.OperationMode {
    if (std.mem.eql(u8, value, "buffer")) return .buffer;
    if (std.mem.eql(u8, value, "stream")) return .stream;
    if (std.mem.eql(u8, value, "loop")) return .loop;
    return null;
}

fn parseSamplerate(value: []const u8) ?u64 {
    const samplerate = std.fmt.parseInt(u64, value, 10) catch return null;
    return parseSamplerateValue(samplerate);
}

fn parseSamplerateValue(samplerate: u64) ?u64 {
    if (!usb.isSupportedSamplerate(samplerate)) return null;
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
    if (!usb.isSupportedSamplerate(samplerate)) return null;
    return samplerate;
}

fn applyConfigKV(
    kv: []const u8,
    samplerate_hz: *u64,
    samplerate_set: *bool,
) !void {
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

fn inferOutputFormat(path: []const u8) capture.OutputFormat {
    if (path.len >= 3 and std.ascii.eqlIgnoreCase(path[path.len - 3 ..], ".sr")) {
        return .sr;
    }
    return .bin;
}

fn detectTag(dev: *c.libusb_device, vid: u16, pid: u16) ?[]const u8 {
    if (comptime builtin.is_test) {
        return modelLabelForIdentity(vid, pid, c.LIBUSB_SPEED_HIGH, .unavailable);
    } else {
        if (!device.isSupportedPxLogic(vid, pid)) return null;

        const usb_speed = c.libusb_get_device_speed(dev);
        const logic_mode: LogicModeProbe = if (device.isLegacyPxLogic(vid, pid)) readLogicMode(dev) else .unavailable;
        return modelLabelForIdentity(vid, pid, usb_speed, logic_mode) orelse "PX-Logic (ready)";
    }
}

fn modelLabelForIdentity(vid: u16, pid: u16, usb_speed: c_int, logic_mode: LogicModeProbe) ?[]const u8 {
    if (device.isWchPxLogic(vid, pid)) {
        return switch (usb_speed) {
            c.LIBUSB_SPEED_SUPER => "PX-Logic U3 channel 32",
            c.LIBUSB_SPEED_HIGH => "PX-Logic U2 channel 32",
            else => "PX-Logic channel 32",
        };
    }

    if (device.isLegacyPxLogic(vid, pid)) {
        return switch (logic_mode) {
            .busy => "PX-Logic (Busy)",
            .value => |mode| switch (mode) {
                0 => switch (usb_speed) {
                    c.LIBUSB_SPEED_SUPER => "PX-Logic U3 channel 32",
                    c.LIBUSB_SPEED_HIGH => "PX-Logic U2 channel 32",
                    else => "PX-Logic channel 32",
                },
                1 => switch (usb_speed) {
                    c.LIBUSB_SPEED_SUPER => "PX-Logic U3 channel 16 Pro",
                    c.LIBUSB_SPEED_HIGH => "PX-Logic U2 channel 16 Pro",
                    else => "PX-Logic channel 16 Pro",
                },
                2 => switch (usb_speed) {
                    c.LIBUSB_SPEED_SUPER => "PX-Logic U3 channel 16 Plus",
                    c.LIBUSB_SPEED_HIGH => "PX-Logic U2 channel 16 Plus",
                    else => "PX-Logic channel 16 Plus",
                },
                3 => switch (usb_speed) {
                    c.LIBUSB_SPEED_SUPER => "PX-Logic U3 channel 16 Base",
                    c.LIBUSB_SPEED_HIGH => "PX-Logic U2 channel 16 Base",
                    else => "PX-Logic channel 16 Base",
                },
                else => switch (usb_speed) {
                    c.LIBUSB_SPEED_SUPER => "PX-Logic U3 (unknown mode)",
                    c.LIBUSB_SPEED_HIGH => "PX-Logic U2 (unknown mode)",
                    else => "PX-Logic (unknown mode)",
                },
            },
            .unavailable => switch (usb_speed) {
                c.LIBUSB_SPEED_SUPER => "PX-Logic U3 (mode unknown)",
                c.LIBUSB_SPEED_HIGH => "PX-Logic U2 (mode unknown)",
                else => "PX-Logic (mode unknown)",
            },
        };
    }
    return null;
}

fn readLogicMode(dev: *c.libusb_device) LogicModeProbe {
    if (comptime builtin.is_test) {
        return .unavailable;
    } else {
        var desc: c.libusb_device_descriptor = undefined;
        if (c.libusb_get_device_descriptor(dev, &desc) != 0) return .unavailable;

        var handle_opt: ?*c.libusb_device_handle = null;
        if (c.libusb_open(dev, &handle_opt) != 0 or handle_opt == null) return .unavailable;
        const handle = handle_opt.?;
        defer c.libusb_close(handle);

        if (!isPxManufacturer(handle, desc.iManufacturer)) return .unavailable;

        if (c.libusb_claim_interface(handle, 0) != 0) return .busy;
        defer _ = c.libusb_release_interface(handle, 0);
        if (c.libusb_claim_interface(handle, 1) != 0) return .busy;
        defer _ = c.libusb_release_interface(handle, 1);

        const mode = usb.readRegister(handle, usb.REG_LOGIC_MODE, usb.DEFAULT_REGISTER_TIMEOUT_MS) catch return .unavailable;
        return .{ .value = mode };
    }
}

fn isPxManufacturer(handle: *c.libusb_device_handle, manufacturer_index: u8) bool {
    if (comptime builtin.is_test) {
        return false;
    } else {
        if (manufacturer_index == 0) return false;

        var buf: [64]u8 = undefined;
        const len = c.libusb_get_string_descriptor_ascii(handle, manufacturer_index, &buf, @intCast(buf.len));
        return len >= 2 and buf[0] == 'P' and buf[1] == 'X';
    }
}

test "modelLabelForIdentity matches PX Logic profiles" {
    try std.testing.expectEqualStrings(
        "PX-Logic U3 channel 32",
        modelLabelForIdentity(device.pxlogic_wch_id.vid, device.pxlogic_wch_id.pid, c.LIBUSB_SPEED_SUPER, .unavailable).?,
    );
    try std.testing.expectEqualStrings(
        "PX-Logic U2 channel 32",
        modelLabelForIdentity(device.pxlogic_wch_id.vid, device.pxlogic_wch_id.pid, c.LIBUSB_SPEED_HIGH, .unavailable).?,
    );
    try std.testing.expectEqualStrings(
        "PX-Logic U3 channel 16 Pro",
        modelLabelForIdentity(device.pxlogic_legacy_id.vid, device.pxlogic_legacy_id.pid, c.LIBUSB_SPEED_SUPER, .{ .value = 1 }).?,
    );
    try std.testing.expectEqualStrings(
        "PX-Logic U2 channel 16 Plus",
        modelLabelForIdentity(device.pxlogic_legacy_id.vid, device.pxlogic_legacy_id.pid, c.LIBUSB_SPEED_HIGH, .{ .value = 2 }).?,
    );
    try std.testing.expectEqualStrings(
        "PX-Logic U3 (mode unknown)",
        modelLabelForIdentity(device.pxlogic_legacy_id.vid, device.pxlogic_legacy_id.pid, c.LIBUSB_SPEED_SUPER, .unavailable).?,
    );
    try std.testing.expectEqualStrings(
        "PX-Logic (Busy)",
        modelLabelForIdentity(device.pxlogic_legacy_id.vid, device.pxlogic_legacy_id.pid, c.LIBUSB_SPEED_HIGH, .busy).?,
    );
}

test "modelLabelForIdentity returns null for unknown IDs" {
    try std.testing.expect(modelLabelForIdentity(0x046D, 0xC52B, c.LIBUSB_SPEED_HIGH, .unavailable) == null);
    try std.testing.expect(modelLabelForIdentity(0x0000, 0x0000, c.LIBUSB_SPEED_HIGH, .unavailable) == null);
}

test "parseArgsFromSlice parses stdout capture options" {
    const argv = [_][]const u8{
        "pxlobster",
        "--stdout",
        "--samples",
        "65536",
        "--op-mode",
        "stream",
        "--samplerate",
        "24000000",
    };

    const cmd = try parseArgsFromSlice(&argv, std.testing.allocator);
    switch (cmd) {
        .capture => |capture_cmd| {
            switch (capture_cmd.output_target) {
                .stdout => {},
                else => return error.TestExpectedEqual,
            }
            try std.testing.expectEqual(capture.OutputFormat.bin, capture_cmd.output_format);
            try std.testing.expectEqual(@as(usize, 65_536), capture_cmd.sample_bytes);
            try std.testing.expectEqual(usb.OperationMode.stream, capture_cmd.op_mode);
            try std.testing.expectEqual(@as(u64, 24_000_000), capture_cmd.samplerate_hz);
        },
        else => return error.TestExpectedEqual,
    }
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
    const cmd = try parseArgsFromSlice(&argv, std.testing.allocator);
    switch (cmd) {
        .capture => |capture_cmd| try std.testing.expectEqual(@as(u64, 24_000_000), capture_cmd.samplerate_hz),
        else => return error.TestExpectedEqual,
    }
}

test "parseArgsFromSlice rejects invalid op-mode" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--op-mode", "invalid" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice rejects unsupported samplerate" {
    const argv = [_][]const u8{ "pxlobster", "--stdout", "--samplerate", "123456789" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseArgsFromSlice keeps scan and capture mutually exclusive" {
    const argv = [_][]const u8{ "pxlobster", "--scan", "--stdout" };
    try std.testing.expectError(error.InvalidArgument, parseArgsFromSlice(&argv, std.testing.allocator));
}

test "parseOpMode accepts supported values" {
    try std.testing.expectEqual(usb.OperationMode.buffer, parseOpMode("buffer").?);
    try std.testing.expectEqual(usb.OperationMode.stream, parseOpMode("stream").?);
    try std.testing.expectEqual(usb.OperationMode.loop, parseOpMode("loop").?);
    try std.testing.expect(parseOpMode("invalid") == null);
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
    var samplerate_hz: u64 = usb.DEFAULT_CAPTURE_SAMPLERATE_HZ;
    var samplerate_set = false;

    try applyConfigKV("samplerate=24M", &samplerate_hz, &samplerate_set);
    try std.testing.expect(samplerate_set);
    try std.testing.expectEqual(@as(u64, 24_000_000), samplerate_hz);
    try std.testing.expectError(error.InvalidArgument, applyConfigKV("samplerate=24X", &samplerate_hz, &samplerate_set));
    try std.testing.expectError(error.InvalidArgument, applyConfigKV("unknown=1", &samplerate_hz, &samplerate_set));
}

test "inferOutputFormat auto-detects sr extension" {
    try std.testing.expectEqual(capture.OutputFormat.sr, inferOutputFormat("capture.sr"));
    try std.testing.expectEqual(capture.OutputFormat.sr, inferOutputFormat("CAPTURE.SR"));
    try std.testing.expectEqual(capture.OutputFormat.bin, inferOutputFormat("capture.bin"));
}

test "buildCaptureCommand selects stdout raw output" {
    const cmd = try buildCaptureCommand(null, true, 4096, true, .stream, 24_000_000);
    try std.testing.expectEqual(capture.OutputFormat.bin, cmd.output_format);
    try std.testing.expectEqual(@as(usize, 4096), cmd.sample_bytes);
    try std.testing.expectEqual(true, cmd.decode_cross);
    try std.testing.expectEqual(usb.OperationMode.stream, cmd.op_mode);
    try std.testing.expectEqual(@as(u64, 24_000_000), cmd.samplerate_hz);
    switch (cmd.output_target) {
        .stdout => {},
        else => return error.TestExpectedEqual,
    }
}

test "buildCaptureCommand rejects stdout and output-file conflict" {
    try std.testing.expectError(
        error.InvalidArgument,
        buildCaptureCommand("capture.bin", true, 1024, false, .buffer, usb.DEFAULT_CAPTURE_SAMPLERATE_HZ),
    );
}

test "buildCaptureCommand enables decode-cross for sr file output" {
    const cmd = try buildCaptureCommand("capture.sr", false, 2048, false, .buffer, usb.DEFAULT_CAPTURE_SAMPLERATE_HZ);
    try std.testing.expectEqual(capture.OutputFormat.sr, cmd.output_format);
    try std.testing.expect(cmd.decode_cross);
    switch (cmd.output_target) {
        .file_path => |path| try std.testing.expectEqualStrings("capture.sr", path),
        else => return error.TestExpectedEqual,
    }
}
