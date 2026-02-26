const std = @import("std");
const device = @import("device.zig");
const usb = @import("usb.zig");
const ringbuffer = @import("ringbuffer.zig");
const stream = @import("output/stream.zig");
const session = @import("output/session.zig");

const c = usb.c;
const no_failure_status: u32 = std.math.maxInt(u32);

pub const CaptureOptions = struct {
    output_path: []const u8,
    sample_bytes: usize,
    decode_cross: bool = false,
    capture_profile: usb.CaptureProfile = .{},
    ring_capacity_bytes: usize = ringbuffer.default_capacity_bytes,
    transfer_size: usize = usb.DEFAULT_CAPTURE_TRANSFER_SIZE,
    transfer_count: usize = usb.DEFAULT_CAPTURE_TRANSFER_COUNT,
    register_timeout_ms: u32 = usb.DEFAULT_REGISTER_TIMEOUT_MS,
    event_poll_timeout_ms: u32 = usb.DEFAULT_CAPTURE_EVENT_TIMEOUT_MS,
    ctl_poll_interval_ms: u32 = 20,
    ctl_poll_timeout_ms: u32 = 20,
    max_idle_ms: u64 = 5000,
};

const SharedState = struct {
    ring: *ringbuffer.RingBuffer,
    stop_requested: std.atomic.Value(bool),
    producer_done: std.atomic.Value(bool),
    active_submissions: std.atomic.Value(u32),
    bytes_in: std.atomic.Value(u64),
    transfer_failed: std.atomic.Value(bool),
    first_failure_status: std.atomic.Value(u32),
};

const CallbackContext = struct {
    shared: *SharedState,
};

const TransferSlot = struct {
    transfer: ?*c.libusb_transfer = null,
    buffer: ?[]u8 = null,
    callback_ctx: CallbackContext = undefined,
};

const OpenedCaptureDevice = struct {
    handle: *c.libusb_device_handle,
    vid: u16,
    pid: u16,
};

