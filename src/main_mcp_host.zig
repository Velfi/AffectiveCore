const std = @import("std");
const mcp_host = @import("mcp_host/mod.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var mcp_mode = false;
    var forwarded = std.ArrayList([]const u8).empty;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--mcp")) {
            mcp_mode = true;
        } else {
            try forwarded.append(allocator, arg);
        }
    }

    if (mcp_mode) {
        var options = mcp_host.session.Options{};
        var idx: usize = 0;
        while (idx < forwarded.items.len) : (idx += 1) {
            const arg = forwarded.items[idx];
            if (std.mem.eql(u8, arg, "--brain-root")) {
                idx += 1;
                options.brain_root = forwarded.items[idx];
            } else if (std.mem.eql(u8, arg, "--brain-id")) {
                idx += 1;
                options.brain_id = forwarded.items[idx];
            } else if (std.mem.eql(u8, arg, "--manifest")) {
                idx += 1;
                options.manifest_path = forwarded.items[idx];
            } else if (std.mem.eql(u8, arg, "--scenario")) {
                idx += 1;
                options.scenario = forwarded.items[idx];
            } else if (std.mem.eql(u8, arg, "--fresh")) {
                options.fresh = true;
            } else if (std.mem.eql(u8, arg, "--models")) {
                idx += 1;
                options.conversation_models = forwarded.items[idx];
            } else {
                std.debug.print("Unknown MCP flag: {s}\n", .{arg});
                return error.UnknownArgument;
            }
        }
        var session = try mcp_host.session.Session.open(init.io, options);
        defer session.deinit();
        try session.setupHost();
        try mcp_host.mcp_server.run(init, &session);
        return;
    }

    try mcp_host.cli.runWithArgs(init, forwarded.items);
}
