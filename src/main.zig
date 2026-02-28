const std = @import("std");
const args = @import("args.zig");
const capture = @import("capture.zig");
const usb = @import("usb.zig");
const device = @import("device.zig");
const c = usb.c;

/// CLI 入口：解析参数、分发命令并将失败映射到退出码 / CLI entry point: parse args, dispatch command, and map failures to exit codes.
pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout.interface.flush() catch {};
    var stderr = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr.interface.flush() catch {};

    var parsed = args.parseArgs() catch |err| switch (err) {
        error.ShowHelp => {
            try printUsage(&stdout.interface);
            return;
        },
        error.InvalidArgument => {
            try printUsage(&stderr.interface);
            try stderr.interface.flush();
            std.process.exit(2);
        },
        else => return err,
    };
    defer args.deinitParsedCommand(&parsed, std.heap.page_allocator);

    switch (parsed.command) {
        .scan => try scanUsbDevices(&stdout.interface, &stderr.interface, parsed.verbose),
        .prime_fw => try primeFirmware(&stdout.interface, &stderr.interface, parsed.verbose),
        .capture => try runCapture(parsed, &stdout.interface, &stderr.interface),
    }
}

const LogicModeProbe = union(enum) {
    value: u32,
    busy,
    unavailable,
};

/// 打印 CLI 用法与参数说明 / Prints CLI usage and option descriptions.
fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage:
        \\  pxlobster [--verbose] --scan
        \\  pxlobster [--verbose] --prime-fw
        \\  pxlobster [--verbose] -o <path> --format <bin|sr> [--samples <bytes>|--time <ms>] [--decode-cross] [--mode <buffer|stream|loop>] [-t <spec>] [--samplerate <hz>]
        \\  pxlobster [--verbose] --stdout --format <bin> [--samples <bytes>|--time <ms>] [--decode-cross] [--mode <buffer|stream|loop>] [-t <spec>] [--samplerate <hz>]
        \\
        \\Options:
        \\  --scan               Read-only scan for supported PX Logic devices.
        \\  --prime-fw           Inject firmware to detected PX Logic devices.
        \\  -o, --output-file    Output destination file path.
        \\  --stdout             Stream capture bytes to stdout (pipe-friendly).
        \\  --format             Explicit output format: bin | sr (required for capture; --stdout supports bin only).
        \\  --samples            Capture bytes target for buffer/stream (default: 8388608).
        \\  --time               Capture duration target in milliseconds (mutually exclusive with --samples).
        \\  --decode-cross       Decode PXView LA_CROSS_DATA into packed channel samples.
        \\  --mode               Capture operation mode: buffer | stream | loop (default: buffer).
        \\  -t, --triggers       Trigger spec, e.g. 0=1,1=r,2=f,3=0.
        \\  --samplerate         Capture sample rate in Hz (must be a PXView-supported discrete value).
        \\  -v, --verbose        Enable verbose debug logs (written to stderr).
        \\  -h, --help           Show this help.
        \\
        \\Notes:
        \\  --scan, --prime-fw, and capture mode are mutually exclusive.
        \\  Output target (--stdout / --output-file) and output format (--format) are configured independently.
        \\  File extension does not control output format.
        \\  loop mode runs continuously until Ctrl+C.
        \\
    );
}

/// 仅在 `--verbose` 打开时输出调试日志 / Emits verbose logs only when `--verbose` is enabled.
fn verboseLog(enabled: bool, writer: anytype, comptime fmt: []const u8, values: anytype) !void {
    if (!enabled) return;
    try writer.print(fmt, values);
}

