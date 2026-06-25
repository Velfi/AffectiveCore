const std = @import("std");

pub const CommandError = error{
    CommandFailed,
};

pub fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    return runCommandWithLogging(allocator, io, argv, true);
}

pub fn runOptionalCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    return runCommandWithLogging(allocator, io, argv, false);
}

fn runCommandWithLogging(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, log_errors: bool) !void {
    const effective_argv = try argvWithCurlDeadline(allocator, argv);
    defer freeEffectiveArgv(allocator, effective_argv, argv);
    logProcessStart(effective_argv, .limited(16 * 1024), .limited(16 * 1024));
    const started_ms = processStartedMs(io);
    const result = std.process.run(allocator, io, .{
        .argv = effective_argv,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => {
            logProcessSpawnError(io, started_ms, effective_argv, err);
            if (log_errors) std.debug.print("Command not found: {s}\n", .{effective_argv[0]});
            return err;
        },
        else => {
            logProcessSpawnError(io, started_ms, effective_argv, err);
            return err;
        },
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) {
            logProcessEnd(io, started_ms, effective_argv, result.term, result.stdout.len, result.stderr.len);
            return;
        },
        else => {},
    }

    logProcessEnd(io, started_ms, effective_argv, result.term, result.stdout.len, result.stderr.len);

    if (log_errors) {
        if (result.stderr.len > 0) {
            std.debug.print("Command failed: {s}\n{s}\n", .{ effective_argv[0], result.stderr });
        } else {
            std.debug.print("Command failed: {s}\n", .{effective_argv[0]});
        }
    }
    return CommandError.CommandFailed;
}

pub fn runCapture(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    return runCaptureLimited(allocator, io, argv, .limited(64 * 1024));
}

pub fn runCaptureLarge(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    return runCaptureLimited(allocator, io, argv, .limited(1024 * 1024));
}

fn runCaptureLimited(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, stdout_limit: std.Io.Limit) ![]u8 {
    const effective_argv = try argvWithCurlDeadline(allocator, argv);
    defer freeEffectiveArgv(allocator, effective_argv, argv);
    logProcessStart(effective_argv, stdout_limit, .limited(16 * 1024));
    const started_ms = processStartedMs(io);
    const result = std.process.run(allocator, io, .{
        .argv = effective_argv,
        .stdout_limit = stdout_limit,
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => {
            logProcessSpawnError(io, started_ms, effective_argv, err);
            std.debug.print("Command not found: {s}\n", .{effective_argv[0]});
            return err;
        },
        else => {
            logProcessSpawnError(io, started_ms, effective_argv, err);
            return err;
        },
    };
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) {
            logProcessEnd(io, started_ms, effective_argv, result.term, result.stdout.len, result.stderr.len);
            return result.stdout;
        },
        else => {},
    }

    logProcessEnd(io, started_ms, effective_argv, result.term, result.stdout.len, result.stderr.len);

    defer allocator.free(result.stdout);
    if (result.stderr.len > 0) {
        std.debug.print("Command failed: {s}\n{s}\n", .{ effective_argv[0], result.stderr });
    } else {
        std.debug.print("Command failed: {s}\n", .{effective_argv[0]});
    }
    return CommandError.CommandFailed;
}

const curl_connect_timeout_seconds = "5";
const curl_max_time_seconds = "25";

fn argvWithCurlDeadline(allocator: std.mem.Allocator, argv: []const []const u8) ![]const []const u8 {
    if (argv.len == 0 or !std.mem.eql(u8, argv[0], "curl")) return argv;
    if (curlHasDeadline(argv)) return argv;

    var out = try std.ArrayList([]const u8).initCapacity(allocator, argv.len + 4);
    try out.append(allocator, argv[0]);
    try out.appendSlice(allocator, &.{
        "--connect-timeout",
        curl_connect_timeout_seconds,
        "--max-time",
        curl_max_time_seconds,
    });
    try out.appendSlice(allocator, argv[1..]);
    return out.toOwnedSlice(allocator);
}

fn freeEffectiveArgv(allocator: std.mem.Allocator, effective_argv: []const []const u8, original_argv: []const []const u8) void {
    if (effective_argv.ptr != original_argv.ptr) allocator.free(effective_argv);
}

fn curlHasDeadline(argv: []const []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--max-time") or std.mem.eql(u8, arg, "-m")) return true;
    }
    return false;
}

fn processStartedMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

fn logProcessStart(argv: []const []const u8, stdout_limit: std.Io.Limit, stderr_limit: std.Io.Limit) void {
    std.debug.print("PROCESS start ", .{});
    printProcessContext(argv);
    std.debug.print(" stdout_limit={d} stderr_limit={d}\n", .{ limitBytes(stdout_limit), limitBytes(stderr_limit) });
}

fn printProcessContext(argv: []const []const u8) void {
    std.debug.print("cmd={s}", .{if (argv.len > 0) argv[0] else "<empty>"});
    if (firstUrlArg(argv)) |url| std.debug.print(" url={s}", .{redactedUrl(url)});
    if (firstOutputArg(argv)) |path| std.debug.print(" output={s}", .{path});
    std.debug.print(" argc={d} argv_bytes={d} payload_bytes={d} max_arg_bytes={d}", .{ argv.len, argvBytes(argv), payloadBytes(argv), maxArgBytes(argv) });
}

