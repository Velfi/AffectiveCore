const std = @import("std");

const config = @import("../core/config.zig");
const files = @import("../platform/common/files.zig");
const cognitive_persistence = @import("../storage/json_store_persistence.zig");
const cognitive_schema = @import("../storage/schema.zig");

pub const file_magic = "AFFECTIVE_BRAIN\x00\x01";
const format_version: u32 = 1;
const compression_name = "zlib";
const max_brain_file_bytes: usize = 1024 * 1024 * 1024;
const max_plain_archive_bytes: usize = 2 * 1024 * 1024 * 1024;
const excluded_component_names = [_][]const u8{
    "provider_credentials.json",
    "secrets.json",
    "pairing_secrets.json",
    "host_permissions.json",
    "host_permission_grants.json",
    "host_pairing.json",
    "pairing_secret",
};

pub const ComponentInfo = struct {
    path: []const u8,
    bytes: u64,
    sha256: []const u8,
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
    sha256: []const u8,
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

    var payloads = std.ArrayList(ComponentPayload).empty;
    var archived_infos = std.ArrayList(ComponentInfo).empty;
    var component_infos = std.ArrayList(ComponentInfo).empty;
    try collectComponents(allocator, io, cfg.brain_root, "", &component_infos);
    const source_infos = try component_infos.toOwnedSlice(allocator);

    for (source_infos) |source_component| {
        const src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cfg.brain_root, source_component.path });
        const source_bytes = try readFileAllocPath(io, src, allocator, .limited(max_brain_file_bytes));
        if (source_bytes.len != source_component.bytes) return error.BrainComponentSizeMismatch;
        const bytes = try archiveComponentBytes(allocator, io, source_component.path, src, source_bytes);
        const archived_sha256 = try sha256Hex(allocator, bytes);
        try archived_infos.append(allocator, .{
            .path = source_component.path,
            .bytes = bytes.len,
            .sha256 = archived_sha256,
        });
        try payloads.append(allocator, .{
            .path = source_component.path,
            .bytes = bytes.len,
            .sha256 = archived_sha256,
            .data_base64 = try encodeBase64(allocator, bytes),
        });
    }
    const infos = try archived_infos.toOwnedSlice(allocator);
    const payload_slice = try payloads.toOwnedSlice(allocator);

    const archive: BrainArchive = .{
        .format_version = format_version,
        .compression = compression_name,
        .brain_id = cfg.brain_id,
        .brain_settings = try portableBrainSettings(allocator, cfg),
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

fn archiveComponentBytes(allocator: std.mem.Allocator, io: std.Io, relative_path: []const u8, source_path: []const u8, source_bytes: []const u8) ![]const u8 {
    if (!isCognitiveStorePath(relative_path)) return source_bytes;
    if (!std.mem.startsWith(u8, source_bytes, "SQLite format 3\x00")) return source_bytes;
    return sanitizeCognitiveStoreBytes(allocator, io, source_path);
}

fn isCognitiveStorePath(relative_path: []const u8) bool {
    return std.mem.eql(u8, relative_path, "memory/people.sqlite");
}

fn sanitizeCognitiveStoreBytes(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8) ![]const u8 {
    const json = try cognitive_persistence.readCognitiveJson(allocator, io, source_path, allocator);
    var parsed = try std.json.parseFromSlice(cognitive_schema.CognitiveFile, allocator, json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try cognitive_persistence.validateCognitiveFile(parsed.value);
    for (parsed.value.host_bindings) |*binding| {
        binding.permissions = &.{};
    }
    for (parsed.value.capability_statuses) |*status| {
        status.permission = .unknown;
    }
    try cognitive_persistence.validateCognitiveFile(parsed.value);
    const sanitized_json = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.archive_tmp_{x}.sqlite", .{ source_path, std.hash.Wyhash.hash(0, sanitized_json) });
    std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    try cognitive_persistence.writeCognitiveJson(allocator, io, temp_path, sanitized_json);
    return try readFileAllocPath(io, temp_path, allocator, .limited(max_brain_file_bytes));
}

pub fn importBrain(allocator: std.mem.Allocator, io: std.Io, brain_file_path: []const u8, cfg: config.Config) !BrainManifest {
    try requireBrainRoot(cfg);
    try expectMissing(io, cfg.brain_root, error.BrainAlreadyExists);

    const archive = try readArchive(allocator, io, brain_file_path);
    try validateArchive(archive);

    for (archive.components) |component| {
        try validateRelativePath(component.path);
        const decoded = try decodeBase64(allocator, component.data_base64);
        if (decoded.len != component.bytes) return error.BrainFileComponentSizeMismatch;
        const actual_sha256 = try sha256Hex(allocator, decoded);
        if (!std.mem.eql(u8, actual_sha256, component.sha256)) return error.BrainFileComponentHashMismatch;
        const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cfg.brain_root, component.path });
        try writeFilePath(io, dst, decoded);
    }

    try rehomeImportedBrainProfile(allocator, io, cfg.brain_root, cfg.brain_id);
    const resolved = try cfg.ensureBrainPaths(allocator);
    var local_fs = files.LocalFileSystem{};
    try config.provisionBrainConfigFiles(allocator, local_fs.filesystem(), io, resolved);
    return try manifestFromArchiveForBrainId(allocator, archive, cfg.brain_id);
}

