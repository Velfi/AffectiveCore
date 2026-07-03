const std = @import("std");
const stress = @import("harness/dispatch_deadlock_stress.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var options = stress.Options{
        .cycles = 1_000,
        .pressure_per_cycle = 24,
        .timeout_ms = 2_000,
        .exit_on_deadlock = true,
    };

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            options.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--seed")) {
            options.seed = try std.fmt.parseInt(u64, args.next() orelse return error.MissingSeed, 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--cycles")) {
            options.cycles = try std.fmt.parseInt(usize, args.next() orelse return error.MissingCycles, 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--pressure")) {
            options.pressure_per_cycle = try std.fmt.parseInt(usize, args.next() orelse return error.MissingPressure, 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--timeout-ms")) {
            options.timeout_ms = try std.fmt.parseInt(u64, args.next() orelse return error.MissingTimeout, 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--root")) {
            options.root = args.next() orelse return error.MissingRoot;
            continue;
        }
        return error.UnknownArgument;
    }

    const stats = try stress.run(allocator, options);
    std.debug.print(
        "dispatch-deadlock-stress PASS seed=0x{x} cycles={d} pressure_dispatches={d} queued_acks={d} busy_errors={d} blocking_completed={d}\n",
        .{
            options.seed,
            stats.cycles,
            stats.pressure_dispatches,
            stats.queued_acks,
            stats.runtime_busy_errors,
            stats.completed_blocking_dispatches,
        },
    );
}
