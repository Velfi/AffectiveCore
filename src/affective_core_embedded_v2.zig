const std = @import("std");
const chat = @import("api/chat_client.zig");
const app_core = @import("app/app_core.zig");
const context_gate = @import("app/context_gate.zig");
const embedded_protocol = @import("app/embedded_protocol.zig");
const files = @import("platform/common/files.zig");
const embedded = @import("affective_core_embedded.zig");

const AffectiveCoreEmbedded = embedded.AffectiveCoreEmbedded;

pub fn emptyBudget(ctx: *AffectiveCoreEmbedded) context_gate.BudgetReport {
    return .{
        .max_bytes = ctx.context_budget.max_envelope_bytes,
        .used_bytes = 0,
        .compacted = false,
        .dropped_event_count = 0,
        .raw_refs = &.{},
    };
}

pub fn dispatchJson(ctx: *AffectiveCoreEmbedded, request_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, request_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) {
        return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, "", "invalid_request", "dispatch request must be a JSON object", false, emptyBudget(ctx));
    }
    const root = parsed.value.object;
    const request_id = getStringFromObject(root, "request_id") orelse "";
    const event = root.get("event") orelse {
        return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing event", false, emptyBudget(ctx));
    };
    if (event != .object) {
        return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "event must be a JSON object", false, emptyBudget(ctx));
    }
    const event_object = event.object;
    const event_type = getStringFromObject(event_object, "type") orelse {
        return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing event.type", false, emptyBudget(ctx));
    };

    embedded.clearHostEffects(ctx);
    if (std.mem.eql(u8, event_type, "speech_transcript") or std.mem.eql(u8, event_type, "typed_text")) {
        const text = getStringFromObject(event_object, "text") orelse "";
        const result = app_core.conversationResult(ctx.brain.handleConversationText(try embedded.tryTypedSpeech(ctx, text)) catch |err| {
            if (err == error.FrontendCaptureRequested) {
                return try encodeDispatchResult(ctx, request_id, event_type, "", false);
            }
            if (err == error.FrontendOrientationRequested) {
                return try encodeDispatchResult(ctx, request_id, event_type, "", false);
            }
            const message = embedded.hostHttpFailureMessage(ctx, "conversation_turn failed", err) orelse @errorName(err);
            return try encodeErrorResult(ctx, request_id, event_type, "conversation_turn_failed", message);
        });
        const result_json = try std.json.Stringify.valueAlloc(ctx.allocator(), result, .{ .whitespace = .indent_2 });
        return try encodeDispatchResult(ctx, request_id, event_type, result_json, true);
    }
    if (std.mem.eql(u8, event_type, "interrupt")) {
        const text = getStringFromObject(event_object, "text") orelse "";
        const reason = getStringFromObject(event_object, "reason") orelse "user_interrupt";
        const interrupted_action = getStringFromObject(event_object, "interrupted_action") orelse "unknown";
        const canceled_count = getIntegerFromObject(event_object, "canceled_queued_action_count") orelse 0;
        const metadata = try std.fmt.allocPrint(ctx.allocator(), "reason={s} interrupted_action={s} canceled_queued_action_count={d} text={s}", .{
            reason,
            interrupted_action,
            canceled_count,
            text,
        });
        _ = try ctx.brain.observeSenseStimulus(.{
            .kind = .interrupt,
            .source = "affective_host",
            .signature = reason,
            .raw_magnitude = 0.70,
            .threat = 0,
            .curiosity = 0.35,
            .metadata = metadata,
        });
        const result_text = try std.fmt.allocPrint(ctx.allocator(), "interrupt: {s}", .{metadata});
        return try encodeDispatchResult(ctx, request_id, event_type, result_text, false);
    }
    if (std.mem.eql(u8, event_type, "short_touch")) {
        const result = try embedded.shortTouchActivation(ctx);
        const result_json = try std.json.Stringify.valueAlloc(ctx.allocator(), result, .{ .whitespace = .indent_2 });
        return try encodeDispatchResult(ctx, request_id, event_type, result_json, true);
    }
    if (std.mem.eql(u8, event_type, "long_touch")) {
        const result = try embedded.longTouchActivation(ctx);
        const result_json = try std.json.Stringify.valueAlloc(ctx.allocator(), result, .{ .whitespace = .indent_2 });
        return try encodeDispatchResult(ctx, request_id, event_type, result_json, true);
    }
    if (std.mem.eql(u8, event_type, "poke_sequence")) {
        const pulse_summary = try pokeSequencePulseSummary(ctx.allocator(), event_object);
        embedded.clearHostEffects(ctx);
        _ = try ctx.brain.observeSenseStimulus(.{
            .kind = .poke_sequence,
            .source = "affective_core_embedded",
            .signature = pulse_summary,
            .raw_magnitude = pokeSequenceMagnitude(event_object),
            .threat = 0,
            .curiosity = 0.40,
            .metadata = pulse_summary,
        });
        embedded.runStimulusAutonomy(ctx) catch |err| switch (err) {
            error.MissingAutonomyPlanner, error.MissingPsycheService, error.LocalDateUnavailable => {},
            else => return try encodeErrorResult(ctx, request_id, event_type, "stimulus_autonomy_failed", @errorName(err)),
        };
        return try encodeDispatchResult(ctx, request_id, event_type, "", false);
    }
    if (std.mem.eql(u8, event_type, "sense_catalog")) {
        return try encodeDispatchResult(ctx, request_id, event_type, try senseCatalogSummary(ctx, event_object), false);
    }
    if (std.mem.eql(u8, event_type, "sense_status")) {
        return try encodeDispatchResult(ctx, request_id, event_type, try senseStatusSummary(ctx, event_object), false);
    }
    if (std.mem.eql(u8, event_type, "sense_observation")) {
        const sense = getStringFromObject(event_object, "sense") orelse "";
        const observation_value = event_object.get("observation") orelse {
            return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing sense observation", false, emptyBudget(ctx));
        };
        if (observation_value != .object) {
            return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "sense observation must be an object", false, emptyBudget(ctx));
        }
        const observation = observation_value.object;
        if (std.mem.eql(u8, sense, "orientation")) {
            const posture = getStringFromObject(observation, "posture") orelse "unknown";
            const summary = getStringFromObject(observation, "summary") orelse "Orientation observed.";
            const confidence = getNumberFromObject(observation, "confidence") orelse 0;
            const metadata = try std.fmt.allocPrint(ctx.allocator(), "posture={s} confidence={d:.2} summary={s}", .{ posture, confidence, summary });
            _ = try ctx.brain.observeSenseStimulus(.{
                .kind = .orientation,
                .source = "affective_orientation",
                .signature = posture,
                .raw_magnitude = @floatCast(@min(@max(confidence, 0), 1)),
                .threat = 0,
                .curiosity = 0.12,
                .metadata = metadata,
            });
            const result_text = try std.fmt.allocPrint(ctx.allocator(), "orientation: {s}", .{summary});
            return try encodeDispatchResult(ctx, request_id, event_type, result_text, false);
        }
        if (std.mem.eql(u8, sense, "motion_gesture")) {
            const gesture = getStringFromObject(observation, "gesture") orelse "unknown";
            const summary = getStringFromObject(observation, "summary") orelse "Motion gesture observed.";
            const confidence = getNumberFromObject(observation, "confidence") orelse 0;
            const metadata = try std.fmt.allocPrint(ctx.allocator(), "gesture={s} confidence={d:.2} summary={s}", .{ gesture, confidence, summary });
            _ = try ctx.brain.observeSenseStimulus(.{
                .kind = .touch,
                .source = "affective_motion_gesture",
                .signature = gesture,
                .raw_magnitude = @floatCast(@min(@max(confidence, 0), 1)),
                .threat = 0,
                .curiosity = 0.25,
                .metadata = metadata,
            });
            const result_text = try std.fmt.allocPrint(ctx.allocator(), "motion_gesture: {s}", .{summary});
            return try encodeDispatchResult(ctx, request_id, event_type, result_text, false);
        }
        if (std.mem.eql(u8, sense, "camera")) {
            const path = getStringFromObject(observation, "path") orelse "";
            const mime_type = getStringFromObject(observation, "mime_type") orelse "image/jpeg";
            const source = getStringFromObject(observation, "source") orelse "affective_camera";
            const owned_path = try ctx.allocator().dupe(u8, path);
            const metadata = try std.fmt.allocPrint(ctx.allocator(), "path={s} mime_type={s} source={s}", .{ owned_path, mime_type, source });
            _ = try ctx.brain.observeSenseStimulus(.{
                .kind = .visual,
                .source = "affective_camera",
                .signature = owned_path,
                .raw_magnitude = 0.75,
                .threat = 0,
                .curiosity = 0.50,
                .metadata = metadata,
            });
            ctx.brain.last_visual_observation_path = owned_path;
            ctx.brain.last_visual_update_seconds = ctx.brain.now_seconds;
            ctx.brain.last_visual_observation_uploaded = false;
            // If this pull was requested to satisfy a recognize skill, finish the
            // identify+greet here so "capture + recognize" resolves as a single
            // awaited operation instead of a separate, never-resumed step.
            if (ctx.brain.pending_camera_intent == .recognize) {
                ctx.brain.pending_camera_intent = .none;
                const recognition = try ctx.brain.recognizeFromCapturedPath(owned_path);
                return try encodeDispatchResult(ctx, request_id, event_type, recognition, false);
            }
            const result_text = try std.fmt.allocPrint(ctx.allocator(), "camera: observed image at {s}", .{owned_path});
            return try encodeDispatchResult(ctx, request_id, event_type, result_text, false);
        }
        return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "unknown_sense", "unknown sense observation", false, emptyBudget(ctx));
    }
    if (std.mem.eql(u8, event_type, "host_capability_status")) {
        try applyHostCapabilityStatus(ctx, request_id, event_object);
        return try encodeDispatchResult(ctx, request_id, event_type, try hostCapabilityStatusSummary(ctx, event_object), false);
    }
    if (std.mem.eql(u8, event_type, "tool_call")) {
        const name = getStringFromObject(event_object, "name") orelse {
            return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing tool_call name", false, emptyBudget(ctx));
        };
        if (std.mem.eql(u8, name, "raw_ref_lookup")) {
            const raw_ref = getStringFromObject(event_object, "raw_ref") orelse return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing raw_ref", false, emptyBudget(ctx));
            const bytes = lookupRawRef(ctx, raw_ref) catch |err| return try encodeErrorResult(ctx, request_id, event_type, "raw_ref_not_found", @errorName(err));
            return try encodeDispatchResult(ctx, request_id, event_type, bytes, true);
        }
        var empty_args = try std.json.ObjectMap.init(std.heap.page_allocator, &.{}, &.{});
        defer empty_args.deinit(std.heap.page_allocator);
        const empty_args_value = std.json.Value{ .object = empty_args };
        const args = event_object.get("arguments") orelse empty_args_value;
        const tool_output = embedded.dispatchTool(ctx, name, args) catch |err| {
            if (err == error.FrontendCaptureRequested) {
                return try encodeDispatchResult(ctx, request_id, event_type, "", false);
            }
            if (err == error.FrontendOrientationRequested) {
                return try encodeDispatchResult(ctx, request_id, event_type, "", false);
            }
            return try encodeErrorResult(ctx, request_id, event_type, "tool_call_failed", @errorName(err));
        };
        defer std.heap.page_allocator.free(tool_output);
        return try encodeDispatchResult(ctx, request_id, event_type, tool_output, true);
    }
    if (std.mem.eql(u8, event_type, "raw_ref_lookup")) {
        const raw_ref = getStringFromObject(event_object, "raw_ref") orelse {
            return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing raw_ref", false, emptyBudget(ctx));
        };
        const bytes = lookupRawRef(ctx, raw_ref) catch |err| return try encodeErrorResult(ctx, request_id, event_type, "raw_ref_not_found", @errorName(err));
        return try encodeDispatchResult(ctx, request_id, event_type, bytes, true);
    }
    if (std.mem.eql(u8, event_type, "maintenance_tick")) {
        ctx.brain.runMaintenance(ctx.io()) catch |err| return try encodeErrorResult(ctx, request_id, event_type, "maintenance_failed", @errorName(err));
        return try encodeDispatchResult(ctx, request_id, event_type, "maintenance_tick", false);
    }
    if (std.mem.eql(u8, event_type, "autonomy_tick")) {
        ctx.brain.runAutonomyTick(ctx.io()) catch |err| return try encodeErrorResult(ctx, request_id, event_type, "autonomy_failed", @errorName(err));
        return try encodeDispatchResult(ctx, request_id, event_type, "autonomy_tick", false);
    }
    if (std.mem.eql(u8, event_type, "introspect_summary")) {
        const result = app_core.executeBrainCommand(ctx.allocator(), &ctx.brain, .{ .command = .introspect }) catch |err| return try encodeErrorResult(ctx, request_id, event_type, "introspect_failed", @errorName(err));
        return try encodeDispatchResult(ctx, request_id, event_type, result.observation, true);
    }
    return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "unknown_event_type", "unknown embedded event type", false, emptyBudget(ctx));
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

