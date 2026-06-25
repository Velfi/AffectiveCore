const std = @import("std");

const Config = struct {
    max_lines: usize = 700,
    top_count: usize = 5,
};

const ModuleSize = struct {
    path: []const u8,
    lines: usize,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const config = try parseArgs(init.minimal.args);

    var sizes: std.ArrayList(ModuleSize) = .empty;
    defer {
        for (sizes.items) |module| allocator.free(module.path);
        sizes.deinit(allocator);
    }

    try collectZigModules(allocator, init.io, "src", &sizes);

    std.mem.sort(ModuleSize, sizes.items, {}, moduleSizeDesc);

    std.debug.print("Module size lint: max {d} lines per Zig module\n", .{config.max_lines});
    std.debug.print("Top {d} largest modules:\n", .{@min(config.top_count, sizes.items.len)});

    const displayed = @min(config.top_count, sizes.items.len);
    for (sizes.items[0..displayed], 1..) |module, rank| {
        const over_by = if (module.lines > config.max_lines) module.lines - config.max_lines else 0;
        if (over_by > 0) {
            std.debug.print("{d}. {s}: {d} lines (+{d})\n", .{ rank, module.path, module.lines, over_by });
        } else {
            std.debug.print("{d}. {s}: {d} lines\n", .{ rank, module.path, module.lines });
        }
    }

    var offender_count: usize = 0;
    for (sizes.items) |module| {
        if (module.lines > config.max_lines) offender_count += 1;
    }

    if (offender_count > 0) {
        std.debug.print("error: {d} Zig module(s) exceed {d} lines\n", .{ offender_count, config.max_lines });
        std.process.exit(1);
    }
}

fn parseArgs(args: std.process.Args) !Config {
    var config: Config = .{};

    var iterator = std.process.Args.Iterator.init(args);

    _ = iterator.next();
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--max-lines")) {
            const value = iterator.next() orelse fatalUsage("--max-lines requires a value");
            config.max_lines = try parsePositiveUsize("--max-lines", value);
        } else if (std.mem.eql(u8, arg, "--top")) {
            const value = iterator.next() orelse fatalUsage("--top requires a value");
            config.top_count = try parsePositiveUsize("--top", value);
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else {
            fatalUsage("unknown argument");
        }
    }

    return config;
}

fn parsePositiveUsize(name: []const u8, value: []const u8) !usize {
    const parsed = std.fmt.parseUnsigned(usize, value, 10) catch {
        fatalUsage(name);
    };
    if (parsed == 0) fatalUsage(name);
    return parsed;
}

fn fatalUsage(message: []const u8) noreturn {
    std.debug.print("error: {s}\n\n", .{message});
    printUsage();
    std.process.exit(2);
}

fn printUsage() void {
    std.debug.print(
        \\usage: lint-module-size [--max-lines N] [--top N]
        \\
        \\Checks Zig modules under src/ by physical line count.
        \\Defaults: --max-lines 700 --top 5
        \\
    , .{});
}

fn collectZigModules(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    sizes: *std.ArrayList(ModuleSize),
) !void {
    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
        errdefer allocator.free(full_path);

        const lines = try countLines(allocator, io, full_path);
        try sizes.append(allocator, .{
            .path = full_path,
            .lines = lines,
        });
    }
}

fn countLines(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !usize {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(100 * 1024 * 1024));
    defer allocator.free(bytes);

    var lines = std.mem.countScalar(u8, bytes, '\n');
    if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') lines += 1;
    return lines;
}

fn moduleSizeDesc(_: void, lhs: ModuleSize, rhs: ModuleSize) bool {
    if (lhs.lines == rhs.lines) return std.mem.lessThan(u8, lhs.path, rhs.path);
    return lhs.lines > rhs.lines;
}
