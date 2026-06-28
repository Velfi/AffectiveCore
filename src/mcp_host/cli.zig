const std = @import("std");
const session_mod = @import("session.zig");
const requests = @import("requests.zig");
const files = @import("../platform/common/files.zig");

const Options = session_mod.Options;

pub fn run(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var forwarded = std.ArrayList([]const u8).empty;
    while (args.next()) |arg| try forwarded.append(allocator, arg);
    try runWithArgs(init, forwarded.items);
}

pub fn runWithArgs(init: std.process.Init, forwarded: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (forwarded.len == 0) {
        printUsage();
        return error.MissingCommand;
    }

    var options = Options{};
    var command: ?[]const u8 = null;
    var positionals = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < forwarded.len) : (i += 1) {
        const arg = forwarded[i];
        if (std.mem.eql(u8, arg, "--brain-root")) {
            i += 1;
            if (i >= forwarded.len) return error.MissingBrainRoot;
            options.brain_root = forwarded[i];
        } else if (std.mem.eql(u8, arg, "--brain-id")) {
            i += 1;
            if (i >= forwarded.len) return error.MissingBrainId;
            options.brain_id = forwarded[i];
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            i += 1;
            if (i >= forwarded.len) return error.MissingManifestPath;
            options.manifest_path = forwarded[i];
        } else if (std.mem.eql(u8, arg, "--scenario")) {
            i += 1;
            if (i >= forwarded.len) return error.MissingScenario;
            options.scenario = forwarded[i];
        } else if (std.mem.eql(u8, arg, "--fresh")) {
            options.fresh = true;
        } else if (std.mem.eql(u8, arg, "--models")) {
            i += 1;
            if (i >= forwarded.len) return error.MissingConversationModels;
            options.conversation_models = forwarded[i];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try positionals.append(allocator, arg);
        } else if (command == null) {
            command = arg;
        } else {
            try positionals.append(allocator, arg);
        }
    }

    const cmd = command orelse {
        printUsage();
        return error.MissingCommand;
    };
    if (std.mem.eql(u8, cmd, "dispatch")) {
        try runDispatch(init.io, allocator, options, positionals.items);
        return;
    }
    if (std.mem.eql(u8, cmd, "drain")) {
        try runDrain(init.io, options);
        return;
    }
    if (std.mem.eql(u8, cmd, "setup")) {
        try runSetup(init.io, options);
        return;
    }
    if (std.mem.eql(u8, cmd, "run")) {
        try runScript(init.io, allocator, options, positionals.items);
        return;
    }
    if (std.mem.eql(u8, cmd, "connect")) {
        try runNamedDispatch(init.io, options, try requests.connect("cli-connect"), false);
        return;
    }
    if (std.mem.eql(u8, cmd, "host_attach")) {
        const host_id = flagValue(positionals.items, "--host-id") orelse "mcp-host";
        try runNamedDispatch(init.io, options, try requests.hostAttach("cli-host-attach", host_id), false);
        return;
    }
    if (std.mem.eql(u8, cmd, "user_text")) {
        const text = flagValue(positionals.items, "--text") orelse return error.MissingText;
        try runNamedDispatch(init.io, options, try requests.userText("cli-user-text", text), true);
        return;
    }
    if (std.mem.eql(u8, cmd, "short_touch")) {
        try runNamedDispatch(init.io, options, try requests.shortTouch("cli-short-touch"), true);
        return;
    }
    if (std.mem.eql(u8, cmd, "sense_observation")) {
        const image = flagValue(positionals.items, "--image") orelse return error.MissingImagePath;
        try runNamedDispatch(init.io, options, try requests.senseObservationCamera("cli-sense-observation", image), true);
        return;
    }
    if (std.mem.eql(u8, cmd, "read_models_snapshot")) {
        try runNamedDispatch(init.io, options, try requests.readModelsSnapshot("cli-read-models"), true);
        return;
    }

    printUsage();
    return error.UnknownCommand;
}

fn runNamedDispatch(io: std.Io, options: Options, request_json: []const u8, with_setup: bool) !void {
    defer std.heap.page_allocator.free(request_json);
    var session = try session_mod.Session.open(io, options);
    defer session.deinit();
    if (with_setup) try session.setupHost();
    const response = try session.dispatch(request_json);
    try writeStdout(io, response);
    try writeStdout(io, "\n");
}

fn flagValue(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return args[i + 1];
    }
    return null;
}

fn runDispatch(io: std.Io, allocator: std.mem.Allocator, options: Options, rest: []const []const u8) !void {
    const request_json = try readRequestJson(io, allocator, rest);
    var session = try session_mod.Session.open(io, options);
    defer session.deinit();
    const response = try session.dispatch(request_json);
    try writeStdout(io, response);
    try writeStdout(io, "\n");
}

