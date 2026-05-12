const std = @import("std");
const session = @import("session.zig");
const io = std.Options.debug_io;

/// ZIP 条目载荷来源类型 / Source variants for each ZIP entry payload.
pub const ZipEntrySource = union(enum) {
    bytes: []const u8,
    file_path: []const u8,
};

/// 需要写入输出 ZIP 的单个文件条目 / One file entry to be written into the output ZIP.
pub const ZipEntry = struct {
    name: []const u8,
    source: ZipEntrySource,
};

/// 从原始采集文件生成 sigrok `.sr` 的输入参数 / Inputs for generating a sigrok `.sr` file from a raw capture file.
pub const WriteSessionFromRawOptions = struct {
    output_path: []const u8,
    raw_path: []const u8,
    samplerate_hz: u64,
    channel_count: u32,
};

const LocalFileHeaderSize: usize = 30;
const CentralDirectoryHeaderSize: usize = 46;
const EndOfCentralDirectorySize: usize = 22;

const local_file_header_signature: u32 = 0x0403_4B50;
const central_directory_header_signature: u32 = 0x0201_4B50;
const end_of_central_directory_signature: u32 = 0x0605_4B50;

const version_needed_to_extract: u16 = 20;
const version_made_by: u16 = 20;
const compression_method_deflate: u16 = 8;
const general_purpose_flags: u16 = 0;
const max_stored_block_len: usize = std.math.maxInt(u16);

const EntrySummary = struct {
    name: []const u8,
    local_header_offset: u32,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
};

const WriteContext = struct {
    file: std.Io.File,
    write_offset: u64 = 0,
    summaries: [3]EntrySummary = undefined,
    summary_count: usize = 0,

    fn appendSummary(self: *WriteContext, summary: EntrySummary) !void {
        if (self.summary_count >= self.summaries.len) return error.TooManyEntries;
        self.summaries[self.summary_count] = summary;
        self.summary_count += 1;
    }
};

/// 构建最小 sigrok 兼容归档（含 version、metadata、raw 数据） / Builds a minimal sigrok-compatible archive containing version, metadata, and raw logic data.
pub fn writeSessionFromRawFile(allocator: std.mem.Allocator, options: WriteSessionFromRawOptions) !void {
    const metadata = try session.initMetadata(options.samplerate_hz, options.channel_count);
    const metadata_text = try session.renderMetadata(allocator, metadata);
    defer allocator.free(metadata_text);

    const entries = [_]ZipEntry{
        .{ .name = "version", .source = .{ .bytes = session.versionFileContent() } },
        .{ .name = "metadata", .source = .{ .bytes = metadata_text } },
        .{ .name = "logic-1-1", .source = .{ .file_path = options.raw_path } },
    };

    try writeSessionZip(options.output_path, entries[0..]);
}

/// 写入全部条目，以及中央目录和 EOCD 记录 / Writes all entries plus central directory and EOCD record.
fn writeSessionZip(output_path: []const u8, entries: []const ZipEntry) !void {
    if (entries.len == 0) return error.EmptyEntryList;
    if (entries.len > std.math.maxInt(u16)) return error.ZipTooManyEntries;

    const output_file = if (std.Io.Dir.path.isAbsolute(output_path))
        try std.Io.Dir.createFileAbsolute(io, output_path, .{ .truncate = true })
    else
        try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });
    defer output_file.close(io);

    var ctx = WriteContext{
        .file = output_file,
    };

    for (entries) |entry| {
        const summary = try writeEntry(&ctx, entry);
        try ctx.appendSummary(summary);
    }

    if (ctx.write_offset > std.math.maxInt(u32)) return error.ZipTooLarge;
    const central_directory_offset: u32 = @intCast(ctx.write_offset);

    for (ctx.summaries[0..ctx.summary_count]) |summary| {
        try writeCentralDirectoryHeader(output_file, summary);
        ctx.write_offset += CentralDirectoryHeaderSize + summary.name.len;
    }

    if (ctx.write_offset > std.math.maxInt(u32)) return error.ZipTooLarge;
    const central_directory_end: u32 = @intCast(ctx.write_offset);
    const central_directory_size = central_directory_end - central_directory_offset;

    try writeEndOfCentralDirectory(output_file, @intCast(ctx.summary_count), central_directory_size, central_directory_offset);
    try output_file.sync(io);
}

