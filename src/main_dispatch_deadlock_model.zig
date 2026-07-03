const std = @import("std");
const model = @import("harness/dispatch_deadlock_model.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var options = model.Options{};

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            options.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-depth")) {
            options.max_depth = try std.fmt.parseInt(usize, args.next() orelse return error.MissingMaxDepth, 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-queue")) {
            options.max_queue = try std.fmt.parseInt(u8, args.next() orelse return error.MissingMaxQueue, 0);
            continue;
        }
        return error.UnknownArgument;
    }

    const stats = try model.verify(allocator, options);
    std.debug.print(
        "dispatch-deadlock-model PASS max_depth={d} max_queue={d} states={d} transitions={d}\n",
        .{ options.max_depth, options.max_queue, stats.states_visited, stats.transitions_checked },
    );
}