/// 枚举已连接设备并打印受支持 PX Logic 识别信息 / Enumerates connected devices and prints supported PX Logic identities.
fn scanUsbDevices(stdout: anytype, stderr: anytype, verbose: bool) !void {
    try verboseLog(verbose, stderr, "verbose: scan start\n", .{});
    var ctx: ?*c.libusb_context = null;
    const init_rc = c.libusb_init(&ctx);
    if (init_rc != 0 or ctx == null) return error.LibusbInitFailed;
    defer c.libusb_exit(ctx);
    try verboseLog(verbose, stderr, "verbose: libusb_init ok\n", .{});

    const active_ctx = ctx.?;

    var device_list: [*c]?*c.libusb_device = undefined;
    const count = c.libusb_get_device_list(active_ctx, &device_list);
    if (count < 0) return error.LibusbGetDeviceListFailed;
    defer c.libusb_free_device_list(device_list, 1);
    try verboseLog(verbose, stderr, "verbose: device count={d}\n", .{count});

    var found_supported = false;
    const count_usize: usize = @intCast(count);
    const device_slice = @as([*]?*c.libusb_device, @ptrCast(device_list))[0..count_usize];
    for (device_slice) |dev_opt| {
        if (dev_opt == null) continue;

        var desc: c.libusb_device_descriptor = undefined;
        if (c.libusb_get_device_descriptor(dev_opt.?, &desc) != 0) continue;

        const vid: u16 = @intCast(desc.idVendor);
        const pid: u16 = @intCast(desc.idProduct);
        const bus = c.libusb_get_bus_number(dev_opt.?);
        const address = c.libusb_get_device_address(dev_opt.?);
        const speed = c.libusb_get_device_speed(dev_opt.?);
        try verboseLog(verbose, stderr, "verbose: scan device bus={d} addr={d} speed={d} vid={X:0>4} pid={X:0>4}\n", .{ bus, address, speed, vid, pid });
        const tag = detectTag(dev_opt.?, vid, pid);
        if (tag) |label| {
            found_supported = true;
            try verboseLog(verbose, stderr, "verbose: matched {s}\n", .{label});
            try stdout.print("{X:0>4}:{X:0>4}  {s}\n", .{ vid, pid, label });
        }
    }

    if (!found_supported) {
        try stdout.writeAll("No supported devices found.\n");
        try verboseLog(verbose, stderr, "verbose: no supported devices detected\n", .{});
    }
}

/// 向受支持 PX Logic 设备上传固件与位流 / Uploads firmware/bitstream to supported PX Logic devices.
fn primeFirmware(stdout: anytype, stderr: anytype, verbose: bool) !void {
    try verboseLog(verbose, stderr, "verbose: prime-fw start\n", .{});
    var ctx: ?*c.libusb_context = null;
    const init_rc = c.libusb_init(&ctx);
    if (init_rc != 0 or ctx == null) return error.LibusbInitFailed;
    defer c.libusb_exit(ctx);
    try verboseLog(verbose, stderr, "verbose: libusb_init ok\n", .{});

    const active_ctx = ctx.?;

    var device_list: [*c]?*c.libusb_device = undefined;
    const count = c.libusb_get_device_list(active_ctx, &device_list);
    if (count < 0) return error.LibusbGetDeviceListFailed;
    defer c.libusb_free_device_list(device_list, 1);
    try verboseLog(verbose, stderr, "verbose: device count={d}\n", .{count});

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
        try verboseLog(verbose, stderr, "verbose: prime candidate vid={X:0>4} pid={X:0>4}\n", .{ vid, pid });

        const state = device.preparePxLogicDevice(dev_opt.?, .{});
        try verboseLog(verbose, stderr, "verbose: prime result={s}\n", .{@tagName(state)});
        switch (state) {
            .ready => {
                const label = detectTag(dev_opt.?, vid, pid) orelse "PX-Logic (ready)";
                try stdout.print("{X:0>4}:{X:0>4}  {s}  [fw loaded]\n", .{ vid, pid, label });
            },
            .busy => try stdout.print("{X:0>4}:{X:0>4}  PX-Logic (Busy)\n", .{ vid, pid }),
            .failed => try stdout.print("{X:0>4}:{X:0>4}  PX-Logic (firmware load failed)\n", .{ vid, pid }),
        }
    }

    if (!found_supported) {
        try stdout.writeAll("No supported devices found.\n");
        try verboseLog(verbose, stderr, "verbose: no supported devices detected\n", .{});
    }
}

