const std = @import("std");

const config = @import("../core/config.zig");
const files = @import("../platform/common/files.zig");

pub const file_magic = "AFFECTIVE_BRAIN\x00\x01";
const format_version: u32 = 1;
const compression_name = "zlib";
const max_brain_file_bytes: usize = 1024 * 1024 * 1024;
const max_plain_archive_bytes: usize = 2 * 1024 * 1024 * 1024;

pub const ComponentInfo = struct {
    path: []const u8,
    bytes: u64,
};

pub const BrainIntrospection = struct {
    brain_id: []const u8,
    brain_root: []const u8,
    format_version: u32,
    component_count: usize,
    total_bytes: u64,
    components: []const ComponentInfo,
};

pub const BrainManifest = struct {
    format_version: u32,
    compression: []const u8,
    brain_id: []const u8,
    component_count: usize,
    total_bytes: u64,
    components: []const ComponentInfo,
};

const BrainArchive = struct {
    format_version: u32,
    compression: []const u8,
    brain_id: []const u8,
    brain_settings: config.BrainSettings,
    component_count: usize,
    total_bytes: u64,
    components: []const ComponentPayload,
};

const ComponentPayload = struct {
    path: []const u8,
    bytes: u64,
    data_base64: []const u8,
};

pub fn inspectBrain(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) !BrainIntrospection {
    try requireBrainRoot(cfg);
    var components = std.ArrayList(ComponentInfo).empty;
    try collectComponents(allocator, io, cfg.brain_root, "", &components);
    const owned = try components.toOwnedSlice(allocator);
    return .{
        .brain_id = cfg.brain_id,
        .brain_root = cfg.brain_root,
        .format_version = format_version,
        .component_count = owned.len,
        .total_bytes = totalBytes(owned),
        .components = owned,
    };
}

pub fn inspectBrainFile(allocator: std.mem.Allocator, io: std.Io, brain_file_path: []const u8) !BrainManifest {
    const archive = try readArchive(allocator, io, brain_file_path);
    return try manifestFromArchive(allocator, archive);
}

pub fn exportBrain(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, brain_file_path: []const u8) !BrainManifest {
    try requireBrainRoot(cfg);
    if (brain_file_path.len == 0) return error.EmptyBrainFilePath;
    try expectMissing(io, brain_file_path, error.BrainFileAlreadyExists);

    var component_infos = std.ArrayList(ComponentInfo).empty;
    try collectComponents(allocator, io, cfg.brain_root, "", &component_infos);
    const infos = try component_infos.toOwnedSlice(allocator);

    var payloads = std.ArrayList(ComponentPayload).empty;
    for (infos) |component| {
        const src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cfg.brain_root, component.path });
        const bytes = try readFileAllocPath(io, src, allocator, .limited(max_brain_file_bytes));
        if (bytes.len != component.bytes) return error.BrainComponentSizeMismatch;
        try payloads.append(allocator, .{
            .path = component.path,
            .bytes = component.bytes,
            .data_base64 = try encodeBase64(allocator, bytes),
        });
    }
    const payload_slice = try payloads.toOwnedSlice(allocator);

    const archive: BrainArchive = .{
        .format_version = format_version,
        .compression = compression_name,
        .brain_id = cfg.brain_id,
        .brain_settings = cfg.brainSettings(),
        .component_count = payload_slice.len,
        .total_bytes = totalBytes(infos),
        .components = payload_slice,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, archive, .{ .whitespace = .minified });
    const compressed = try compressBytes(allocator, json);
    const brain_file = try withMagic(allocator, compressed);
    try writeFilePath(io, brain_file_path, brain_file);
    return try manifestFromArchive(allocator, archive);
}

pub fn importBrain(allocator: std.mem.Allocator, io: std.Io, brain_file_path: []const u8, cfg: config.Config) !BrainManifest {
    try requireBrainRoot(cfg);
    try expectMissing(io, cfg.brain_root, error.BrainAlreadyExists);

    const archive = try readArchive(allocator, io, brain_file_path);
    try validateArchive(archive);
    if (!std.mem.eql(u8, archive.brain_id, cfg.brain_id)) return error.BrainFileIdMismatch;

    for (archive.components) |component| {
        try validateRelativePath(component.path);
        const decoded = try decodeBase64(allocator, component.data_base64);
        if (decoded.len != component.bytes) return error.BrainFileComponentSizeMismatch;
        const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cfg.brain_root, component.path });
        try writeFilePath(io, dst, decoded);
    }

    return try manifestFromArchive(allocator, archive);
}

