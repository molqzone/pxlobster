const std = @import("std");
const builtin = @import("builtin");
const device = @import("device.zig");
const usb = @import("usb.zig");
const ringbuffer = @import("ringbuffer.zig");
const stream = @import("output/stream.zig");
const session = @import("output/session.zig");
const srzip = @import("output/srzip.zig");

const c = usb.c;
const no_failure_status: u32 = std.math.maxInt(u32);
const supports_posix_sigint = builtin.os.tag != .windows and builtin.os.tag != .wasi;
var loop_interrupt_requested = std.atomic.Value(bool).init(false);

pub const OutputFormat = session.OutputFormat;

pub const CaptureOutputTarget = union(enum) {
    file_path: []const u8,
    stdout,
};

pub const CaptureOptions = struct {
    output_target: CaptureOutputTarget,
    sample_bytes: usize,
    duration_ms: ?u64 = null,
    strict_channel_count_probe: bool = false,
    output_format: OutputFormat = .bin,
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

const DefaultTransferOps = struct {
    fn allocTransfer(_: @This()) ?*c.libusb_transfer {
        return c.libusb_alloc_transfer(0);
    }

    fn freeTransfer(_: @This(), transfer: *c.libusb_transfer) void {
        c.libusb_free_transfer(transfer);
    }

    fn fillTransfer(
        _: @This(),
        transfer: *c.libusb_transfer,
        handle: *c.libusb_device_handle,
        endpoint: u8,
        buffer: []u8,
        callback_ctx: *CallbackContext,
    ) void {
        c.libusb_fill_bulk_transfer(
            transfer,
            handle,
            endpoint,
            @ptrCast(buffer.ptr),
            @intCast(buffer.len),
            transferCallback,
            @ptrCast(callback_ctx),
            0,
        );
    }

    fn submitTransfer(_: @This(), transfer: *c.libusb_transfer) c_int {
        return c.libusb_submit_transfer(transfer);
    }
};

const OpenedCaptureDevice = struct {
    handle: *c.libusb_device_handle,
    vid: u16,
    pid: u16,
};

const prime_settle_delay_ms: u64 = 100;

const CandidateSlot = struct {
    snapshot: usb.DeviceSnapshot,
    dev: ?*c.libusb_device = null,
};

const LoopSignalGuard = struct {
    active: bool = false,
    previous: std.posix.Sigaction = undefined,

    fn install() LoopSignalGuard {
        if (!supports_posix_sigint) return .{};

        loop_interrupt_requested.store(false, .release);
        var guard = LoopSignalGuard{ .active = true };
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = loopSigIntHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &action, &guard.previous);
        return guard;
    }

    fn restore(self: *LoopSignalGuard) void {
        if (!self.active) return;
        std.posix.sigaction(std.posix.SIG.INT, &self.previous, null);
        self.active = false;
    }

    fn interrupted() bool {
        if (!supports_posix_sigint) return false;
        return loop_interrupt_requested.load(.acquire);
    }
};

fn loopSigIntHandler(_: i32) callconv(.c) void {
    loop_interrupt_requested.store(true, .release);
}

fn captureRegisterTargetBytes(sample_bytes: usize, transfer_size: usize, op_mode: usb.OperationMode) u64 {
    if (op_mode == .loop) {
        return std.math.maxInt(u64) - @as(u64, @intCast(transfer_size));
    }
    return @intCast(sample_bytes);
}

fn targetBytesFromDurationMs(duration_ms: u64, samplerate_hz: u64, channel_count: u32, decode_cross: bool) !usize {
    if (duration_ms == 0) return error.InvalidCaptureDuration;

    const unitsize = try session.unitsizeForChannelCount(channel_count);
    const duration_samples_numerator = std.math.mul(u128, @as(u128, samplerate_hz), @as(u128, duration_ms)) catch {
        return error.CaptureDurationTooLarge;
    };

    var sample_count: u128 = (duration_samples_numerator + 999) / 1000;
    if (sample_count == 0) sample_count = 1;

    if (decode_cross) {
        const aligned = std.math.add(u128, sample_count, 63) catch return error.CaptureDurationTooLarge;
        sample_count = (aligned / 64) * 64;
    }

    const target_bytes_u128 = std.math.mul(u128, sample_count, @as(u128, unitsize)) catch {
        return error.CaptureDurationTooLarge;
    };
    if (target_bytes_u128 == 0 or target_bytes_u128 > std.math.maxInt(usize)) {
        return error.CaptureDurationTooLarge;
    }

    return @intCast(target_bytes_u128);
}

