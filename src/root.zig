/// 所有 USB 模块共享的 libusb C 绑定入口 / Direct libusb C bindings shared by all USB-facing modules.
pub const libusb = @import("c");

test "libusb headers are reachable" {
    _ = libusb.libusb_init;
}