/// 序列化单个条目，并返回中央目录所需偏移和校验信息 / Serializes one entry and returns offsets/checksums for central directory emission.
fn writeEntry(ctx: *WriteContext, entry: ZipEntry) !EntrySummary {
    if (entry.name.len == 0) return error.InvalidEntryName;
    if (entry.name.len > std.math.maxInt(u16)) return error.EntryNameTooLong;

    if (ctx.write_offset > std.math.maxInt(u32)) return error.ZipTooLarge;
    const local_header_offset: u32 = @intCast(ctx.write_offset);

    switch (entry.source) {
        .bytes => |bytes| {
            if (bytes.len > std.math.maxInt(u32)) return error.EntryTooLarge;

            const uncompressed_size_u64: u64 = bytes.len;
            const compressed_size_u64 = try deflateStoredEncodedSize(uncompressed_size_u64);
            if (compressed_size_u64 > std.math.maxInt(u32)) return error.EntryTooLarge;

            var crc = std.hash.Crc32.init();
            crc.update(bytes);
            const crc32 = crc.final();

            try writeLocalFileHeader(
                ctx.file,
                entry.name,
                crc32,
                @intCast(compressed_size_u64),
                @intCast(uncompressed_size_u64),
            );
            ctx.write_offset += LocalFileHeaderSize + entry.name.len;

            const written_compressed = try writeDeflateStoredFromSlice(ctx.file, bytes);
            if (written_compressed != compressed_size_u64) return error.ZipSizeMismatch;
            ctx.write_offset += written_compressed;

            return .{
                .name = entry.name,
                .local_header_offset = local_header_offset,
                .crc32 = crc32,
                .compressed_size = @intCast(compressed_size_u64),
                .uncompressed_size = @intCast(uncompressed_size_u64),
            };
        },
        .file_path => |path| {
            const raw_file = if (std.Io.Dir.path.isAbsolute(path))
                try std.Io.Dir.openFileAbsolute(io, path, .{})
            else
                try std.Io.Dir.cwd().openFile(io, path, .{});
            defer raw_file.close(io);

            const raw_stat = try raw_file.stat(io);
            const uncompressed_size_u64 = raw_stat.size;
            if (uncompressed_size_u64 > std.math.maxInt(u32)) return error.EntryTooLarge;
            const compressed_size_u64 = try deflateStoredEncodedSize(uncompressed_size_u64);
            if (compressed_size_u64 > std.math.maxInt(u32)) return error.EntryTooLarge;
            const crc32 = try computeCrc32FromFile(raw_file, uncompressed_size_u64);

            try writeLocalFileHeader(
                ctx.file,
                entry.name,
                crc32,
                @intCast(compressed_size_u64),
                @intCast(uncompressed_size_u64),
            );
            ctx.write_offset += LocalFileHeaderSize + entry.name.len;

            var written_crc = std.hash.Crc32.init();
            var written_compressed: u64 = 0;
            const written_uncompressed = try writeDeflateStoredFromFile(ctx.file, raw_file, &written_crc, &written_compressed);
            if (written_uncompressed != uncompressed_size_u64) return error.ZipSizeMismatch;
            if (written_compressed != compressed_size_u64) return error.ZipSizeMismatch;
            if (written_crc.final() != crc32) return error.ZipChecksumMismatch;
            ctx.write_offset += written_compressed;

            return .{
                .name = entry.name,
                .local_header_offset = local_header_offset,
                .crc32 = crc32,
                .compressed_size = @intCast(compressed_size_u64),
                .uncompressed_size = @intCast(uncompressed_size_u64),
            };
        },
    }
}

fn deflateStoredEncodedSize(uncompressed_size: u64) !u64 {
    const max_block_len_u64: u64 = max_stored_block_len;
    const block_count = if (uncompressed_size == 0)
        @as(u64, 1)
    else
        (uncompressed_size + max_block_len_u64 - 1) / max_block_len_u64;
    const overhead = try std.math.mul(u64, block_count, 5);
    return try std.math.add(u64, uncompressed_size, overhead);
}

