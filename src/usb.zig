const std = @import("std");
const caps = @import("caps.zig");

/// 从根模块转导出的 libusb C 绑定 / Re-export of libusb C bindings from project root module.
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

pub const STREAM_MODE_BIT: u32 = 1 << 1;
pub const STREAM_ENABLE_FLAGS_BASE: u32 = 0x00000005;
pub const STREAM_ENABLE_PULSE_FLAG: u32 = 1 << 4;
pub const STREAM_FILTER_SHIFT: u5 = 3;
pub const STREAM_START_FLAGS: u32 = 0x0000_0000;
pub const STREAM_STOP_FLAGS: u32 = 0xFFFF_FFFF;
pub const DEFAULT_CAPTURE_CHANNEL_COUNT: u32 = 16;
pub const DEFAULT_CAPTURE_TRIGGER_POS: u32 = 64;
pub const DEFAULT_EXT_TRIGGER_MODE: u32 = 0;
pub const DEFAULT_TRIGGER_OUT_ENABLE: u32 = 0;
pub const DEFAULT_TRIGGER_MASK: u32 = 0;
pub const DEFAULT_PWM_CLOCK_HZ: u32 = 120_000_000;
pub const DEFAULT_THRESHOLD_PWM_FREQ_HZ: u32 = 10_000;
pub const DEFAULT_VTH_VOLTS: f64 = 2.0;
pub const DEFAULT_VTH_SCALE: f64 = 3.334;
pub const MAX_CAPTURE_REGISTER_WRITES: usize = 26;

/// 基础 USB 描述符与拓扑字段快照 / Snapshot of basic USB descriptor and topology fields.
pub const DeviceSnapshot = struct {
    vid: u16,
    pid: u16,
    speed: c_int,
    bus: u8,
    address: u8,
};

/// PX 控制端点返回的厂商控制状态载荷 / Vendor control status payload returned by PX control endpoint.
pub const ControlStatus = extern struct {
    sync_cur_sample: u64,
    trig_out_validset: u32,
    real_pos: u32,
};

/// 与 PXView 字段对齐的运行时采集寄存器配置 / Runtime capture register profile mirroring PXView fields.
pub const CaptureProfile = struct {
    op_mode: caps.OperationMode = .buffer,
    samplerate_hz: u64 = caps.default_capture_samplerate_hz,
    filter: u8 = 0,
    clock_edge: u8 = 0,
    ext_trigger_mode: u32 = DEFAULT_EXT_TRIGGER_MODE,
    trigger_out_enable: u32 = DEFAULT_TRIGGER_OUT_ENABLE,
    trigger_zero: u32 = DEFAULT_TRIGGER_MASK,
    trigger_one: u32 = DEFAULT_TRIGGER_MASK,
    trigger_rise: u32 = DEFAULT_TRIGGER_MASK,
    trigger_fall: u32 = DEFAULT_TRIGGER_MASK,
    trigger_pos: u32 = DEFAULT_CAPTURE_TRIGGER_POS,
    vth_volts: f64 = DEFAULT_VTH_VOLTS,
};

/// 有序采集脚本中的一条寄存器写操作 / One register write in an ordered capture script.
pub const RegisterWrite = struct {
    addr: u32,
    value: u32,
};

/// 固定容量的有序寄存器写程序，用于启动采集 / Fixed-capacity ordered register write program for capture start.
pub const CaptureRegisterScript = struct {
    writes: [MAX_CAPTURE_REGISTER_WRITES]RegisterWrite,
    len: usize,

    fn init() CaptureRegisterScript {
        return .{
            .writes = undefined,
            .len = 0,
        };
    }

    fn append(self: *CaptureRegisterScript, addr: u32, value: u32) !void {
        if (self.len >= self.writes.len) return error.CaptureScriptTooLarge;
        self.writes[self.len] = .{ .addr = addr, .value = value };
        self.len += 1;
    }

    pub fn slice(self: *const CaptureRegisterScript) []const RegisterWrite {
        return self.writes[0..self.len];
    }
};

/// 枚举当前连接 USB 设备并生成稳定快照 / Enumerates connected USB devices into stable snapshots.
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

/// 从 libusb 设备描述符提取快照信息 / Extracts a device snapshot from a libusb device descriptor.
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

/// 为给定设备打开原始 libusb 句柄 / Opens a raw libusb handle for the provided device.
pub fn openDevice(dev: *c.libusb_device) !*c.libusb_device_handle {
    var handle_opt: ?*c.libusb_device_handle = null;
    const open_rc = c.libusb_open(dev, &handle_opt);
    if (open_rc == c.LIBUSB_ERROR_ACCESS) {
        return error.LibusbPermissionDenied;
    }
    if (open_rc != 0 or handle_opt == null) {
        return error.LibusbOpenFailed;
    }
    return handle_opt.?;
}

