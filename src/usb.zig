const std = @import("std");

pub const c = @import("pxlobster").libusb;

pub const BULK_EP_REG_OUT: u8 = 0x01;
pub const BULK_EP_REG_IN: u8 = 0x81;
pub const BULK_EP_DATA_OUT: u8 = 0x03;
pub const BULK_EP_DATA_IN: u8 = 0x82;

pub const CMD_WRITE_REGISTER: u32 = 0xFEFE0000;
pub const CMD_READ_REGISTER: u32 = 0xFEFE0001;
pub const CMD_REGISTER_ACK: u32 = 0xFEFEFEFE;
pub const CMD_CTL_READ: u8 = 0xB0;

pub const REG_BASE: u32 = 8192;
pub const REG_STREAM_CONTROL: u32 = 0 << 2;
pub const REG_STREAM_TRANSFER_SIZE: u32 = 7 << 2;
pub const REG_STREAM_START: u32 = 8 << 2;
pub const REG_STREAM_CHANNEL_ENABLE: u32 = 4 << 2;
pub const REG_GPIO_MODE: u32 = 5 << 2;
pub const REG_GPIO_DIV: u32 = 6 << 2;
pub const REG_TRIGGER_ZERO: u32 = 9 << 2;
pub const REG_TRIGGER_ONE: u32 = 10 << 2;
pub const REG_TRIGGER_RISE: u32 = 11 << 2;
pub const REG_TRIGGER_FALL: u32 = 12 << 2;
pub const REG_EXT_TRIGGER_MODE: u32 = 15 << 2;
pub const REG_TRIGGER_OUT_ENABLE: u32 = 22 << 2;
pub const REG_THRESHOLD_PWM_MAX: u32 = 2 << 1;
pub const REG_THRESHOLD_VALUE: u32 = 2 << 2;
pub const REG_STREAM_DMA_SIZE: u32 = REG_BASE + 2 * 4;
pub const REG_WRITE_DATA_START: u32 = REG_BASE + 6 * 4;
pub const REG_WRITE_DATA_END: u32 = REG_BASE + 7 * 4;
pub const REG_WRITE_DATA_MODE: u32 = REG_BASE + 8 * 4;
pub const REG_CAPTURE_BYTES_LOW: u32 = REG_BASE + 9 * 4;
pub const REG_CAPTURE_BYTES_HIGH: u32 = REG_BASE + 10 * 4;
pub const REG_BLOCK_START: u32 = REG_BASE + 11 * 4;
pub const REG_CAPTURE_CHANNEL_COUNT: u32 = REG_BASE + 19 * 4;
pub const REG_CAPTURE_TRIGGER_POS: u32 = REG_BASE + 20 * 4;
pub const REG_LOGIC_MODE: u32 = REG_BASE + 22 * 4;

pub const DEFAULT_REGISTER_TIMEOUT_MS: u32 = 1000;
pub const DEFAULT_CAPTURE_TRANSFER_SIZE: usize = 256 * 1024;
pub const DEFAULT_CAPTURE_TRANSFER_COUNT: usize = 8;
pub const DEFAULT_CAPTURE_EVENT_TIMEOUT_MS: u32 = 20;

pub const STREAM_MODE_MASK: u32 = 0;
pub const STREAM_ENABLE_FLAGS: u32 = 0x00000005 | STREAM_MODE_MASK;
pub const STREAM_ENABLE_PULSE_FLAGS: u32 = STREAM_ENABLE_FLAGS | (1 << 4);
pub const STREAM_RUN_FLAGS: u32 = STREAM_MODE_MASK;
pub const STREAM_START_FLAGS: u32 = 0x0000_0000;
pub const STREAM_STOP_FLAGS: u32 = 0xFFFF_FFFF;
pub const DEFAULT_CAPTURE_CHANNEL_COUNT: u32 = 16;
pub const DEFAULT_CAPTURE_TRIGGER_POS: u32 = 64;
pub const DEFAULT_GPIO_MODE: u32 = 2;
pub const DEFAULT_GPIO_DIV: u32 = 0;
pub const DEFAULT_EXT_TRIGGER_MODE: u32 = 0;
pub const DEFAULT_TRIGGER_OUT_ENABLE: u32 = 0;
pub const DEFAULT_TRIGGER_MASK: u32 = 0;
pub const DEFAULT_PWM_CLOCK_HZ: u32 = 120_000_000;
pub const DEFAULT_THRESHOLD_PWM_FREQ_HZ: u32 = 10_000;
pub const DEFAULT_VTH_VOLTS: f64 = 2.0;
pub const DEFAULT_VTH_SCALE: f64 = 3.334;

