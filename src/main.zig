const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const capture = if (builtin.is_test) struct {} else @import("capture.zig");
const usb = if (builtin.is_test) struct {} else @import("usb.zig");

const TestLibUsb = struct {
    pub const LIBUSB_SPEED_HIGH: c_int = 3;
    pub const LIBUSB_SPEED_SUPER: c_int = 4;
    pub const libusb_context = opaque {};
    pub const libusb_device = opaque {};
    pub const libusb_device_handle = opaque {};
};

const TestDevice = struct {
    pub fn isWchPxLogic(vid: u16, pid: u16) bool {
        return vid == 0x1A86 and pid == 0x5237;
    }

    pub fn isLegacyPxLogic(vid: u16, pid: u16) bool {
        return vid == 0x16C0 and pid == 0x05DC;
    }

    pub fn isSupportedPxLogic(vid: u16, pid: u16) bool {
        return TestDevice.isWchPxLogic(vid, pid) or TestDevice.isLegacyPxLogic(vid, pid);
    }
};

const device = if (builtin.is_test) TestDevice else @import("device.zig");
const c = if (builtin.is_test) TestLibUsb else @import("pxlobster").libusb;

pub fn main() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var cmd = args.parseArgs() catch |err| switch (err) {
        error.ShowHelp => {
            try printUsage(stdout);
            return;
        },
        error.InvalidArgument => {
            try printUsage(stderr);
            std.process.exit(2);
        },
        else => return err,
    };
    defer args.deinitCommand(&cmd, std.heap.page_allocator);

    switch (cmd) {
        .scan => try scanUsbDevices(stdout),
        .prime_fw => try primeFirmware(stdout),
        .capture => |options| try runCapture(options, stdout, stderr),
    }
}

const LogicModeProbe = union(enum) {
    value: u32,
    busy,
    unavailable,
};

fn isWchPxLogic(vid: u16, pid: u16) bool {
    return device.isWchPxLogic(vid, pid);
}

fn isLegacyPxLogic(vid: u16, pid: u16) bool {
    return device.isLegacyPxLogic(vid, pid);
}

fn isSupportedPxLogic(vid: u16, pid: u16) bool {
    return device.isSupportedPxLogic(vid, pid);
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage:
        \\  pxlobster --scan
        \\  pxlobster --prime-fw
        \\  pxlobster -o <path> [-c <key=value>] [--samples <bytes>|--time <ms>] [--decode-cross] [--op-mode <buffer|stream|loop>] [--samplerate <hz>]
        \\  pxlobster --stdout [-c <key=value>] [--samples <bytes>|--time <ms>] [--decode-cross] [--op-mode <buffer|stream|loop>] [--samplerate <hz>]
        \\
        \\Options:
        \\  --scan               Read-only scan for supported PX Logic devices.
        \\  --prime-fw           Inject firmware to detected PX Logic devices.
        \\  -o, --output-file    Output file (.sr => Sigrok session, others => raw binary).
        \\  --stdout             Stream raw binary capture to stdout (pipe-friendly).
        \\  -c, --config         Capture config key-value (e.g. samplerate=24M).
        \\  --samples            Capture bytes target for buffer/stream (default: 8388608).
        \\  --time               Capture duration target in milliseconds (mutually exclusive with --samples).
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
            if (!isSupportedPxLogic(vid, pid)) continue;
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

fn runCapture(cmd: args.CaptureCommand, stdout: anytype, stderr: anytype) !void {
    if (comptime builtin.is_test) {
        return;
    } else {
        var ctx: ?*c.libusb_context = null;
        const init_rc = c.libusb_init(&ctx);
        if (init_rc != 0 or ctx == null) return error.LibusbInitFailed;
        defer c.libusb_exit(ctx);

        const output_target = switch (cmd.output_target) {
            .file_path => |path| capture.CaptureOutputTarget{ .file_path = path },
            .stdout => capture.CaptureOutputTarget.stdout,
        };
        const output_format = switch (cmd.output_format) {
            .bin => capture.OutputFormat.bin,
            .sr => capture.OutputFormat.sr,
        };
        const op_mode = switch (cmd.op_mode) {
            .buffer => usb.OperationMode.buffer,
            .stream => usb.OperationMode.stream,
            .loop => usb.OperationMode.loop,
        };

        const stats = capture.runCapture(std.heap.page_allocator, ctx.?, .{
            .output_target = output_target,
            .output_format = output_format,
            .sample_bytes = cmd.sample_bytes,
            .duration_ms = cmd.time_ms,
            .decode_cross = cmd.decode_cross,
            .capture_profile = .{
                .op_mode = op_mode,
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

fn detectTag(dev: *c.libusb_device, vid: u16, pid: u16) ?[]const u8 {
    if (comptime builtin.is_test) {
        return modelLabelForIdentity(vid, pid, c.LIBUSB_SPEED_HIGH, .unavailable);
    } else {
        if (!isSupportedPxLogic(vid, pid)) return null;

        const usb_speed = c.libusb_get_device_speed(dev);
        const logic_mode: LogicModeProbe = if (isLegacyPxLogic(vid, pid)) readLogicMode(dev) else .unavailable;
        return modelLabelForIdentity(vid, pid, usb_speed, logic_mode) orelse "PX-Logic (ready)";
    }
}

fn modelLabelForIdentity(vid: u16, pid: u16, usb_speed: c_int, logic_mode: LogicModeProbe) ?[]const u8 {
    if (isWchPxLogic(vid, pid)) {
        return switch (usb_speed) {
            c.LIBUSB_SPEED_SUPER => "PX-Logic U3 channel 32",
            c.LIBUSB_SPEED_HIGH => "PX-Logic U2 channel 32",
            else => "PX-Logic channel 32",
        };
    }

    if (isLegacyPxLogic(vid, pid)) {
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
