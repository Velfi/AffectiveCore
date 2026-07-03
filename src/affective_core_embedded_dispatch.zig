const std = @import("std");
const chat_client = @import("api/chat_client.zig");
const app_core = @import("app/app_core.zig");
const context_gate = @import("app/context_gate.zig");
const embedded_protocol = @import("app/embedded_protocol.zig");
const files = @import("platform/common/files.zig");
const embedded = @import("affective_core_embedded.zig");
const stimulus_inbox_mod = @import("core/stimulus_inbox.zig");
const stimulus_ingest_mod = @import("core/stimulus_ingest.zig");
const embedded_ops = @import("affective_core_embedded_ops.zig");
const error_descriptions = @import("core/error_descriptions.zig");
const brain_mod = @import("core/brain.zig");
const brain_process = @import("core/brain_process.zig");
const host_capability_activation = @import("core/host_capability_activation.zig");
const request_timings = @import("core/request_timings.zig");

const AffectiveCoreEmbedded = embedded.AffectiveCoreEmbedded;

const PublicOperation = enum {
    connect,
    host_update,
    stimulus_ingest,
    brain_step,
    brain_read,
    mailbox_read,
    mailbox_update,
    brain_archive,
    debug_prompt,
};

pub const DispatchRequestMeta = struct {
    request_id_buf: [96]u8 = undefined,
    event_type_buf: [96]u8 = undefined,
    request_id_len: u8 = 0,
    event_type_len: u8 = 0,

    pub fn requestId(self: *const DispatchRequestMeta) []const u8 {
        if (self.request_id_len == 0) return "";
        return self.request_id_buf[0..self.request_id_len];
    }

    pub fn eventType(self: *const DispatchRequestMeta) []const u8 {
        if (self.event_type_len == 0) return "invalid";
        return self.event_type_buf[0..self.event_type_len];
    }

    fn init(request_id_src: []const u8, event_type_src: []const u8) DispatchRequestMeta {
        var meta: DispatchRequestMeta = .{};
        meta.request_id_len = copyInto(&meta.request_id_buf, request_id_src);
        meta.event_type_len = copyInto(&meta.event_type_buf, event_type_src);
        return meta;
    }
};

fn copyInto(dest: []u8, src: []const u8) u8 {
    if (src.len == 0) return 0;
    const len = @min(src.len, dest.len);
    @memcpy(dest[0..len], src[0..len]);
    return @intCast(len);
}

const DispatchOutputSummary = struct {
    status: []const u8,
    detail: []const u8,
};

pub fn parseDispatchRequestMeta(request_json: []const u8) DispatchRequestMeta {
    var meta: DispatchRequestMeta = .{};
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), request_json, .{}) catch {
        meta.event_type_len = copyInto(&meta.event_type_buf, "invalid");
        return meta;
    };
    if (parsed.value != .object) {
        meta.event_type_len = copyInto(&meta.event_type_buf, "invalid");
        return meta;
    }
    const root = parsed.value.object;
    if (getStringFromObject(root, "request_id")) |request_id| {
        meta.request_id_len = copyInto(&meta.request_id_buf, request_id);
    }
    const event = root.get("event") orelse {
        meta.event_type_len = copyInto(&meta.event_type_buf, "missing_event");
        return meta;
    };
    if (event != .object) {
        meta.event_type_len = copyInto(&meta.event_type_buf, "invalid_event");
        return meta;
    }
    const event_type = getStringFromObject(event.object, "type") orelse "missing_event_type";
    meta.event_type_len = copyInto(&meta.event_type_buf, event_type);
    return meta;
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
    defer ctx.resetDispatchScratch();
    ctx.clearHttpTransportLastError();
    ctx.wireDispatchScratchToLlmClients();
    ctx.brain.clearChatParseFailure();
    embedded.clearHostEffects(ctx);
    const meta = parseDispatchRequestMeta(request_json);
    logDispatchStart(meta.eventType(), meta.requestId(), request_json.len);
    try ctx.brain.beginRequestTimings(meta.requestId());
    defer ctx.brain.resetRequestTimings();
    const output = dispatchJsonImpl(ctx, request_json) catch |err| {
        const detail_owned = error_descriptions.formatFailureDetail(std.heap.page_allocator, err, ctx.brain.chatParseFailureBody()) catch null;
        const detail: []const u8 = detail_owned orelse error_descriptions.name(err);
        defer if (detail_owned != null) std.heap.page_allocator.free(detail);
        logDispatchResult(meta.eventType(), meta.requestId(), "failed", 0, detail);
        var timings = try finishDispatchTimings(ctx);
        defer deinitDispatchTimingsReport(ctx, &timings);
        return embedded_protocol.errorEnvelopeAlloc(
            std.heap.page_allocator,
            meta.requestId(),
            "runtime_error",
            detail,
            false,
            emptyBudget(ctx),
            timings,
            ctx.brain.dispatchContextReportView(),
        );
    };
    const summary = summarizeDispatchOutput(output);
    logDispatchResult(meta.eventType(), meta.requestId(), summary.status, output.len, summary.detail);
    return output;
}

pub fn finishDispatchTimings(ctx: *AffectiveCoreEmbedded) !request_timings.Report {
    return ctx.brain.finishRequestTimings();
}

pub fn deinitDispatchTimingsReport(ctx: *AffectiveCoreEmbedded, report: *request_timings.Report) void {
    request_timings.deinitReport(ctx.brain.allocator, report);
}

fn errorEnvelopeWithTimings(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    code: []const u8,
    message: []const u8,
    recoverable: bool,
    budget: context_gate.BudgetReport,
) ![]u8 {
    var timings = try finishDispatchTimings(ctx);
    defer deinitDispatchTimingsReport(ctx, &timings);
    return embedded_protocol.errorEnvelopeAlloc(
        std.heap.page_allocator,
        request_id,
        code,
        message,
        recoverable,
        budget,
        timings,
        ctx.brain.dispatchContextReportView(),
    );
}

