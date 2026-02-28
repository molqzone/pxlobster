pub const libusb = @cImport({
    @cInclude("libusb.h");
});

test "libusb headers are reachable" {
    _ = libusb.libusb_init;
}