fn computeCrc32FromFile(raw_file: std.Io.File, total_size: u64) !u32 {
    var remaining = total_size;
    var read_offset: u64 = 0;
    var read_buffer: [max_stored_block_len]u8 = undefined;
    var crc = std.hash.Crc32.init();

    while (remaining > 0) {
        const chunk_len: usize = @intCast(@min(remaining, max_stored_block_len));
        const got = try raw_file.readPositionalAll(io, read_buffer[0..chunk_len], read_offset);
        if (got != chunk_len) return error.UnexpectedEndOfStream;
        crc.update(read_buffer[0..chunk_len]);
        remaining -= chunk_len;
        read_offset += got;
    }

    return crc.final();
}

/// 从内存字节写出 stored-deflate 数据块 / Emits stored-deflate payload blocks from in-memory bytes.
fn writeDeflateStoredFromSlice(file: std.Io.File, data: []const u8) !u64 {
    var written: u64 = 0;
    if (data.len == 0) {
        written += try writeDeflateStoredBlock(file, true, "");
        return written;
    }

    var offset: usize = 0;
    while (offset < data.len) {
        const chunk_len = @min(max_stored_block_len, data.len - offset);
        const final = offset + chunk_len == data.len;
        written += try writeDeflateStoredBlock(file, final, data[offset .. offset + chunk_len]);
        offset += chunk_len;
    }
    return written;
}

/// 以 stored-deflate 块流式写文件并计算 CRC32 / Streams a file as stored-deflate blocks while calculating CRC32.
fn writeDeflateStoredFromFile(file: std.Io.File, raw_file: std.Io.File, crc: *std.hash.Crc32, compressed_size: *u64) !u64 {
    const raw_stat = try raw_file.stat(io);
    const total_size = raw_stat.size;
    if (total_size > std.math.maxInt(u32)) return error.EntryTooLarge;

    if (total_size == 0) {
        compressed_size.* = try writeDeflateStoredBlock(file, true, "");
        return 0;
    }

    var remaining = total_size;
    var read_offset: u64 = 0;
    compressed_size.* = 0;
    var read_buffer: [max_stored_block_len]u8 = undefined;
    while (remaining > 0) {
        const chunk_len: usize = @intCast(@min(remaining, max_stored_block_len));
        const got = try raw_file.readPositionalAll(io, read_buffer[0..chunk_len], read_offset);
        if (got != chunk_len) return error.UnexpectedEndOfStream;
        read_offset += got;

        const chunk = read_buffer[0..chunk_len];
        crc.update(chunk);
        compressed_size.* += try writeDeflateStoredBlock(file, remaining == chunk_len, chunk);
        remaining -= chunk_len;
    }

    return total_size;
}
/// 写出一个 RFC1951 stored 块（不压缩，按 ZIP deflate 封装） / Emits one RFC1951 stored block (no compression, framed for ZIP deflate method).
fn writeDeflateStoredBlock(file: std.Io.File, final: bool, data: []const u8) !u64 {
    if (data.len > max_stored_block_len) return error.DeflateBlockTooLarge;

    const len_u16: u16 = @intCast(data.len);
    var header: [5]u8 = undefined;
    header[0] = if (final) 0x01 else 0x00;
    writeU16LE(header[1..3], len_u16);
    writeU16LE(header[3..5], ~len_u16);

    try file.writeStreamingAll(io, &header);
    try file.writeStreamingAll(io, data);
    return @as(u64, header.len + data.len);
}

/// 写 ZIP 本地文件头，CRC 与大小先写占位值 / Writes ZIP local file header with placeholders for CRC and sizes.
fn writeLocalFileHeader(file: std.Io.File, name: []const u8, crc32: u32, compressed_size: u32, uncompressed_size: u32) !void {
    var header: [LocalFileHeaderSize]u8 = [_]u8{0} ** LocalFileHeaderSize;
    writeU32LE(header[0..4], local_file_header_signature);
    writeU16LE(header[4..6], version_needed_to_extract);
    writeU16LE(header[6..8], general_purpose_flags);
    writeU16LE(header[8..10], compression_method_deflate);
    writeU16LE(header[10..12], 0);
    writeU16LE(header[12..14], 0);
    writeU32LE(header[14..18], crc32);
    writeU32LE(header[18..22], compressed_size);
    writeU32LE(header[22..26], uncompressed_size);
    writeU16LE(header[26..28], @intCast(name.len));
    writeU16LE(header[28..30], 0);

    try file.writeStreamingAll(io, &header);
    try file.writeStreamingAll(io, name);
}