fn dispatchJsonImpl(ctx: *AffectiveCoreEmbedded, request_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, ctx.dispatchScratch(), request_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) {
        return try errorEnvelopeWithTimings(ctx, "", "invalid_request", "dispatch request must be a JSON object", false, emptyBudget(ctx));
    }
    const root = parsed.value.object;
    const request_id = getStringFromObject(root, "request_id") orelse "";
    const event = root.get("event") orelse {
        return try errorEnvelopeWithTimings(ctx, request_id, "invalid_request", "missing event", false, emptyBudget(ctx));
    };
    if (event != .object) {
        return try errorEnvelopeWithTimings(ctx, request_id, "invalid_request", "event must be a JSON object", false, emptyBudget(ctx));
    }
    const event_object = event.object;
    const event_type = getStringFromObject(event_object, "type") orelse {
        return try errorEnvelopeWithTimings(ctx, request_id, "invalid_request", "missing event.type", false, emptyBudget(ctx));
    };
    const operation = publicOperation(event_type) orelse {
        return try errorEnvelopeWithTimings(ctx, request_id, "unknown_event_type", "unknown embedded event type", false, emptyBudget(ctx));
    };
    return try acceptPublicOperation(ctx, request_id, operation, event_object);
}

fn publicOperation(event_type: []const u8) ?PublicOperation {
    if (std.mem.eql(u8, event_type, "connect")) return .connect;
    if (std.mem.eql(u8, event_type, "host_update")) return .host_update;
    if (std.mem.eql(u8, event_type, "stimulus_ingest")) return .stimulus_ingest;
    if (std.mem.eql(u8, event_type, "brain_step")) return .brain_step;
    if (std.mem.eql(u8, event_type, "brain_read")) return .brain_read;
    if (std.mem.eql(u8, event_type, "mailbox_read")) return .mailbox_read;
    if (std.mem.eql(u8, event_type, "mailbox_update")) return .mailbox_update;
    if (std.mem.eql(u8, event_type, "brain_archive")) return .brain_archive;
    if (std.mem.eql(u8, event_type, "debug_prompt")) return .debug_prompt;
    return null;
}

fn operationName(operation: PublicOperation) []const u8 {
    return switch (operation) {
        .connect => "connect",
        .host_update => "host_update",
        .stimulus_ingest => "stimulus_ingest",
        .brain_step => "brain_step",
        .brain_read => "brain_read",
        .mailbox_read => "mailbox_read",
        .mailbox_update => "mailbox_update",
        .brain_archive => "brain_archive",
        .debug_prompt => "debug_prompt",
    };
}

fn acceptPublicOperation(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    operation: PublicOperation,
    event_object: std.json.ObjectMap,
) ![]u8 {
    const event_type = operationName(operation);
    switch (operation) {
        .brain_step => return try handleBrainStep(ctx, request_id, event_object),
        .brain_read => return try handleBrainRead(ctx, request_id, event_object),
        .mailbox_read => return try handleMailboxRead(ctx, request_id, event_object),
        .mailbox_update => return try handleMailboxUpdate(ctx, request_id, event_object),
        .brain_archive => return try handleBrainArchive(ctx, request_id, event_object),
        .debug_prompt => return try handleDebugPrompt(ctx, request_id, event_object),
        .stimulus_ingest => {
            if (validateStimulusIngest(event_object)) |message| {
                return try errorEnvelopeWithTimings(ctx, request_id, "invalid_request", message, false, emptyBudget(ctx));
            }
            try applyIngestEvent(ctx, event_type, event_object);
        },
        .host_update => try applyHostUpdate(ctx, request_id, event_object),
        else => try enqueueAcceptedTerminalEvent(ctx, request_id, event_type),
    }
    return try encodeAcceptedResult(ctx, request_id, event_type);
}

fn invalidOperationEnvelope(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    message: []const u8,
) ![]u8 {
    return try errorEnvelopeWithTimings(ctx, request_id, "invalid_request", message, false, emptyBudget(ctx));
}

fn operationSelector(event_object: std.json.ObjectMap, primary_key: []const u8, fallback_key: []const u8) ?[]const u8 {
    return getStringFromObject(event_object, primary_key) orelse getStringFromObject(event_object, fallback_key);
}

fn handleBrainStep(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    event_object: std.json.ObjectMap,
) ![]u8 {
    const kind = getStringFromObject(event_object, "kind") orelse "autonomy";
    if (!std.mem.eql(u8, kind, "autonomy")) {
        return try invalidOperationEnvelope(ctx, request_id, "unsupported brain_step kind");
    }
    try embedded_ops.runStimulusAutonomy(ctx);
    return try encodeStructuredDispatchResult(ctx, request_id, "brain_step", .{
        .kind = "autonomy",
        .status = "completed",
    });
}

fn handleBrainRead(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    event_object: std.json.ObjectMap,
) ![]u8 {
    const query = operationSelector(event_object, "query", "kind") orelse {
        return try invalidOperationEnvelope(ctx, request_id, "missing brain_read query");
    };
    if (std.mem.eql(u8, query, "brain_mode")) {
        const mode = try embedded_ops.brainMode(ctx);
        return try encodeStructuredDispatchResult(ctx, request_id, "brain_read", .{
            .kind = "brain_mode",
            .brain_mode = mode,
        });
    }
    if (std.mem.eql(u8, query, "models_snapshot")) {
        const snapshot = try embedded_ops.readModelsSnapshot(ctx);
        return try encodeStructuredDispatchResult(ctx, request_id, "brain_read", .{
            .kind = "models_snapshot",
            .read_models = snapshot,
        });
    }
    return try invalidOperationEnvelope(ctx, request_id, "unsupported brain_read query");
}

fn handleMailboxRead(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    event_object: std.json.ObjectMap,
) ![]u8 {
    const query = operationSelector(event_object, "query", "kind") orelse "list";
    if (!std.mem.eql(u8, query, "list")) {
        return try invalidOperationEnvelope(ctx, request_id, "unsupported mailbox_read query");
    }
    const items = try embedded_ops.mailboxList(ctx);
    return try encodeStructuredDispatchResult(ctx, request_id, "mailbox_read", .{
        .kind = "mailbox_list",
        .items = items,
    });
}