/// 打开首个匹配 VID/PID 的设备；若无匹配则返回 null / Opens the first device matching VID/PID, or null if no match exists.
pub fn openFirstDeviceByVidPid(ctx: *c.libusb_context, vid: u16, pid: u16) !?*c.libusb_device_handle {
    var device_list: [*c]?*c.libusb_device = undefined;
    const count = c.libusb_get_device_list(ctx, &device_list);
    if (count < 0) return error.LibusbGetDeviceListFailed;
    defer c.libusb_free_device_list(device_list, 1);

    var matched_device = false;
    var open_failed = false;
    var permission_denied = false;
    const count_usize: usize = @intCast(count);
    const device_slice = @as([*]?*c.libusb_device, @ptrCast(device_list))[0..count_usize];
    for (device_slice) |dev_opt| {
        if (dev_opt == null) continue;
        if (snapshotFromDevice(dev_opt.?)) |snapshot| {
            if (snapshot.vid == vid and snapshot.pid == pid) {
                matched_device = true;
                const opened = openDevice(dev_opt.?) catch |err| {
                    switch (err) {
                        error.LibusbPermissionDenied => permission_denied = true,
                        else => open_failed = true,
                    }
                    continue;
                };
                return opened;
            }
        }
    }

    if (matched_device and permission_denied) return error.LibusbPermissionDenied;
    if (matched_device and open_failed) return error.LibusbOpenFailed;
    return null;
}

/// 关闭此前打开的 libusb 设备句柄 / Closes a previously opened libusb device handle.
pub fn closeDevice(handle: *c.libusb_device_handle) void {
    c.libusb_close(handle);
}

/// claim 指定 USB 接口 / Claims the selected USB interface.
pub fn claimInterface(handle: *c.libusb_device_handle, index: c_int) !void {
    if (c.libusb_claim_interface(handle, index) != 0) {
        return error.LibusbClaimInterfaceFailed;
    }
}

/// release 指定 USB 接口 / Releases the selected USB interface.
pub fn releaseInterface(handle: *c.libusb_device_handle, index: c_int) void {
    _ = c.libusb_release_interface(handle, index);
}

/// 执行厂商自定义 OUT 控制传输，并严格校验长度 / Performs a vendor-specific OUT control transfer with exact-length validation.
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

/// 执行厂商自定义 IN 控制传输并返回实际字节数 / Performs a vendor-specific IN control transfer and returns bytes received.
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

/// 通过厂商 IN 控制传输读取 PX 控制状态结构 / Reads the PX control status structure via vendor IN control transfer.
pub fn readControlStatus(handle: *c.libusb_device_handle, timeout_ms: u32) !ControlStatus {
    var status: ControlStatus = std.mem.zeroes(ControlStatus);
    const bytes = std.mem.asBytes(&status);
    const read_len = try controlTransferVendorIn(handle, CMD_CTL_READ, 0, 0, bytes, timeout_ms);
    if (read_len != bytes.len) return error.ControlStatusLengthMismatch;
    return status;
}

/// 向指定端点写入完整 bulk 载荷 / Writes an exact bulk payload to the given endpoint.
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

/// 从指定端点读取完整 bulk 载荷 / Reads an exact bulk payload from the given endpoint.
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

/// 清除端点 halt/stall 状态 / Clears endpoint halt/stall state.
pub fn clearHalt(handle: *c.libusb_device_handle, endpoint: u8) !void {
    if (c.libusb_clear_halt(handle, endpoint) != 0) {
        return error.LibusbClearHaltFailed;
    }
}

/// 写入单个 PX 寄存器并校验 ACK 标记 / Writes a single PX register and validates the ACK token.
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

/// 读取单个 PX 寄存器值 / Reads one PX register value.
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

/// 将对齐后的固件/位流字节写入 PX 写数据窗口 / Uploads aligned firmware/bitstream bytes into PX write-data window.
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

    const padding = [_]u8{0} ** page_size;
    var remaining = pad_len;
    while (remaining > 0) {
        const chunk = @min(remaining, padding.len);
        try bulkWrite(handle, BULK_EP_DATA_OUT, padding[0..chunk], timeout_ms);
        remaining -= chunk;
    }
}

