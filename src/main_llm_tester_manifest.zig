const std = @import("std");
const build_all = @import("harness/llm_tester/build_all.zig");
const files = @import("platform/common/files.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.skip();

    var output_path: ?[]const u8 = null;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--output")) {
            output_path = args_iter.next() orelse return error.MissingOutputPath;
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }

    const json = try build_all.manifestJson(allocator, init.io);

    if (output_path) |path| {
        try files.writeFilePath(init.io, path, json);
    } else {
        var stdout_buffer: [8192]u8 = undefined;
        var stdout_file_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        const writer = &stdout_file_writer.interface;
        try writer.writeAll(json);
        try writer.flush();
    }
}
