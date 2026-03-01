const std = @import("std");
const firmware = @import("pxresources");
const usb = @import("usb.zig");

const c = usb.c;

/// PX Logic 设备采集前准备结果 / Result of preparing a PX Logic device for capture.
pub const BootstrapState = enum {
    /// 设备已就绪，可接收采集命令 / Device is ready for capture commands.
    ready,
    /// 设备存在，但当前不可用或忙碌 / Device is present but currently unavailable/busy.
    busy,
    /// 设备存在，但访问被系统权限拒绝（常见于 Linux 缺少 udev 放行） / Device is present but access is denied by OS permissions (commonly missing udev rules on Linux).
    permission_denied,
    /// 固件或 FPGA 引导失败 / Firmware/FPGA bootstrap failed.
    failed,
};

/// 引导传输可选调优参数 / Optional tuning knobs for bootstrap transfers.
pub const BootstrapOptions = struct {
    /// 固件 bulk 传输超时（0 表示使用默认值） / Timeout used for firmware bulk transfers (0 uses defaults).
    bulk_timeout_ms: u32 = 0,
};

/// 随二进制内嵌的复位位流 / Embedded reset bitstream shipped with this binary.
pub const fpga_reset_bitstream = firmware.fpga_reset_bitstream;
/// 随二进制内嵌的主 FPGA 位流 / Embedded main FPGA bitstream shipped with this binary.
pub const fpga_bitstream = firmware.fpga_bitstream;

/// USB 厂商/产品 ID 组合 / USB vendor/product identifier pair.
pub const UsbId = struct {
    vid: u16,
    pid: u16,
};

/// WCH 方案设备使用的现代 PX Logic VID/PID / Modern PX Logic VID/PID pair used by WCH-based devices.
pub const pxlogic_wch_id = UsbId{ .vid = 0x1A86, .pid = 0x5237 };
/// 为 PXView 兼容保留的 legacy PX Logic VID/PID / Legacy PX Logic VID/PID pair retained for PXView compatibility.
pub const pxlogic_legacy_id = UsbId{ .vid = 0x16C0, .pid = 0x05DC };
/// 受支持 PX Logic 设备的标准 VID/PID 列表 / Canonical list of all VID/PID pairs treated as supported PX Logic devices.
pub const supported_pxlogic_ids = [_]UsbId{
    pxlogic_wch_id,
    pxlogic_legacy_id,
};

comptime {
    if (fpga_reset_bitstream.len == 0) @compileError("resources/hspi_ddr_RST.bin must not be empty");
    if (fpga_bitstream.len == 0) @compileError("resources/hspi_ddr.bin must not be empty");
}

/// 若 VID/PID 属于任一受支持 PX Logic 家族则返回 true / Returns true if the VID/PID belongs to any supported PX Logic family.
pub fn isSupportedPxLogic(vid: u16, pid: u16) bool {
    for (supported_pxlogic_ids) |id| {
        if (isExactId(id, vid, pid)) return true;
    }
    return false;
}

/// 当 ID 匹配 WCH PX Logic 变体时返回 true / Returns true when the ID matches the WCH PX Logic variant.
pub fn isWchPxLogic(vid: u16, pid: u16) bool {
    return isExactId(pxlogic_wch_id, vid, pid);
}

/// 当 ID 匹配 legacy PX Logic 变体时返回 true / Returns true when the ID matches the legacy PX Logic variant.
pub fn isLegacyPxLogic(vid: u16, pid: u16) bool {
    return isExactId(pxlogic_legacy_id, vid, pid);
}

/// 精确 VID/PID 匹配辅助函数 / Exact VID/PID matcher helper.
pub fn isExactId(id: UsbId, vid: u16, pid: u16) bool {
    return id.vid == vid and id.pid == pid;
}

/// 按 PXView 兼容顺序打开设备并上传固件/位流 / Opens the device and uploads firmware/bitstream in PXView-compatible order.
pub fn preparePxLogicDevice(dev: *c.libusb_device, options: BootstrapOptions) BootstrapState {
    const handle = usb.openDevice(dev) catch |err| {
        return switch (err) {
            error.LibusbPermissionDenied => .permission_denied,
            else => .busy,
        };
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
    // 按 PXView 顺序先写复位位流，再写主位流 / Follow PXView order: reset bitstream first, then main bitstream.
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