pub const DeviceSnapshot = struct {
    vid: u16,
    pid: u16,
    speed: c_int,
    bus: u8,
    address: u8,
};

pub const ControlStatus = extern struct {
    sync_cur_sample: u64,
    trig_out_validset: u32,
    real_pos: u32,
};

pub fn listSnapshots(allocator: std.mem.Allocator, ctx: *c.libusb_context) ![]DeviceSnapshot {
    var device_list: [*c]?*c.libusb_device = undefined;
    const count = c.libusb_get_device_list(ctx, &device_list);
    if (count < 0) return error.LibusbGetDeviceListFailed;
    defer c.libusb_free_device_list(device_list, 1);

    var snapshots: std.ArrayList(DeviceSnapshot) = .empty;
    defer snapshots.deinit(allocator);

    const count_usize: usize = @intCast(count);
    const device_slice = @as([*]?*c.libusb_device, @ptrCast(device_list))[0..count_usize];
    for (device_slice) |dev_opt| {
        if (dev_opt == null) continue;
        if (snapshotFromDevice(dev_opt.?)) |snapshot| {
            try snapshots.append(allocator, snapshot);
        }
    }

    return snapshots.toOwnedSlice(allocator);
}

pub fn snapshotFromDevice(dev: *c.libusb_device) ?DeviceSnapshot {
    var desc: c.libusb_device_descriptor = undefined;
    if (c.libusb_get_device_descriptor(dev, &desc) != 0) return null;

    return .{
        .vid = @intCast(desc.idVendor),
        .pid = @intCast(desc.idProduct),
        .speed = c.libusb_get_device_speed(dev),
        .bus = c.libusb_get_bus_number(dev),
        .address = c.libusb_get_device_address(dev),
    };
}

pub fn openDevice(dev: *c.libusb_device) !*c.libusb_device_handle {
    var handle_opt: ?*c.libusb_device_handle = null;
    if (c.libusb_open(dev, &handle_opt) != 0 or handle_opt == null) {
        return error.LibusbOpenFailed;
    }
    return handle_opt.?;
}

pub fn openFirstDeviceByVidPid(ctx: *c.libusb_context, vid: u16, pid: u16) !?*c.libusb_device_handle {
    var device_list: [*c]?*c.libusb_device = undefined;
    const count = c.libusb_get_device_list(ctx, &device_list);
    if (count < 0) return error.LibusbGetDeviceListFailed;
    defer c.libusb_free_device_list(device_list, 1);

    const count_usize: usize = @intCast(count);
    const device_slice = @as([*]?*c.libusb_device, @ptrCast(device_list))[0..count_usize];
    for (device_slice) |dev_opt| {
        if (dev_opt == null) continue;
        if (snapshotFromDevice(dev_opt.?)) |snapshot| {
            if (snapshot.vid == vid and snapshot.pid == pid) {
                return openDevice(dev_opt.?);
            }
        }
    }

    return null;
}

pub fn closeDevice(handle: *c.libusb_device_handle) void {
    c.libusb_close(handle);
}

pub fn claimInterface(handle: *c.libusb_device_handle, index: c_int) !void {
    if (c.libusb_claim_interface(handle, index) != 0) {
        return error.LibusbClaimInterfaceFailed;
    }
}

pub fn releaseInterface(handle: *c.libusb_device_handle, index: c_int) void {
    _ = c.libusb_release_interface(handle, index);
}