fn senseCatalogSummary(ctx: *AffectiveCoreEmbedded, event_object: std.json.ObjectMap) ![]const u8 {
    const senses = event_object.get("senses") orelse {
        return try ctx.allocator().dupe(u8, "sense_catalog: count=0");
    };
    if (senses != .array) {
        return try ctx.allocator().dupe(u8, "sense_catalog: count=0");
    }
    return try std.fmt.allocPrint(ctx.allocator(), "sense_catalog: count={d}", .{senses.array.items.len});
}

fn senseStatusSummary(ctx: *AffectiveCoreEmbedded, event_object: std.json.ObjectMap) ![]const u8 {
    const sense = getStringFromObject(event_object, "sense") orelse getStringFromObject(event_object, "sense_id") orelse "unknown";
    const status = getStringFromObject(event_object, "status") orelse "unknown";
    const reason = getStringFromObject(event_object, "reason") orelse getStringFromObject(event_object, "status_reason") orelse "";
    return try std.fmt.allocPrint(ctx.allocator(), "sense_status: {s}={s} reason={s}", .{ sense, status, reason });
}

fn applyHostCapabilityStatus(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_object: std.json.ObjectMap) !void {
    const capability = getStringFromObject(event_object, "capability") orelse "";
    const status = getStringFromObject(event_object, "status") orelse "";
    if (!std.mem.eql(u8, capability, "camera")) return;

    if (std.mem.eql(u8, status, "pending")) {
        const pending_request_id = getStringFromObject(event_object, "request_id") orelse request_id;
        const reason = getStringFromObject(event_object, "reason") orelse "host capability pending";
        ctx.pending_camera_permission = .{
            .request_id = try ctx.allocator().dupe(u8, pending_request_id),
            .pending_since_unix_ms = getIntegerFromObject(event_object, "pending_since_unix_ms") orelse 0,
            .reason = try ctx.allocator().dupe(u8, reason),
        };
        return;
    }

    if (std.mem.eql(u8, status, "available") or std.mem.eql(u8, status, "denied") or std.mem.eql(u8, status, "unavailable")) {
        ctx.pending_camera_permission = null;
    }
}

