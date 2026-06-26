const std = @import("std");
const chat = @import("api/chat_client.zig");
const skills = @import("core/port_skills.zig");
const brain_container = @import("app/brain_container.zig");
const app_core = @import("app/app_core.zig");
const context_gate = @import("app/context_gate.zig");
const embedded_protocol = @import("app/embedded_protocol.zig");
const files = @import("platform/common/files.zig");
const input_mod = @import("platform/common/input.zig");
const embedded = @import("affective_core_embedded.zig");

const AffectiveCoreEmbedded = embedded.AffectiveCoreEmbedded;

pub fn dispatchTool(ctx: *AffectiveCoreEmbedded, name: []const u8, args: std.json.Value) ![]u8 {
    if (std.mem.eql(u8, name, "conversation_turn")) {
        const result = app_core.conversationResult(try ctx.brain.handleConversationText(try tryTypedSpeech(ctx, try requireString(args, "text"))));
        return std.json.Stringify.valueAlloc(std.heap.page_allocator, result, .{ .whitespace = .indent_2 });
    }
    if (std.mem.eql(u8, name, "short_touch") or std.mem.eql(u8, name, "button_short_touch")) {
        const result = try shortTouchActivation(ctx);
        return std.json.Stringify.valueAlloc(std.heap.page_allocator, result, .{ .whitespace = .indent_2 });
    }
    if (std.mem.eql(u8, name, "long_touch") or std.mem.eql(u8, name, "button_long_touch")) {
        const result = try longTouchActivation(ctx);
        return std.json.Stringify.valueAlloc(std.heap.page_allocator, result, .{ .whitespace = .indent_2 });
    }
    if (std.mem.eql(u8, name, "brain_inspect")) {
        const info = try brain_container.inspectBrain(std.heap.page_allocator, ctx.io(), ctx.brain.cfg);
        return std.json.Stringify.valueAlloc(std.heap.page_allocator, info, .{ .whitespace = .indent_2 });
    }
    if (std.mem.eql(u8, name, "introspect") or std.mem.eql(u8, name, "inner_state")) {
        return try executeCommand(ctx, .{ .command = .introspect });
    }
    if (std.mem.eql(u8, name, "request_orientation")) {
        return try executeCommand(ctx, .{ .command = .request_orientation });
    }
    if (std.mem.eql(u8, name, "memory_index")) return try memoryIndex(ctx);
    if (std.mem.eql(u8, name, "remember_memory")) {
        return try executeCommand(ctx, .{
            .command = .remember_memory,
            .text = try requireString(args, "text"),
            .tags = try getStringArray(ctx.allocator(), args, "tags"),
        });
    }
    if (std.mem.eql(u8, name, "recall_memory")) {
        return try executeCommand(ctx, .{
            .command = .recall_memory,
            .query = getString(args, "query") orelse "",
            .tags = try getStringArray(ctx.allocator(), args, "tags"),
        });
    }
    if (std.mem.eql(u8, name, "choose_attention")) return try executeCommand(ctx, .{ .command = .choose_attention });
    if (std.mem.eql(u8, name, "consolidate_memory")) return try executeCommand(ctx, .{ .command = .consolidate_memory });
    if (std.mem.eql(u8, name, "dream")) {
        return try executeCommand(ctx, .{
            .command = .dream,
            .text = getString(args, "text"),
            .tags = try getStringArray(ctx.allocator(), args, "tags"),
            .heat_bias = getString(args, "heat_bias"),
        });
    }
    if (std.mem.eql(u8, name, "set_reminder")) {
        return try executeCommand(ctx, .{
            .command = .set_reminder,
            .schedule = try requireString(args, "schedule"),
            .text = try requireString(args, "text"),
        });
    }
    if (std.mem.eql(u8, name, "list_reminders")) return try listReminders(ctx);
    if (std.mem.eql(u8, name, "developer_tools")) return try developerTools(ctx);
    if (skillCommandFromToolCall(ctx, name, args)) |command| {
        return try executeCommand(ctx, command);
    }
    return error.UnknownEmbeddedTool;
}

const DeveloperTool = struct {
    id: []const u8,
    title: []const u8,
    tool_name: []const u8,
    symbol_name: []const u8,
    mirror_to_chat: bool = false,
    requires_camera: bool = false,
};