/// 将解析后的采集命令转换为运行参数并执行采集 / Converts parsed capture command to runtime options and executes capture.
fn runCapture(parsed: args.ParsedCommand, stdout: anytype, stderr: anytype) !void {
    const cmd = switch (parsed.command) {
        .capture => |capture_cmd| capture_cmd,
        else => unreachable,
    };
    const verbose = parsed.verbose;

    try verboseLog(verbose, stderr, "verbose: capture start mode={s} samplerate={d} samples={d} decode_cross={any} strict_probe={any}\n", .{
        @tagName(cmd.op_mode),
        cmd.samplerate_hz,
        cmd.sample_bytes,
        cmd.decode_cross,
        cmd.triggers_specified,
    });
    if (cmd.time_ms) |duration_ms| {
        try verboseLog(verbose, stderr, "verbose: capture duration_ms={d}\n", .{duration_ms});
    }
    try verboseLog(verbose, stderr, "verbose: trigger masks zero=0x{X:0>8} one=0x{X:0>8} rise=0x{X:0>8} fall=0x{X:0>8}\n", .{
        cmd.trigger_zero,
        cmd.trigger_one,
        cmd.trigger_rise,
        cmd.trigger_fall,
    });

    var ctx: ?*c.libusb_context = null;
    const init_rc = c.libusb_init(&ctx);
    if (init_rc != 0 or ctx == null) return error.LibusbInitFailed;
    defer c.libusb_exit(ctx);
    try verboseLog(verbose, stderr, "verbose: libusb_init ok\n", .{});

    const output_target = switch (cmd.output_target) {
        .file_path => |path| capture.CaptureOutputTarget{ .file_path = path },
        .stdout => capture.CaptureOutputTarget.stdout,
    };
    const output_format = switch (cmd.output_format) {
        .bin => capture.OutputFormat.bin,
        .sr => capture.OutputFormat.sr,
    };
    const stats = capture.runCapture(std.heap.page_allocator, ctx.?, .{
        .output_target = output_target,
        .output_format = output_format,
        .sample_bytes = cmd.sample_bytes,
        .duration_ms = cmd.time_ms,
        .strict_channel_count_probe = cmd.triggers_specified,
        .decode_cross = cmd.decode_cross,
        .capture_profile = .{
            .op_mode = cmd.op_mode,
            .samplerate_hz = cmd.samplerate_hz,
            .trigger_zero = cmd.trigger_zero,
            .trigger_one = cmd.trigger_one,
            .trigger_rise = cmd.trigger_rise,
            .trigger_fall = cmd.trigger_fall,
        },
    }) catch |err| {
        try stderr.print("capture failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };

    try verboseLog(verbose, stderr, "verbose: capture done bytes_out={d} bytes_in={d} dropped={d} elapsed_ms={d}\n", .{
        stats.bytes_out,
        stats.bytes_in,
        stats.dropped,
        stats.elapsed_ms,
    });

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

fn detectTag(dev: *c.libusb_device, vid: u16, pid: u16) ?[]const u8 {
    if (!device.isSupportedPxLogic(vid, pid)) return null;

    const usb_speed = c.libusb_get_device_speed(dev);
    const logic_mode: LogicModeProbe = if (device.isLegacyPxLogic(vid, pid)) readLogicMode(dev) else .unavailable;
    return modelLabelForIdentity(vid, pid, usb_speed, logic_mode) orelse "PX-Logic (ready)";
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

fn isPxManufacturer(handle: *c.libusb_device_handle, manufacturer_index: u8) bool {
    if (manufacturer_index == 0) return false;

    var buf: [64]u8 = undefined;
    const len = c.libusb_get_string_descriptor_ascii(handle, manufacturer_index, &buf, @intCast(buf.len));
    return len >= 2 and buf[0] == 'P' and buf[1] == 'X';
}

test "modelLabelForIdentity matches PX Logic profiles" {
    const wch_vid: u16 = 0x1A86;
    const wch_pid: u16 = 0x5237;
    const legacy_vid: u16 = 0x16C0;
    const legacy_pid: u16 = 0x05DC;

    try std.testing.expectEqualStrings(
        "PX-Logic U3 channel 32",
        modelLabelForIdentity(wch_vid, wch_pid, c.LIBUSB_SPEED_SUPER, .unavailable).?,
    );
    try std.testing.expectEqualStrings(
        "PX-Logic U2 channel 32",
        modelLabelForIdentity(wch_vid, wch_pid, c.LIBUSB_SPEED_HIGH, .unavailable).?,
    );
    try std.testing.expectEqualStrings(
        "PX-Logic U3 channel 16 Pro",
        modelLabelForIdentity(legacy_vid, legacy_pid, c.LIBUSB_SPEED_SUPER, .{ .value = 1 }).?,
    );
    try std.testing.expectEqualStrings(
        "PX-Logic U2 channel 16 Plus",
        modelLabelForIdentity(legacy_vid, legacy_pid, c.LIBUSB_SPEED_HIGH, .{ .value = 2 }).?,
    );
    try std.testing.expectEqualStrings(
        "PX-Logic U3 (mode unknown)",
        modelLabelForIdentity(legacy_vid, legacy_pid, c.LIBUSB_SPEED_SUPER, .unavailable).?,
    );
    try std.testing.expectEqualStrings(
        "PX-Logic (Busy)",
        modelLabelForIdentity(legacy_vid, legacy_pid, c.LIBUSB_SPEED_HIGH, .busy).?,
    );
}

test "modelLabelForIdentity returns null for unknown IDs" {
    try std.testing.expect(modelLabelForIdentity(0x046D, 0xC52B, c.LIBUSB_SPEED_HIGH, .unavailable) == null);
    try std.testing.expect(modelLabelForIdentity(0x0000, 0x0000, c.LIBUSB_SPEED_HIGH, .unavailable) == null);
}

test "parseArgsFromSlice keeps scan and capture mutually exclusive" {
    const argv = [_][]const u8{ "pxlobster", "--scan", "--stdout" };
    try std.testing.expectError(error.InvalidArgument, args.parseArgsFromSlice(&argv, std.testing.allocator));
}
