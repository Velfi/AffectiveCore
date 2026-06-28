const std = @import("std");
const chat_client = @import("api/chat_client.zig");
const app_core = @import("app/app_core.zig");
const context_gate = @import("app/context_gate.zig");
const embedded_protocol = @import("app/embedded_protocol.zig");
const files = @import("platform/common/files.zig");
const embedded = @import("affective_core_embedded.zig");
const embedded_ops = @import("affective_core_embedded_ops.zig");
const error_descriptions = @import("core/error_descriptions.zig");
const brain_mod = @import("core/brain.zig");

const AffectiveCoreEmbedded = embedded.AffectiveCoreEmbedded;

const DispatchRequestMeta = struct {
    request_id_buf: [96]u8 = undefined,
    event_type_buf: [96]u8 = undefined,
    request_id: []const u8 = "",
    event_type: []const u8 = "invalid",

    fn init(request_id_src: []const u8, event_type_src: []const u8) DispatchRequestMeta {
        var meta: DispatchRequestMeta = .{};
        meta.request_id = copyLogField(&meta.request_id_buf, request_id_src);
        meta.event_type = copyLogField(&meta.event_type_buf, event_type_src);
        return meta;
    }
};

fn copyLogField(dest: []u8, src: []const u8) []const u8 {
    if (src.len == 0) return "";
    const len = @min(src.len, dest.len);
    @memcpy(dest[0..len], src[0..len]);
    return dest[0..len];
}

const DispatchOutputSummary = struct {
    status: []const u8,
    detail: []const u8,
};

fn parseDispatchRequestMeta(request_json: []const u8) DispatchRequestMeta {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, request_json, .{}) catch {
        return DispatchRequestMeta.init("", "invalid");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return DispatchRequestMeta.init("", "invalid");
    const root = parsed.value.object;
    const request_id = getStringFromObject(root, "request_id") orelse "";
    const event = root.get("event") orelse return DispatchRequestMeta.init(request_id, "missing_event");
    if (event != .object) return DispatchRequestMeta.init(request_id, "invalid_event");
    const event_type = getStringFromObject(event.object, "type") orelse "missing_event_type";
    return DispatchRequestMeta.init(request_id, event_type);
}

fn summarizeDispatchOutput(output: []const u8) DispatchOutputSummary {
    const Envelope = struct {
        ok: bool = true,
        @"error": ?struct {
            code: []const u8,
            message: []const u8,
        } = null,
    };
    const parsed = std.json.parseFromSlice(Envelope, std.heap.page_allocator, output, .{ .ignore_unknown_fields = true }) catch {
        return .{ .status = "ok", .detail = "response returned" };
    };
    defer parsed.deinit();
    if (!parsed.value.ok) {
        const err = parsed.value.@"error" orelse return .{ .status = "error", .detail = "dispatch returned ok=false without an error object" };
        return .{ .status = "error", .detail = err.message };
    }
    return .{ .status = "ok", .detail = "dispatch completed" };
}

fn logDispatchStart(operation: []const u8, dispatch_id: []const u8, request_bytes: usize) void {
    std.debug.print(
        "Dispatch operation start operation={s} dispatch_id={s} requestBytes={d}\n",
        .{ operation, if (dispatch_id.len > 0) dispatch_id else "(none)", request_bytes },
    );
}