/// 为已写出的本地条目写一条中央目录头 / Writes one central directory header for a previously emitted local entry.
fn writeCentralDirectoryHeader(file: std.Io.File, summary: EntrySummary) !void {
    var header: [CentralDirectoryHeaderSize]u8 = [_]u8{0} ** CentralDirectoryHeaderSize;
    writeU32LE(header[0..4], central_directory_header_signature);
    writeU16LE(header[4..6], version_made_by);
    writeU16LE(header[6..8], version_needed_to_extract);
    writeU16LE(header[8..10], general_purpose_flags);
    writeU16LE(header[10..12], compression_method_deflate);
    writeU16LE(header[12..14], 0);
    writeU16LE(header[14..16], 0);
    writeU32LE(header[16..20], summary.crc32);
    writeU32LE(header[20..24], summary.compressed_size);
    writeU32LE(header[24..28], summary.uncompressed_size);
    writeU16LE(header[28..30], @intCast(summary.name.len));
    writeU16LE(header[30..32], 0);
    writeU16LE(header[32..34], 0);
    writeU16LE(header[34..36], 0);
    writeU16LE(header[36..38], 0);
    writeU32LE(header[38..42], 0);
    writeU32LE(header[42..46], summary.local_header_offset);

    try file.writeStreamingAll(io, &header);
    try file.writeStreamingAll(io, summary.name);
}

/// 写入 ZIP 末尾 EOCD（End of Central Directory）记录 / Writes the ZIP end-of-central-directory record.
fn writeEndOfCentralDirectory(file: std.Io.File, record_count: u16, central_directory_size: u32, central_directory_offset: u32) !void {
    var record: [EndOfCentralDirectorySize]u8 = [_]u8{0} ** EndOfCentralDirectorySize;
    writeU32LE(record[0..4], end_of_central_directory_signature);
    writeU16LE(record[4..6], 0);
    writeU16LE(record[6..8], 0);
    writeU16LE(record[8..10], record_count);
    writeU16LE(record[10..12], record_count);
    writeU32LE(record[12..16], central_directory_size);
    writeU32LE(record[16..20], central_directory_offset);
    writeU16LE(record[20..22], 0);
    try file.writeStreamingAll(io, &record);
}

/// 以 little-endian 顺序写入 u16 / Writes u16 in little-endian order.
fn writeU16LE(dst: []u8, value: u16) void {
    std.mem.writeInt(u16, dst[0..2], value, .little);
}

/// 以 little-endian 顺序写入 u32 / Writes u32 in little-endian order.
fn writeU32LE(dst: []u8, value: u32) void {
    std.mem.writeInt(u32, dst[0..4], value, .little);
}

