const std = @import("std");
const brain_container = @import("app/brain_container.zig");
const app_core = @import("app/app_core.zig");
const embedded = @import("affective_core_embedded.zig");
const embedded_protocol = @import("app/embedded_protocol.zig");
const belief_updates = @import("core/belief_updates.zig");
const mise_en_scene = @import("core/mise_en_scene.zig");
const read_models = @import("core/read_models.zig");
const schema = @import("core/port_schema.zig");
const input_mod = @import("platform/common/input.zig");

const AffectiveCoreEmbedded = embedded.AffectiveCoreEmbedded;

pub fn connect(ctx: *AffectiveCoreEmbedded) !read_models.Snapshot {
    _ = try ctx.brain.recordSimpleExperienceEvent("Host.Connected", .host, "connect");
    try appendMiseEnScene(ctx);
    return try ctx.brain.readModelsSnapshot(ctx.allocator());
}

pub fn appendMiseEnScene(ctx: *AffectiveCoreEmbedded) !void {
    const effects = ctx.host_effects orelse return error.MissingHostEffects;
    const scene = try mise_en_scene.resolve(&ctx.brain);
    defer {
        ctx.allocator().free(scene.name);
        if (scene.theme_color) |color| ctx.allocator().free(color);
    }
    try effects.appendMiseEnScene(scene.name, scene.theme_color);
}

pub fn hostAttach(ctx: *AffectiveCoreEmbedded, args: std.json.Value) !schema.HostBinding {
    const host_id = try requireString(args, "host_id");
    const binding: schema.HostBinding = .{
        .host_id = host_id,
        .platform = getString(args, "platform") orelse "",
        .app_version = getString(args, "app_version") orelse "",
        .attached_at_ms = ctx.brain.now_seconds * 1000,
        .permissions = try getStringArray(ctx.allocator(), args, "permissions"),
        .capability_ids = try getStringArray(ctx.allocator(), args, "capability_ids"),
        .provider_availability = getString(args, "provider_availability") orelse "",
        .sensor_quality = getString(args, "sensor_quality") orelse "",
        .local_policy = getString(args, "local_policy") orelse "",
    };
    try ctx.brain.deps.store.upsertHostBinding(binding);
    _ = try ctx.brain.recordSimpleExperienceEvent("Host.Attached", .host, host_id);
    return binding;
}

pub fn hostCapabilityManifest(ctx: *AffectiveCoreEmbedded, args: std.json.Value) !usize {
    const host_id = getString(args, "host_id") orelse try ctx.allocator().dupe(u8, ctx.brain.currentHostId());
    const ids = try getStringArray(ctx.allocator(), args, "capability_ids");
    try ctx.brain.recordManifestStatuses(host_id, ids);
    return ids.len;
}

pub fn sendExperienceEvent(ctx: *AffectiveCoreEmbedded, args: std.json.Value) !schema.ExperienceEvent {
    const kind = try requireString(args, "kind");
    const payload = getString(args, "payload") orelse "";
    const event: schema.ExperienceEvent = .{
        .id = getString(args, "id") orelse try std.fmt.allocPrint(ctx.allocator(), "host_evt_{d}_{s}", .{ ctx.brain.now_seconds * 1000, kind }),
        .brain_id = ctx.brain.cfg.brain_id,
        .host_id = getString(args, "host_id") orelse try ctx.allocator().dupe(u8, ctx.brain.currentHostId()),
        .timestamp_ms = getInteger(args, "timestamp_ms") orelse ctx.brain.now_seconds * 1000,
        .source = experienceEventSourceFromString(getString(args, "source") orelse "host"),
        .kind = kind,
        .payload = payload,
        .salience = getF32(args, "salience") orelse 0.40,
        .confidence = getF32(args, "confidence") orelse 0.70,
        .valence = getF32(args, "valence") orelse 0.0,
        .arousal = getF32(args, "arousal") orelse 0.0,
        .uncertainty = getF32(args, "uncertainty") orelse 0.30,
        .causal_parent_ids = try getStringArray(ctx.allocator(), args, "causal_parent_ids"),
        .retention = retentionFromString(getString(args, "retention") orelse "episode"),
        .visibility = visibilityFromString(getString(args, "visibility") orelse "internal"),
    };
    try ctx.brain.recordExperienceEvent(event);
    return event;
}

pub fn requestDreamTime(ctx: *AffectiveCoreEmbedded, prompt: ?[]const u8) !schema.MailboxItem {
    const item = try ctx.brain.requestDreamTime(prompt);
    try appendMiseEnScene(ctx);
    return item;
}