fn logProcessSpawnError(io: std.Io, started_ms: i64, argv: []const []const u8, err: anyerror) void {
    const elapsed_ms = std.Io.Clock.awake.now(io).toMilliseconds() - started_ms;
    std.debug.print("PROCESS spawn_error ", .{});
    printProcessContext(argv);
    std.debug.print(" elapsed_ms={d} error={s}\n", .{ elapsed_ms, @errorName(err) });
}

fn logProcessEnd(io: std.Io, started_ms: i64, argv: []const []const u8, term: std.process.Child.Term, stdout_len: usize, stderr_len: usize) void {
    const elapsed_ms = std.Io.Clock.awake.now(io).toMilliseconds() - started_ms;
    std.debug.print("PROCESS ", .{});
    printProcessContext(argv);
    std.debug.print(" elapsed_ms={d} term=", .{elapsed_ms});
    switch (term) {
        .exited => |code| std.debug.print("exited:{d}", .{code}),
        .signal => |signal| std.debug.print("signal:{d}", .{signal}),
        .stopped => |signal| std.debug.print("stopped:{d}", .{signal}),
        .unknown => |code| std.debug.print("unknown:{d}", .{code}),
    }
    std.debug.print(" stdout_bytes={d} stderr_bytes={d}\n", .{ stdout_len, stderr_len });
}

fn limitBytes(limit: std.Io.Limit) usize {
    return switch (limit) {
        .unlimited => 0,
        else => @intFromEnum(limit),
    };
}

fn argvBytes(argv: []const []const u8) usize {
    var total: usize = 0;
    for (argv) |arg| total += arg.len;
    return total;
}

fn payloadBytes(argv: []const []const u8) usize {
    var total: usize = 0;
    for (argv, 0..) |arg, i| {
        if ((std.mem.eql(u8, arg, "-d") or
            std.mem.eql(u8, arg, "--data") or
            std.mem.eql(u8, arg, "--data-raw") or
            std.mem.eql(u8, arg, "--data-binary")) and
            i + 1 < argv.len)
        {
            total += argv[i + 1].len;
        }
    }
    return total;
}

fn maxArgBytes(argv: []const []const u8) usize {
    var max: usize = 0;
    for (argv) |arg| max = @max(max, arg.len);
    return max;
}

fn firstUrlArg(argv: []const []const u8) ?[]const u8 {
    for (argv) |arg| {
        if (std.mem.startsWith(u8, arg, "http://") or std.mem.startsWith(u8, arg, "https://")) return arg;
    }
    return null;
}

fn redactedUrl(url: []const u8) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, url, '?') orelse return url;
    const query = url[query_start + 1 ..];
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        const key_end = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        if (isSensitiveQueryKey(part[0..key_end])) return url[0..query_start];
    }
    return url;
}

fn isSensitiveQueryKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "key") or
        std.ascii.eqlIgnoreCase(key, "api_key") or
        std.ascii.eqlIgnoreCase(key, "apikey") or
        std.ascii.eqlIgnoreCase(key, "access_token") or
        std.ascii.eqlIgnoreCase(key, "token");
}

fn firstOutputArg(argv: []const []const u8) ?[]const u8 {
    for (argv, 0..) |arg, i| {
        if ((std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) and i + 1 < argv.len) return argv[i + 1];
    }
    return null;
}

test "curl argv gets a connect and total deadline" {
    const argv: []const []const u8 = &.{ "curl", "-sS", "https://example.invalid" };
    const effective = try argvWithCurlDeadline(std.testing.allocator, argv);
    defer freeEffectiveArgv(std.testing.allocator, effective, argv);

    try std.testing.expectEqualStrings("curl", effective[0]);
    try std.testing.expectEqualStrings("--connect-timeout", effective[1]);
    try std.testing.expectEqualStrings(curl_connect_timeout_seconds, effective[2]);
    try std.testing.expectEqualStrings("--max-time", effective[3]);
    try std.testing.expectEqualStrings(curl_max_time_seconds, effective[4]);
    try std.testing.expectEqualStrings("-sS", effective[5]);
}

test "curl argv keeps explicit max time" {
    const argv: []const []const u8 = &.{ "curl", "-m", "2", "https://example.invalid" };
    const effective = try argvWithCurlDeadline(std.testing.allocator, argv);
    defer freeEffectiveArgv(std.testing.allocator, effective, argv);

    try std.testing.expectEqual(@intFromPtr(argv.ptr), @intFromPtr(effective.ptr));
}

test "process start log redacts sensitive URL query keys" {
    try std.testing.expectEqualStrings(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini:generateContent",
        redactedUrl("https://generativelanguage.googleapis.com/v1beta/models/gemini:generateContent?key=secret"),
    );
    try std.testing.expectEqualStrings(
        "https://example.com/path?mode=health",
        redactedUrl("https://example.com/path?mode=health"),
    );
    try std.testing.expectEqualStrings(
        "https://example.com/path",
        redactedUrl("https://example.com/path?mode=health&access_token=secret"),
    );
}
