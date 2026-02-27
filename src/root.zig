const std = @import("std");
const builtin = @import("builtin");

const TestLibUsb = struct {
    // Single-file `zig test src/root.zig` does not link libc/include paths.
    pub const libusb_init = struct {};
};

pub const libusb = if (builtin.link_libc) @cImport({
    @cInclude("libusb.h");
}) else TestLibUsb;

pub fn bufferedPrint() !void {
    std.debug.print("pxlobster core ready.\n", .{});
}

test "libusb headers are reachable" {
    if (!builtin.link_libc) return;
    _ = libusb.libusb_init;
}