fn handleMailboxUpdate(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    event_object: std.json.ObjectMap,
) ![]u8 {
    const action = operationSelector(event_object, "action", "kind") orelse {
        return try invalidOperationEnvelope(ctx, request_id, "missing mailbox_update action");
    };
    const event_value = std.json.Value{ .object = event_object };
    if (std.mem.eql(u8, action, "request_dream_time")) {
        const item = try embedded_ops.requestDreamTime(ctx, getStringFromObject(event_object, "prompt"));
        return try encodeStructuredDispatchResult(ctx, request_id, "mailbox_update", .{
            .kind = "request_dream_time",
            .mailbox_item = item,
        });
    }
    if (std.mem.eql(u8, action, "mark_read")) {
        if (getStringFromObject(event_object, "mailbox_id") == null) {
            return try invalidOperationEnvelope(ctx, request_id, "missing mailbox_id");
        }
        const items = try embedded_ops.mailboxMarkRead(ctx, event_value);
        return try encodeStructuredDispatchResult(ctx, request_id, "mailbox_update", .{
            .kind = "mailbox_mark_read",
            .items = items,
        });
    }
    return try invalidOperationEnvelope(ctx, request_id, "unsupported mailbox_update action");
}

fn handleBrainArchive(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    event_object: std.json.ObjectMap,
) ![]u8 {
    const action = operationSelector(event_object, "action", "kind") orelse {
        return try invalidOperationEnvelope(ctx, request_id, "missing brain_archive action");
    };
    const event_value = std.json.Value{ .object = event_object };
    if (std.mem.eql(u8, action, "export")) {
        if (getStringFromObject(event_object, "brain_file_path") == null) {
            return try invalidOperationEnvelope(ctx, request_id, "missing brain_file_path");
        }
        const manifest = try embedded_ops.exportBrain(ctx, event_value);
        return try encodeStructuredDispatchResult(ctx, request_id, "brain_archive", .{
            .kind = "brain_export",
            .manifest = manifest,
        });
    }
    if (std.mem.eql(u8, action, "import")) {
        if (getStringFromObject(event_object, "brain_file_path") == null) {
            return try invalidOperationEnvelope(ctx, request_id, "missing brain_file_path");
        }
        const manifest = try embedded_ops.importBrain(ctx, event_value);
        return try encodeStructuredDispatchResult(ctx, request_id, "brain_archive", .{
            .kind = "brain_import",
            .manifest = manifest,
        });
    }
    return try invalidOperationEnvelope(ctx, request_id, "unsupported brain_archive action");
}

fn handleDebugPrompt(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    event_object: std.json.ObjectMap,
) ![]u8 {
    const text = getStringFromObject(event_object, "text") orelse {
        return try invalidOperationEnvelope(ctx, request_id, "missing debug_prompt text");
    };
    const prompt = try ctx.brain.dryRunConversationPrompt(text);
    return try encodeLargeStructuredDispatchResult(ctx, request_id, "debug_prompt", .{
        .kind = "debug_prompt",
        .system_prompt = prompt.system_prompt,
        .user_prompt = prompt.user_prompt,
    });
}

fn encodeAcceptedResult(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8) ![]u8 {
    return try encodeStructuredDispatchResult(ctx, request_id, event_type, .{
        .kind = "accepted",
        .event_type = event_type,
        .status = "accepted",
    });
}

fn enqueueAcceptedTerminalEvent(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8) !void {
    const event_kind = try std.fmt.allocPrint(ctx.allocator(), "{s}.accepted", .{event_type});
    const title = try std.fmt.allocPrint(ctx.allocator(), "{s} accepted", .{event_type});
    try ctx.event_queue.append(ctx.allocator(), .{
        .type = "developer_log",
        .request_id = try ctx.allocator().dupe(u8, request_id),
        .kind = event_kind,
        .title = title,
        .body = try ctx.allocator().dupe(u8, "accepted"),
    });
}

