const std = @import("std");
const embedded_ffi_fuzz = @import("harness/embedded_ffi_fuzz.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var iterations: usize = 4096;
    var seed: u64 = 0x667269656e646c79;
    var verbose = false;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--seed")) {
            const value = args.next() orelse return error.MissingSeed;
            seed = try std.fmt.parseInt(u64, value, 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--iterations")) {
            const value = args.next() orelse return error.MissingIterations;
            iterations = try std.fmt.parseInt(usize, value, 0);
            continue;
        }
        iterations = try std.fmt.parseInt(usize, arg, 0);
    }

    const stats = try embedded_ffi_fuzz.run(allocator, .{
        .iterations = iterations,
        .seed = seed,
        .verbose = verbose,
    });

    std.debug.print(
        "embedded-ffi-fuzz PASS dispatches={d} ok={d} invalid_argument={d} runtime_error={d} unexpected={d} connect_ok={d}\n",
        .{
            stats.dispatches,
            stats.ok,
            stats.invalid_argument,
            stats.runtime_error,
            stats.unexpected_status,
            stats.connect_ok,
        },
    );
}