fn resolveTargetBytes(options: CaptureOptions, channel_count: u32) !usize {
    if (options.duration_ms) |duration_ms| {
        if (options.capture_profile.op_mode == .loop) return error.InvalidCaptureDurationMode;
        if (options.sample_bytes != 0) return error.InvalidCaptureTargetSelection;
        return targetBytesFromDurationMs(duration_ms, options.capture_profile.samplerate_hz, channel_count, options.decode_cross);
    }

    if (options.sample_bytes == 0) return error.InvalidSampleSize;
    return options.sample_bytes;
}

fn initializeTransferSlot(
    allocator: std.mem.Allocator,
    slot: *TransferSlot,
    transfer_size: usize,
    handle: *c.libusb_device_handle,
    shared: *SharedState,
    transfer_ops: anytype,
) !void {
    slot.buffer = try allocator.alloc(u8, transfer_size);
    errdefer if (slot.buffer) |buffer| {
        allocator.free(buffer);
        slot.buffer = null;
    };

    const transfer = transfer_ops.allocTransfer() orelse return error.LibusbAllocTransferFailed;
    slot.transfer = transfer;
    errdefer if (slot.transfer) |owned_transfer| {
        transfer_ops.freeTransfer(owned_transfer);
        slot.transfer = null;
    };
    slot.callback_ctx = .{ .shared = shared };

    transfer_ops.fillTransfer(
        transfer,
        handle,
        usb.BULK_EP_DATA_IN,
        slot.buffer.?,
        &slot.callback_ctx,
    );

    const submit_rc = transfer_ops.submitTransfer(transfer);
    if (submit_rc != 0) return error.LibusbSubmitTransferFailed;
}

fn validateTriggerMasksForChannelCount(profile: usb.CaptureProfile, channel_count: u32) !void {
    const channel_mask = try usb.captureChannelMask(channel_count);
    const invalid_bits: u32 = ~channel_mask;
    if ((profile.trigger_zero & invalid_bits) != 0) return error.InvalidTriggerChannel;
    if ((profile.trigger_one & invalid_bits) != 0) return error.InvalidTriggerChannel;
    if ((profile.trigger_rise & invalid_bits) != 0) return error.InvalidTriggerChannel;
    if ((profile.trigger_fall & invalid_bits) != 0) return error.InvalidTriggerChannel;
}

fn requiresStrictChannelCountProbe(options: CaptureOptions) bool {
    return options.duration_ms != null or options.strict_channel_count_probe;
}

