pub const BootstrapState = enum {
    ready,
    busy,
    failed,
};

pub const BootstrapOptions = struct {
    bulk_timeout_ms: u32 = 0,
};

pub const UsbId = struct {
    vid: u16,
    pid: u16,
};

pub const pxlogic_wch_id = UsbId{ .vid = 0x1A86, .pid = 0x5237 };
pub const pxlogic_legacy_id = UsbId{ .vid = 0x16C0, .pid = 0x05DC };

pub fn isSupportedPxLogic(vid: u16, pid: u16) bool {
    return isWchPxLogic(vid, pid) or isLegacyPxLogic(vid, pid);
}

pub fn isWchPxLogic(vid: u16, pid: u16) bool {
    return vid == pxlogic_wch_id.vid and pid == pxlogic_wch_id.pid;
}

pub fn isLegacyPxLogic(vid: u16, pid: u16) bool {
    return vid == pxlogic_legacy_id.vid and pid == pxlogic_legacy_id.pid;
}

pub fn preparePxLogicDevice(_: anytype, _: BootstrapOptions) BootstrapState {
    return .ready;
}