pub fn runCaptureToFile(
    allocator: std.mem.Allocator,
    ctx: *c.libusb_context,
    options: CaptureOptions,
) !session.CaptureSessionStats {
    if (options.sample_bytes == 0) return error.InvalidSampleSize;
    if (options.transfer_count == 0) return error.InvalidTransferCount;
    if (options.transfer_size == 0) return error.InvalidTransferSize;
    if (options.transfer_size > std.math.maxInt(u32)) return error.TransferSizeTooLarge;
    if (options.ring_capacity_bytes < options.transfer_size) return error.RingBufferTooSmall;

    var ring = try ringbuffer.RingBuffer.init(allocator, options.ring_capacity_bytes);
    defer ring.deinit();

    var shared = SharedState{
        .ring = &ring,
        .stop_requested = std.atomic.Value(bool).init(false),
        .producer_done = std.atomic.Value(bool).init(false),
        .active_submissions = std.atomic.Value(u32).init(0),
        .bytes_in = std.atomic.Value(u64).init(0),
        .transfer_failed = std.atomic.Value(bool).init(false),
        .first_failure_status = std.atomic.Value(u32).init(no_failure_status),
    };

    const opened = try openFirstSupportedDevice(ctx);
    const handle = opened.handle;
    defer usb.closeDevice(handle);

    try usb.claimInterface(handle, 0);
    defer usb.releaseInterface(handle, 0);
    try usb.claimInterface(handle, 1);
    defer usb.releaseInterface(handle, 1);

    const capture_channel_count = detectCaptureChannelCount(handle, opened.vid, opened.pid);
    if (options.decode_cross) {
        const stripe_bytes = @as(usize, @intCast(capture_channel_count)) * @sizeOf(u64);
        if (stripe_bytes == 0 or options.sample_bytes % stripe_bytes != 0) {
            return error.InvalidDecodeSampleSize;
        }
    }

    const output_file = try std.fs.cwd().createFile(options.output_path, .{ .truncate = true });
    defer output_file.close();

    try usb.prepareCaptureRegistersWithProfile(
        handle,
        @intCast(options.transfer_size),
        @intCast(options.sample_bytes),
        capture_channel_count,
        options.capture_profile,
        options.register_timeout_ms,
    );
    defer usb.stopCaptureRegisters(handle, options.register_timeout_ms) catch {};

    var slots = try allocator.alloc(TransferSlot, options.transfer_count);
    defer allocator.free(slots);
    for (slots) |*slot| slot.* = .{};

    var initialized: usize = 0;
    defer {
        drainTransfers(ctx, slots[0..initialized], &shared);
        for (slots[0..initialized]) |*slot| {
            if (slot.transfer) |transfer| c.libusb_free_transfer(transfer);
            if (slot.buffer) |buffer| allocator.free(buffer);
        }
    }

    while (initialized < slots.len) : (initialized += 1) {
        var slot = &slots[initialized];
        slot.buffer = try allocator.alloc(u8, options.transfer_size);

        const transfer = c.libusb_alloc_transfer(0) orelse return error.LibusbAllocTransferFailed;
        slot.transfer = transfer;
        slot.callback_ctx = .{ .shared = &shared };

        c.libusb_fill_bulk_transfer(
            transfer,
            handle,
            usb.BULK_EP_DATA_IN,
            @ptrCast(slot.buffer.?.ptr),
            @intCast(slot.buffer.?.len),
            transferCallback,
            @ptrCast(&slot.callback_ctx),
            0,
        );

        const submit_rc = c.libusb_submit_transfer(transfer);
        if (submit_rc != 0) return error.LibusbSubmitTransferFailed;
        _ = shared.active_submissions.fetchAdd(1, .acq_rel);
    }

    var writer_ctx = stream.RawWriterContext{
        .ring = &ring,
        .file = output_file,
        .target_bytes = options.sample_bytes,
        .decode_cross = options.decode_cross,
        .channel_count = capture_channel_count,
        .producer_done = &shared.producer_done,
        .stop_requested = &shared.stop_requested,
    };
    var writer_thread = try std.Thread.spawn(.{}, stream.runRawWriter, .{&writer_ctx});
    var writer_joined = false;
    defer if (!writer_joined) writer_thread.join();

    const start_ns = std.time.nanoTimestamp();
    var last_progress_ns = start_ns;
    var last_bytes_in: u64 = 0;
    var last_bytes_out: u64 = 0;
    var last_ctl_probe_ns: i128 = start_ns - (@as(i128, options.ctl_poll_interval_ms) * std.time.ns_per_ms);
    var trigger_seen = false;
    var cancel_sent = false;
    while (true) {
        if (writer_ctx.failed.load(.acquire)) {
            shared.transfer_failed.store(true, .release);
            shared.stop_requested.store(true, .release);
        }

        const bytes_out_now = writer_ctx.bytes_written.load(.acquire);
        const bytes_in_now = shared.bytes_in.load(.acquire);
        if (bytes_out_now >= options.sample_bytes or bytes_in_now >= options.sample_bytes) {
            shared.stop_requested.store(true, .release);
        }

        if (bytes_in_now != last_bytes_in or bytes_out_now != last_bytes_out) {
            last_bytes_in = bytes_in_now;
            last_bytes_out = bytes_out_now;
            last_progress_ns = std.time.nanoTimestamp();
        } else if (options.max_idle_ms > 0) {
            const now_ns = std.time.nanoTimestamp();
            const idle_ns = @max(now_ns - last_progress_ns, 0);
            if (@as(u64, @intCast(idle_ns / std.time.ns_per_ms)) >= options.max_idle_ms) {
                shared.transfer_failed.store(true, .release);
                shared.stop_requested.store(true, .release);
            }
        }

        if (shared.stop_requested.load(.acquire) and !cancel_sent) {
            cancelActiveTransfers(slots[0..initialized]);
            cancel_sent = true;
        }

        if (!trigger_seen and !shared.stop_requested.load(.acquire)) {
            const now_ns = std.time.nanoTimestamp();
            const elapsed_ms = @as(u64, @intCast(@max(now_ns - last_ctl_probe_ns, 0) / std.time.ns_per_ms));
            if (elapsed_ms >= options.ctl_poll_interval_ms) {
                if (usb.readControlStatus(handle, options.ctl_poll_timeout_ms)) |ctl| {
                    if (ctl.trig_out_validset != 0 or ctl.sync_cur_sample != 0) {
                        trigger_seen = true;
                    }
                } else |_| {}
                last_ctl_probe_ns = now_ns;
            }
        }

        var tv = c.timeval{
            .tv_sec = 0,
            .tv_usec = @intCast(options.event_poll_timeout_ms * 1000),
        };
        const rc = c.libusb_handle_events_timeout_completed(ctx, &tv, null);
        if (rc != 0 and rc != c.LIBUSB_ERROR_INTERRUPTED) {
            shared.transfer_failed.store(true, .release);
            shared.stop_requested.store(true, .release);
            if (!cancel_sent) {
                cancelActiveTransfers(slots[0..initialized]);
                cancel_sent = true;
            }
        }

        if (shared.stop_requested.load(.acquire) and shared.active_submissions.load(.acquire) == 0) {
            break;
        }
    }

    shared.producer_done.store(true, .release);
    if (!writer_joined) {
        writer_thread.join();
        writer_joined = true;
    }

    const end_ns = std.time.nanoTimestamp();
    const elapsed_ns = @max(end_ns - start_ns, 0);

    if (writer_ctx.failed.load(.acquire)) return error.OutputWriteFailed;
    if (shared.transfer_failed.load(.acquire)) {
        const first_status = shared.first_failure_status.load(.acquire);
        if (first_status != no_failure_status) {
            std.debug.print(
                "usb transfer failed: status={s} ({d})\n",
                .{ transferStatusName(first_status), first_status },
            );
        }
        return error.UsbTransferFailed;
    }

    const bytes_out = writer_ctx.bytes_written.load(.acquire);
    if (bytes_out != options.sample_bytes) return error.CaptureIncomplete;

    return .{
        .bytes_in = shared.bytes_in.load(.acquire),
        .bytes_out = bytes_out,
        .dropped = ring.dropped(),
        .elapsed_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
    };
}