pub fn controlTransferVendorOut(
    handle: *c.libusb_device_handle,
    request: u8,
    value: u16,
    index: u16,
    data: []const u8,
    timeout_ms: u32,
) !void {
    const payload: [*c]u8 = @ptrCast(@constCast(data.ptr));
    const rc = c.libusb_control_transfer(
        handle,
        c.LIBUSB_REQUEST_TYPE_VENDOR | c.LIBUSB_ENDPOINT_OUT,
        request,
        value,
        index,
        payload,
        @intCast(data.len),
        timeout_ms,
    );
    const expected: c_int = @intCast(data.len);
    if (rc < 0 or rc != expected) return error.LibusbControlTransferFailed;
}

pub fn controlTransferVendorIn(
    handle: *c.libusb_device_handle,
    request: u8,
    value: u16,
    index: u16,
    data: []u8,
    timeout_ms: u32,
) !usize {
    const payload: [*c]u8 = @ptrCast(data.ptr);
    const rc = c.libusb_control_transfer(
        handle,
        c.LIBUSB_REQUEST_TYPE_VENDOR | c.LIBUSB_ENDPOINT_IN,
        request,
        value,
        index,
        payload,
        @intCast(data.len),
        timeout_ms,
    );
    if (rc < 0) return error.LibusbControlTransferFailed;
    return @intCast(rc);
}

pub fn readControlStatus(handle: *c.libusb_device_handle, timeout_ms: u32) !ControlStatus {
    var status: ControlStatus = std.mem.zeroes(ControlStatus);
    const bytes = std.mem.asBytes(&status);
    const read_len = try controlTransferVendorIn(handle, CMD_CTL_READ, 0, 0, bytes, timeout_ms);
    if (read_len != bytes.len) return error.ControlStatusLengthMismatch;
    return status;
}

pub fn bulkWrite(handle: *c.libusb_device_handle, endpoint: u8, data: []const u8, timeout_ms: u32) !void {
    var transferred: c_int = 0;
    const payload: [*c]u8 = @ptrCast(@constCast(data.ptr));
    const rc = c.libusb_bulk_transfer(
        handle,
        endpoint,
        payload,
        @intCast(data.len),
        &transferred,
        timeout_ms,
    );
    const expected: c_int = @intCast(data.len);
    if (rc != 0 or transferred != expected) return error.LibusbBulkTransferFailed;
}

pub fn bulkRead(handle: *c.libusb_device_handle, endpoint: u8, data: []u8, timeout_ms: u32) !void {
    var transferred: c_int = 0;
    const payload: [*c]u8 = @ptrCast(data.ptr);
    const rc = c.libusb_bulk_transfer(
        handle,
        endpoint,
        payload,
        @intCast(data.len),
        &transferred,
        timeout_ms,
    );
    const expected: c_int = @intCast(data.len);
    if (rc != 0 or transferred != expected) return error.LibusbBulkTransferFailed;
}

pub fn clearHalt(handle: *c.libusb_device_handle, endpoint: u8) !void {
    if (c.libusb_clear_halt(handle, endpoint) != 0) {
        return error.LibusbClearHaltFailed;
    }
}

pub fn writeRegister(handle: *c.libusb_device_handle, reg_addr: u32, reg_data: u32, timeout_ms: u32) !void {
    var packet = [_]u32{
        CMD_WRITE_REGISTER,
        0x08,
        reg_addr,
        reg_data,
    };
    const bytes = std.mem.asBytes(&packet);
    try bulkWrite(handle, BULK_EP_REG_OUT, bytes, timeout_ms);
    try bulkRead(handle, BULK_EP_REG_IN, bytes, timeout_ms);
    if (packet[3] != CMD_REGISTER_ACK) return error.PxLogicRegisterAckMismatch;
}

