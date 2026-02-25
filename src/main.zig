const std = @import("std");
const builtin = @import("builtin");

const TestLibUsb = struct {
    pub const LIBUSB_SPEED_HIGH: c_int = 3;
    pub const LIBUSB_SPEED_SUPER: c_int = 4;
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
            return err;
        },
        else => return err,
    };

    switch (cmd) {
        .scan => try scanUsbDevices(stdout),
    }
}

const Command = enum {
    scan,
};

fn parseArgs() !Command {
    var args = std.process.args();
    _ = args.next();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scan")) return .scan;
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage(stdout);
            return error.ShowHelp;
        }
        return error.InvalidArgument;
    }

    try printUsage(stdout);
    return error.InvalidArgument;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage:
        \\  pxlobster --scan
        \\
        \\Options:
        \\  --scan       Enumerate supported PX Logic USB devices.
        \\  -h, --help   Show this help.
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

        var device_list: [*c]?*c.libusb_device = undefined;
        const count = c.libusb_get_device_list(ctx, &device_list);
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

fn detectTag(dev: *c.libusb_device, vid: u16, pid: u16) ?[]const u8 {
    if (comptime builtin.is_test) {
        return modelLabelForIdentity(vid, pid, c.LIBUSB_SPEED_HIGH, null);
    } else {
        const usb_speed = c.libusb_get_device_speed(dev);
        const logic_mode: ?u32 = if (vid == 0x16C0 and pid == 0x05DC) readLogicMode(dev) else null;
        return modelLabelForIdentity(vid, pid, usb_speed, logic_mode);
    }
}

fn modelLabelForIdentity(vid: u16, pid: u16, usb_speed: c_int, logic_mode: ?u32) ?[]const u8 {
    if (vid == 0x1A86 and pid == 0x5237) {
        return switch (usb_speed) {
            c.LIBUSB_SPEED_SUPER => "PX-Logic U3 channel 32",
            c.LIBUSB_SPEED_HIGH => "PX-Logic U2 channel 32",
            else => "PX-Logic channel 32",
        };
    }

    if (vid == 0x16C0 and pid == 0x05DC) {
        if (logic_mode) |mode| {
            return switch (mode) {
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
            };
        }

        return switch (usb_speed) {
            c.LIBUSB_SPEED_SUPER => "PX-Logic U3 (mode unknown)",
            c.LIBUSB_SPEED_HIGH => "PX-Logic U2 (mode unknown)",
            else => "PX-Logic (mode unknown)",
        };
    }
    return null;
}

fn readLogicMode(dev: *c.libusb_device) ?u32 {
    if (comptime builtin.is_test) {
        return null;
    } else {
        var desc: c.libusb_device_descriptor = undefined;
        if (c.libusb_get_device_descriptor(dev, &desc) != 0) return null;

        var handle_opt: ?*c.libusb_device_handle = null;
        if (c.libusb_open(dev, &handle_opt) != 0 or handle_opt == null) return null;
        const handle = handle_opt.?;
        defer c.libusb_close(handle);

        if (!isPxManufacturer(handle, desc.iManufacturer)) return null;

        if (c.libusb_claim_interface(handle, 0) != 0) return null;
        defer _ = c.libusb_release_interface(handle, 0);
        if (c.libusb_claim_interface(handle, 1) != 0) return null;
        defer _ = c.libusb_release_interface(handle, 1);

        var packet = [_]u32{
            0xfefe0001,
            0x08,
            8192 + 22 * 4,
            0,
        };
        const bytes = std.mem.asBytes(&packet);
        const packet_ptr: [*c]u8 = @ptrCast(bytes.ptr);

        if (c.libusb_bulk_transfer(handle, 0x01, packet_ptr, @intCast(bytes.len), null, 1000) != 0) return null;
        if (c.libusb_bulk_transfer(handle, 0x81, packet_ptr, @intCast(bytes.len), null, 1000) != 0) return null;

        return packet[3];
    }
}

fn isPxManufacturer(handle: *c.libusb_device_handle, manufacturer_index: u8) bool {
    if (comptime builtin.is_test) {
        return false;
    } else {
        if (manufacturer_index == 0) return false;

        var buf: [64]u8 = undefined;
        const buf_ptr: [*c]u8 = @ptrCast(buf[0..].ptr);
        const len = c.libusb_get_string_descriptor_ascii(handle, manufacturer_index, buf_ptr, @intCast(buf.len));
        return len >= 2 and buf[0] == 'P' and buf[1] == 'X';
    }
}

test "modelLabelForIdentity matches PX Logic profiles" {
    try std.testing.expectEqualStrings("PX-Logic U3 channel 32", modelLabelForIdentity(0x1A86, 0x5237, c.LIBUSB_SPEED_SUPER, null).?);
    try std.testing.expectEqualStrings("PX-Logic U2 channel 32", modelLabelForIdentity(0x1A86, 0x5237, c.LIBUSB_SPEED_HIGH, null).?);
    try std.testing.expectEqualStrings("PX-Logic U3 channel 16 Pro", modelLabelForIdentity(0x16C0, 0x05DC, c.LIBUSB_SPEED_SUPER, 1).?);
    try std.testing.expectEqualStrings("PX-Logic U2 channel 16 Plus", modelLabelForIdentity(0x16C0, 0x05DC, c.LIBUSB_SPEED_HIGH, 2).?);
    try std.testing.expectEqualStrings("PX-Logic U3 (mode unknown)", modelLabelForIdentity(0x16C0, 0x05DC, c.LIBUSB_SPEED_SUPER, null).?);
}

test "modelLabelForIdentity returns null for unknown IDs" {
    try std.testing.expect(modelLabelForIdentity(0x046D, 0xC52B, c.LIBUSB_SPEED_HIGH, null) == null);
    try std.testing.expect(modelLabelForIdentity(0x0000, 0x0000, c.LIBUSB_SPEED_HIGH, null) == null);
}