fn transferCallback(raw_transfer: ?*c.libusb_transfer) callconv(.c) void {
    const transfer = raw_transfer orelse return;
    const user_data = transfer.user_data orelse return;
    const callback_ctx: *CallbackContext = @ptrCast(@alignCast(user_data));
    const shared = callback_ctx.shared;

    const status = transfer.status;
    if (status == c.LIBUSB_TRANSFER_COMPLETED and transfer.actual_length > 0) {
        const received: usize = @intCast(transfer.actual_length);
        pushTransferPayload(shared, transfer.buffer[0..received]);
    } else if (status == c.LIBUSB_TRANSFER_NO_DEVICE or status == c.LIBUSB_TRANSFER_STALL) {
        markTransferFailure(shared, status);
    } else if (status != c.LIBUSB_TRANSFER_CANCELLED and status != c.LIBUSB_TRANSFER_TIMED_OUT and status != c.LIBUSB_TRANSFER_COMPLETED) {
        markTransferFailure(shared, status);
    }

    const can_resubmit = !shared.stop_requested.load(.acquire) and
        (status == c.LIBUSB_TRANSFER_COMPLETED or status == c.LIBUSB_TRANSFER_TIMED_OUT);
    if (can_resubmit) {
        if (c.libusb_submit_transfer(transfer) == 0) return;
        markTransferFailure(shared, c.LIBUSB_TRANSFER_ERROR);
    }

    _ = shared.active_submissions.fetchSub(1, .acq_rel);
}

fn pushTransferPayload(shared: *SharedState, payload: []const u8) void {
    const pushed = shared.ring.push(payload);
    if (pushed > 0) {
        _ = shared.bytes_in.fetchAdd(@as(u64, @intCast(pushed)), .acq_rel);
    }
}

fn cancelActiveTransfers(slots: []TransferSlot) void {
    for (slots) |slot| {
        if (slot.transfer) |transfer| {
            _ = c.libusb_cancel_transfer(transfer);
        }
    }
}