pub fn brainMode(ctx: *AffectiveCoreEmbedded) !schema.BrainMode {
    return try ctx.brain.deps.store.loadBrainMode();
}

pub fn readModelsSnapshot(ctx: *AffectiveCoreEmbedded) !read_models.Snapshot {
    return try ctx.brain.readModelsSnapshot(ctx.allocator());
}

pub fn mailboxList(ctx: *AffectiveCoreEmbedded) ![]schema.MailboxItem {
    return try ctx.brain.deps.store.loadMailboxItems(ctx.allocator());
}

pub fn mailboxMarkRead(ctx: *AffectiveCoreEmbedded, args: std.json.Value) ![]schema.MailboxItem {
    const mailbox_id = try requireString(args, "mailbox_id");
    _ = try ctx.brain.markMailboxRead(mailbox_id);
    return try ctx.brain.deps.store.loadMailboxItems(ctx.allocator());
}

pub fn capabilityStatus(ctx: *AffectiveCoreEmbedded, args: std.json.Value) !schema.CapabilityStatus {
    const status: schema.CapabilityStatus = .{
        .capability_id = try requireString(args, "capability_id"),
        .host_id = getString(args, "host_id") orelse try ctx.allocator().dupe(u8, ctx.brain.currentHostId()),
        .permission = permissionFromString(getString(args, "permission") orelse "unknown"),
        .availability = availabilityFromString(getString(args, "availability") orelse "unavailable"),
        .quality = getF32(args, "quality") orelse 0.0,
        .reliability = getF32(args, "reliability") orelse 0.0,
        .cost = getF32(args, "cost") orelse 0.0,
        .latency_ms = getU32(args, "latency_ms") orelse 0,
        .risk = getF32(args, "risk") orelse 0.0,
        .unavailable_reason = getString(args, "unavailable_reason") orelse "",
        .updated_at_ms = ctx.brain.now_seconds * 1000,
    };
    try ctx.brain.recordCapabilityStatus(status);
    return status;
}

pub fn exportBrain(ctx: *AffectiveCoreEmbedded, args: std.json.Value) !brain_container.BrainManifest {
    const path = try requireString(args, "brain_file_path");
    const manifest = try brain_container.exportBrain(ctx.allocator(), ctx.io(), ctx.brain.cfg, path);
    _ = try ctx.brain.recordSimpleExperienceEvent("Brain.Exported", .system, path);
    return manifest;
}

pub fn importBrain(ctx: *AffectiveCoreEmbedded, args: std.json.Value) !brain_container.BrainManifest {
    const path = try requireString(args, "brain_file_path");
    const inspected = if (getString(args, "brain_id") == null)
        try brain_container.inspectBrainFile(ctx.allocator(), ctx.io(), path)
    else
        null;
    const brain_id = getString(args, "brain_id") orelse inspected.?.brain_id;
    const brain_root = getString(args, "brain_root") orelse ctx.brain.cfg.brain_root;
    const manifest = try brain_container.importBrain(ctx.allocator(), ctx.io(), path, .{
        .brain_id = brain_id,
        .brain_root = brain_root,
    });
    try embedded.reloadEmbeddedBrain(ctx, manifest.brain_id, brain_root);
    const host_id = getString(args, "host_id") orelse ctx.brain.currentHostId();
    const payload = if (host_id.len > 0)
        try std.fmt.allocPrint(ctx.allocator(), "brain_id={s}; brain_root={s}; host_id={s}", .{ manifest.brain_id, brain_root, host_id })
    else
        try std.fmt.allocPrint(ctx.allocator(), "brain_id={s}; brain_root={s}", .{ manifest.brain_id, brain_root });
    _ = try ctx.brain.recordSimpleExperienceEvent("Brain.Imported", .system, payload);
    if (host_id.len > 0) _ = try ctx.brain.recordSimpleExperienceEvent("Host.BindingChangedAfterImport", .host, host_id);
    return manifest;
}

