const std = @import("std");
const usb = @import("usb.zig");

const c = usb.c;

pub const BootstrapState = enum {
    ready,
    busy,
    failed,
};

pub const BootstrapOptions = struct {
    bulk_timeout_ms: u32 = 0,
};

pub const fpga_reset_bitstream = @embedFile("firmware/fpga_rst.bin");
pub const fpga_bitstream = @embedFile("firmware/fpga.bin");

const pxlogic_wch_vid: u16 = 0x1A86;
const pxlogic_wch_pid: u16 = 0x5237;
const pxlogic_legacy_vid: u16 = 0x16C0;
const pxlogic_legacy_pid: u16 = 0x05DC;

comptime {
    if (fpga_reset_bitstream.len == 0) @compileError("firmware/fpga_rst.bin must not be empty");
    if (fpga_bitstream.len == 0) @compileError("firmware/fpga.bin must not be empty");
}

pub fn isSupportedPxLogic(vid: u16, pid: u16) bool {
    return (vid == pxlogic_wch_vid and pid == pxlogic_wch_pid) or
        (vid == pxlogic_legacy_vid and pid == pxlogic_legacy_pid);
}

pub fn preparePxLogicDevice(dev: *c.libusb_device, options: BootstrapOptions) BootstrapState {
    const handle = usb.openDevice(dev) catch {
        return .busy;
    };
    defer usb.closeDevice(handle);

    return switch (uploadFpgaWithHandle(handle, options)) {
        .ready => .ready,
        .busy => .busy,
        .failed => .failed,
    };
}

const FpgaUploadState = enum {
    ready,
    busy,
    failed,
};

fn uploadFpgaWithHandle(handle: *c.libusb_device_handle, options: BootstrapOptions) FpgaUploadState {
    usb.claimInterface(handle, 0) catch return .busy;
    defer usb.releaseInterface(handle, 0);
    usb.claimInterface(handle, 1) catch return .busy;
    defer usb.releaseInterface(handle, 1);

    configureFpgaBitstream(handle, options) catch {
        return .failed;
    };

    return .ready;
}

fn configureFpgaBitstream(handle: *c.libusb_device_handle, options: BootstrapOptions) !void {
    // Follow PXView order: reset bitstream first, then main bitstream.
    try usb.clearHalt(handle, 0x03);
    try usb.writeDataUpdate(handle, 0, fpga_reset_bitstream, 4, options.bulk_timeout_ms);
    try usb.clearHalt(handle, 0x03);
    try usb.writeDataUpdate(handle, 0, fpga_bitstream, 4, options.bulk_timeout_ms);
}

test "id classification helpers are correct" {
    try std.testing.expect(isSupportedPxLogic(0x1A86, 0x5237));
    try std.testing.expect(isSupportedPxLogic(0x16C0, 0x05DC));
    try std.testing.expect(!isSupportedPxLogic(0x046D, 0xC52B));
}

test "embedded firmware payloads are non-empty" {
    try std.testing.expect(fpga_reset_bitstream.len > 0);
    try std.testing.expect(fpga_bitstream.len > 0);
}
