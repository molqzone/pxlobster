const std = @import("std");

/// 采集生产者/消费者缓冲默认容量（字节） / Default byte capacity used by capture producer/consumer buffering.
pub const default_capacity_bytes: usize = 64 * 1024 * 1024;

/// 单生产者/单消费者字节环形缓冲，并统计丢弃字节 / Single-producer/single-consumer byte ring buffer with drop accounting.
pub const RingBuffer = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    capacity: usize,
    write_index: std.atomic.Value(usize),
    read_index: std.atomic.Value(usize),
    dropped_bytes: std.atomic.Value(u64),

    /// 按指定容量为 ring buffer 分配存储 / Allocates storage for a ring buffer with the requested capacity.
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !RingBuffer {
        if (capacity == 0) return error.InvalidRingBufferCapacity;
        return .{
            .allocator = allocator,
            .storage = try allocator.alloc(u8, capacity),
            .capacity = capacity,
            .write_index = std.atomic.Value(usize).init(0),
            .read_index = std.atomic.Value(usize).init(0),
            .dropped_bytes = std.atomic.Value(u64).init(0),
        };
    }

    /// 使用 `default_capacity_bytes` 分配 ring buffer / Allocates a ring buffer using `default_capacity_bytes`.
    pub fn initDefault(allocator: std.mem.Allocator) !RingBuffer {
        return init(allocator, default_capacity_bytes);
    }

    /// 释放已分配存储并使结构体失效 / Releases allocated storage and invalidates the struct.
    pub fn deinit(self: *RingBuffer) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    /// 返回消费者当前可读字节数 / Returns bytes currently readable by the consumer.
    pub fn available(self: *const RingBuffer) usize {
        const write = self.write_index.load(.acquire);
        const read = self.read_index.load(.acquire);
        return write - read;
    }

    /// 返回生产者当前可写空闲字节数 / Returns free bytes available for the producer.
    pub fn freeSpace(self: *const RingBuffer) usize {
        return self.capacity - self.available();
    }

    /// 返回因溢出累计丢弃的字节数 / Returns the cumulative count of dropped bytes due to overflow.
    pub fn dropped(self: *const RingBuffer) u64 {
        return self.dropped_bytes.load(.acquire);
    }

    /// 尽量写入可容纳字节，超出的字节计入 dropped / Pushes as many bytes as fit; extra bytes are counted as dropped.
    pub fn push(self: *RingBuffer, data: []const u8) usize {
        if (data.len == 0) return 0;

        const write = self.write_index.load(.monotonic);
        const read = self.read_index.load(.acquire);
        const free = self.capacity - (write - read);
        const writable = @min(data.len, free);
        if (writable == 0) {
            _ = self.dropped_bytes.fetchAdd(@as(u64, @intCast(data.len)), .acq_rel);
            return 0;
        }

        const start = write % self.capacity;
        const first = @min(writable, self.capacity - start);
        @memcpy(self.storage[start .. start + first], data[0..first]);
        if (first < writable) {
            const remaining = writable - first;
            @memcpy(self.storage[0..remaining], data[first .. first + remaining]);
        }

        if (writable < data.len) {
            const lost = data.len - writable;
            _ = self.dropped_bytes.fetchAdd(@as(u64, @intCast(lost)), .acq_rel);
        }
        self.write_index.store(write + writable, .release);
        return writable;
    }

    /// 从缓冲区最多弹出 `out.len` 字节并推进读指针 / Pops up to `out.len` bytes from the buffer and advances read cursor.
    pub fn pop(self: *RingBuffer, out: []u8) usize {
        if (out.len == 0) return 0;

        const read = self.read_index.load(.monotonic);
        const write = self.write_index.load(.acquire);
        const available_bytes = write - read;
        const readable = @min(out.len, available_bytes);
        if (readable == 0) return 0;

        const start = read % self.capacity;
        const first = @min(readable, self.capacity - start);
        @memcpy(out[0..first], self.storage[start .. start + first]);
        if (first < readable) {
            const remaining = readable - first;
            @memcpy(out[first .. first + remaining], self.storage[0..remaining]);
        }

        self.read_index.store(read + readable, .release);
        return readable;
    }
};

test "ringbuffer push and pop preserves data order" {
    var rb = try RingBuffer.init(std.testing.allocator, 16);
    defer rb.deinit();

    const payload = "abcdef";
    try std.testing.expectEqual(@as(usize, payload.len), rb.push(payload));

    var out: [8]u8 = undefined;
    const read = rb.pop(out[0..]);
    try std.testing.expectEqual(@as(usize, payload.len), read);
    try std.testing.expectEqualStrings(payload, out[0..read]);
}

test "ringbuffer wraps around correctly" {
    var rb = try RingBuffer.init(std.testing.allocator, 8);
    defer rb.deinit();

    try std.testing.expectEqual(@as(usize, 6), rb.push("123456"));
    var tmp: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), rb.pop(tmp[0..]));
    try std.testing.expectEqualStrings("1234", tmp[0..4]);

    try std.testing.expectEqual(@as(usize, 6), rb.push("abcdef"));

    var out: [8]u8 = undefined;
    const read = rb.pop(out[0..]);
    try std.testing.expectEqual(@as(usize, 8), read);
    try std.testing.expectEqualStrings("56abcdef", out[0..read]);
}

test "ringbuffer tracks dropped bytes when full" {
    var rb = try RingBuffer.init(std.testing.allocator, 4);
    defer rb.deinit();

    try std.testing.expectEqual(@as(usize, 4), rb.push("ABCD"));
    try std.testing.expectEqual(@as(usize, 0), rb.push("XYZ"));
    try std.testing.expectEqual(@as(u64, 3), rb.dropped());
}