fn drainTransfers(ctx: *c.libusb_context, slots: []TransferSlot, shared: *SharedState) void {
    if (slots.len == 0) return;

    shared.stop_requested.store(true, .release);
    cancelActiveTransfers(slots);

    while (shared.active_submissions.load(.acquire) > 0) {
        var tv = c.timeval{
            .tv_sec = 0,
            .tv_usec = @intCast(usb.DEFAULT_CAPTURE_EVENT_TIMEOUT_MS * 1000),
        };
        const rc = c.libusb_handle_events_timeout_completed(ctx, &tv, null);
        if (rc != 0 and rc != c.LIBUSB_ERROR_INTERRUPTED) break;
    }

    shared.producer_done.store(true, .release);
}

fn openFirstSupportedDevice(ctx: *c.libusb_context) !OpenedCaptureDevice {
    var saw_open_failure = false;
    for (device.supported_pxlogic_ids) |id| {
        const handle_opt = usb.openFirstDeviceByVidPid(ctx, id.vid, id.pid) catch |err| switch (err) {
            error.LibusbOpenFailed => {
                saw_open_failure = true;
                continue;
            },
            else => return err,
        };
        if (handle_opt) |handle| {
            return .{
                .handle = handle,
                .vid = id.vid,
                .pid = id.pid,
            };
        }
    }

    if (saw_open_failure) return error.LibusbOpenFailed;
    return error.NoSupportedDevicesFound;
}

fn detectCaptureChannelCount(handle: *c.libusb_device_handle, vid: u16, pid: u16) u32 {
    if (device.isWchPxLogic(vid, pid)) return 32;
    if (!device.isLegacyPxLogic(vid, pid)) return usb.DEFAULT_CAPTURE_CHANNEL_COUNT;

    const logic_mode = usb.readRegister(handle, usb.REG_LOGIC_MODE, usb.DEFAULT_REGISTER_TIMEOUT_MS) catch {
        return usb.DEFAULT_CAPTURE_CHANNEL_COUNT;
    };

    return if (logic_mode == 0) 32 else 16;
}

fn markTransferFailure(shared: *SharedState, status: u32) void {
    const first = shared.first_failure_status.load(.acquire);
    if (first == no_failure_status) {
        _ = shared.first_failure_status.cmpxchgStrong(first, status, .acq_rel, .acquire);
    }
    shared.transfer_failed.store(true, .release);
    shared.stop_requested.store(true, .release);
}

fn transferStatusName(status: u32) []const u8 {
    return switch (status) {
        c.LIBUSB_TRANSFER_COMPLETED => "COMPLETED",
        c.LIBUSB_TRANSFER_ERROR => "ERROR",
        c.LIBUSB_TRANSFER_TIMED_OUT => "TIMED_OUT",
        c.LIBUSB_TRANSFER_CANCELLED => "CANCELLED",
        c.LIBUSB_TRANSFER_STALL => "STALL",
        c.LIBUSB_TRANSFER_NO_DEVICE => "NO_DEVICE",
        c.LIBUSB_TRANSFER_OVERFLOW => "OVERFLOW",
        else => "UNKNOWN",
    };
}

test "pushTransferPayload tracks only bytes accepted by ringbuffer" {
    var rb = try ringbuffer.RingBuffer.init(std.testing.allocator, 4);
    defer rb.deinit();

    var shared = SharedState{
        .ring = &rb,
        .stop_requested = std.atomic.Value(bool).init(false),
        .producer_done = std.atomic.Value(bool).init(false),
        .active_submissions = std.atomic.Value(u32).init(0),
        .bytes_in = std.atomic.Value(u64).init(0),
        .transfer_failed = std.atomic.Value(bool).init(false),
        .first_failure_status = std.atomic.Value(u32).init(no_failure_status),
    };

    const first = [_]u8{ 0x01, 0x02, 0x03 };
    pushTransferPayload(&shared, first[0..]);
    try std.testing.expectEqual(@as(u64, 3), shared.bytes_in.load(.acquire));

    const second = [_]u8{ 0x11, 0x12, 0x13 };
    pushTransferPayload(&shared, second[0..]);
    try std.testing.expectEqual(@as(u64, 4), shared.bytes_in.load(.acquire));
    try std.testing.expectEqual(@as(u64, 2), rb.dropped());
}
