const std = @import("std");

pub const libusb = @cImport({
    @cInclude("libusb.h");
});

pub fn bufferedPrint() !void {
    std.debug.print("pxlobster core ready.\n", .{});
}

test "libusb headers are reachable" {
    _ = libusb.libusb_init;
}