pub fn developerTools(ctx: *AffectiveCoreEmbedded) ![]u8 {
    var tools = std.ArrayList(DeveloperTool).empty;
    for (skills.registry) |entry| {
        const title = entry.developer_title orelse continue;
        try tools.append(ctx.allocator(), .{
            .id = entry.name,
            .title = title,
            .tool_name = entry.name,
            .symbol_name = entry.developer_symbol_name orelse "hammer",
            .mirror_to_chat = entry.developer_mirror_to_chat,
            .requires_camera = entry.developer_requires_camera,
        });
    }
    return std.json.Stringify.valueAlloc(std.heap.page_allocator, struct { tools: []const DeveloperTool }{ .tools = tools.items }, .{ .whitespace = .indent_2 });
}

fn skillCommandFromToolCall(ctx: *AffectiveCoreEmbedded, name: []const u8, args: std.json.Value) ?chat.ChatCommand {
    const id = skillIdFromName(name) orelse return null;
    return .{
        .command = id,
        .text = getString(args, "text"),
        .query = getString(args, "query"),
        .memory_id = getString(args, "memory_id"),
        .person_id = getString(args, "person_id"),
        .name = getString(args, "name"),
        .image_path = getString(args, "image_path"),
        .schedule = getString(args, "schedule"),
        .to = getString(args, "to"),
        .subject = getString(args, "subject"),
        .heat_bias = getString(args, "heat_bias"),
        .eyes = getString(args, "eyes"),
        .mouth = getString(args, "mouth"),
        .duration_ms = getU32(args, "duration_ms"),
        .keep_existing = getBool(args, "keep_existing") orelse false,
        .tags = getStringArray(ctx.allocator(), args, "tags") catch &.{},
    };
}

fn skillIdFromName(name: []const u8) ?skills.SkillId {
    inline for (@typeInfo(skills.SkillId).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @field(skills.SkillId, field.name);
    }
    return null;
}

pub fn shortTouchActivation(ctx: *AffectiveCoreEmbedded) !app_core.CommandResult {
    var observations = std.ArrayList(u8).empty;
    ctx.brain.handleFaceMemoryActivation() catch |err| {
        if (try ctx.brain.handleTouchStimulusError(err)) {
            return .{
                .command = .unknown,
                .observation = try observations.toOwnedSlice(ctx.allocator()),
                .spoken_text = null,
                .ended_with_speech = false,
                .interrupted_by = null,
            };
        }
        return err;
    };
    return .{
        .command = .unknown,
        .observation = try observations.toOwnedSlice(ctx.allocator()),
        .spoken_text = null,
        .ended_with_speech = false,
        .interrupted_by = null,
    };
}

pub fn longTouchActivation(ctx: *AffectiveCoreEmbedded) !app_core.CommandResult {
    try ctx.brain.handleLongTouchActivation();
    return .{
        .command = .unknown,
        .observation = try ctx.allocator().dupe(u8, ""),
        .spoken_text = null,
        .ended_with_speech = false,
        .interrupted_by = null,
    };
}

pub fn runStimulusAutonomy(ctx: *AffectiveCoreEmbedded) !void {
    const io = ctx.brain.deps.io orelse return error.LocalDateUnavailable;
    try ctx.brain.runStimulusAutonomy(io);
}

