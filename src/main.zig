const std = @import("std");
const builtin = @import("builtin");
const device = @import("device.zig");
const usb = @import("usb.zig");

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

    const cmd = parseArgs() catch |err| switch (err) {
        error.ShowHelp => return,
        error.InvalidArgument => {
            try printUsage(stderr);
            std.process.exit(2);
        },
        else => return err,
    };

    switch (cmd) {
        .scan => try scanUsbDevices(stdout),
        .prime_fw => try primeFirmware(stdout),
    }
}

const Command = enum {
    scan,
    prime_fw,
};

const LogicModeProbe = union(enum) {
    value: u32,
    busy,
    unavailable,
};

fn parseArgs() !Command {
    var args = std.process.args();
    _ = args.next();
    const stdout = std.fs.File.stdout().deprecatedWriter();
    var requested: ?Command = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scan")) {
            if (requested != null and requested.? != .scan) return error.InvalidArgument;
            requested = .scan;
            continue;
        }
        if (std.mem.eql(u8, arg, "--prime-fw")) {
            if (requested != null and requested.? != .prime_fw) return error.InvalidArgument;
            requested = .prime_fw;
            continue;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage(stdout);
            return error.ShowHelp;
        }
        return error.InvalidArgument;
    }

    if (requested) |cmd| return cmd;

    try printUsage(stdout);
    return error.InvalidArgument;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage:
        \\  pxlobster --scan
        \\  pxlobster --prime-fw
        \\
        \\Options:
        \\  --scan               Read-only scan for supported PX Logic devices.
        \\  --prime-fw           Inject firmware to detected PX Logic devices.
        \\  -h, --help           Show this help.
        \\
        \\Notes:
        \\  --scan and --prime-fw are mutually exclusive.
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

fn detectTag(dev: *c.libusb_device, vid: u16, pid: u16) ?[]const u8 {
    if (comptime builtin.is_test) {
        return modelLabelForIdentity(vid, pid, c.LIBUSB_SPEED_HIGH, .unavailable);
    } else {
        if (!device.isSupportedPxLogic(vid, pid)) return null;

        const usb_speed = c.libusb_get_device_speed(dev);
        const logic_mode: LogicModeProbe = if (vid == 0x16C0 and pid == 0x05DC) readLogicMode(dev) else .unavailable;
        return modelLabelForIdentity(vid, pid, usb_speed, logic_mode) orelse "PX-Logic (ready)";
    }
}

fn modelLabelForIdentity(vid: u16, pid: u16, usb_speed: c_int, logic_mode: LogicModeProbe) ?[]const u8 {
    if (vid == 0x1A86 and pid == 0x5237) {
        return switch (usb_speed) {
            c.LIBUSB_SPEED_SUPER => "PX-Logic U3 channel 32",
            c.LIBUSB_SPEED_HIGH => "PX-Logic U2 channel 32",
            else => "PX-Logic channel 32",
        };
    }

    if (vid == 0x16C0 and pid == 0x05DC) {
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
    try std.testing.expectEqualStrings("PX-Logic U3 channel 32", modelLabelForIdentity(0x1A86, 0x5237, c.LIBUSB_SPEED_SUPER, .unavailable).?);
    try std.testing.expectEqualStrings("PX-Logic U2 channel 32", modelLabelForIdentity(0x1A86, 0x5237, c.LIBUSB_SPEED_HIGH, .unavailable).?);
    try std.testing.expectEqualStrings("PX-Logic U3 channel 16 Pro", modelLabelForIdentity(0x16C0, 0x05DC, c.LIBUSB_SPEED_SUPER, .{ .value = 1 }).?);
    try std.testing.expectEqualStrings("PX-Logic U2 channel 16 Plus", modelLabelForIdentity(0x16C0, 0x05DC, c.LIBUSB_SPEED_HIGH, .{ .value = 2 }).?);
    try std.testing.expectEqualStrings("PX-Logic U3 (mode unknown)", modelLabelForIdentity(0x16C0, 0x05DC, c.LIBUSB_SPEED_SUPER, .unavailable).?);
    try std.testing.expectEqualStrings("PX-Logic (Busy)", modelLabelForIdentity(0x16C0, 0x05DC, c.LIBUSB_SPEED_HIGH, .busy).?);
}

test "modelLabelForIdentity returns null for unknown IDs" {
    try std.testing.expect(modelLabelForIdentity(0x046D, 0xC52B, c.LIBUSB_SPEED_HIGH, .unavailable) == null);
    try std.testing.expect(modelLabelForIdentity(0x0000, 0x0000, c.LIBUSB_SPEED_HIGH, .unavailable) == null);
}