fn logDispatchResult(operation: []const u8, dispatch_id: []const u8, status: []const u8, data_bytes: usize, detail: []const u8) void {
    std.debug.print(
        "Dispatch operation result operation={s} dispatch_id={s} status={s} dataBytes={d} detail=\"{s}\"\n",
        .{ operation, if (dispatch_id.len > 0) dispatch_id else "(none)", status, data_bytes, detail },
    );
}

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
    ctx.http_transport.last_error = null;
    ctx.brain.clearChatParseFailure();
    const meta = parseDispatchRequestMeta(request_json);
    logDispatchStart(meta.event_type, meta.request_id, request_json.len);
    const output = dispatchJsonImpl(ctx, request_json) catch |err| {
        const detail_owned = error_descriptions.formatFailureDetail(std.heap.page_allocator, err, ctx.brain.chatParseFailureBody()) catch null;
        const detail: []const u8 = detail_owned orelse error_descriptions.name(err);
        defer if (detail_owned != null) std.heap.page_allocator.free(detail);
        logDispatchResult(meta.event_type, meta.request_id, "failed", 0, detail);
        return err;
    };
    const summary = summarizeDispatchOutput(output);
    logDispatchResult(meta.event_type, meta.request_id, summary.status, output.len, summary.detail);
    return output;
}