pub fn dispatchJson(ctx: *AffectiveCoreEmbedded, request_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, request_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) {
        return embedded_protocol.legacyErrorEnvelopeAlloc(std.heap.page_allocator, "", "invalid_request", "dispatch request must be a JSON object", false);
    }
    const root = parsed.value.object;
    const request_id = getStringFromObject(root, "request_id") orelse "";
    const event = root.get("event") orelse {
        return embedded_protocol.legacyErrorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing event", false);
    };
    if (event != .object) {
        return embedded_protocol.legacyErrorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "event must be a JSON object", false);
    }
    const event_object = event.object;
    const event_type = getStringFromObject(event_object, "type") orelse {
        return embedded_protocol.legacyErrorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing event.type", false);
    };

    embedded.clearHostEffects(ctx);
    const output = if (std.mem.eql(u8, event_type, "speech_transcript") or std.mem.eql(u8, event_type, "typed_text")) blk: {
        const text = getStringFromObject(event_object, "text") orelse "";
        const result = app_core.conversationResult(ctx.brain.handleConversationText(try tryTypedSpeech(ctx, text)) catch |err| switch (err) {
            error.FrontendCaptureRequested => break :blk try encodeDispatchResult(ctx, request_id, event_type, .{
                .kind = "sense_request",
                .message = "",
            }),
            else => return err,
        });
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{ .kind = "conversation_turn", .conversation_turn = result });
    } else if (std.mem.eql(u8, event_type, "short_touch")) blk: {
        const result = try shortTouchActivation(ctx);
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{ .kind = "activation", .activation = "short_touch", .command_result = result });
    } else if (std.mem.eql(u8, event_type, "long_touch")) blk: {
        const result = try longTouchActivation(ctx);
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{ .kind = "activation", .activation = "long_touch", .command_result = result });
    } else if (std.mem.eql(u8, event_type, "poke_sequence")) blk: {
        const pulse_summary = try pokeSequencePulseSummary(ctx.allocator(), event_object);
        _ = try ctx.brain.observeSenseStimulus(.{
            .kind = .poke_sequence,
            .source = "affective_core_embedded",
            .signature = pulse_summary,
            .raw_magnitude = pokeSequenceMagnitude(event_object),
            .threat = 0,
            .curiosity = 0.40,
            .metadata = pulse_summary,
        });
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{
            .kind = "stimulus",
            .stimulus = "poke_sequence",
            .conversation_turn = .{
                .user_text = "",
                .spoken_text = "Poke received.",
                .user_summary = pulse_summary,
                .brain_summary = "Acknowledged a local poke stimulus without calling a provider.",
                .interrupted_by = null,
            },
        });
    } else if (std.mem.eql(u8, event_type, "tool_call")) blk: {
        const name = getStringFromObject(event_object, "name") orelse {
            return embedded_protocol.legacyErrorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing tool_call name", false);
        };
        var empty_args = try std.json.ObjectMap.init(std.heap.page_allocator, &.{}, &.{});
        defer empty_args.deinit(std.heap.page_allocator);
        const empty_args_value = std.json.Value{ .object = empty_args };
        const args = event_object.get("arguments") orelse empty_args_value;
        const tool_output = dispatchTool(ctx, name, args) catch |err| switch (err) {
            error.FrontendCaptureRequested => break :blk try encodeDispatchResult(ctx, request_id, event_type, .{
                .kind = "sense_request",
                .tool_name = name,
                .message = "",
            }),
            else => return err,
        };
        defer std.heap.page_allocator.free(tool_output);
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{ .kind = "tool_call", .tool_name = name, .output_json = tool_output });
    } else if (std.mem.eql(u8, event_type, "maintenance_tick")) blk: {
        try ctx.brain.runMaintenance(ctx.io());
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{ .kind = "maintenance_tick" });
    } else if (std.mem.eql(u8, event_type, "autonomy_tick")) blk: {
        try ctx.brain.runAutonomyTick(ctx.io());
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{ .kind = "autonomy_tick" });
    } else {
        return embedded_protocol.legacyErrorEnvelopeAlloc(std.heap.page_allocator, request_id, "unknown_event_type", "unknown embedded event type", false);
    };
    return output;
}

pub fn encodeDispatchResult(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8, result: anytype) ![]u8 {
    const events = embedded.hostEvents(ctx);
    const correlated_events = try correlateEvents(ctx, request_id, events);
    try appendQueuedEvents(ctx, correlated_events);
    return embedded_protocol.legacySuccessEnvelopeAlloc(std.heap.page_allocator, request_id, correlated_events, .{
        .event_type = event_type,
        .value = result,
    });
}

fn pokeSequencePulseSummary(allocator: std.mem.Allocator, event_object: std.json.ObjectMap) ![]const u8 {
    const pulses = event_object.get("pulses") orelse {
        return try allocator.dupe(u8, "poke_sequence pulse_count=0");
    };
    if (pulses != .array) {
        return try allocator.dupe(u8, "poke_sequence pulse_count=0");
    }

    var pulse_count: usize = 0;
    var total_press_ms: f64 = 0;
    var total_pause_ms: f64 = 0;
    var max_press_ms: f64 = 0;
    for (pulses.array.items) |pulse| {
        if (pulse != .object) continue;
        const press_ms = getNumberFromObject(pulse.object, "press_ms") orelse 0;
        const pause_before_ms = getNumberFromObject(pulse.object, "pause_before_ms") orelse 0;
        pulse_count += 1;
        total_press_ms += press_ms;
        total_pause_ms += pause_before_ms;
        max_press_ms = @max(max_press_ms, press_ms);
    }
    return try std.fmt.allocPrint(
        allocator,
        "poke_sequence pulse_count={d} total_press_ms={d:.0} total_pause_before_ms={d:.0} max_press_ms={d:.0}",
        .{ pulse_count, total_press_ms, total_pause_ms, max_press_ms },
    );
}

fn pokeSequenceMagnitude(event_object: std.json.ObjectMap) f32 {
    const pulses = event_object.get("pulses") orelse return 0.20;
    if (pulses != .array) return 0.20;
    var total_press_ms: f64 = 0;
    var max_press_ms: f64 = 0;
    for (pulses.array.items) |pulse| {
        if (pulse != .object) continue;
        const press_ms = getNumberFromObject(pulse.object, "press_ms") orelse 0;
        total_press_ms += press_ms;
        max_press_ms = @max(max_press_ms, press_ms);
    }
    return @floatCast(@min(1.0, 0.20 + total_press_ms / 2400.0 + max_press_ms / 1800.0));
}

