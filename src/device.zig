const std = @import("std");
const firmware = @import("pxresources");
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

pub const fpga_reset_bitstream = firmware.fpga_reset_bitstream;
pub const fpga_bitstream = firmware.fpga_bitstream;

pub const UsbId = struct {
    vid: u16,
    pid: u16,
};

pub const pxlogic_wch_id = UsbId{ .vid = 0x1A86, .pid = 0x5237 };
pub const pxlogic_legacy_id = UsbId{ .vid = 0x16C0, .pid = 0x05DC };
pub const supported_pxlogic_ids = [_]UsbId{
    pxlogic_wch_id,
    pxlogic_legacy_id,
};

comptime {
    if (fpga_reset_bitstream.len == 0) @compileError("resources/hspi_ddr_RST.bin must not be empty");
    if (fpga_bitstream.len == 0) @compileError("resources/hspi_ddr.bin must not be empty");
}

pub fn isSupportedPxLogic(vid: u16, pid: u16) bool {
    for (supported_pxlogic_ids) |id| {
        if (isExactId(id, vid, pid)) return true;
    }
    return false;
}

pub fn isWchPxLogic(vid: u16, pid: u16) bool {
    return isExactId(pxlogic_wch_id, vid, pid);
}

pub fn isLegacyPxLogic(vid: u16, pid: u16) bool {
    return isExactId(pxlogic_legacy_id, vid, pid);
}

pub fn isExactId(id: UsbId, vid: u16, pid: u16) bool {
    return id.vid == vid and id.pid == pid;
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
    try std.testing.expect(isSupportedPxLogic(pxlogic_wch_id.vid, pxlogic_wch_id.pid));
    try std.testing.expect(isSupportedPxLogic(pxlogic_legacy_id.vid, pxlogic_legacy_id.pid));
    try std.testing.expect(isWchPxLogic(pxlogic_wch_id.vid, pxlogic_wch_id.pid));
    try std.testing.expect(isLegacyPxLogic(pxlogic_legacy_id.vid, pxlogic_legacy_id.pid));
    try std.testing.expect(!isSupportedPxLogic(0x046D, 0xC52B));
}

test "supported_pxlogic_ids provides canonical ID list" {
    try std.testing.expectEqual(@as(usize, 2), supported_pxlogic_ids.len);
    try std.testing.expect(isExactId(supported_pxlogic_ids[0], pxlogic_wch_id.vid, pxlogic_wch_id.pid));
    try std.testing.expect(isExactId(supported_pxlogic_ids[1], pxlogic_legacy_id.vid, pxlogic_legacy_id.pid));
    try std.testing.expect(!isExactId(supported_pxlogic_ids[0], pxlogic_legacy_id.vid, pxlogic_legacy_id.pid));
}

test "embedded firmware payloads are non-empty" {
    try std.testing.expect(fpga_reset_bitstream.len > 0);
    try std.testing.expect(fpga_bitstream.len > 0);
}