test "writeSessionFromRawFile writes sigrok-compatible zip entry set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const raw_bytes = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 };
    var tmp_root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_storage);
    const tmp_root_path = tmp_root_storage[0..tmp_root_len];

    const raw_name = "capture.raw";
    const sr_name = "capture.sr";
    const raw_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_root_path, raw_name });
    defer std.testing.allocator.free(raw_path);
    const sr_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_root_path, sr_name });
    defer std.testing.allocator.free(sr_path);

    {
        const raw_file = try tmp.dir.createFile(std.testing.io, raw_name, .{ .truncate = true });
        defer raw_file.close(std.testing.io);
        try raw_file.writeStreamingAll(std.testing.io, raw_bytes[0..]);
    }

    try writeSessionFromRawFile(std.testing.allocator, .{
        .output_path = sr_path,
        .raw_path = raw_path,
        .samplerate_hz = 24_000_000,
        .channel_count = 16,
    });

    const sr_file = try tmp.dir.openFile(std.testing.io, sr_name, .{});
    defer sr_file.close(std.testing.io);

    const archive_len_u64 = try sr_file.length(std.testing.io);
    try std.testing.expect(archive_len_u64 <= 1024 * 1024);
    const archive_len: usize = @intCast(archive_len_u64);
    const archive_bytes = try std.testing.allocator.alloc(u8, archive_len);
    defer std.testing.allocator.free(archive_bytes);
    const archive_read = try sr_file.readPositionalAll(std.testing.io, archive_bytes, 0);
    try std.testing.expectEqual(archive_len, archive_read);

    try std.testing.expect(archive_bytes.len > EndOfCentralDirectorySize);
    try std.testing.expect(std.mem.eql(u8, archive_bytes[0..4], "PK\x03\x04"));
    try std.testing.expect(std.mem.find(u8, archive_bytes, "PK\x01\x02") != null);
    try std.testing.expect(std.mem.find(u8, archive_bytes, "PK\x05\x06") != null);

    var reader_buf: [4096]u8 = undefined;
    var reader = sr_file.reader(std.testing.io, &reader_buf);
    var iter = try std.zip.Iterator.init(&reader);

    const expected_names = [_][]const u8{ "version", "metadata", "logic-1-1" };
    var idx: usize = 0;
    var filename_buf: [64]u8 = undefined;

    while (try iter.next()) |entry| {
        try std.testing.expect(idx < expected_names.len);
        try std.testing.expectEqual(std.zip.CompressionMethod.deflate, entry.compression_method);

        const filename_len: usize = @intCast(entry.filename_len);
        try std.testing.expect(filename_len <= filename_buf.len);

        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(filename_buf[0..filename_len]);
        try std.testing.expectEqualStrings(expected_names[idx], filename_buf[0..filename_len]);

        idx += 1;
    }
    try std.testing.expectEqual(expected_names.len, idx);

    var extract_dir = try tmp.dir.createDirPathOpen(std.testing.io, "unzipped", .{});
    defer extract_dir.close(std.testing.io);

    var extract_reader_buf: [4096]u8 = undefined;
    var extract_reader = sr_file.reader(std.testing.io, &extract_reader_buf);
    try extract_reader.seekTo(0);
    try std.zip.extract(extract_dir, &extract_reader, .{});

    const metadata_file = try extract_dir.openFile(std.testing.io, "metadata", .{});
    defer metadata_file.close(std.testing.io);
    const metadata_len_u64 = try metadata_file.length(std.testing.io);
    try std.testing.expect(metadata_len_u64 <= 8 * 1024);
    const metadata_text = try std.testing.allocator.alloc(u8, @intCast(metadata_len_u64));
    defer std.testing.allocator.free(metadata_text);
    const metadata_read = try metadata_file.readPositionalAll(std.testing.io, metadata_text, 0);
    try std.testing.expectEqual(@as(usize, @intCast(metadata_len_u64)), metadata_read);

    try std.testing.expect(std.mem.find(u8, metadata_text, "capturefile=logic-1") != null);
    try std.testing.expect(std.mem.find(u8, metadata_text, "samplerate=24000000") != null);
    try std.testing.expect(std.mem.find(u8, metadata_text, "total probes=16") != null);
    try std.testing.expect(std.mem.find(u8, metadata_text, "unitsize=2") != null);
    try std.testing.expect(std.mem.find(u8, metadata_text, "probe1=D0") != null);
    try std.testing.expect(std.mem.find(u8, metadata_text, "probe16=D15") != null);

    const logic_file = try extract_dir.openFile(std.testing.io, "logic-1-1", .{});
    defer logic_file.close(std.testing.io);
    const logic_len_u64 = try logic_file.length(std.testing.io);
    try std.testing.expect(logic_len_u64 <= 8 * 1024);
    const logic_bytes = try std.testing.allocator.alloc(u8, @intCast(logic_len_u64));
    defer std.testing.allocator.free(logic_bytes);
    const logic_read = try logic_file.readPositionalAll(std.testing.io, logic_bytes, 0);
    try std.testing.expectEqual(@as(usize, @intCast(logic_len_u64)), logic_read);
    try std.testing.expectEqualSlices(u8, raw_bytes[0..], logic_bytes);
}