fn rehomeImportedBrainProfile(allocator: std.mem.Allocator, io: std.Io, brain_root: []const u8, brain_id: []const u8) !void {
    const profile_path = try std.fmt.allocPrint(allocator, "{s}/brain_profile.json", .{brain_root});
    const bytes = try readFileAllocPath(io, profile_path, allocator, .limited(max_brain_file_bytes));
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidBrainProfile;
    try parsed.value.object.put(allocator, "id", .{ .string = brain_id });
    const json = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    try writeFilePath(io, profile_path, json);
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
    var seen = std.StringHashMap(void).init(std.heap.page_allocator);
    defer seen.deinit();
    for (archive.components) |component| {
        try validateRelativePath(component.path);
        if (seen.contains(component.path)) return error.DuplicateBrainFileComponent;
        try seen.put(component.path, {});
        try validateSha256Hex(component.sha256);
        _ = try std.base64.standard.Decoder.calcSizeForSlice(component.data_base64);
        total += component.bytes;
    }
    if (archive.total_bytes != total) return error.InvalidBrainFileManifest;
}

fn manifestFromArchive(allocator: std.mem.Allocator, archive: BrainArchive) !BrainManifest {
    return manifestFromArchiveForBrainId(allocator, archive, archive.brain_id);
}

fn manifestFromArchiveForBrainId(allocator: std.mem.Allocator, archive: BrainArchive, brain_id: []const u8) !BrainManifest {
    var infos = std.ArrayList(ComponentInfo).empty;
    for (archive.components) |component| {
        try infos.append(allocator, .{ .path = component.path, .bytes = component.bytes, .sha256 = component.sha256 });
    }
    const owned = try infos.toOwnedSlice(allocator);
    return .{
        .format_version = archive.format_version,
        .compression = archive.compression,
        .brain_id = brain_id,
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
        if (isExcludedComponentName(entry.name)) continue;
        const rel = if (relative_dir.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_dir, entry.name });
        try validateRelativePath(rel);
        switch (entry.kind) {
            .file => {
                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, rel });
                const bytes = try readFileAllocPath(io, full_path, allocator, .limited(max_brain_file_bytes));
                try out.append(allocator, .{ .path = rel, .bytes = bytes.len, .sha256 = try sha256Hex(allocator, bytes) });
            },
            .directory => try collectComponents(allocator, io, root, rel, out),
            else => return error.UnsupportedBrainComponentKind,
        }
    }
}

fn portableBrainSettings(allocator: std.mem.Allocator, cfg: config.Config) !config.BrainSettings {
    var settings = cfg.brainSettings();
    settings.brain_root = "";
    settings.image_generation_output_dir = try portablePathSetting(allocator, cfg.brain_root, settings.image_generation_output_dir);
    settings.face_embeddings_dir = try portablePathSetting(allocator, cfg.brain_root, settings.face_embeddings_dir);
    settings.memory_path = try portablePathSetting(allocator, cfg.brain_root, settings.memory_path);
    settings.graph_path = try portablePathSetting(allocator, cfg.brain_root, settings.graph_path);
    settings.seed_path = try portablePathSetting(allocator, cfg.brain_root, settings.seed_path);
    settings.maintenance_schedule_path = try portablePathSetting(allocator, cfg.brain_root, settings.maintenance_schedule_path);
    settings.maintenance_state_path = try portablePathSetting(allocator, cfg.brain_root, settings.maintenance_state_path);
    settings.context_stats_path = try portablePathSetting(allocator, cfg.brain_root, settings.context_stats_path);
    settings.runtime_options_path = try portablePathSetting(allocator, cfg.brain_root, settings.runtime_options_path);
    settings.llm_providers_path = try portablePathSetting(allocator, cfg.brain_root, settings.llm_providers_path);
    settings.captures_dir = try portablePathSetting(allocator, cfg.brain_root, settings.captures_dir);
    settings.id_monitor_external_command = "";
    return settings;
}