fn dispatchJsonImpl(ctx: *AffectiveCoreEmbedded, request_json: []const u8) ![]u8 {
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
    if (std.mem.eql(u8, event_type, "connect")) {
        const snapshot = try embedded_ops.connect(ctx);
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "connect",
            .read_models = snapshot,
        });
    }
    if (std.mem.eql(u8, event_type, "host_attach")) {
        const binding = try embedded_ops.hostAttach(ctx, event);
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "host_attach",
            .host_binding = binding,
        });
    }
    if (std.mem.eql(u8, event_type, "host_capability_manifest")) {
        const capability_count = try embedded_ops.hostCapabilityManifest(ctx, event);
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "host_capability_manifest",
            .capability_count = capability_count,
        });
    }
    if (std.mem.eql(u8, event_type, "send_experience_event")) {
        const recorded = try embedded_ops.sendExperienceEvent(ctx, event);
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "send_experience_event",
            .event = recorded,
        });
    }
    if (std.mem.eql(u8, event_type, "user_text")) {
        const text = getStringFromObject(event_object, "text") orelse {
            return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing text", false, emptyBudget(ctx));
        };
        const result = app_core.userTextOutcome(try ctx.brain.handleConversationText(try embedded_ops.tryTypedSpeech(ctx, text), .{ .request_id = request_id }));
        return try encodeUserTextOutcome(ctx, request_id, event_type, result);
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
        const detail = try std.fmt.allocPrint(ctx.allocator(), "interrupt: {s}", .{metadata});
        return try encodeDetailResult(ctx, request_id, event_type, detail);
    }
    if (std.mem.eql(u8, event_type, "short_touch")) {
        const result = embedded_ops.shortTouchActivation(ctx) catch |err| {
            if (err == error.FrontendCaptureRequested or err == error.FrontendOrientationRequested) {
                return try encodeDetailResult(ctx, request_id, event_type, "");
            }
            return try encodeErrorResult(ctx, request_id, event_type, "short_touch_failed", err);
        };
        embedded_ops.runStimulusAutonomy(ctx) catch |err| switch (err) {
            error.MissingAutonomyPlanner, error.MissingPsycheService, error.LocalDateUnavailable, error.ContextBudgetExceeded => {},
            else => return try encodeErrorResult(ctx, request_id, event_type, "stimulus_autonomy_failed", err),
        };
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "activation",
            .activation = "short_touch",
            .action_result = result,
        });
    }
    if (std.mem.eql(u8, event_type, "long_touch")) {
        const result = embedded_ops.longTouchActivation(ctx) catch |err| {
            if (err == error.FrontendCaptureRequested or err == error.FrontendOrientationRequested) {
                return try encodeDetailResult(ctx, request_id, event_type, "");
            }
            return try encodeErrorResult(ctx, request_id, event_type, "long_touch_failed", err);
        };
        embedded_ops.runStimulusAutonomy(ctx) catch |err| switch (err) {
            error.MissingAutonomyPlanner, error.MissingPsycheService, error.LocalDateUnavailable, error.ContextBudgetExceeded => {},
            else => return try encodeErrorResult(ctx, request_id, event_type, "stimulus_autonomy_failed", err),
        };
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "activation",
            .activation = "long_touch",
            .action_result = result,
        });
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
        embedded_ops.runStimulusAutonomy(ctx) catch |err| switch (err) {
            error.MissingAutonomyPlanner, error.MissingPsycheService, error.LocalDateUnavailable, error.ContextBudgetExceeded => {},
            else => return try encodeErrorResult(ctx, request_id, event_type, "stimulus_autonomy_failed", err),
        };
        return try encodeDetailResult(ctx, request_id, event_type, pulse_summary);
    }
    if (std.mem.eql(u8, event_type, "sense_catalog")) {
        return try encodeDetailResult(ctx, request_id, event_type, try senseCatalogSummary(ctx, event_object));
    }
    if (std.mem.eql(u8, event_type, "sense_status")) {
        return try encodeDetailResult(ctx, request_id, event_type, try senseStatusSummary(ctx, event_object));
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
            const packet = try ctx.brain.observeSenseStimulus(.{
                .kind = .orientation,
                .source = "affective_orientation",
                .signature = posture,
                .raw_magnitude = @floatCast(@min(@max(confidence, 0), 1)),
                .threat = 0,
                .curiosity = 0.12,
                .metadata = metadata,
            });
            if (try ctx.brain.reactToSalientSense(packet)) |conversation| {
                return try encodeSenseObservationOutcome(ctx, request_id, event_type, app_core.userTextOutcome(conversation));
            }
            const detail = try std.fmt.allocPrint(ctx.allocator(), "orientation: {s}", .{summary});
            return try encodeDetailResult(ctx, request_id, event_type, detail);
        }
        if (std.mem.eql(u8, sense, "motion_gesture")) {
            const gesture = getStringFromObject(observation, "gesture") orelse "unknown";
            const summary = getStringFromObject(observation, "summary") orelse "Motion gesture observed.";
            const confidence = getNumberFromObject(observation, "confidence") orelse 0;
            const metadata = try std.fmt.allocPrint(ctx.allocator(), "gesture={s} confidence={d:.2} summary={s}", .{ gesture, confidence, summary });
            const packet = try ctx.brain.observeSenseStimulus(.{
                .kind = .touch,
                .source = "affective_motion_gesture",
                .signature = gesture,
                .raw_magnitude = @floatCast(@min(@max(confidence, 0), 1)),
                .threat = 0,
                .curiosity = 0.25,
                .metadata = metadata,
            });
            if (try ctx.brain.reactToSalientSense(packet)) |conversation| {
                return try encodeSenseObservationOutcome(ctx, request_id, event_type, app_core.userTextOutcome(conversation));
            }
            const detail = try std.fmt.allocPrint(ctx.allocator(), "motion_gesture: {s}", .{summary});
            return try encodeDetailResult(ctx, request_id, event_type, detail);
        }
        if (std.mem.eql(u8, sense, "autonomy_replenish")) {
            const actions = getU32FromObject(observation, "actions") orelse {
                return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "autonomy_replenish requires observation.actions as a positive integer", false, emptyBudget(ctx));
            };
            if (actions == 0) {
                return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "autonomy_replenish observation.actions must be at least 1", false, emptyBudget(ctx));
            }
            const applied_actions = try ctx.brain.runAutonomyReplenishFromPush(ctx.io(), actions);
            const detail = try std.fmt.allocPrint(ctx.allocator(), "autonomy_replenish: requested={d} applied={d}", .{ actions, applied_actions });
            return try encodeDetailResult(ctx, request_id, event_type, detail);
        }
        if (std.mem.eql(u8, sense, "camera")) {
            const path = getStringFromObject(observation, "path") orelse "";
            const mime_type = getStringFromObject(observation, "mime_type") orelse "image/jpeg";
            const source = getStringFromObject(observation, "source") orelse "affective_camera";
            const visual_result = try ctx.brain.handleHostVisualObservation(path, source, mime_type);
            return try encodeHostVisualObservationResult(ctx, request_id, event_type, visual_result);
        }
        return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "unknown_sense", "unknown sense observation", false, emptyBudget(ctx));
    }
    if (std.mem.eql(u8, event_type, "capability_status")) {
        try applyHostCapabilityStatus(ctx, request_id, event_object);
        return try encodeDetailResult(ctx, request_id, event_type, try hostCapabilityStatusSummary(ctx, event_object));
    }
    if (std.mem.eql(u8, event_type, "brain_mode")) {
        const mode = try embedded_ops.brainMode(ctx);
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "brain_mode",
            .brain_mode = mode,
        });
    }
    if (std.mem.eql(u8, event_type, "read_models_snapshot")) {
        const snapshot = try embedded_ops.readModelsSnapshot(ctx);
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "read_models_snapshot",
            .read_models = snapshot,
        });
    }
    if (std.mem.eql(u8, event_type, "request_dream_time")) {
        const item = try embedded_ops.requestDreamTime(ctx, getStringFromObject(event_object, "text"));
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "request_dream_time",
            .mailbox_item = item,
        });
    }
    if (std.mem.eql(u8, event_type, "mailbox_list")) {
        const items = try embedded_ops.mailboxList(ctx);
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "mailbox_list",
            .items = items,
        });
    }
    if (std.mem.eql(u8, event_type, "mailbox_mark_read")) {
        const items = try embedded_ops.mailboxMarkRead(ctx, event);
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "mailbox_mark_read",
            .items = items,
        });
    }
    if (std.mem.eql(u8, event_type, "raw_ref_lookup")) {
        const raw_ref = getStringFromObject(event_object, "raw_ref") orelse {
            return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing raw_ref", false, emptyBudget(ctx));
        };
        const bytes = lookupRawRef(ctx, raw_ref) catch |err| return try encodeErrorResult(ctx, request_id, event_type, "raw_ref_not_found", err);
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "raw_ref_lookup",
            .raw_ref = raw_ref,
            .content = bytes,
        });
    }
    if (std.mem.eql(u8, event_type, "export_brain")) {
        const manifest = try embedded_ops.exportBrain(ctx, event);
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "export_brain",
            .manifest = manifest,
        });
    }
    if (std.mem.eql(u8, event_type, "import_brain")) {
        const manifest = try embedded_ops.importBrain(ctx, event);
        return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
            .kind = "import_brain",
            .manifest = manifest,
        });
    }
    if (std.mem.eql(u8, event_type, "maintenance_tick")) {
        ctx.brain.runMaintenance(ctx.io()) catch |err| return try encodeErrorResult(ctx, request_id, event_type, "maintenance_failed", err);
        return try encodeDetailResult(ctx, request_id, event_type, "maintenance_tick");
    }
    if (std.mem.eql(u8, event_type, "autonomy_tick")) {
        ctx.brain.runAutonomyReplenish(ctx.io()) catch |err| return try encodeErrorResult(ctx, request_id, event_type, "autonomy_replenish_failed", err);
        ctx.brain.runAutonomyTick(ctx.io()) catch |err| return try encodeErrorResult(ctx, request_id, event_type, "autonomy_failed", err);
        return try encodeDetailResult(ctx, request_id, event_type, "autonomy_tick");
    }
    return try embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "unknown_event_type", "unknown embedded event type", false, emptyBudget(ctx));
}