pub fn readRegister(handle: *c.libusb_device_handle, reg_addr: u32, timeout_ms: u32) !u32 {
    var packet = [_]u32{
        CMD_READ_REGISTER,
        0x08,
        reg_addr,
        0,
    };
    const bytes = std.mem.asBytes(&packet);
    try bulkWrite(handle, BULK_EP_REG_OUT, bytes, timeout_ms);
    try bulkRead(handle, BULK_EP_REG_IN, bytes, timeout_ms);
    return packet[3];
}

pub fn writeDataUpdate(
    handle: *c.libusb_device_handle,
    base_addr: u32,
    data: []const u8,
    mode: u32,
    timeout_ms: u32,
) !void {
    const page_size: usize = 4096;
    const aligned_len = if (data.len % page_size == 0)
        data.len
    else
        ((data.len / page_size) + 1) * page_size;
    if (aligned_len > std.math.maxInt(u32) - base_addr) {
        return error.PxLogicAddressOverflow;
    }

    const start_reg: u32 = REG_WRITE_DATA_START;
    const end_reg: u32 = REG_WRITE_DATA_END;
    const mode_reg: u32 = REG_WRITE_DATA_MODE;
    const end_addr: u32 = base_addr + @as(u32, @intCast(aligned_len));
    const reg_timeout_ms: u32 = if (timeout_ms == 0) DEFAULT_REGISTER_TIMEOUT_MS else timeout_ms;

    try writeRegister(handle, start_reg, base_addr, reg_timeout_ms);
    try writeRegister(handle, end_reg, end_addr, reg_timeout_ms);
    try writeRegister(handle, mode_reg, mode, reg_timeout_ms);

    try writeBulkChunks(handle, BULK_EP_DATA_OUT, data, timeout_ms);

    const pad_len = aligned_len - data.len;
    if (pad_len == 0) return;

    var padding = [_]u8{0} ** page_size;
    var remaining = pad_len;
    while (remaining > 0) {
        const chunk = @min(remaining, padding.len);
        try bulkWrite(handle, BULK_EP_DATA_OUT, padding[0..chunk], timeout_ms);
        remaining -= chunk;
    }
}