/// 按给定 profile 应用完整的采集启动寄存器程序 / Applies full capture-start register program for the given profile.
pub fn prepareCaptureRegistersWithProfile(
    handle: *c.libusb_device_handle,
    transfer_size: u32,
    target_bytes: u64,
    channel_count: u32,
    profile: CaptureProfile,
    timeout_ms: u32,
) !void {
    if (transfer_size == 0) return error.InvalidTransferSize;

    const reg_timeout_ms: u32 = if (timeout_ms == 0) DEFAULT_REGISTER_TIMEOUT_MS else timeout_ms;

    // 保持 PXView 启动顺序：先复位块指针，再清理数据端点 / Keep PXView start order: reset block pointer then clear data endpoints.
    try writeRegister(handle, REG_BLOCK_START, 0, reg_timeout_ms);
    try clearHalt(handle, BULK_EP_DATA_IN);
    try clearHalt(handle, 0x04);
    try clearHalt(handle, 0x84);

    var script = try buildCaptureRegisterScript(transfer_size, target_bytes, channel_count, profile);
    try applyCaptureRegisterScript(handle, &script, reg_timeout_ms);
}

/// 以 PXView 兼容顺序构建采集寄存器写序列 / Builds capture register writes in PXView-compatible ordering.
pub fn buildCaptureRegisterScript(
    transfer_size: u32,
    target_bytes: u64,
    channel_count: u32,
    profile: CaptureProfile,
) !CaptureRegisterScript {
    if (transfer_size == 0) return error.InvalidTransferSize;

    const channel_mask = try captureChannelMask(channel_count);
    const target_total = std.math.add(u64, target_bytes, transfer_size) catch return error.InvalidCaptureTarget;
    const target_low: u32 = @truncate(target_total);
    const target_high: u32 = @truncate(target_total >> 32);
    const stream_mask = streamMaskForMode(profile.op_mode);
    const stream_enable_flags = STREAM_ENABLE_FLAGS_BASE | stream_mask;
    const stream_enable_pulse_flags = stream_enable_flags | STREAM_ENABLE_PULSE_FLAG;
    const stream_run_flags = stream_mask | (@as(u32, profile.filter) << STREAM_FILTER_SHIFT);
    const gpio_timing = try caps.gpioTimingForSamplerate(profile.samplerate_hz);
    const gpio_mode = gpio_timing.mode | (@as(u32, profile.clock_edge) << STREAM_FILTER_SHIFT);
    const pwm_max: u32 = DEFAULT_PWM_CLOCK_HZ / DEFAULT_THRESHOLD_PWM_FREQ_HZ;
    const threshold_vth: u32 = @intFromFloat((profile.vth_volts * 0.5 / DEFAULT_VTH_SCALE) * @as(f64, @floatFromInt(pwm_max)));

    var script = CaptureRegisterScript.init();
    try script.append(REG_THRESHOLD_PWM_MAX, pwm_max);
    try script.append(REG_THRESHOLD_VALUE, threshold_vth);
    try script.append(REG_STREAM_CHANNEL_ENABLE, 0);
    try script.append(REG_STREAM_CONTROL, stream_enable_flags);
    try script.append(REG_STREAM_CONTROL, stream_enable_pulse_flags);
    try script.append(REG_STREAM_CONTROL, stream_enable_flags);
    try script.append(REG_STREAM_START, STREAM_STOP_FLAGS);
    try script.append(REG_STREAM_TRANSFER_SIZE, transfer_size);
    try script.append(REG_STREAM_DMA_SIZE, transfer_size);
    try script.append(REG_CAPTURE_BYTES_LOW, target_low);
    try script.append(REG_CAPTURE_BYTES_HIGH, target_high);
    try script.append(REG_EXT_TRIGGER_MODE, profile.ext_trigger_mode);
    try script.append(REG_TRIGGER_OUT_ENABLE, profile.trigger_out_enable);
    try script.append(REG_GPIO_MODE, gpio_mode);
    try script.append(REG_GPIO_DIV, gpio_timing.div);
    try script.append(REG_CAPTURE_CHANNEL_COUNT, channel_count);
    try script.append(REG_CAPTURE_TRIGGER_POS, profile.trigger_pos);
    try script.append(REG_BLOCK_START, 0);
    try script.append(REG_STREAM_CHANNEL_ENABLE, channel_mask);
    try script.append(REG_STREAM_CONTROL, stream_run_flags);
    try script.append(REG_TRIGGER_ZERO, profile.trigger_zero);
    try script.append(REG_TRIGGER_ONE, profile.trigger_one);
    try script.append(REG_TRIGGER_RISE, profile.trigger_rise);
    try script.append(REG_TRIGGER_FALL, profile.trigger_fall);
    try script.append(REG_STREAM_START, STREAM_START_FLAGS);
    return script;
}