pub fn runCapture(
    allocator: std.mem.Allocator,
    ctx: *c.libusb_context,
    options: CaptureOptions,
) !session.CaptureSessionStats {
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

    const opened = try openFirstSupportedDevice(allocator, ctx);
    const handle = opened.handle;
    defer usb.closeDevice(handle);

    try usb.claimInterface(handle, 0);
    defer usb.releaseInterface(handle, 0);
    try usb.claimInterface(handle, 1);
    defer usb.releaseInterface(handle, 1);

    const capture_channel_count = if (requiresStrictChannelCountProbe(options))
        try detectCaptureChannelCountStrict(handle, opened.vid, opened.pid)
    else
        detectCaptureChannelCount(handle, opened.vid, opened.pid);
    try validateTriggerMasksForChannelCount(options.capture_profile, capture_channel_count);
    const target_bytes = try resolveTargetBytes(options, capture_channel_count);
    if (options.decode_cross) {
        const stripe_bytes = @as(usize, @intCast(capture_channel_count)) * @sizeOf(u64);
        if (stripe_bytes == 0 or target_bytes % stripe_bytes != 0) {
            return error.InvalidDecodeSampleSize;
        }
    }

    const output_stdout = switch (options.output_target) {
        .stdout => true,
        .file_path => false,
    };
    if (options.output_format == .sr and output_stdout) return error.InvalidOutputTarget;

    var temp_output_path: ?[]u8 = null;
    defer if (temp_output_path) |path| {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    };

    var output_file: std.fs.File = undefined;
    var close_output_file = false;
    switch (options.output_target) {
        .file_path => |output_path| {
            const capture_output_path: []const u8 = blk: {
                if (options.output_format == .sr) {
                    const temp_path = try std.fmt.allocPrint(allocator, "{s}.pxlobster.raw.tmp", .{output_path});
                    temp_output_path = temp_path;
                    break :blk temp_path;
                }
                break :blk output_path;
            };

            output_file = try std.fs.cwd().createFile(capture_output_path, .{ .truncate = true });
            close_output_file = true;
        },
        .stdout => {
            output_file = std.fs.File.stdout();
        },
    }
    defer if (close_output_file) output_file.close();

    const loop_mode = options.capture_profile.op_mode == .loop;
    var loop_signal_guard = LoopSignalGuard{};
    if (loop_mode) {
        loop_signal_guard = LoopSignalGuard.install();
    }
    defer loop_signal_guard.restore();

    const register_target_bytes = captureRegisterTargetBytes(
        target_bytes,
        options.transfer_size,
        options.capture_profile.op_mode,
    );

    try usb.prepareCaptureRegistersWithProfile(
        handle,
        @intCast(options.transfer_size),
        register_target_bytes,
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

    const transfer_ops = DefaultTransferOps{};
    while (initialized < slots.len) : (initialized += 1) {
        const slot = &slots[initialized];
        try initializeTransferSlot(
            allocator,
            slot,
            options.transfer_size,
            handle,
            &shared,
            transfer_ops,
        );
        _ = shared.active_submissions.fetchAdd(1, .acq_rel);
    }

    var writer_ctx = stream.RawWriterContext{
        .ring = &ring,
        .file = output_file,
        .target_bytes = target_bytes,
        .continuous = loop_mode,
        .decode_cross = options.decode_cross,
        .channel_count = capture_channel_count,
        .sync_on_finish = !output_stdout,
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
        if (loop_mode and LoopSignalGuard.interrupted()) {
            shared.stop_requested.store(true, .release);
        }

        if (writer_ctx.failed.load(.acquire)) {
            shared.transfer_failed.store(true, .release);
            shared.stop_requested.store(true, .release);
        }

        const bytes_out_now = writer_ctx.bytes_written.load(.acquire);
        const bytes_in_now = shared.bytes_in.load(.acquire);
        if (!loop_mode and (bytes_out_now >= target_bytes or bytes_in_now >= target_bytes)) {
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
    if (!loop_mode and bytes_out != target_bytes) return error.CaptureIncomplete;

    if (options.output_format == .sr) {
        const raw_path = temp_output_path orelse return error.OutputPathMissing;
        const output_path = switch (options.output_target) {
            .file_path => |path| path,
            .stdout => return error.InvalidOutputTarget,
        };
        try output_file.sync();
        try srzip.writeSessionFromRawFile(allocator, .{
            .output_path = output_path,
            .raw_path = raw_path,
            .samplerate_hz = options.capture_profile.samplerate_hz,
            .channel_count = capture_channel_count,
        });
    }

    return .{
        .bytes_in = shared.bytes_in.load(.acquire),
        .bytes_out = bytes_out,
        .dropped = ring.dropped(),
        .elapsed_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .channel_count = capture_channel_count,
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

fn openFirstSupportedDevice(allocator: std.mem.Allocator, ctx: *c.libusb_context) !OpenedCaptureDevice {
    var device_list: [*c]?*c.libusb_device = undefined;
    const count = c.libusb_get_device_list(ctx, &device_list);
    if (count < 0) return error.LibusbGetDeviceListFailed;
    defer c.libusb_free_device_list(device_list, 1);

    var candidates: std.ArrayList(CandidateSlot) = .empty;
    defer candidates.deinit(allocator);

    const count_usize: usize = @intCast(count);
    const device_slice = @as([*]?*c.libusb_device, @ptrCast(device_list))[0..count_usize];
    for (device_slice) |dev_opt| {
        if (dev_opt == null) continue;
        const snapshot = usb.snapshotFromDevice(dev_opt.?) orelse continue;
        try candidates.append(allocator, .{
            .snapshot = snapshot,
            .dev = dev_opt.?,
        });
    }

    var saw_open_failure = false;
    var saw_prime_busy = false;
    var saw_prime_failed = false;
    var opened: ?OpenedCaptureDevice = null;

    const Visitor = struct {
        candidates: []const CandidateSlot,
        saw_open_failure: *bool,
        saw_prime_busy: *bool,
        saw_prime_failed: *bool,
        opened: *?OpenedCaptureDevice,

        fn call(self: @This(), idx: usize) !bool {
            const candidate = self.candidates[idx];
            const dev_ptr = candidate.dev orelse return false;

            switch (device.preparePxLogicDevice(dev_ptr, .{})) {
                .ready => {},
                .busy => {
                    self.saw_prime_busy.* = true;
                    return false;
                },
                .failed => {
                    self.saw_prime_failed.* = true;
                    return false;
                },
            }

            std.Thread.sleep(prime_settle_delay_ms * std.time.ns_per_ms);
            const handle = usb.openDevice(dev_ptr) catch {
                self.saw_open_failure.* = true;
                return false;
            };

            self.opened.* = .{
                .handle = handle,
                .vid = candidate.snapshot.vid,
                .pid = candidate.snapshot.pid,
            };
            return true;
        }
    };
    const visitor = Visitor{
        .candidates = candidates.items,
        .saw_open_failure = &saw_open_failure,
        .saw_prime_busy = &saw_prime_busy,
        .saw_prime_failed = &saw_prime_failed,
        .opened = &opened,
    };
    try visitCandidateIndexesByPriority(candidates.items, visitor);

    if (opened) |device_handle| return device_handle;
    return openSelectionFailure(saw_open_failure, saw_prime_busy, saw_prime_failed);
}

fn visitCandidateIndexesByPriority(candidates: []const CandidateSlot, visitor: anytype) !void {
    for (device.supported_pxlogic_ids) |id| {
        for (candidates, 0..) |candidate, idx| {
            if (candidate.snapshot.vid != id.vid or candidate.snapshot.pid != id.pid) continue;
            if (try visitor.call(idx)) return;
        }
    }
}

fn openSelectionFailure(
    saw_open_failure: bool,
    saw_prime_busy: bool,
    saw_prime_failed: bool,
) error{ PxLogicPrimeFailed, PxLogicPrimeBusy, LibusbOpenFailed, NoSupportedDevicesFound } {
    if (saw_prime_failed) return error.PxLogicPrimeFailed;
    if (saw_prime_busy) return error.PxLogicPrimeBusy;
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

fn detectCaptureChannelCountStrict(handle: *c.libusb_device_handle, vid: u16, pid: u16) !u32 {
    if (device.isWchPxLogic(vid, pid)) return 32;
    if (!device.isLegacyPxLogic(vid, pid)) return usb.DEFAULT_CAPTURE_CHANNEL_COUNT;

    const logic_mode = usb.readRegister(handle, usb.REG_LOGIC_MODE, usb.DEFAULT_REGISTER_TIMEOUT_MS) catch {
        return error.ChannelCountProbeFailed;
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

test "captureRegisterTargetBytes uses max range for loop mode" {
    const sample_bytes: usize = 4096;
    const transfer_size: usize = 1024;

    try std.testing.expectEqual(@as(u64, sample_bytes), captureRegisterTargetBytes(sample_bytes, transfer_size, .buffer));
    try std.testing.expectEqual(@as(u64, sample_bytes), captureRegisterTargetBytes(sample_bytes, transfer_size, .stream));
    try std.testing.expectEqual(std.math.maxInt(u64) - @as(u64, transfer_size), captureRegisterTargetBytes(sample_bytes, transfer_size, .loop));
}

test "targetBytesFromDurationMs converts milliseconds to byte target" {
    const bytes_16ch = try targetBytesFromDurationMs(1, 24_000_000, 16, false);
    try std.testing.expectEqual(@as(usize, 48_000), bytes_16ch);

    const bytes_32ch = try targetBytesFromDurationMs(1, 24_000_000, 32, false);
    try std.testing.expectEqual(@as(usize, 96_000), bytes_32ch);
}

test "targetBytesFromDurationMs aligns decode-cross to full cross stripes" {
    // 25 MHz * 1 ms = 25_000 samples => rounded up to 25_024 for decode-cross.
    const bytes_16ch = try targetBytesFromDurationMs(1, 25_000_000, 16, true);
    try std.testing.expectEqual(@as(usize, 50_048), bytes_16ch);
}

test "resolveTargetBytes rejects duration with loop mode" {
    try std.testing.expectError(error.InvalidCaptureDurationMode, resolveTargetBytes(.{
        .output_target = .stdout,
        .sample_bytes = 4096,
        .duration_ms = 100,
        .capture_profile = .{ .op_mode = .loop, .samplerate_hz = 24_000_000 },
    }, 16));
}

test "resolveTargetBytes rejects simultaneous sample and duration targets" {
    try std.testing.expectError(error.InvalidCaptureTargetSelection, resolveTargetBytes(.{
        .output_target = .stdout,
        .sample_bytes = 4096,
        .duration_ms = 100,
        .capture_profile = .{ .op_mode = .buffer, .samplerate_hz = 24_000_000 },
    }, 16));
}

test "resolveTargetBytes accepts duration target with zero sample_bytes" {
    const target = try resolveTargetBytes(.{
        .output_target = .stdout,
        .sample_bytes = 0,
        .duration_ms = 1,
        .capture_profile = .{ .op_mode = .buffer, .samplerate_hz = 24_000_000 },
    }, 16);
    try std.testing.expectEqual(@as(usize, 48_000), target);
}

test "requiresStrictChannelCountProbe is true for duration mode" {
    try std.testing.expect(requiresStrictChannelCountProbe(.{
        .output_target = .stdout,
        .sample_bytes = 0,
        .duration_ms = 1,
    }));
}

test "requiresStrictChannelCountProbe is true for explicit trigger mode" {
    try std.testing.expect(requiresStrictChannelCountProbe(.{
        .output_target = .stdout,
        .sample_bytes = 4096,
        .strict_channel_count_probe = true,
    }));
}

test "requiresStrictChannelCountProbe is false for default capture mode" {
    try std.testing.expect(!requiresStrictChannelCountProbe(.{
        .output_target = .stdout,
        .sample_bytes = 4096,
    }));
}

test "validateTriggerMasksForChannelCount accepts masks within channel range" {
    try validateTriggerMasksForChannelCount(.{
        .trigger_zero = 1 << 15,
        .trigger_one = 1 << 0,
        .trigger_rise = 1 << 7,
        .trigger_fall = 1 << 3,
    }, 16);
}

test "validateTriggerMasksForChannelCount rejects masks outside channel range" {
    try std.testing.expectError(error.InvalidTriggerChannel, validateTriggerMasksForChannelCount(.{
        .trigger_one = 1 << 16,
    }, 16));
    try std.testing.expectError(error.InvalidTriggerChannel, validateTriggerMasksForChannelCount(.{
        .trigger_fall = 1 << 31,
    }, 16));
}

test "visitCandidateIndexesByPriority follows supported ID order" {
    const candidates = [_]CandidateSlot{
        .{ .snapshot = .{ .vid = device.pxlogic_legacy_id.vid, .pid = device.pxlogic_legacy_id.pid, .speed = 0, .bus = 1, .address = 1 } },
        .{ .snapshot = .{ .vid = device.pxlogic_wch_id.vid, .pid = device.pxlogic_wch_id.pid, .speed = 0, .bus = 1, .address = 2 } },
        .{ .snapshot = .{ .vid = device.pxlogic_legacy_id.vid, .pid = device.pxlogic_legacy_id.pid, .speed = 0, .bus = 1, .address = 3 } },
    };

    var seen: [3]usize = undefined;
    var seen_len: usize = 0;

    const Visitor = struct {
        seen: *[3]usize,
        seen_len: *usize,

        fn call(self: @This(), idx: usize) !bool {
            self.seen[self.seen_len.*] = idx;
            self.seen_len.* += 1;
            return false;
        }
    };
    const visitor = Visitor{ .seen = &seen, .seen_len = &seen_len };
    try visitCandidateIndexesByPriority(candidates[0..], visitor);

    try std.testing.expectEqual(@as(usize, 3), seen_len);
    try std.testing.expectEqual(@as(usize, 1), seen[0]);
    try std.testing.expectEqual(@as(usize, 0), seen[1]);
    try std.testing.expectEqual(@as(usize, 2), seen[2]);
}

test "visitCandidateIndexesByPriority stops when visitor returns true" {
    const candidates = [_]CandidateSlot{
        .{ .snapshot = .{ .vid = device.pxlogic_legacy_id.vid, .pid = device.pxlogic_legacy_id.pid, .speed = 0, .bus = 1, .address = 1 } },
        .{ .snapshot = .{ .vid = device.pxlogic_wch_id.vid, .pid = device.pxlogic_wch_id.pid, .speed = 0, .bus = 1, .address = 2 } },
        .{ .snapshot = .{ .vid = device.pxlogic_legacy_id.vid, .pid = device.pxlogic_legacy_id.pid, .speed = 0, .bus = 1, .address = 3 } },
    };

    var first_seen: ?usize = null;
    var calls: usize = 0;

    const Visitor = struct {
        first_seen: *?usize,
        calls: *usize,

        fn call(self: @This(), idx: usize) !bool {
            self.calls.* += 1;
            if (self.first_seen.* == null) self.first_seen.* = idx;
            return true;
        }
    };
    const visitor = Visitor{ .first_seen = &first_seen, .calls = &calls };
    try visitCandidateIndexesByPriority(candidates[0..], visitor);

    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 1), first_seen.?);
}

test "openSelectionFailure prioritizes prime errors over open failures" {
    try std.testing.expectEqual(error.PxLogicPrimeFailed, openSelectionFailure(true, true, true));
    try std.testing.expectEqual(error.PxLogicPrimeBusy, openSelectionFailure(true, true, false));
    try std.testing.expectEqual(error.LibusbOpenFailed, openSelectionFailure(true, false, false));
    try std.testing.expectEqual(error.NoSupportedDevicesFound, openSelectionFailure(false, false, false));
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

test "initializeTransferSlot frees buffer when transfer allocation fails" {
    var rb = try ringbuffer.RingBuffer.init(std.testing.allocator, 16);
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
    var slot: TransferSlot = .{};
    const fake_handle: *c.libusb_device_handle = @ptrFromInt(0x1000);

    var free_calls: usize = 0;
    var fill_calls: usize = 0;
    var submit_calls: usize = 0;
    const FailingAllocOps = struct {
        free_calls: *usize,
        fill_calls: *usize,
        submit_calls: *usize,

        fn allocTransfer(_: *@This()) ?*c.libusb_transfer {
            return null;
        }

        fn freeTransfer(self: *@This(), _: *c.libusb_transfer) void {
            self.free_calls.* += 1;
        }

        fn fillTransfer(
            self: *@This(),
            _: *c.libusb_transfer,
            _: *c.libusb_device_handle,
            _: u8,
            _: []u8,
            _: *CallbackContext,
        ) void {
            self.fill_calls.* += 1;
        }

        fn submitTransfer(self: *@This(), _: *c.libusb_transfer) c_int {
            self.submit_calls.* += 1;
            return 0;
        }
    };
    var ops = FailingAllocOps{
        .free_calls = &free_calls,
        .fill_calls = &fill_calls,
        .submit_calls = &submit_calls,
    };

    try std.testing.expectError(
        error.LibusbAllocTransferFailed,
        initializeTransferSlot(std.testing.allocator, &slot, 1024, fake_handle, &shared, &ops),
    );
    try std.testing.expect(slot.buffer == null);
    try std.testing.expect(slot.transfer == null);
    try std.testing.expectEqual(@as(usize, 0), free_calls);
    try std.testing.expectEqual(@as(usize, 0), fill_calls);
    try std.testing.expectEqual(@as(usize, 0), submit_calls);
}

test "initializeTransferSlot frees slot resources when transfer submit fails" {
    var rb = try ringbuffer.RingBuffer.init(std.testing.allocator, 16);
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
    var slot: TransferSlot = .{};
    const fake_handle: *c.libusb_device_handle = @ptrFromInt(0x1000);
    const fake_transfer: *c.libusb_transfer = @ptrFromInt(0x2000);

    var free_calls: usize = 0;
    var fill_calls: usize = 0;
    var submit_calls: usize = 0;
    const FailingSubmitOps = struct {
        free_calls: *usize,
        fill_calls: *usize,
        submit_calls: *usize,
        fake_transfer: *c.libusb_transfer,

        fn allocTransfer(self: *@This()) ?*c.libusb_transfer {
            return self.fake_transfer;
        }

        fn freeTransfer(self: *@This(), transfer: *c.libusb_transfer) void {
            if (transfer == self.fake_transfer) {
                self.free_calls.* += 1;
            }
        }

        fn fillTransfer(
            self: *@This(),
            _: *c.libusb_transfer,
            _: *c.libusb_device_handle,
            _: u8,
            _: []u8,
            _: *CallbackContext,
        ) void {
            self.fill_calls.* += 1;
        }

        fn submitTransfer(self: *@This(), _: *c.libusb_transfer) c_int {
            self.submit_calls.* += 1;
            return -1;
        }
    };
    var ops = FailingSubmitOps{
        .free_calls = &free_calls,
        .fill_calls = &fill_calls,
        .submit_calls = &submit_calls,
        .fake_transfer = fake_transfer,
    };

    try std.testing.expectError(
        error.LibusbSubmitTransferFailed,
        initializeTransferSlot(std.testing.allocator, &slot, 1024, fake_handle, &shared, &ops),
    );
    try std.testing.expect(slot.buffer == null);
    try std.testing.expect(slot.transfer == null);
    try std.testing.expectEqual(@as(usize, 1), fill_calls);
    try std.testing.expectEqual(@as(usize, 1), submit_calls);
    try std.testing.expectEqual(@as(usize, 1), free_calls);
}