pub fn prepareCaptureRegisters(
    handle: *c.libusb_device_handle,
    transfer_size: u32,
    target_bytes: u64,
    channel_count: u32,
    timeout_ms: u32,
) !void {
    if (transfer_size == 0) return error.InvalidTransferSize;

    const reg_timeout_ms: u32 = if (timeout_ms == 0) DEFAULT_REGISTER_TIMEOUT_MS else timeout_ms;
    const channel_mask = try captureChannelMask(channel_count);
    const target_total = std.math.add(u64, target_bytes, transfer_size) catch return error.InvalidCaptureTarget;
    const target_low: u32 = @truncate(target_total);
    const target_high: u32 = @truncate(target_total >> 32);
    const pwm_max: u32 = DEFAULT_PWM_CLOCK_HZ / DEFAULT_THRESHOLD_PWM_FREQ_HZ;
    const threshold_vth: u32 = @intFromFloat((DEFAULT_VTH_VOLTS * 0.5 / DEFAULT_VTH_SCALE) * @as(f64, @floatFromInt(pwm_max)));

    // Match PXView's capture bootstrap order for PX-Logic streaming.
    try writeRegister(handle, REG_BLOCK_START, 0, reg_timeout_ms);
    try clearHalt(handle, BULK_EP_DATA_IN);
    try clearHalt(handle, 0x04);
    try clearHalt(handle, 0x84);
    try writeRegister(handle, REG_THRESHOLD_PWM_MAX, pwm_max, reg_timeout_ms);
    try writeRegister(handle, REG_THRESHOLD_VALUE, threshold_vth, reg_timeout_ms);
    try writeRegister(handle, REG_STREAM_CHANNEL_ENABLE, 0, reg_timeout_ms);
    try writeRegister(handle, REG_STREAM_CONTROL, STREAM_ENABLE_FLAGS, reg_timeout_ms);
    try writeRegister(handle, REG_STREAM_CONTROL, STREAM_ENABLE_PULSE_FLAGS, reg_timeout_ms);
    try writeRegister(handle, REG_STREAM_CONTROL, STREAM_ENABLE_FLAGS, reg_timeout_ms);
    try writeRegister(handle, REG_STREAM_START, STREAM_STOP_FLAGS, reg_timeout_ms);
    try writeRegister(handle, REG_STREAM_TRANSFER_SIZE, transfer_size, reg_timeout_ms);
    try writeRegister(handle, REG_STREAM_DMA_SIZE, transfer_size, reg_timeout_ms);
    try writeRegister(handle, REG_CAPTURE_BYTES_LOW, target_low, reg_timeout_ms);
    try writeRegister(handle, REG_CAPTURE_BYTES_HIGH, target_high, reg_timeout_ms);
    try writeRegister(handle, REG_EXT_TRIGGER_MODE, DEFAULT_EXT_TRIGGER_MODE, reg_timeout_ms);
    try writeRegister(handle, REG_TRIGGER_OUT_ENABLE, DEFAULT_TRIGGER_OUT_ENABLE, reg_timeout_ms);
    try writeRegister(handle, REG_GPIO_MODE, DEFAULT_GPIO_MODE, reg_timeout_ms);
    try writeRegister(handle, REG_GPIO_DIV, DEFAULT_GPIO_DIV, reg_timeout_ms);
    try writeRegister(handle, REG_CAPTURE_CHANNEL_COUNT, channel_count, reg_timeout_ms);
    try writeRegister(handle, REG_CAPTURE_TRIGGER_POS, DEFAULT_CAPTURE_TRIGGER_POS, reg_timeout_ms);
    try writeRegister(handle, REG_BLOCK_START, 0, reg_timeout_ms);
    try writeRegister(handle, REG_STREAM_CHANNEL_ENABLE, channel_mask, reg_timeout_ms);
    try writeRegister(handle, REG_STREAM_CONTROL, STREAM_RUN_FLAGS, reg_timeout_ms);
    try writeRegister(handle, REG_TRIGGER_ZERO, DEFAULT_TRIGGER_MASK, reg_timeout_ms);
    try writeRegister(handle, REG_TRIGGER_ONE, DEFAULT_TRIGGER_MASK, reg_timeout_ms);
    try writeRegister(handle, REG_TRIGGER_RISE, DEFAULT_TRIGGER_MASK, reg_timeout_ms);
    try writeRegister(handle, REG_TRIGGER_FALL, DEFAULT_TRIGGER_MASK, reg_timeout_ms);
    try writeRegister(handle, REG_STREAM_START, STREAM_START_FLAGS, reg_timeout_ms);
}

pub fn captureChannelMask(channel_count: u32) !u32 {
    if (channel_count == 0 or channel_count > 32) return error.InvalidChannelCount;
    if (channel_count == 32) return std.math.maxInt(u32);

    const shift: u5 = @intCast(channel_count);
    return (@as(u32, 1) << shift) - 1;
}

pub fn stopCaptureRegisters(handle: *c.libusb_device_handle, timeout_ms: u32) !void {
    const reg_timeout_ms: u32 = if (timeout_ms == 0) DEFAULT_REGISTER_TIMEOUT_MS else timeout_ms;
    try writeRegister(handle, REG_STREAM_START, STREAM_STOP_FLAGS, reg_timeout_ms);
}

fn writeBulkChunks(handle: *c.libusb_device_handle, endpoint: u8, data: []const u8, timeout_ms: u32) !void {
    const chunk_size: usize = 64 * 1024;
    var offset: usize = 0;
    while (offset < data.len) {
        const end = @min(offset + chunk_size, data.len);
        try bulkWrite(handle, endpoint, data[offset..end], timeout_ms);
        offset = end;
    }
}

test "captureChannelMask supports 16 and 32 channels" {
    try std.testing.expectEqual(@as(u32, 0x0000_FFFF), try captureChannelMask(16));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try captureChannelMask(32));
    try std.testing.expectError(error.InvalidChannelCount, captureChannelMask(0));
    try std.testing.expectError(error.InvalidChannelCount, captureChannelMask(33));
}
