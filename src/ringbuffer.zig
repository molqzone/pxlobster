const std = @import("std");

pub const default_capacity_bytes: usize = 64 * 1024 * 1024;

pub const RingBuffer = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    capacity: usize,
    write_index: std.atomic.Value(usize),
    read_index: std.atomic.Value(usize),
    dropped_bytes: std.atomic.Value(u64),

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

    pub fn initDefault(allocator: std.mem.Allocator) !RingBuffer {
        return init(allocator, default_capacity_bytes);
    }

    pub fn deinit(self: *RingBuffer) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn available(self: *const RingBuffer) usize {
        const write = self.write_index.load(.acquire);
        const read = self.read_index.load(.acquire);
        return write - read;
    }

    pub fn freeSpace(self: *const RingBuffer) usize {
        return self.capacity - self.available();
    }

    pub fn dropped(self: *const RingBuffer) u64 {
        return self.dropped_bytes.load(.acquire);
    }

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
