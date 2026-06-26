const std = @import("std");

pub const FileSystem = struct {
    ctx: *anyopaque,
    ensureParentDirFn: *const fn (*anyopaque, std.Io, []const u8) anyerror!void,
    readFileAllocPathFn: *const fn (*anyopaque, std.Io, []const u8, std.mem.Allocator, std.Io.Limit) anyerror![]u8,
    writeFilePathFn: *const fn (*anyopaque, std.Io, []const u8, []const u8) anyerror!void,
    ensureDirFn: *const fn (*anyopaque, std.Io, []const u8) anyerror!void,
    sweepSpeechArtifactsFn: *const fn (*anyopaque, std.Io, SpeechArtifactSweepRequest) anyerror!SpeechArtifactSweepResult,

    pub fn ensureParentDir(self: FileSystem, io: std.Io, path: []const u8) !void {
        return self.ensureParentDirFn(self.ctx, io, path);
    }

    pub fn readFileAllocPath(self: FileSystem, io: std.Io, path: []const u8, allocator: std.mem.Allocator, limit: std.Io.Limit) ![]u8 {
        return self.readFileAllocPathFn(self.ctx, io, path, allocator, limit);
    }

    pub fn writeFilePath(self: FileSystem, io: std.Io, path: []const u8, data: []const u8) !void {
        return self.writeFilePathFn(self.ctx, io, path, data);
    }

    pub fn ensureDir(self: FileSystem, io: std.Io, path: []const u8) !void {
        return self.ensureDirFn(self.ctx, io, path);
    }

    pub fn sweepSpeechArtifacts(self: FileSystem, io: std.Io, request: SpeechArtifactSweepRequest) !SpeechArtifactSweepResult {
        return self.sweepSpeechArtifactsFn(self.ctx, io, request);
    }
};

pub const SpeechArtifactSweepRequest = struct {
    dir_path: []const u8,
    prefix: []const u8,
    audio_suffix: []const u8,
    transcription_json_suffix: []const u8,
    cutoff_ms: i64,
};

pub const SpeechArtifactSweepResult = struct {
    audio_removed: usize = 0,
    transcription_json_removed: usize = 0,
};

pub const TestFileSystem = struct {
    const max_files = 16;

    allocator: std.mem.Allocator,
    files: [max_files]File = [_]File{.{}} ** max_files,
    sweep_result: SpeechArtifactSweepResult = .{},

    const File = struct {
        path: []const u8 = "",
        data: []const u8 = "",
    };

    pub fn deinit(self: *TestFileSystem) void {
        for (&self.files) |*file| {
            if (file.path.len == 0) continue;
            self.allocator.free(file.path);
            self.allocator.free(file.data);
            file.* = .{};
        }
    }

    pub fn filesystem(self: *TestFileSystem) FileSystem {
        return .{
            .ctx = self,
            .ensureParentDirFn = ensureParentDir,
            .readFileAllocPathFn = readFileAllocPath,
            .writeFilePathFn = writeFilePath,
            .ensureDirFn = ensureDir,
            .sweepSpeechArtifactsFn = sweepSpeechArtifacts,
        };
    }

    fn find(self: *TestFileSystem, path: []const u8) ?*File {
        for (&self.files) |*file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        return null;
    }

    fn emptySlot(self: *TestFileSystem) !*File {
        for (&self.files) |*file| {
            if (file.path.len == 0) return file;
        }
        return error.TestFileSystemFull;
    }

    fn ensureParentDir(_: *anyopaque, _: std.Io, _: []const u8) !void {}

    fn readFileAllocPath(ctx: *anyopaque, _: std.Io, path: []const u8, allocator: std.mem.Allocator, _: std.Io.Limit) ![]u8 {
        const self: *TestFileSystem = @ptrCast(@alignCast(ctx));
        const file = self.find(path) orelse return error.FileNotFound;
        return allocator.dupe(u8, file.data);
    }

    fn writeFilePath(ctx: *anyopaque, _: std.Io, path: []const u8, data: []const u8) !void {
        const self: *TestFileSystem = @ptrCast(@alignCast(ctx));
        const file = self.find(path) orelse try self.emptySlot();
        if (file.path.len == 0) file.path = try self.allocator.dupe(u8, path);
        self.allocator.free(file.data);
        file.data = try self.allocator.dupe(u8, data);
    }

    fn ensureDir(_: *anyopaque, _: std.Io, _: []const u8) !void {}

    fn sweepSpeechArtifacts(ctx: *anyopaque, _: std.Io, _: SpeechArtifactSweepRequest) !SpeechArtifactSweepResult {
        const self: *TestFileSystem = @ptrCast(@alignCast(ctx));
        return self.sweep_result;
    }
};