fn encodeDetailResult(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    event_type: []const u8,
    detail: []const u8,
) ![]u8 {
    return encodeStructuredDispatchResult(ctx, request_id, event_type, .{
        .kind = event_type,
        .detail = detail,
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
    const reason = getStringFromObject(event_object, "reason") orelse "";
    return try std.fmt.allocPrint(ctx.allocator(), "sense_status: {s}={s} reason={s}", .{ sense, status, reason });
}

fn applyHostCapabilityStatus(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_object: std.json.ObjectMap) !void {
    const capability = getStringFromObject(event_object, "capability_id") orelse "";
    if (capability.len == 0) return;
    const availability = getStringFromObject(event_object, "availability") orelse "unavailable";
    try ctx.brain.recordCapabilityStatus(.{
        .capability_id = capability,
        .host_id = getStringFromObject(event_object, "host_id") orelse try ctx.allocator().dupe(u8, ctx.brain.currentHostId()),
        .permission = embedded_ops.permissionFromString(getStringFromObject(event_object, "permission") orelse "unknown"),
        .availability = embedded_ops.availabilityFromString(availability),
        .quality = getF32FromObject(event_object, "quality") orelse 0.0,
        .reliability = getF32FromObject(event_object, "reliability") orelse 0.0,
        .cost = getF32FromObject(event_object, "cost") orelse 0.0,
        .latency_ms = getU32FromObject(event_object, "latency_ms") orelse 0,
        .risk = getF32FromObject(event_object, "risk") orelse 0.0,
        .unavailable_reason = getStringFromObject(event_object, "unavailable_reason") orelse "",
        .updated_at_ms = ctx.brain.now_seconds * 1000,
    });
    if (!std.mem.eql(u8, capability, "camera")) return;

    if (std.mem.eql(u8, availability, "pending") or std.mem.eql(u8, availability, "degraded")) {
        const pending_request_id = getStringFromObject(event_object, "request_id") orelse request_id;
        const reason = getStringFromObject(event_object, "unavailable_reason") orelse "host capability pending";
        ctx.pending_camera_permission = .{
            .request_id = try ctx.allocator().dupe(u8, pending_request_id),
            .pending_since_unix_ms = getIntegerFromObject(event_object, "pending_since_unix_ms") orelse 0,
            .reason = try ctx.allocator().dupe(u8, reason),
        };
        return;
    }

    if (std.mem.eql(u8, availability, "available") or std.mem.eql(u8, availability, "refused") or std.mem.eql(u8, availability, "unavailable")) {
        ctx.pending_camera_permission = null;
    }
}

fn hostCapabilityStatusSummary(ctx: *AffectiveCoreEmbedded, event_object: std.json.ObjectMap) ![]const u8 {
    const capability = getStringFromObject(event_object, "capability_id") orelse "unknown";
    const status = getStringFromObject(event_object, "availability") orelse "unknown";
    const elapsed = getIntegerFromObject(event_object, "pending_elapsed_ms") orelse 0;
    const reason = getStringFromObject(event_object, "unavailable_reason") orelse "";
    return try std.fmt.allocPrint(ctx.allocator(), "capability_status: {s}={s} pending_elapsed_ms={d} reason={s}", .{ capability, status, elapsed, reason });
}

pub fn encodeUserTextOutcome(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    event_type: []const u8,
    result: app_core.UserTextOutcome,
) ![]u8 {
    return encodeStructuredDispatchResult(ctx, request_id, event_type, .{
        .kind = "user_text",
        .outcome = result,
    });
}

pub fn encodeSenseObservationOutcome(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    event_type: []const u8,
    result: app_core.UserTextOutcome,
) ![]u8 {
    return encodeStructuredDispatchResult(ctx, request_id, event_type, .{
        .kind = event_type,
        .outcome = result,
    });
}

fn encodeHostVisualObservationResult(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    event_type: []const u8,
    result: brain_mod.HostVisualObservationResult,
) ![]u8 {
    switch (result) {
        .conversation_resume => |conversation| {
            return try encodeSenseObservationOutcome(ctx, request_id, event_type, app_core.userTextOutcome(conversation));
        },
        .salient_reaction => |conversation| {
            return try encodeSenseObservationOutcome(ctx, request_id, event_type, app_core.userTextOutcome(conversation));
        },
        .recognition_only => |detail| {
            return try encodeDetailResult(ctx, request_id, event_type, detail);
        },
        .detail_only => |detail| {
            return try encodeDetailResult(ctx, request_id, event_type, detail);
        },
    }
}

pub fn encodeStructuredDispatchResult(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    event_type: []const u8,
    value: anytype,
) ![]u8 {
    const activity_id = ctx.brain.activeActivityId() orelse "";
    const compacted_events = try context_gate.compactEvents(ctx.allocator(), ctx.brain.now_seconds, request_id, activity_id, embedded.hostEvents(ctx), ctx.context_budget);
    try persistRawRefs(ctx, compacted_events.raw_refs);
    const envelope_events = try filterSuppressedEvents(ctx, compacted_events.events);

    const value_json = try std.json.Stringify.valueAlloc(ctx.allocator(), value, .{});
    defer ctx.allocator().free(value_json);
    const budget = try context_gate.budgetWithResult(ctx.allocator(), compacted_events.budget, value_json.len, &.{}, false);
    const output = try embedded_protocol.successEnvelopeAlloc(std.heap.page_allocator, request_id, envelope_events, .{
        .event_type = event_type,
        .value = value,
    }, budget);
    if (output.len > ctx.context_budget.max_envelope_bytes) {
        std.heap.page_allocator.free(output);
        return try minimalEnvelope(ctx, request_id, event_type, "compacted envelope exceeded max_bytes");
    }
    return output;
}

pub fn filterSuppressedEvents(ctx: *AffectiveCoreEmbedded, events: []const embedded_protocol.HostEvent) ![]const embedded_protocol.HostEvent {
    if (ctx.pending_camera_permission == null) return events;
    const awaiting_camera = ctx.brain.awaitedHostRequestMatches("camera", "recognize");
    var filtered = std.ArrayList(embedded_protocol.HostEvent).empty;
    for (events) |event| {
        if (!awaiting_camera and std.mem.eql(u8, event.type, "sense_request") and event.sense != null and std.mem.eql(u8, event.sense.?, "camera")) continue;
        try filtered.append(ctx.allocator(), event);
    }
    return try filtered.toOwnedSlice(ctx.allocator());
}

fn encodeErrorResult(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8, code: []const u8, err: anyerror) ![]u8 {
    _ = event_type;
    const detail = try error_descriptions.formatFailureDetail(ctx.allocator(), err, ctx.brain.chatParseFailureBody());
    defer ctx.allocator().free(detail);
    const message = try std.fmt.allocPrint(ctx.allocator(), "{s}: {s}", .{ error_descriptions.name(err), detail });
    defer ctx.allocator().free(message);
    return embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, code, message, false, emptyBudget(ctx));
}

fn minimalEnvelope(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8, detail: []const u8) ![]u8 {
    const budget = context_gate.BudgetReport{
        .max_bytes = ctx.context_budget.max_envelope_bytes,
        .used_bytes = detail.len,
        .compacted = true,
        .dropped_event_count = embedded.hostEvents(ctx).len,
        .raw_refs = &.{},
    };
    return embedded_protocol.successEnvelopeAlloc(std.heap.page_allocator, request_id, &[_]embedded_protocol.HostEvent{}, .{
        .event_type = event_type,
        .value = .{
            .kind = event_type,
            .detail = detail,
        },
    }, budget);
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

fn getF32FromObject(object: std.json.ObjectMap, key: []const u8) ?f32 {
    const value = getNumberFromObject(object, key) orelse return null;
    return @floatCast(value);
}

fn getU32FromObject(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = getIntegerFromObject(object, key) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

fn readFileAllocPath(io: std.Io, path: []const u8, allocator: std.mem.Allocator, limit: std.Io.Limit) ![]u8 {
    return files.readFileAllocPath(io, path, allocator, limit);
}

fn writeFilePath(io: std.Io, path: []const u8, data: []const u8) !void {
    return files.writeFilePath(io, path, data);
}