fn applyHostUpdate(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_object: std.json.ObjectMap) !void {
    const update_kind = getStringFromObject(event_object, "kind") orelse "host_update";
    const event_value = std.json.Value{ .object = event_object };
    if (std.mem.eql(u8, update_kind, "host_attach")) {
        _ = try embedded_ops.hostAttach(ctx, event_value);
    } else if (std.mem.eql(u8, update_kind, "capability_manifest")) {
        _ = try embedded_ops.hostCapabilityManifest(ctx, event_value);
    } else if (std.mem.eql(u8, update_kind, "facial_expression_catalog")) {
        _ = try embedded_ops.refreshFacialExpressionCatalog(ctx);
    } else if (std.mem.eql(u8, update_kind, "capability_status")) {
        try applyHostCapabilityStatus(ctx, request_id, event_object);
    } else if (std.mem.eql(u8, update_kind, "capability_status_batch")) {
        _ = try applyHostCapabilityStatusBatch(ctx, request_id, event_object);
    } else if (std.mem.eql(u8, update_kind, "sense_catalog")) {
        _ = try senseCatalogSummary(ctx, event_object);
    } else if (std.mem.eql(u8, update_kind, "sense_status")) {
        try applySenseStatus(ctx, event_object);
    } else {
        return error.UnknownHostUpdateKind;
    }
    try enqueueAcceptedTerminalEvent(ctx, request_id, "host_update");
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

fn validateStimulusIngest(event_object: std.json.ObjectMap) ?[]const u8 {
    const kind = getStringFromObject(event_object, "kind") orelse "speech";
    if (std.mem.eql(u8, kind, "speech") or std.mem.eql(u8, kind, "text") or std.mem.eql(u8, kind, "user_text")) {
        if (getStringFromObject(event_object, "text") == null and getStringFromObject(event_object, "payload") == null) {
            return "stimulus_ingest speech requires text or payload";
        }
        return null;
    }
    if (std.mem.eql(u8, kind, "typing")) return null;
    if (std.mem.eql(u8, kind, "interrupt")) return null;
    if (std.mem.eql(u8, kind, "emoji") or std.mem.eql(u8, kind, "reaction")) {
        if (getStringFromObject(event_object, "emoji") == null and getStringFromObject(event_object, "signature") == null) {
            return "stimulus_ingest reaction requires emoji or signature";
        }
        return null;
    }
    if (std.mem.eql(u8, kind, "touch")) return null;
    if (std.mem.eql(u8, kind, "orientation")) return null;
    if (std.mem.eql(u8, kind, "motion") or std.mem.eql(u8, kind, "motion_gesture")) return null;
    if (std.mem.eql(u8, kind, "experience_event")) {
        if (getStringFromObject(event_object, "event_kind") == null) {
            return "stimulus_ingest experience_event requires event_kind";
        }
        if (getStringFromObject(event_object, "payload") == null) {
            return "stimulus_ingest experience_event requires payload";
        }
        return null;
    }
    if (std.mem.eql(u8, kind, "camera") or std.mem.eql(u8, kind, "visual")) {
        if (getStringFromObject(event_object, "path") == null and getStringFromObject(event_object, "signature") == null) {
            return "stimulus_ingest camera requires path or signature";
        }
        return null;
    }
    if (std.mem.eql(u8, kind, "poke") or std.mem.eql(u8, kind, "poke_sequence")) return null;
    if (std.mem.eql(u8, kind, "timer") or std.mem.eql(u8, kind, "reminder")) return null;
    return "unknown stimulus_ingest kind";
}

fn senseCatalogSummary(ctx: *AffectiveCoreEmbedded, event_object: std.json.ObjectMap) ![]const u8 {
    const senses = event_object.get("senses") orelse {
        return try ctx.dispatchScratch().dupe(u8, "sense_catalog: count=0");
    };
    if (senses != .array) {
        return try ctx.dispatchScratch().dupe(u8, "sense_catalog: count=0");
    }
    return try std.fmt.allocPrint(ctx.dispatchScratch(), "sense_catalog: count={d}", .{senses.array.items.len});
}

fn senseStatusSummary(ctx: *AffectiveCoreEmbedded, event_object: std.json.ObjectMap) ![]const u8 {
    const sense = getStringFromObject(event_object, "sense") orelse getStringFromObject(event_object, "sense_id") orelse "unknown";
    const status = getStringFromObject(event_object, "status") orelse "unknown";
    const reason = getStringFromObject(event_object, "reason") orelse "";
    return try std.fmt.allocPrint(ctx.dispatchScratch(), "sense_status: {s}={s} reason={s}", .{ sense, status, reason });
}

/// Hosts report pull-sense status under a "<sense>_read" capability id and may
/// omit a top-level sense field; derive the sense from the capability id then.
fn senseFromStatusEvent(event_object: std.json.ObjectMap) ?[]const u8 {
    if (getStringFromObject(event_object, "sense")) |sense| return sense;
    if (getStringFromObject(event_object, "sense_id")) |sense| return sense;
    const capability = getStringFromObject(event_object, "capability_id") orelse return null;
    const suffix = "_read";
    if (std.mem.endsWith(u8, capability, suffix) and capability.len > suffix.len) {
        return capability[0 .. capability.len - suffix.len];
    }
    return null;
}

/// A non-terminal status is the host's "accepted, still working" ack; only a
/// terminal status closes out the pull. Prefer the host's explicit flag.
fn senseStatusIsTerminal(event_object: std.json.ObjectMap, status: []const u8) bool {
    if (getBoolFromObject(event_object, "terminal")) |terminal| return terminal;
    const non_terminal = [_][]const u8{ "busy", "accepted", "fulfilled", "pending", "permission_pending", "permission_required" };
    for (non_terminal) |candidate| {
        if (std.mem.eql(u8, status, candidate)) return false;
    }
    return true;
}

fn senseStatusIsSuccess(status: []const u8) bool {
    return std.mem.eql(u8, status, "fulfilled") or
        std.mem.eql(u8, status, "available") or
        std.mem.eql(u8, status, "completed");
}

fn applySenseStatus(ctx: *AffectiveCoreEmbedded, event_object: std.json.ObjectMap) !void {
    const sense = senseFromStatusEvent(event_object) orelse return;
    const status = getStringFromObject(event_object, "status") orelse return;
    const reason = getStringFromObject(event_object, "reason") orelse "";
    const elapsed_raw = getIntegerFromObject(event_object, "elapsed_ms") orelse @as(i64, @intCast(getU32FromObject(event_object, "latency_ms") orelse 0));
    const elapsed_ms: u32 = @intCast(@max(elapsed_raw, 0));
    const purpose = if (std.mem.eql(u8, sense, "camera"))
        (if (ctx.brain.awaited_host_request) |req| req.purpose else "recognize")
    else if (std.mem.eql(u8, sense, "orientation"))
        "sample"
    else
        return;
    if (getStringFromObject(event_object, "availability")) |availability| {
        if (getStringFromObject(event_object, "capability_id")) |capability| {
            try recordSenseAvailabilityStatus(ctx, capability, availability, reason);
        }
    }
    if (!senseStatusIsTerminal(event_object, status)) return;
    try host_capability_activation.recordHostSensePullOutcome(&ctx.brain, sense, purpose, status, reason, elapsed_ms);
    if (!senseStatusIsSuccess(status)) {
        _ = ctx.brain.fulfillAwaitedHostRequestIfMatches(sense, purpose);
    }
}

fn recordSenseAvailabilityStatus(ctx: *AffectiveCoreEmbedded, capability_id: []const u8, availability: []const u8, reason: []const u8) !void {
    try ctx.brain.recordCapabilityStatus(.{
        .capability_id = capability_id,
        .host_id = ctx.brain.currentHostId(),
        .permission = .unknown,
        .availability = embedded_ops.availabilityFromString(availability),
        .quality = 0.0,
        .reliability = 0.0,
        .cost = 0.0,
        .latency_ms = 0,
        .risk = 0.0,
        .unavailable_reason = reason,
        .updated_at_ms = ctx.brain.now_seconds * 1000,
    });
}

fn applyHostCapabilityStatus(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_object: std.json.ObjectMap) !void {
    const capability = getStringFromObject(event_object, "capability_id") orelse "";
    if (capability.len == 0) return;
    const availability = getStringFromObject(event_object, "availability") orelse "unavailable";
    try ctx.brain.recordCapabilityStatus(.{
        .capability_id = capability,
        .host_id = getStringFromObject(event_object, "host_id") orelse try ctx.dispatchScratch().dupe(u8, ctx.brain.currentHostId()),
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
    if (!std.mem.eql(u8, capability, "camera") and !std.mem.eql(u8, capability, "camera_read")) return;

    if (std.mem.eql(u8, availability, "pending") or std.mem.eql(u8, availability, "degraded")) {
        const pending_request_id = getStringFromObject(event_object, "request_id") orelse request_id;
        const reason = getStringFromObject(event_object, "unavailable_reason") orelse "host capability pending";
        ctx.pending_camera_permission = .{
            .request_id = try ctx.dispatchScratch().dupe(u8, pending_request_id),
            .pending_since_unix_ms = getIntegerFromObject(event_object, "pending_since_unix_ms") orelse 0,
            .reason = try ctx.dispatchScratch().dupe(u8, reason),
        };
        return;
    }

    if (std.mem.eql(u8, availability, "available") or std.mem.eql(u8, availability, "refused") or std.mem.eql(u8, availability, "unavailable")) {
        ctx.pending_camera_permission = null;
    }

    // A camera that the host reports gone is terminal for any awaited camera
    // pull: clear it so the scheduler stops holding user turns behind it.
    if (std.mem.eql(u8, availability, "refused") or std.mem.eql(u8, availability, "unavailable")) {
        if (ctx.brain.awaitingHostSense("camera")) {
            ctx.brain.clearAwaitedHostRequest();
        }
    }
}

fn applyHostCapabilityStatusBatch(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_object: std.json.ObjectMap) !usize {
    const statuses_value = event_object.get("statuses") orelse return error.MissingCapabilityStatuses;
    if (statuses_value != .array) return error.ExpectedCapabilityStatusArray;
    var persist = try ctx.brain.deps.store.deferredPersistGuard();
    const count = applyHostCapabilityStatusBatchInner(ctx, request_id, statuses_value.array.items) catch |err| {
        persist.cancel() catch return error.DeferredPersistEndFailed;
        return err;
    };
    try persist.commit();
    return count;
}

fn applyHostCapabilityStatusBatchInner(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    statuses: []std.json.Value,
) !usize {
    for (statuses) |item| {
        if (item != .object) return error.ExpectedCapabilityStatusObject;
        try applyHostCapabilityStatus(ctx, request_id, item.object);
    }
    return statuses.len;
}

fn hostCapabilityStatusSummary(ctx: *AffectiveCoreEmbedded, event_object: std.json.ObjectMap) ![]const u8 {
    const capability = getStringFromObject(event_object, "capability_id") orelse "unknown";
    const status = getStringFromObject(event_object, "availability") orelse "unknown";
    const elapsed = getIntegerFromObject(event_object, "pending_elapsed_ms") orelse 0;
    const reason = getStringFromObject(event_object, "unavailable_reason") orelse "";
    return try std.fmt.allocPrint(ctx.dispatchScratch(), "capability_status: {s}={s} pending_elapsed_ms={d} reason={s}", .{ capability, status, elapsed, reason });
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
    try ensureAwaitedHostSenseRequestEvent(ctx);
    stampAwaitedHostSenseTimeouts(ctx);
    const activity_id = ctx.brain.activeActivityId() orelse "";
    const compacted_events = try context_gate.compactEvents(ctx.dispatchScratch(), ctx.brain.now_seconds, request_id, activity_id, embedded.hostEvents(ctx), ctx.context_budget);
    try persistRawRefs(ctx, compacted_events.raw_refs);
    const envelope_events = try filterSuppressedEvents(ctx, compacted_events.events);

    const value_json = try std.json.Stringify.valueAlloc(ctx.dispatchScratch(), value, .{});
    defer ctx.dispatchScratch().free(value_json);
    const budget = try context_gate.budgetWithResult(ctx.dispatchScratch(), compacted_events.budget, value_json.len, &.{}, false);
    var timings = try finishDispatchTimings(ctx);
    defer deinitDispatchTimingsReport(ctx, &timings);
    const output = try embedded_protocol.successEnvelopeAlloc(std.heap.page_allocator, request_id, envelope_events, .{
        .event_type = event_type,
        .value = value,
    }, budget, timings, ctx.brain.dispatchContextReportView());
    if (output.len <= ctx.context_budget.max_envelope_bytes) return output;
    std.heap.page_allocator.free(output);

    const slim_budget = context_gate.BudgetReport{
        .max_bytes = ctx.context_budget.max_envelope_bytes,
        .used_bytes = value_json.len,
        .compacted = true,
        .dropped_event_count = envelope_events.len,
        .raw_refs = &.{},
    };
    const slim = try embedded_protocol.successEnvelopeCompactAlloc(std.heap.page_allocator, request_id, &[_]embedded_protocol.HostEvent{}, .{
        .event_type = event_type,
        .value = value,
    }, slim_budget, request_timings.empty_report, null);
    if (slim.len <= ctx.context_budget.max_envelope_bytes) return slim;
    std.heap.page_allocator.free(slim);

    const message = try std.fmt.allocPrint(
        ctx.dispatchScratch(),
        "dispatch envelope_bytes={d} value_bytes={d} max_envelope_bytes={d}",
        .{ slim.len, value_json.len, ctx.context_budget.max_envelope_bytes },
    );
    defer ctx.dispatchScratch().free(message);
    return try embedded_protocol.errorEnvelopeAlloc(
        std.heap.page_allocator,
        request_id,
        "envelope_too_large",
        message,
        false,
        slim_budget,
        timings,
        null,
    );
}

fn encodeLargeStructuredDispatchResult(
    ctx: *AffectiveCoreEmbedded,
    request_id: []const u8,
    event_type: []const u8,
    value: anytype,
) ![]u8 {
    try ensureAwaitedHostSenseRequestEvent(ctx);
    stampAwaitedHostSenseTimeouts(ctx);
    const activity_id = ctx.brain.activeActivityId() orelse "";
    const compacted_events = try context_gate.compactEvents(ctx.dispatchScratch(), ctx.brain.now_seconds, request_id, activity_id, embedded.hostEvents(ctx), ctx.context_budget);
    try persistRawRefs(ctx, compacted_events.raw_refs);
    const envelope_events = try filterSuppressedEvents(ctx, compacted_events.events);

    const value_json = try std.json.Stringify.valueAlloc(ctx.dispatchScratch(), value, .{});
    defer ctx.dispatchScratch().free(value_json);
    const budget = try context_gate.budgetWithResult(ctx.dispatchScratch(), compacted_events.budget, value_json.len, &.{}, false);
    var timings = try finishDispatchTimings(ctx);
    defer deinitDispatchTimingsReport(ctx, &timings);
    return try embedded_protocol.successEnvelopeAlloc(std.heap.page_allocator, request_id, envelope_events, .{
        .event_type = event_type,
        .value = value,
    }, budget, timings, ctx.brain.dispatchContextReportView());
}

/// When a host pull is still pending (restored activity or a deduped recognize retry),
/// the host still needs a `sense_request` event in the envelope. Capture only emits one
/// on the first pull attempt; re-emit here when awaiting state outlives that attempt.
fn ensureAwaitedHostSenseRequestEvent(ctx: *AffectiveCoreEmbedded) !void {
    const req = ctx.brain.awaited_host_request orelse return;
    const effects = ctx.host_effects orelse return;
    for (effects.events.items) |event| {
        if (!std.mem.eql(u8, event.type, "sense_request")) continue;
        const sense = event.sense orelse continue;
        if (std.mem.eql(u8, sense, req.sense)) return;
    }
    const body = try std.fmt.allocPrint(
        ctx.dispatchScratch(),
        "The frontend should fulfill host pull sense {s} for purpose {s}.",
        .{ req.sense, req.purpose },
    );
    defer ctx.dispatchScratch().free(body);
    if (std.mem.eql(u8, req.sense, "camera")) {
        try effects.appendCaptureRequested("webcam photo", body);
    } else {
        try effects.appendSenseRequested(req.sense, req.sense, body);
    }
}

fn stampAwaitedHostSenseTimeouts(ctx: *AffectiveCoreEmbedded) void {
    const req = ctx.brain.awaited_host_request orelse return;
    const effects = ctx.host_effects orelse return;
    for (effects.events.items) |*event| {
        if (!std.mem.eql(u8, event.type, "sense_request")) continue;
        const sense = event.sense orelse continue;
        if (!std.mem.eql(u8, sense, req.sense)) continue;
        event.timeout_ms = req.timeout_ms;
    }
}

pub fn filterSuppressedEvents(ctx: *AffectiveCoreEmbedded, events: []const embedded_protocol.HostEvent) ![]const embedded_protocol.HostEvent {
    const camera_permission_pending = ctx.pending_camera_permission != null;
    const camera_reported_gone = host_capability_activation.hostSenseReportedUnavailable(&ctx.brain, "camera");
    if (!camera_permission_pending and !camera_reported_gone) return events;
    // While a permission prompt is pending, only the awaited recognize pull may
    // keep asking; while the host reports the camera gone, nothing may — asking
    // again before a capability_status flips back just re-feeds the loop.
    const awaiting_camera = ctx.brain.awaitedHostRequestMatches("camera", "recognize");
    const suppress_camera = camera_reported_gone or !awaiting_camera;
    var filtered = std.ArrayList(embedded_protocol.HostEvent).empty;
    for (events) |event| {
        if (suppress_camera and std.mem.eql(u8, event.type, "sense_request") and event.sense != null and std.mem.eql(u8, event.sense.?, "camera")) continue;
        try filtered.append(ctx.dispatchScratch(), event);
    }
    return try filtered.toOwnedSlice(ctx.dispatchScratch());
}

fn encodeErrorResult(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8, code: []const u8, err: anyerror) ![]u8 {
    _ = event_type;
    const detail = try error_descriptions.formatFailureDetail(ctx.dispatchScratch(), err, ctx.brain.chatParseFailureBody());
    defer ctx.dispatchScratch().free(detail);
    const message = try std.fmt.allocPrint(ctx.dispatchScratch(), "{s}: {s}", .{ error_descriptions.name(err), detail });
    defer ctx.dispatchScratch().free(message);
    return errorEnvelopeWithTimings(ctx, request_id, code, message, false, emptyBudget(ctx));
}

pub fn persistRawRefs(ctx: *AffectiveCoreEmbedded, raw_refs: []const context_gate.RawRef) !void {
    for (raw_refs) |raw_ref| {
        const path = try rawRefPath(ctx.dispatchScratch(), ctx.brain.cfg.brain_root, raw_ref.id);
        try writeFilePath(ctx.io(), path, raw_ref.bytes);
    }
}

pub fn lookupRawRef(ctx: *AffectiveCoreEmbedded, raw_ref: []const u8) ![]const u8 {
    if (!validRawRef(raw_ref)) return error.InvalidRawRef;
    if (rawRefExpired(ctx, raw_ref)) return error.RawRefExpired;
    const path = try rawRefPath(ctx.dispatchScratch(), ctx.brain.cfg.brain_root, raw_ref);
    return readFileAllocPath(ctx.io(), path, ctx.dispatchScratch(), .limited(8 * 1024 * 1024));
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

fn getBoolFromObject(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
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

fn applyHostStimulusContext(brain: *brain_mod.Brain, event_object: std.json.ObjectMap) !void {
    const context_value = event_object.get("context") orelse return;
    if (context_value != .object) return;
    const context = context_value.object;
    const kind = getStringFromObject(context, "kind");
    const received_during = getStringFromObject(context, "received_during");
    const idle_seconds = getIntegerFromObject(context, "host_idle_seconds");
    try brain.setHostStimulusMetadata(kind, received_during, idle_seconds);
}

fn emitInnerStateHostEvents(ctx: *AffectiveCoreEmbedded) !void {
    const effects = ctx.host_effects orelse return;
    const snapshot = try ctx.brain.readModelsSnapshot(ctx.dispatchScratch());
    if (snapshot.need_model.top_needs.len > 0) {
        var summary = std.ArrayList(u8).empty;
        defer summary.deinit(ctx.dispatchScratch());
        for (snapshot.need_model.top_needs) |need| {
            try summary.print(ctx.dispatchScratch(), "- {s}: {s}\n", .{ need.text, need.urgency });
        }
        try effects.appendNeedState(summary.items);
    }
    if (snapshot.focus_model.text) |focus| {
        try effects.appendAttentionState(focus, null);
    }
    if (snapshot.inner_state_model.active_intention) |intention| {
        try effects.appendIntention(intention.goal, intention.expected_action);
    }
    if (snapshot.inner_state_model.latest_appraisal) |appraisal| {
        if (appraisal.summary) |summary| try effects.appendAppraisal(summary);
    }
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

pub fn applyQueuedMessage(ctx: *AffectiveCoreEmbedded, request_json: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, ctx.dispatchScratch(), request_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const root = parsed.value.object;
    const request_id = getStringFromObject(root, "request_id") orelse "";
    const event = root.get("event") orelse return error.InvalidRequest;
    if (event != .object) return error.InvalidRequest;
    const event_object = event.object;
    const event_type = getStringFromObject(event_object, "type") orelse return error.InvalidRequest;
    const operation = publicOperation(event_type) orelse return error.InvalidRequest;
    switch (operation) {
        .stimulus_ingest => {
            if (validateStimulusIngest(event_object) != null) return error.InvalidRequest;
            try applyIngestEvent(ctx, event_type, event_object);
        },
        .host_update => try applyHostUpdate(ctx, request_id, event_object),
        .brain_step, .brain_read, .mailbox_read, .mailbox_update, .brain_archive, .debug_prompt => return error.InvalidRequest,
        else => try enqueueAcceptedTerminalEvent(ctx, request_id, event_type),
    }
}

pub fn applyIngestFromRequestJson(ctx: *AffectiveCoreEmbedded, request_json: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, ctx.dispatchScratch(), request_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const root = parsed.value.object;
    const event = root.get("event") orelse return error.InvalidRequest;
    if (event != .object) return error.InvalidRequest;
    const event_object = event.object;
    const event_type = getStringFromObject(event_object, "type") orelse return error.InvalidRequest;
    if (validateStimulusIngest(event_object) != null) return error.InvalidRequest;
    try applyIngestEvent(ctx, event_type, event_object);
}

pub fn applyIngestEvent(ctx: *AffectiveCoreEmbedded, event_type: []const u8, event_object: std.json.ObjectMap) !void {
    if (std.mem.eql(u8, event_type, "stimulus_ingest")) {
        try applyHostStimulusContext(&ctx.brain, event_object);
        const kind = getStringFromObject(event_object, "kind") orelse "speech";
        if (std.mem.eql(u8, kind, "speech") or std.mem.eql(u8, kind, "text") or std.mem.eql(u8, kind, "user_text")) {
            const text = getStringFromObject(event_object, "text") orelse getStringFromObject(event_object, "payload") orelse return;
            try stimulus_ingest_mod.ingestHeardSpeech(&ctx.brain, text, .typed_text);
            return;
        }
        if (std.mem.eql(u8, kind, "typing")) {
            const text = getStringFromObject(event_object, "text") orelse getStringFromObject(event_object, "payload") orelse "";
            try stimulus_ingest_mod.ingestTyping(&ctx.brain, text);
            return;
        }
        if (std.mem.eql(u8, kind, "interrupt")) {
            const text = getStringFromObject(event_object, "text") orelse getStringFromObject(event_object, "payload") orelse "";
            const reason = getStringFromObject(event_object, "reason") orelse "user_interrupt";
            const interrupted_action = getStringFromObject(event_object, "interrupted_action") orelse "unknown";
            const canceled_count = getIntegerFromObject(event_object, "canceled_queued_action_count") orelse 0;
            try stimulus_ingest_mod.ingestInterrupt(&ctx.brain, reason, interrupted_action, text, canceled_count);
            return;
        }
        if (std.mem.eql(u8, kind, "emoji") or std.mem.eql(u8, kind, "reaction")) {
            const emoji = getStringFromObject(event_object, "emoji") orelse getStringFromObject(event_object, "signature") orelse return;
            const utterance_text = getStringFromObject(event_object, "utterance_text") orelse getStringFromObject(event_object, "payload") orelse "";
            const summary = try std.fmt.allocPrint(ctx.dispatchScratch(), "emoji={s} utterance={s}", .{ emoji, utterance_text });
            _ = try stimulus_ingest_mod.ingestStimulus(&ctx.brain, .{
                .kind = .reaction,
                .source = getStringFromObject(event_object, "source") orelse "affective_host",
                .signature = emoji,
                .payload = summary,
                .raw_magnitude = @floatCast(@min(@max(getNumberFromObject(event_object, "raw_magnitude") orelse 0.55, 0), 1)),
                .curiosity = 0.40,
            });
            return;
        }
        if (std.mem.eql(u8, kind, "touch")) {
            const gesture = getStringFromObject(event_object, "gesture") orelse getStringFromObject(event_object, "signature") orelse "touch";
            const summary = getStringFromObject(event_object, "summary") orelse getStringFromObject(event_object, "payload") orelse "Touch observed.";
            const duration_class = getStringFromObject(event_object, "duration_class") orelse "";
            const metadata = try std.fmt.allocPrint(ctx.dispatchScratch(), "gesture={s} duration_class={s} summary={s}", .{ gesture, duration_class, summary });
            const observation_line = try std.fmt.allocPrint(ctx.dispatchScratch(), "touch: {s}", .{summary});
            const ingested = try stimulus_ingest_mod.ingestStimulus(&ctx.brain, .{
                .kind = .touch,
                .source = getStringFromObject(event_object, "source") orelse "affective_touch",
                .signature = gesture,
                .payload = observation_line,
                .raw_magnitude = @floatCast(@min(@max(getNumberFromObject(event_object, "raw_magnitude") orelse 0.45, 0), 1)),
                .curiosity = 0.40,
                .metadata = metadata,
            });
            if (brain_process.activeConversationPresent(&ctx.brain)) {
                try brain_process.recordSenseDuringConversation(&ctx.brain, "touch", observation_line, ingested.event_id);
            }
            return;
        }
        if (std.mem.eql(u8, kind, "orientation")) {
            const summary = getStringFromObject(event_object, "summary") orelse getStringFromObject(event_object, "payload") orelse "Orientation observed.";
            const posture = getStringFromObject(event_object, "posture") orelse getStringFromObject(event_object, "signature") orelse "unknown";
            const confidence = getNumberFromObject(event_object, "confidence") orelse getNumberFromObject(event_object, "raw_magnitude") orelse 0;
            const metadata = try std.fmt.allocPrint(ctx.dispatchScratch(), "posture={s} confidence={d:.2} summary={s}", .{ posture, confidence, summary });
            const observation_line = try std.fmt.allocPrint(ctx.dispatchScratch(), "orientation: {s}", .{summary});
            const ingested = try stimulus_ingest_mod.ingestStimulus(&ctx.brain, .{
                .kind = .orientation,
                .source = getStringFromObject(event_object, "source") orelse "affective_orientation",
                .signature = posture,
                .payload = observation_line,
                .raw_magnitude = @floatCast(@min(@max(confidence, 0), 1)),
                .curiosity = 0.12,
                .metadata = metadata,
            });
            if (brain_process.activeConversationPresent(&ctx.brain)) {
                try brain_process.recordSenseDuringConversation(&ctx.brain, "orientation", observation_line, ingested.event_id);
            }
            return;
        }
        if (std.mem.eql(u8, kind, "motion") or std.mem.eql(u8, kind, "motion_gesture")) {
            const gesture = getStringFromObject(event_object, "gesture") orelse getStringFromObject(event_object, "signature") orelse "unknown";
            const summary = getStringFromObject(event_object, "summary") orelse getStringFromObject(event_object, "payload") orelse "Motion gesture observed.";
            const confidence = getNumberFromObject(event_object, "confidence") orelse getNumberFromObject(event_object, "raw_magnitude") orelse 0;
            const metadata = try std.fmt.allocPrint(ctx.dispatchScratch(), "gesture={s} confidence={d:.2} summary={s}", .{ gesture, confidence, summary });
            const observation_line = try std.fmt.allocPrint(ctx.dispatchScratch(), "motion_gesture: {s}", .{summary});
            const ingested = try stimulus_ingest_mod.ingestStimulus(&ctx.brain, .{
                .kind = .touch,
                .source = getStringFromObject(event_object, "source") orelse "affective_motion_gesture",
                .signature = gesture,
                .payload = observation_line,
                .raw_magnitude = @floatCast(@min(@max(confidence, 0), 1)),
                .curiosity = 0.25,
                .metadata = metadata,
            });
            if (brain_process.activeConversationPresent(&ctx.brain)) {
                try brain_process.recordSenseDuringConversation(&ctx.brain, "motion_gesture", observation_line, ingested.event_id);
            }
            return;
        }
        if (std.mem.eql(u8, kind, "camera") or std.mem.eql(u8, kind, "visual")) {
            const path = getStringFromObject(event_object, "path") orelse getStringFromObject(event_object, "signature") orelse return;
            const source = getStringFromObject(event_object, "source") orelse "affective_camera";
            const mime_type = getStringFromObject(event_object, "mime_type") orelse "image/jpeg";
            const owned_path = try ctx.brain.allocator.dupe(u8, path);
            ctx.brain.rememberVisualUpdate(owned_path);
            const metadata = try std.fmt.allocPrint(ctx.brain.allocator, "path={s} mime_type={s} source={s}", .{ owned_path, mime_type, source });
            const observation_line = try std.fmt.allocPrint(ctx.dispatchScratch(), "sensed_image:\n- image: {s}\n- source: {s}\n", .{ path, source });
            const ingested = try stimulus_ingest_mod.ingestStimulus(&ctx.brain, .{
                .kind = .visual,
                .source = "affective_camera",
                .signature = owned_path,
                .payload = observation_line,
                .raw_magnitude = @floatCast(@min(@max(getNumberFromObject(event_object, "raw_magnitude") orelse 0.75, 0), 1)),
                .curiosity = 0.50,
                .metadata = metadata,
            });
            if (brain_process.activeConversationPresent(&ctx.brain)) {
                try brain_process.recordSenseDuringConversation(&ctx.brain, @tagName(ingested.packet.kind), observation_line, ingested.event_id);
            }
            return;
        }
        if (std.mem.eql(u8, kind, "poke") or std.mem.eql(u8, kind, "poke_sequence")) {
            const summary = getStringFromObject(event_object, "summary") orelse getStringFromObject(event_object, "payload") orelse "poke_sequence";
            _ = try stimulus_ingest_mod.ingestStimulus(&ctx.brain, .{
                .kind = .poke_sequence,
                .source = getStringFromObject(event_object, "source") orelse "affective_host",
                .signature = getStringFromObject(event_object, "signature") orelse summary,
                .payload = summary,
                .raw_magnitude = @floatCast(@min(@max(getNumberFromObject(event_object, "raw_magnitude") orelse 0.50, 0), 1)),
                .curiosity = 0.40,
                .metadata = summary,
            });
            return;
        }
        const payload = getStringFromObject(event_object, "payload") orelse getStringFromObject(event_object, "summary") orelse kind;
        _ = try stimulus_ingest_mod.ingestStimulus(&ctx.brain, .{
            .kind = .timer,
            .source = getStringFromObject(event_object, "source") orelse "affective_host",
            .signature = getStringFromObject(event_object, "signature") orelse kind,
            .payload = payload,
            .raw_magnitude = @floatCast(@min(@max(getNumberFromObject(event_object, "raw_magnitude") orelse 0.25, 0), 1)),
            .curiosity = 0.25,
            .metadata = payload,
        });
        return;
    }
}

pub fn isQueueableWhileBusyEventType(event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, "stimulus_ingest") or
        std.mem.eql(u8, event_type, "host_update");
}

pub fn queuedAckKind(event_type: []const u8) []const u8 {
    if (std.mem.eql(u8, event_type, "host_update")) return "host_update_queued";
    return "stimulus_queued";
}

pub fn encodeQueuedAck(_: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8) ![]u8 {
    const budget = context_gate.BudgetReport{
        .max_bytes = 16 * 1024,
        .used_bytes = 0,
        .compacted = false,
        .dropped_event_count = 0,
        .raw_refs = &.{},
    };
    return embedded_protocol.successEnvelopeCompactAlloc(std.heap.page_allocator, request_id, &[_]embedded_protocol.HostEvent{}, .{
        .event_type = event_type,
        .value = .{ .kind = queuedAckKind(event_type) },
    }, budget, request_timings.empty_report, null);
}

pub fn encodeStimulusQueued(ctx: *AffectiveCoreEmbedded, request_id: []const u8) ![]u8 {
    return encodeQueuedAck(ctx, request_id, "stimulus_ingest");
}