fn portablePathSetting(allocator: std.mem.Allocator, brain_root: []const u8, value: []const u8) ![]const u8 {
    if (value.len == 0) return "";
    if (!std.fs.path.isAbsolute(value)) {
        try validateRelativePath(value);
        return value;
    }
    if (brain_root.len > 0 and std.fs.path.isAbsolute(brain_root)) {
        const root_with_sep = try std.fmt.allocPrint(allocator, "{s}/", .{brain_root});
        if (std.mem.startsWith(u8, value, root_with_sep)) {
            const relative = value[root_with_sep.len..];
            try validateRelativePath(relative);
            return relative;
        }
    }
    return "";
}

fn isExcludedComponentName(name: []const u8) bool {
    for (excluded_component_names) |excluded| {
        if (std.mem.eql(u8, name, excluded)) return true;
    }
    return false;
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

fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const out = try allocator.alloc(u8, digest.len * 2);
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

fn validateSha256Hex(value: []const u8) !void {
    if (value.len != std.crypto.hash.sha2.Sha256.digest_length * 2) return error.InvalidBrainFileComponentHash;
    for (value) |c| {
        if (!std.ascii.isHex(c)) return error.InvalidBrainFileComponentHash;
    }
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
    deleteTree(std.testing.io, "data/test/brain_container_other");
    defer deleteTree(std.testing.io, src_root);
    defer deleteTree(std.testing.io, brain_file_path);
    defer deleteTree(std.testing.io, dst_root);
    defer deleteTree(std.testing.io, "data/test/brain_container_other");

    try writeFilePath(std.testing.io, "data/test/brain_container_src/brain_profile.json", "{\"id\":\"ada\",\"name\":\"Ada\"}");
    try writeFilePath(std.testing.io, "data/test/brain_container_src/memory/people.sqlite", "{\"memories\":[\"private\"]}");
    try writeFilePath(std.testing.io, "data/test/brain_container_src/captures/face.jpg", "fake image bytes");
    try writeFilePath(std.testing.io, "data/test/brain_container_src/provider_credentials.json", "{\"openai\":\"secret-key\"}");
    try writeFilePath(std.testing.io, "data/test/brain_container_src/pairing_secrets.json", "{\"pairing\":\"secret-pairing\"}");
    try writeFilePath(std.testing.io, "data/test/brain_container_src/host_permissions.json", "{\"camera\":\"granted\"}");

    const cfg = config.Config{
        .brain_id = "ada",
        .brain_root = src_root,
        .conversation_model = "gpt-4.1-mini",
        .memory_path = "/Users/zelda/Library/Application Support/Affective/brains/ada/memory/people.sqlite",
        .id_monitor_external_command = "/usr/bin/env host-only-monitor",
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
    for (inspected_file.components) |component| {
        try std.testing.expectEqual(@as(usize, std.crypto.hash.sha2.Sha256.digest_length * 2), component.sha256.len);
    }
    const inspected_json = try std.json.Stringify.valueAlloc(allocator, inspected_file, .{ .whitespace = .minified });
    try std.testing.expect(std.mem.indexOf(u8, inspected_json, "private") == null);
    try std.testing.expect(std.mem.indexOf(u8, inspected_json, "secret-password") == null);
    try std.testing.expect(std.mem.indexOf(u8, inspected_json, "provider_credentials") == null);
    try std.testing.expect(std.mem.indexOf(u8, inspected_json, "pairing_secrets") == null);
    try std.testing.expect(std.mem.indexOf(u8, inspected_json, "host_permissions") == null);

    const archive = try readArchive(allocator, std.testing.io, brain_file_path);
    try std.testing.expectEqualStrings("", archive.brain_settings.brain_root);
    try std.testing.expectEqualStrings("", archive.brain_settings.memory_path);
    try std.testing.expectEqualStrings("", archive.brain_settings.id_monitor_external_command);

    const imported = try importBrain(allocator, std.testing.io, brain_file_path, .{ .brain_id = "ada", .brain_root = dst_root });
    try std.testing.expectEqual(@as(usize, 3), imported.component_count);
    const copied = try readFileAllocPath(std.testing.io, "data/test/brain_container_dst/memory/people.sqlite", allocator, .limited(1024));
    try std.testing.expectEqualStrings("{\"memories\":[\"private\"]}", copied);
    try std.testing.expectError(error.FileNotFound, readFileAllocPath(std.testing.io, "data/test/brain_container_dst/provider_credentials.json", allocator, .limited(1024)));
    try std.testing.expectError(error.FileNotFound, readFileAllocPath(std.testing.io, "data/test/brain_container_dst/pairing_secrets.json", allocator, .limited(1024)));
    try std.testing.expectError(error.FileNotFound, readFileAllocPath(std.testing.io, "data/test/brain_container_dst/host_permissions.json", allocator, .limited(1024)));
    const rehomed = try importBrain(allocator, std.testing.io, brain_file_path, .{ .brain_id = "otto", .brain_root = "data/test/brain_container_other" });
    try std.testing.expectEqualStrings("otto", rehomed.brain_id);
    const rehomed_profile = try readFileAllocPath(std.testing.io, "data/test/brain_container_other/brain_profile.json", allocator, .limited(1024));
    try std.testing.expect(std.mem.indexOf(u8, rehomed_profile, "\"id\": \"otto\"") != null);
}

test "brain file strips host permission grants from cognitive archive component" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const src_root = "data/test/brain_container_permissions_src";
    const dst_root = "data/test/brain_container_permissions_dst";
    const brain_file_path = "data/test/permissions.brain";
    const archived_component_path = "data/test/brain_container_permissions_component.sqlite";
    deleteTree(std.testing.io, src_root);
    deleteTree(std.testing.io, dst_root);
    deleteTree(std.testing.io, brain_file_path);
    deleteTree(std.testing.io, archived_component_path);
    defer deleteTree(std.testing.io, src_root);
    defer deleteTree(std.testing.io, dst_root);
    defer deleteTree(std.testing.io, brain_file_path);
    defer deleteTree(std.testing.io, archived_component_path);

    try writeFilePath(std.testing.io, "data/test/brain_container_permissions_src/brain_profile.json", "{\"id\":\"ada\",\"name\":\"Ada\"}");
    const source_json =
        \\{
        \\  "brain_id": "ada",
        \\  "host_bindings": [
        \\    {
        \\      "host_id": "mac-host",
        \\      "platform": "macOS",
        \\      "attached_at_ms": 1,
        \\      "permissions": ["camera", "microphone"],
        \\      "capability_ids": ["take_picture"]
        \\    }
        \\  ],
        \\  "capability_statuses": [
        \\    {
        \\      "capability_id": "camera.capture",
        \\      "host_id": "mac-host",
        \\      "permission": "granted",
        \\      "availability": "available",
        \\      "quality": 0.9,
        \\      "reliability": 0.8,
        \\      "updated_at_ms": 1
        \\    }
        \\  ]
        \\}
    ;
    try cognitive_persistence.writeCognitiveJson(allocator, std.testing.io, "data/test/brain_container_permissions_src/memory/people.sqlite", source_json);

    const cfg = config.Config{
        .brain_id = "ada",
        .brain_root = src_root,
        .memory_path = "data/test/brain_container_permissions_src/memory/people.sqlite",
    };
    _ = try exportBrain(allocator, std.testing.io, cfg, brain_file_path);
    const archive = try readArchive(allocator, std.testing.io, brain_file_path);
    var encoded_component: ?[]const u8 = null;
    for (archive.components) |component| {
        if (std.mem.eql(u8, component.path, "memory/people.sqlite")) encoded_component = component.data_base64;
    }
    const data_base64 = encoded_component orelse return error.MissingCognitiveArchiveComponent;
    const archived_bytes = try decodeBase64(allocator, data_base64);
    try writeFilePath(std.testing.io, archived_component_path, archived_bytes);
    const archived_json = try cognitive_persistence.readCognitiveJson(allocator, std.testing.io, archived_component_path, allocator);
    const archived = try std.json.parseFromSlice(cognitive_schema.CognitiveFile, allocator, archived_json, .{ .ignore_unknown_fields = false });
    try std.testing.expectEqual(@as(usize, 1), archived.value.host_bindings.len);
    try std.testing.expectEqual(@as(usize, 0), archived.value.host_bindings[0].permissions.len);
    try std.testing.expectEqual(cognitive_schema.CapabilityPermission.unknown, archived.value.capability_statuses[0].permission);

    _ = try importBrain(allocator, std.testing.io, brain_file_path, .{ .brain_id = "ada", .brain_root = dst_root });
    const imported_json = try cognitive_persistence.readCognitiveJson(allocator, std.testing.io, "data/test/brain_container_permissions_dst/memory/people.sqlite", allocator);
    const imported = try std.json.parseFromSlice(cognitive_schema.CognitiveFile, allocator, imported_json, .{ .ignore_unknown_fields = false });
    try std.testing.expectEqual(@as(usize, 1), imported.value.host_bindings.len);
    try std.testing.expectEqual(@as(usize, 0), imported.value.host_bindings[0].permissions.len);
    try std.testing.expectEqual(cognitive_schema.CapabilityPermission.unknown, imported.value.capability_statuses[0].permission);
}