fn requireBrainRoot(cfg: config.Config) !void {
    if (cfg.brain_id.len == 0) return error.EmptyBrainId;
    if (cfg.brain_root.len == 0) return error.EmptyBrainRoot;
}

fn readArchive(allocator: std.mem.Allocator, io: std.Io, brain_file_path: []const u8) !BrainArchive {
    if (brain_file_path.len == 0) return error.EmptyBrainFilePath;
    const bytes = try readFileAllocPath(io, brain_file_path, allocator, .limited(max_brain_file_bytes));
    if (!std.mem.startsWith(u8, bytes, file_magic)) return error.InvalidBrainFileMagic;
    const compressed = bytes[file_magic.len..];
    const json = try decompressBytes(allocator, compressed);
    const parsed = try std.json.parseFromSlice(BrainArchive, allocator, json, .{ .ignore_unknown_fields = false });
    const archive = parsed.value;
    try validateArchive(archive);
    return archive;
}

fn validateArchive(archive: BrainArchive) !void {
    if (archive.format_version != format_version) return error.UnsupportedBrainFileVersion;
    if (!std.mem.eql(u8, archive.compression, compression_name)) return error.UnsupportedBrainFileCompression;
    if (archive.brain_id.len == 0) return error.EmptyBrainId;
    if (archive.brain_settings.brain_id.len > 0 and !std.mem.eql(u8, archive.brain_settings.brain_id, archive.brain_id)) return error.BrainFileSettingsIdMismatch;
    if (archive.component_count != archive.components.len) return error.InvalidBrainFileManifest;
    var total: u64 = 0;
    for (archive.components) |component| {
        try validateRelativePath(component.path);
        total += component.bytes;
    }
    if (archive.total_bytes != total) return error.InvalidBrainFileManifest;
}

fn manifestFromArchive(allocator: std.mem.Allocator, archive: BrainArchive) !BrainManifest {
    var infos = std.ArrayList(ComponentInfo).empty;
    for (archive.components) |component| {
        try infos.append(allocator, .{ .path = component.path, .bytes = component.bytes });
    }
    const owned = try infos.toOwnedSlice(allocator);
    return .{
        .format_version = archive.format_version,
        .compression = archive.compression,
        .brain_id = archive.brain_id,
        .component_count = archive.component_count,
        .total_bytes = archive.total_bytes,
        .components = owned,
    };
}

fn collectComponents(allocator: std.mem.Allocator, io: std.Io, root: []const u8, relative_dir: []const u8, out: *std.ArrayList(ComponentInfo)) !void {
    const dir_path = if (relative_dir.len == 0) root else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, relative_dir });
    var dir = try openDirPath(io, dir_path);
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) return error.InvalidBrainComponentPath;
        const rel = if (relative_dir.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_dir, entry.name });
        try validateRelativePath(rel);
        switch (entry.kind) {
            .file => {
                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, rel });
                try out.append(allocator, .{ .path = rel, .bytes = try fileSize(io, full_path) });
            },
            .directory => try collectComponents(allocator, io, root, rel, out),
            else => return error.UnsupportedBrainComponentKind,
        }
    }
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidBrainComponentPath;
    if (std.fs.path.isAbsolute(path)) return error.InvalidBrainComponentPath;
    if (std.mem.indexOfScalar(u8, path, '\n') != null or std.mem.indexOfScalar(u8, path, '\r') != null) return error.InvalidBrainComponentPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidBrainComponentPath;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidBrainComponentPath;
    }
}

fn totalBytes(components: []const ComponentInfo) u64 {
    var total: u64 = 0;
    for (components) |component| total += component.bytes;
    return total;
}

fn encodeBase64(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, len);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
}

fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, len);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}

fn compressBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const bound = bytes.len + bytes.len / 8 + bytes.len / 16 + 4096;
    const out_buf = try allocator.alloc(u8, @max(bound, @as(usize, 8192)));
    var out_writer = std.Io.Writer.fixed(out_buf);
    var flate_buf: [std.compress.flate.max_window_len * 2]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&out_writer, &flate_buf, .zlib, .best);
    try compressor.writer.writeAll(bytes);
    try compressor.finish();
    return try allocator.dupe(u8, out_writer.buffered());
}

fn decompressBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var in_reader = std.Io.Reader.fixed(bytes);
    var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&in_reader, .zlib, &flate_buf);
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, @min(bytes.len * 4, max_plain_archive_bytes));
    defer out.deinit();
    const written = try decompressor.reader.streamRemaining(&out.writer);
    if (written > max_plain_archive_bytes) return error.BrainFileTooLarge;
    return try allocator.dupe(u8, out.written());
}