pub fn shortTouchActivation(ctx: *AffectiveCoreEmbedded) !app_core.ActionExecutionResult {
    var observations = std.ArrayList(u8).empty;
    const conversation = ctx.brain.handleFaceMemoryActivation() catch |err| {
        if (try ctx.brain.handleTouchStimulusError(err)) {
            return .{
                .action = .unknown,
                .observation = try observations.toOwnedSlice(ctx.allocator()),
                .spoken_text = null,
                .ended_with_speech = false,
                .interrupted_by = null,
            };
        }
        return err;
    };
    const spoken_text = if (conversation) |turn| turn.spoken_text else null;
    return .{
        .action = .unknown,
        .observation = try observations.toOwnedSlice(ctx.allocator()),
        .spoken_text = spoken_text,
        .ended_with_speech = spoken_text != null and spoken_text.?.len > 0,
        .interrupted_by = null,
    };
}

pub fn longTouchActivation(ctx: *AffectiveCoreEmbedded) !app_core.ActionExecutionResult {
    const conversation = try ctx.brain.handleLongTouchActivation();
    const spoken_text = if (conversation) |turn| turn.spoken_text else null;
    return .{
        .action = .unknown,
        .observation = try ctx.allocator().dupe(u8, ""),
        .spoken_text = spoken_text,
        .ended_with_speech = spoken_text != null and spoken_text.?.len > 0,
        .interrupted_by = null,
    };
}

pub fn runStimulusAutonomy(ctx: *AffectiveCoreEmbedded) !void {
    const io = ctx.brain.deps.io orelse return error.LocalDateUnavailable;
    try ctx.brain.runStimulusAutonomy(io);
}

pub fn tryTypedSpeech(ctx: *AffectiveCoreEmbedded, text: []const u8) !input_mod.HeardSpeech {
    return input_mod.HeardSpeech.typed(ctx.allocator(), text);
}

fn retentionFromString(value: []const u8) schema.ExperienceEventRetention {
    if (std.mem.eql(u8, value, "ephemeral") or std.mem.eql(u8, value, "working")) return .ephemeral;
    if (std.mem.eql(u8, value, "durable") or std.mem.eql(u8, value, "long_term")) return .durable;
    if (std.mem.eql(u8, value, "disposition")) return .disposition;
    if (std.mem.eql(u8, value, "discard")) return .discard;
    return .episode;
}

fn visibilityFromString(value: []const u8) schema.ExperienceEventVisibility {
    if (std.mem.eql(u8, value, "host") or std.mem.eql(u8, value, "public")) return .host;
    if (std.mem.eql(u8, value, "developer") or std.mem.eql(u8, value, "diagnostic")) return .developer;
    if (std.mem.eql(u8, value, "private")) return .private;
    return .internal;
}

fn experienceEventSourceFromString(value: []const u8) schema.ExperienceEventSource {
    if (std.mem.eql(u8, value, "user")) return .user;
    if (std.mem.eql(u8, value, "sense")) return .sense;
    if (std.mem.eql(u8, value, "subsystem")) return .subsystem;
    if (std.mem.eql(u8, value, "capability")) return .capability;
    if (std.mem.eql(u8, value, "memory")) return .memory;
    if (std.mem.eql(u8, value, "autonomy")) return .autonomy;
    if (std.mem.eql(u8, value, "dream_time")) return .dream_time;
    if (std.mem.eql(u8, value, "system")) return .system;
    return .host;
}

pub fn permissionFromString(value: []const u8) schema.CapabilityPermission {
    if (std.mem.eql(u8, value, "granted")) return .granted;
    if (std.mem.eql(u8, value, "denied")) return .denied;
    if (std.mem.eql(u8, value, "prompt_required")) return .prompt_required;
    if (std.mem.eql(u8, value, "not_required")) return .not_required;
    return .unknown;
}

pub fn availabilityFromString(value: []const u8) schema.CapabilityAvailability {
    if (std.mem.eql(u8, value, "available")) return .available;
    if (std.mem.eql(u8, value, "degraded")) return .degraded;
    if (std.mem.eql(u8, value, "refused")) return .refused;
    if (std.mem.eql(u8, value, "pending")) return .degraded;
    return .unavailable;
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

fn getInteger(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        else => null,
    };
}

fn getF32(args: std.json.Value, key: []const u8) ?f32 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| @floatCast(n),
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

fn getStringArray(allocator: std.mem.Allocator, args: std.json.Value, key: []const u8) ![][]const u8 {
    if (args != .object) return @constCast(&.{});
    const value = args.object.get(key) orelse return @constCast(&.{});
    if (value != .array) return error.ExpectedStringArray;
    const out = try allocator.alloc([]const u8, value.array.items.len);
    for (value.array.items, 0..) |item, i| {
        if (item != .string) return error.ExpectedStringArray;
        out[i] = item.string;
    }
    return out;
}