fn appendQueuedEvents(ctx: *AffectiveCoreEmbedded, events: []const embedded_protocol.HostEvent) !void {
    for (events) |event| try ctx.event_queue.append(ctx.allocator(), event);
}

fn correlateEvents(ctx: *AffectiveCoreEmbedded, request_id: []const u8, events: []const embedded_protocol.HostEvent) ![]embedded_protocol.HostEvent {
    const out = try ctx.allocator().alloc(embedded_protocol.HostEvent, events.len);
    for (events, 0..) |event, i| {
        out[i] = event;
        out[i].request_id = if (request_id.len == 0) null else try ctx.allocator().dupe(u8, request_id);
    }
    return out;
}

pub fn tryTypedSpeech(ctx: *AffectiveCoreEmbedded, text: []const u8) !input_mod.HeardSpeech {
    return input_mod.HeardSpeech.typed(ctx.allocator(), text);
}

pub fn executeCommand(ctx: *AffectiveCoreEmbedded, command: chat.ChatCommand) ![]u8 {
    const result = try app_core.executeBrainCommand(ctx.allocator(), &ctx.brain, command);
    return std.json.Stringify.valueAlloc(std.heap.page_allocator, result, .{ .whitespace = .indent_2 });
}

pub fn memoryIndex(ctx: *AffectiveCoreEmbedded) ![]u8 {
    const allocator = ctx.allocator();
    const memories = try ctx.brain.deps.store.loadMemoryRecords(allocator);
    const summaries = try ctx.brain.deps.store.loadConversationSummaries(allocator);
    var long_term: usize = 0;
    var short_term: usize = 0;
    var tags = std.ArrayList([]const u8).empty;
    for (memories) |memory| {
        switch (memory.scope) {
            .long_term => long_term += 1,
            .short_term => short_term += 1,
        }
        for (memory.tags) |tag| {
            if (tags.items.len >= 32) break;
            if (!tagInSlice(tags.items, tag)) try tags.append(allocator, tag);
        }
    }
    return std.json.Stringify.valueAlloc(std.heap.page_allocator, struct {
        long_term: usize,
        short_term: usize,
        tags: []const []const u8,
        conversation_summaries: usize,
    }{
        .long_term = long_term,
        .short_term = short_term,
        .tags = tags.items,
        .conversation_summaries = summaries.len,
    }, .{ .whitespace = .indent_2 });
}

pub fn listReminders(ctx: *AffectiveCoreEmbedded) ![]u8 {
    const markdown = readFileAllocPath(ctx.io(), ctx.brain.cfg.maintenance_schedule_path, ctx.allocator(), .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    return std.json.Stringify.valueAlloc(std.heap.page_allocator, struct { markdown: []const u8 }{ .markdown = markdown }, .{ .whitespace = .indent_2 });
}

fn requireString(args: std.json.Value, key: []const u8) ![]const u8 {
    return getString(args, key) orelse error.MissingRequiredString;
}

fn getString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getBool(args: std.json.Value, key: []const u8) ?bool {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn getU32(args: std.json.Value, key: []const u8) ?u32 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    const integer = switch (value) {
        .integer => |n| n,
        else => return null,
    };
    if (integer < 0 or integer > std.math.maxInt(u32)) return null;
    return @intCast(integer);
}

fn getStringFromObject(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getIntegerFromObject(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

fn getNumberFromObject(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => null,
    };
}

fn getStringArray(allocator: std.mem.Allocator, args: std.json.Value, key: []const u8) ![]const []const u8 {
    if (args != .object) return &.{};
    const value = args.object.get(key) orelse return &.{};
    if (value != .array) return error.ExpectedStringArray;
    const out = try allocator.alloc([]const u8, value.array.items.len);
    for (value.array.items, 0..) |item, i| {
        if (item != .string) return error.ExpectedStringArray;
        out[i] = item.string;
    }
    return out;
}

fn tagInSlice(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

pub fn readFileAllocPath(io: std.Io, path: []const u8, allocator: std.mem.Allocator, limit: std.Io.Limit) ![]u8 {
    return files.readFileAllocPath(io, path, allocator, limit);
}

pub fn writeFilePath(io: std.Io, path: []const u8, data: []const u8) !void {
    return files.writeFilePath(io, path, data);
}