fn hostCapabilityStatusSummary(ctx: *AffectiveCoreEmbedded, event_object: std.json.ObjectMap) ![]const u8 {
    const capability = getStringFromObject(event_object, "capability") orelse "unknown";
    const status = getStringFromObject(event_object, "status") orelse "unknown";
    const elapsed = getIntegerFromObject(event_object, "pending_elapsed_ms") orelse 0;
    const reason = getStringFromObject(event_object, "reason") orelse "";
    return try std.fmt.allocPrint(ctx.allocator(), "host_capability_status: {s}={s} pending_elapsed_ms={d} reason={s}", .{ capability, status, elapsed, reason });
}

pub fn encodeDispatchResult(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8, result_text: []const u8, raw_result: bool) ![]u8 {
    const compacted_events = try context_gate.compactEvents(ctx.allocator(), ctx.brain.now_seconds, request_id, embedded.hostEvents(ctx), ctx.context_budget);
    try persistRawRefs(ctx, compacted_events.raw_refs);
    const envelope_events = try filterSuppressedEvents(ctx, compacted_events.events);
    try appendQueuedEvents(ctx, envelope_events);

    const compacted_result = try context_gate.compactText(ctx.allocator(), ctx.brain.now_seconds, event_type, result_text, ctx.context_budget.max_result_bytes);
    try persistRawRefs(ctx, compacted_result.raw_refs);
    const budget = try context_gate.budgetWithResult(ctx.allocator(), compacted_events.budget, compacted_result.summary.len, compacted_result.raw_refs, compacted_result.compacted);
    const output = try embedded_protocol.successEnvelopeAlloc(std.heap.page_allocator, request_id, envelope_events, .{
        .event_type = event_type,
        .summary = compacted_result.summary,
        .raw_result = raw_result,
    }, budget);
    if (output.len > ctx.context_budget.max_envelope_bytes) {
        std.heap.page_allocator.free(output);
        return try minimalEnvelope(ctx, request_id, event_type, "compacted envelope exceeded max_bytes");
    }
    return output;
}