fn withMagic(allocator: std.mem.Allocator, compressed: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, file_magic.len + compressed.len);
    @memcpy(out[0..file_magic.len], file_magic);
    @memcpy(out[file_magic.len..], compressed);
    return out;
}

fn expectMissing(io: std.Io, path: []const u8, exists_error: anyerror) !void {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return exists_error;
}

fn fileSize(io: std.Io, path: []const u8) !u64 {
    const stat = try files.statFilePath(io, path);
    return stat.size;
}

fn openDirPath(io: std.Io, path: []const u8) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path)) return std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
}

fn readFileAllocPath(io: std.Io, path: []const u8, allocator: std.mem.Allocator, limit: std.Io.Limit) ![]u8 {
    return files.readFileAllocPath(io, path, allocator, limit);
}

fn writeFilePath(io: std.Io, path: []const u8, data: []const u8) !void {
    return files.writeFilePath(io, path, data);
}

fn deleteTree(io: std.Io, path: []const u8) void {
    var dir = openDirPath(io, path) catch {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        return;
    };
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const child = std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ path, entry.name }) catch return;
        defer std.testing.allocator.free(child);
        switch (entry.kind) {
            .file => std.Io.Dir.cwd().deleteFile(io, child) catch {},
            .directory => deleteTree(io, child),
            else => {},
        }
    }
    dir.close(io);
    std.Io.Dir.cwd().deleteDir(io, path) catch {};
}

test "brain file exports imports and introspects without raw content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const src_root = "data/test/brain_container_src";
    const brain_file_path = "data/test/ada.brain";
    const dst_root = "data/test/brain_container_dst";
    deleteTree(std.testing.io, src_root);
    deleteTree(std.testing.io, brain_file_path);
    deleteTree(std.testing.io, dst_root);
    defer deleteTree(std.testing.io, src_root);
    defer deleteTree(std.testing.io, brain_file_path);
    defer deleteTree(std.testing.io, dst_root);

    try writeFilePath(std.testing.io, "data/test/brain_container_src/memory/people.sqlite", "{\"memories\":[\"private\"]}");
    try writeFilePath(std.testing.io, "data/test/brain_container_src/events.jsonl", "{\"event\":\"private\"}\n");
    try writeFilePath(std.testing.io, "data/test/brain_container_src/captures/face.jpg", "fake image bytes");

    const cfg = config.Config{
        .brain_id = "ada",
        .brain_root = src_root,
        .conversation_model = "gpt-4.1-mini",
        .email_password = "secret-password",
    };
    const info = try inspectBrain(allocator, std.testing.io, cfg);
    try std.testing.expectEqualStrings("ada", info.brain_id);
    try std.testing.expectEqual(@as(usize, 3), info.component_count);
    for (info.components) |component| {
        try std.testing.expect(std.mem.indexOf(u8, component.path, "private") == null);
    }

    const manifest = try exportBrain(allocator, std.testing.io, cfg, brain_file_path);
    try std.testing.expectEqualStrings("ada", manifest.brain_id);
    try std.testing.expectEqualStrings(compression_name, manifest.compression);
    try std.testing.expectEqual(@as(usize, 3), manifest.component_count);
    try std.Io.Dir.cwd().access(std.testing.io, brain_file_path, .{});

    const inspected_file = try inspectBrainFile(allocator, std.testing.io, brain_file_path);
    try std.testing.expectEqualStrings("ada", inspected_file.brain_id);
    try std.testing.expectEqual(@as(usize, 3), inspected_file.component_count);
    const inspected_json = try std.json.Stringify.valueAlloc(allocator, inspected_file, .{ .whitespace = .minified });
    try std.testing.expect(std.mem.indexOf(u8, inspected_json, "private") == null);
    try std.testing.expect(std.mem.indexOf(u8, inspected_json, "secret-password") == null);

    const imported = try importBrain(allocator, std.testing.io, brain_file_path, .{ .brain_id = "ada", .brain_root = dst_root });
    try std.testing.expectEqual(@as(usize, 3), imported.component_count);
    const copied = try readFileAllocPath(std.testing.io, "data/test/brain_container_dst/memory/people.sqlite", allocator, .limited(1024));
    try std.testing.expectEqualStrings("{\"memories\":[\"private\"]}", copied);
    try std.testing.expectError(error.BrainFileIdMismatch, importBrain(allocator, std.testing.io, brain_file_path, .{ .brain_id = "otto", .brain_root = "data/test/brain_container_other" }));
}