fn applyCaptureRegisterScript(
    handle: *c.libusb_device_handle,
    script: *const CaptureRegisterScript,
    timeout_ms: u32,
) !void {
    for (script.slice()) |write_cmd| {
        try writeRegister(handle, write_cmd.addr, write_cmd.value, timeout_ms);
    }
}

pub fn streamMaskForMode(op_mode: caps.OperationMode) u32 {
    return switch (op_mode) {
        .buffer => 0,
        .stream, .loop => STREAM_MODE_BIT,
    };
}

/// 返回启用通道位掩码（支持 1..32 通道） / Returns bitmask for enabled channels (1..32 channels).
pub fn captureChannelMask(channel_count: u32) !u32 {
    if (channel_count == 0 or channel_count > 32) return error.InvalidChannelCount;
    if (channel_count == 32) return std.math.maxInt(u32);

    const shift: u5 = @intCast(channel_count);
    return (@as(u32, 1) << shift) - 1;
}

/// 发送停止采集的寄存器命令 / Sends capture-stop register command.
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

fn expectScriptWrite(script: *const CaptureRegisterScript, index: usize, addr: u32, value: u32) !void {
    try std.testing.expect(index < script.len);
    try std.testing.expectEqual(addr, script.writes[index].addr);
    try std.testing.expectEqual(value, script.writes[index].value);
}

test "streamMaskForMode matches pxview op mode rules" {
    try std.testing.expectEqual(@as(u32, 0), streamMaskForMode(.buffer));
    try std.testing.expectEqual(STREAM_MODE_BIT, streamMaskForMode(.stream));
    try std.testing.expectEqual(STREAM_MODE_BIT, streamMaskForMode(.loop));
}

test "buildCaptureRegisterScript buffer mode produces pxview-compatible sequence" {
    var script = try buildCaptureRegisterScript(4096, 65_536, 16, .{});

    try std.testing.expectEqual(@as(usize, 25), script.len);
    try expectScriptWrite(&script, 0, REG_THRESHOLD_PWM_MAX, 12_000);
    try expectScriptWrite(&script, 1, REG_THRESHOLD_VALUE, 3_599);
    try expectScriptWrite(&script, 3, REG_STREAM_CONTROL, 5);
    try expectScriptWrite(&script, 4, REG_STREAM_CONTROL, 21);
    try expectScriptWrite(&script, 5, REG_STREAM_CONTROL, 5);
    try expectScriptWrite(&script, 6, REG_STREAM_START, STREAM_STOP_FLAGS);
    try expectScriptWrite(&script, 9, REG_CAPTURE_BYTES_LOW, 69_632);
    try expectScriptWrite(&script, 10, REG_CAPTURE_BYTES_HIGH, 0);
    try expectScriptWrite(&script, 13, REG_GPIO_MODE, 2);
    try expectScriptWrite(&script, 14, REG_GPIO_DIV, 0);
    try expectScriptWrite(&script, 18, REG_STREAM_CHANNEL_ENABLE, 0x0000_FFFF);
    try expectScriptWrite(&script, 19, REG_STREAM_CONTROL, 0);
    try expectScriptWrite(&script, 24, REG_STREAM_START, STREAM_START_FLAGS);
}

test "buildCaptureRegisterScript stream mode applies stream mask and filter bits" {
    var script = try buildCaptureRegisterScript(8192, 1_000_000, 16, .{
        .op_mode = .stream,
        .samplerate_hz = 10_000_000,
        .filter = 2,
        .clock_edge = 1,
        .trigger_zero = 0xAAAA,
        .trigger_one = 0xBBBB,
        .trigger_rise = 0xCCCC,
        .trigger_fall = 0xDDDD,
    });

    try std.testing.expectEqual(@as(usize, 25), script.len);
    try expectScriptWrite(&script, 3, REG_STREAM_CONTROL, 7);
    try expectScriptWrite(&script, 4, REG_STREAM_CONTROL, 23);
    try expectScriptWrite(&script, 5, REG_STREAM_CONTROL, 7);
    try expectScriptWrite(&script, 13, REG_GPIO_MODE, 15);
    try expectScriptWrite(&script, 14, REG_GPIO_DIV, 9);
    try expectScriptWrite(&script, 19, REG_STREAM_CONTROL, 18);
    try expectScriptWrite(&script, 20, REG_TRIGGER_ZERO, 0xAAAA);
    try expectScriptWrite(&script, 21, REG_TRIGGER_ONE, 0xBBBB);
    try expectScriptWrite(&script, 22, REG_TRIGGER_RISE, 0xCCCC);
    try expectScriptWrite(&script, 23, REG_TRIGGER_FALL, 0xDDDD);
}