pub fn filterSuppressedEvents(ctx: *AffectiveCoreEmbedded, events: []const embedded_protocol.HostEvent) ![]const embedded_protocol.HostEvent {
    if (ctx.pending_camera_permission == null) return events;
    var filtered = std.ArrayList(embedded_protocol.HostEvent).empty;
    for (events) |event| {
        if (std.mem.eql(u8, event.type, "sense_request") and event.sense != null and std.mem.eql(u8, event.sense.?, "camera")) continue;
        try filtered.append(ctx.allocator(), event);
    }
    return try filtered.toOwnedSlice(ctx.allocator());
}

fn encodeErrorResult(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8, code: []const u8, message: []const u8) ![]u8 {
    const text = try std.fmt.allocPrint(ctx.allocator(), "{s}: {s}", .{ code, message });
    return encodeDispatchResult(ctx, request_id, event_type, text, false);
}

fn minimalEnvelope(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8, summary: []const u8) ![]u8 {
    const budget = context_gate.BudgetReport{
        .max_bytes = ctx.context_budget.max_envelope_bytes,
        .used_bytes = summary.len,
        .compacted = true,
        .dropped_event_count = embedded.hostEvents(ctx).len,
        .raw_refs = &.{},
    };
    return embedded_protocol.successEnvelopeAlloc(std.heap.page_allocator, request_id, &[_]embedded_protocol.HostEvent{}, .{
        .event_type = event_type,
        .summary = summary,
        .raw_result = false,
    }, budget);
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

pub fn persistRawRefs(ctx: *AffectiveCoreEmbedded, raw_refs: []const context_gate.RawRef) !void {
    for (raw_refs) |raw_ref| {
        const path = try rawRefPath(ctx.allocator(), ctx.brain.cfg.brain_root, raw_ref.id);
        try writeFilePath(ctx.io(), path, raw_ref.bytes);
    }
}

pub fn lookupRawRef(ctx: *AffectiveCoreEmbedded, raw_ref: []const u8) ![]const u8 {
    if (!validRawRef(raw_ref)) return error.InvalidRawRef;
    if (rawRefExpired(ctx, raw_ref)) return error.RawRefExpired;
    const path = try rawRefPath(ctx.allocator(), ctx.brain.cfg.brain_root, raw_ref);
    return readFileAllocPath(ctx.io(), path, ctx.allocator(), .limited(8 * 1024 * 1024));
}

fn rawRefPath(allocator: std.mem.Allocator, brain_root: []const u8, raw_ref: []const u8) ![]const u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.txt", .{raw_ref});
    return std.fs.path.join(allocator, &.{ brain_root, "raw_refs", filename });
}

fn validRawRef(raw_ref: []const u8) bool {
    if (!std.mem.startsWith(u8, raw_ref, "raw_event_")) return false;
    for (raw_ref) |ch| {
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_') continue;
        return false;
    }
    return true;
}

fn rawRefExpired(ctx: *AffectiveCoreEmbedded, raw_ref: []const u8) bool {
    const prefix = "raw_event_";
    if (!std.mem.startsWith(u8, raw_ref, prefix)) return true;
    const rest = raw_ref[prefix.len..];
    const split = std.mem.indexOfScalar(u8, rest, '_') orelse return true;
    const created_at = std.fmt.parseInt(i64, rest[0..split], 10) catch return true;
    return ctx.brain.now_seconds - created_at > ctx.raw_ref_ttl_seconds;
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

fn readFileAllocPath(io: std.Io, path: []const u8, allocator: std.mem.Allocator, limit: std.Io.Limit) ![]u8 {
    return files.readFileAllocPath(io, path, allocator, limit);
}

fn writeFilePath(io: std.Io, path: []const u8, data: []const u8) !void {
    return files.writeFilePath(io, path, data);
}