fn runDrain(io: std.Io, options: Options) !void {
    var session = try session_mod.Session.open(io, options);
    defer session.deinit();
    const response = try session.drain();
    try writeStdout(io, response);
    try writeStdout(io, "\n");
}

fn runSetup(io: std.Io, options: Options) !void {
    var session = try session_mod.Session.open(io, options);
    defer session.deinit();
    try session.setupHost();
    const response = try session.dispatch(
        \\{"request_id":"mcp-host-read-models","event":{"type":"read_models_snapshot"}}
    );
    try writeStdout(io, response);
    try writeStdout(io, "\n");
}

fn runScript(io: std.Io, allocator: std.mem.Allocator, options: Options, rest: []const []const u8) !void {
    if (rest.len == 0) return error.MissingFlowPath;
    const flow_path = rest[0];
    const flow_bytes = try readPath(io, allocator, flow_path);
    var session = try session_mod.Session.open(io, options);
    defer session.deinit();

    if (std.mem.endsWith(u8, flow_path, ".json")) {
        try runJsonFlow(allocator, &session, flow_bytes);
        return;
    }
    try runJsonlFlow(allocator, &session, flow_bytes);
}

fn runJsonFlow(allocator: std.mem.Allocator, session: *session_mod.Session, flow_bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, flow_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    if (root.get("setup")) |_| {
        try session.setupHost();
    }
    const steps = root.get("steps") orelse return error.MissingFlowSteps;
    if (steps != .array) return error.InvalidFlowSteps;
    for (steps.array.items) |step| {
        try runFlowStep(session, step);
    }
}

fn runJsonlFlow(allocator: std.mem.Allocator, session: *session_mod.Session, flow_bytes: []const u8) !void {
    var lines = std.mem.splitScalar(u8, flow_bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\n\t");
        if (line.len == 0 or line[0] == '#') continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try runFlowStep(session, parsed.value);
    }
}

fn runFlowStep(session: *session_mod.Session, step: std.json.Value) !void {
    if (step == .object) {
        if (step.object.get("op")) |op| {
            if (op == .string and std.mem.eql(u8, op.string, "drain")) {
                const response = try session.drain();
                std.debug.print("--- drain ---\n{s}\n", .{response});
                return;
            }
            if (op == .string and std.mem.eql(u8, op.string, "setup")) {
                try session.setupHost();
                std.debug.print("--- setup ---\n", .{});
                return;
            }
        }
    }
    const request_json = try std.json.Stringify.valueAlloc(std.heap.page_allocator, step, .{});
    defer std.heap.page_allocator.free(request_json);
    const response = try session.dispatch(request_json);
    std.debug.print("--- dispatch ---\n{s}\n", .{response});
}

fn readRequestJson(io: std.Io, allocator: std.mem.Allocator, rest: []const []const u8) ![]const u8 {
    if (rest.len == 0) {
        return readAllStdin(io, allocator);
    }
    const path = rest[0];
    if (std.mem.eql(u8, path, "-")) {
        return readAllStdin(io, allocator);
    }
    return readPath(io, allocator, path);
}

fn readPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try files.readFileAllocPath(io, path, allocator, .limited(1024 * 1024));
}

fn readAllStdin(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    return try files.readFileAllocPath(io, "/dev/stdin", allocator, .limited(1024 * 1024));
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn printUsage() void {
    std.debug.print(
        \\mcp-host — drive the embedded brain API from the CLI
        \\
        \\Usage:
        \\  mcp-host setup [--fresh] [--brain-root PATH] [--scenario NAME]
        \\  mcp-host dispatch REQUEST.json [--brain-root PATH] [--scenario NAME]
        \\  mcp-host dispatch -   # read JSON from stdin
        \\  mcp-host drain [--brain-root PATH]
        \\  mcp-host run FLOW.json|FLOW.jsonl [--fresh] [--scenario NAME]
        \\  mcp-host connect | host_attach | user_text --text TEXT | short_touch
        \\  mcp-host sense_observation --image PATH | read_models_snapshot | drain
        \\
        \\  mcp-host --mcp [--brain-root PATH]   # stdio MCP server
        \\
        \\Shared flags:
        \\  --brain-root PATH     default: data/test/mcp_host/default
        \\  --brain-id ID         default: mcp-host
        \\  --manifest PATH       default: fixtures/embedded_api/manifest_macos.json
        \\  --models SPEC         default: openai:gpt-4.1-nano
        \\  --scenario NAME       default | resume_invalid_llm | enrollment_without_remember_person
        \\                        | upstream_rejected | scripted_recognize_resume | unknown_want_achievement
        \\  --fresh               delete brain-root before opening session
        \\
    , .{});
}
