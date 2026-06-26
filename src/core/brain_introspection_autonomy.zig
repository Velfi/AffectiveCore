const std = @import("std");
const brain_mod = @import("brain.zig");
const config_mod = @import("config.zig");
const events = @import("events.zig");
const facts = @import("facts.zig");
const greeting = @import("greeting_policy.zig");
const identity = @import("identity.zig");
const interrupt_mod = @import("interrupt.zig");
const state_mod = @import("state.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const store_mod = ports.store;
const graph_store = ports.graph_store;
const intent_mod = ports.intent;
const openai = ports.openai;
const greeting_client = ports.greeting;
const speech_mod = ports.speech;
const chat_mod = ports.chat;
const skills_mod = ports.skills;
const email_mod = ports.email;
const autonomy_mod = ports.autonomy;
const psyche_client = ports.psyche;
const want_achievement_mod = ports.want_achievement;
const image_mod = ports.image;
const audio_mod = ports.audio;
const camera_mod = ports.camera;
const speaker_mod = ports.speaker;
const input_mod = ports.input;
const button_mod = ports.button;
const command_log_mod = ports.command_log;
const facial_expression = ports.facial_expression;
const system_senses_mod = ports.system_senses;
const time_mod = @import("time.zig");
const maintenance = @import("maintenance.zig");
const id_monitor = @import("id_monitor.zig");
const needs_mod = @import("needs.zig");
const psyche_mod = @import("psyche.zig");
const seed_mod = @import("seed.zig");
const vector_index = @import("vector_index.zig");
const emotion = @import("emotion.zig");
const process = ports.process;
const helpers = @import("brain_helpers.zig");
const brain_autonomy = @import("brain_autonomy.zig");

const Brain = brain_mod.Brain;
const BrainDeps = brain_mod.BrainDeps;
const CommandBatchResult = brain_mod.CommandBatchResult;
const ConversationTurnResult = brain_mod.ConversationTurnResult;
const ConversationSpeakerContext = brain_mod.Brain.ConversationSpeakerContext;
const QuietHours = brain_mod.Brain.QuietHours;
const SelfDirectiveKind = brain_mod.Brain.SelfDirectiveKind;
const SpeechArtifactSweepResult = brain_mod.SpeechArtifactSweepResult;
const MediaKind = helpers.MediaKind;
const remote_thinking_failure_message = brain_mod.remote_thinking_failure_message;
const speech_artifact_ttl_seconds = brain_mod.speech_artifact_ttl_seconds;
const speech_artifact_prefix = brain_mod.speech_artifact_prefix;
const speech_audio_suffix = brain_mod.speech_audio_suffix;
const speech_transcription_json_suffix = brain_mod.speech_transcription_json_suffix;

const IntrospectionFieldSize = struct {
    name: []const u8 = "none",
    bytes: usize = 0,

    fn note(self: *IntrospectionFieldSize, name: []const u8, bytes: usize) void {
        if (bytes > self.bytes) {
            self.* = .{ .name = name, .bytes = bytes };
        }
    }

    fn trace(self: IntrospectionFieldSize, brain: *Brain) void {
        brain.outputFmt("TRACE now={d} stage=introspect.largest_field name={s} bytes={d}\n", .{ brain.now_seconds, self.name, self.bytes });
    }
};

fn traceIntrospectionLoad(self: *Brain, name: []const u8, count: usize) void {
    self.outputFmt("TRACE now={d} stage=introspect.load.done name={s} count={d}\n", .{ self.now_seconds, name, count });
}

pub fn introspect(self: *Brain) ![]const u8 {
    self.outputFmt("TRACE now={d} stage=introspect.start\n", .{self.now_seconds});
    const can_read_memory = capabilityAvailable(self, .stored_memory_read);
    self.outputFmt("TRACE now={d} stage=introspect.memory_capability available={any}\n", .{ self.now_seconds, can_read_memory });
    const memories = if (can_read_memory) blk: {
        const loaded = try self.deps.store.loadMemoryRecords(self.allocator);
        traceIntrospectionLoad(self, "memory_records", loaded.len);
        break :blk loaded;
    } else &[_]schema.MemoryRecord{};
    const summaries = if (can_read_memory) blk: {
        const loaded = try self.deps.store.loadConversationSummaries(self.allocator);
        traceIntrospectionLoad(self, "conversation_summaries", loaded.len);
        break :blk loaded;
    } else &[_]schema.ConversationSummary{};
    const impressions = if (can_read_memory) blk: {
        const loaded = try self.deps.store.loadImpressions(self.allocator);
        traceIntrospectionLoad(self, "impressions", loaded.len);
        break :blk loaded;
    } else &[_]schema.Impression{};
    const appraisals = if (can_read_memory) blk: {
        const loaded = try self.deps.store.loadAppraisals(self.allocator);
        traceIntrospectionLoad(self, "appraisals", loaded.len);
        break :blk loaded;
    } else &[_]schema.Appraisal{};
    const dreams = if (can_read_memory) blk: {
        const loaded = try self.deps.store.loadDreamRecords(self.allocator);
        traceIntrospectionLoad(self, "dreams", loaded.len);
        break :blk loaded;
    } else &[_]schema.DreamRecord{};
    var largest = IntrospectionFieldSize{};
    var long_count: usize = 0;
    var short_count: usize = 0;
    var score_total: i64 = 0;
    var access_total: u64 = 0;
    var salient: ?schema.MemoryRecord = null;
    for (memories) |memory| {
        switch (memory.scope) {
            .long_term => long_count += 1,
            .short_term => short_count += 1,
        }
        score_total += memory.score;
        access_total += memory.access_count;
        if (salient == null or helpers.memoryIsMoreSalient(memory, salient.?)) salient = memory;
    }
    const salient_text = if (salient) |memory| try memoryOneLineSummary(self, memory) else "none yet";
    largest.note("salient_memory", salient_text.len);
    largest.trace(self);
    const recent_appraisal = if (appraisals.len > 0) appraisals[appraisals.len - 1].freeform else "none yet";
    largest.note("recent_appraisal", recent_appraisal.len);
    largest.trace(self);
    const affordances = try affordanceCatalog(self);
    largest.note("skills", affordances.len);
    largest.trace(self);
    const autonomy_status = try brain_autonomy.autonomyIntrospection(self);
    largest.note("autonomy_status", autonomy_status.len);
    largest.trace(self);
    const needs_status = try activeNeedsSummary(self);
    largest.note("needs_status", needs_status.len);
    largest.trace(self);
    const flexible_identity_status = try flexibleIdentitySummary(self, memories);
    largest.note("flexible_identity_status", flexible_identity_status.len);
    largest.trace(self);
    const self_facts = try selfFactsSummary(self);
    largest.note("self_facts", self_facts.len);
    largest.trace(self);
    const senses = try sensesSummary(self);
    largest.note("senses", senses.len);
    largest.trace(self);
    const capabilities = try capabilityCatalog(self);
    largest.note("capabilities", capabilities.len);
    largest.trace(self);
    const memory_status = if (can_read_memory)
        try std.fmt.allocPrint(self.allocator, "{d} long-term, {d} short-term, {d} recent summaries", .{ long_count, short_count, summaries.len })
    else
        try std.fmt.allocPrint(self.allocator, "unavailable: {s}", .{try capabilityUnavailableReason(self, .stored_memory_read)});
    largest.note("memory_status", memory_status.len);
    largest.trace(self);
    const focus_status = try focusStatusSummary(self);
    largest.note("focus", focus_status.len);
    largest.trace(self);
    return std.fmt.allocPrint(
        self.allocator,
        "introspection:\n{s}- senses: {s}\n- capabilities:\n{s}- memory: {s}\n- impressions={d} appraisals={d} dreams={d}\n- memory_score_total: {d}\n- memory_access_total: {d}\n- salient_memory: {s}\n- recent_appraisal: {s}\n- focus: {s}\n- uncertainty/human_needs: ask_human is available when an appraisal needs human help, clarification, or permission; use think_about for private reflection or model-mediated judgment\n{s}{s}{s}\n- skills:\n{s}",
        .{ self_facts, senses, capabilities, memory_status, impressions.len, appraisals.len, dreams.len, score_total, access_total, salient_text, recent_appraisal, focus_status, autonomy_status, needs_status, flexible_identity_status, affordances },
    );
}

/// One-line view of working memory for the introspect summary.
fn focusStatusSummary(self: *Brain) ![]const u8 {
    if (self.focusMode() == .focused) {
        if (self.current_focus) |focus| {
            const level = self.currentFocusAttention() orelse focus.base_attention;
            return std.fmt.allocPrint(self.allocator, "focused ({s}): {s} (attention={d:.3})", .{ @tagName(focus.source), focus.text, level });
        }
        return self.allocator.dupe(u8, "focused");
    }
    return self.allocator.dupe(u8, "unfocused");
}

pub fn memoryOneLineSummary(self: *Brain, memory: schema.MemoryRecord) ![]const u8 {
    const raw = helpers.memoryInterpretation(memory);
    const first_line_end = std.mem.indexOfScalar(u8, raw, '\n') orelse raw.len;
    const first_line = raw[0..first_line_end];
    const max_len: usize = 160;
    const summary = if (first_line.len > max_len)
        try std.fmt.allocPrint(self.allocator, "{s}...", .{first_line[0..max_len]})
    else
        first_line;
    return std.fmt.allocPrint(
        self.allocator,
        "{s} ({s}; score={d}; salience={d:.3})",
        .{ summary, memory.memory_id, memory.score, memory.salience },
    );
}

pub fn affordanceObservation(self: *Brain) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try appendAffordanceObservation(self, &out);
    return out.toOwnedSlice(self.allocator);
}

pub fn appendAffordanceObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(self.allocator, "Current skill availability:\n");
    try appendAffordanceCatalog(self, out);
}

pub fn affordanceCatalog(self: *Brain) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try appendAffordanceCatalog(self, &out);
    return out.toOwnedSlice(self.allocator);
}

pub fn appendAffordanceCatalog(self: *Brain, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(self.allocator, "callable:\n");
    inline for (@typeInfo(chat_mod.ChatCommandType).@"enum".fields) |field| {
        const command: chat_mod.ChatCommandType = @field(chat_mod.ChatCommandType, field.name);
        if (chat_mod.commandSpec(command)) |spec| {
            if (commandIsAvailable(self, command)) {
                try out.print(self.allocator, "- {s}: {s}\n", .{ skills_mod.name(command), spec.description });
            }
        }
    }
}

pub fn commandUnavailableReason(self: *Brain, command: chat_mod.ChatCommandType) !?[]const u8 {
    var visiting = [_]bool{false} ** @typeInfo(chat_mod.ChatCommandType).@"enum".fields.len;
    return skillUnavailableReason(self, command, &visiting);
}

pub fn commandIsAvailable(self: *Brain, command: chat_mod.ChatCommandType) bool {
    var visiting = [_]bool{false} ** @typeInfo(chat_mod.ChatCommandType).@"enum".fields.len;
    return skillIsAvailable(self, command, &visiting);
}

pub fn skillIsAvailable(self: *Brain, command: chat_mod.ChatCommandType, visiting: *[@typeInfo(chat_mod.ChatCommandType).@"enum".fields.len]bool) bool {
    const spec = skills_mod.spec(command) orelse return false;
    const index = @intFromEnum(command);
    if (visiting[index]) return false;
    visiting[index] = true;
    defer visiting[index] = false;

    if (command == .describe_image) {
        if (!senseAvailable(self, .visual_description)) return false;
        if (!senseAvailable(self, .live_camera) and !senseAvailable(self, .stored_image_read)) return false;
    } else {
        for (spec.requires_senses) |sense| {
            if (!senseAvailable(self, sense)) return false;
        }
    }
    for (spec.requires_skills) |required| {
        if (!skillIsAvailable(self, required, visiting)) return false;
    }
    return true;
}

pub fn skillUnavailableReason(self: *Brain, command: chat_mod.ChatCommandType, visiting: *[@typeInfo(chat_mod.ChatCommandType).@"enum".fields.len]bool) !?[]const u8 {
    const spec = skills_mod.spec(command) orelse return "unknown skill";
    const index = @intFromEnum(command);
    if (visiting[index]) return error.CyclicSkillDependency;
    visiting[index] = true;
    defer visiting[index] = false;

    if (command == .describe_image) {
        if (!senseAvailable(self, .visual_description)) return try capabilityUnavailableReason(self, .visual_description);
        if (!senseAvailable(self, .live_camera) and !senseAvailable(self, .stored_image_read)) return "no live camera or uploaded image is available for this body";
    } else {
        for (spec.requires_senses) |sense| {
            if (!senseAvailable(self, sense)) return try capabilityUnavailableReason(self, sense);
        }
    }
    for (spec.requires_skills) |required| {
        if (try skillUnavailableReason(self, required, visiting)) |reason| {
            return try std.fmt.allocPrint(self.allocator, "required skill {s} unavailable: {s}", .{ skills_mod.name(required), reason });
        }
    }
    return null;
}

pub fn capabilityAvailable(self: *Brain, capability: chat_mod.Capability) bool {
    return senseAvailable(self, capability);
}

pub fn senseAvailable(self: *Brain, capability: chat_mod.Capability) bool {
    if (!self.deps.capabilities.has(capability)) return false;
    return switch (capability) {
        .stored_image_read => self.last_visual_observation_path != null,
        .reminder_io => self.deps.io != null,
        .orientation_query => self.deps.orientation_query != null,
        .email_delivery => self.deps.email_service != null,
        .local_process_io => self.deps.io != null,
        .audio_classification, .audio_transcription => self.deps.audio_inspection_service != null,
        .video_inspection => false,
        .facial_expression_output => self.deps.facial_expression_output != null,
        else => true,
    };
}

pub fn capabilityUnavailableReason(self: *Brain, capability: chat_mod.Capability) ![]const u8 {
    if (!self.deps.capabilities.has(capability)) {
        return skills_mod.senseUnavailableReason(capability);
    }
    return switch (capability) {
        .stored_image_read => "there is no previous retained visual observation to read or compare",
        .reminder_io => "local reminder I/O is unavailable",
        .orientation_query => if (self.deps.orientation_query == null)
            "orientation query is not configured"
        else
            "orientation query is unavailable",
        .email_delivery => if (self.deps.email_service == null)
            "email service is not configured"
        else
            "email delivery is unavailable",
        .local_process_io => "local process I/O is unavailable",
        .audio_classification => "audio classification service is not configured",
        .audio_transcription => "audio transcription service is not configured",
        .video_inspection => "video inspection is not configured",
        .facial_expression_output => if (self.deps.facial_expression_output == null)
            "facial expression output is not configured"
        else
            "facial expression output is unavailable",
        else => try std.fmt.allocPrint(self.allocator, "{s} is unavailable", .{@tagName(capability)}),
    };
}

pub fn capabilityCatalog(self: *Brain) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    inline for (@typeInfo(chat_mod.Capability).@"enum".fields) |field| {
        const capability: chat_mod.Capability = @field(chat_mod.Capability, field.name);
        if (capabilityAvailable(self, capability)) {
            try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "- {s}: available\n", .{field.name}));
        } else {
            try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "- {s}: unavailable: {s}\n", .{ field.name, try capabilityUnavailableReason(self, capability) }));
        }
    }
    return out.toOwnedSlice(self.allocator);
}

pub fn sensesSummary(self: *Brain) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.allocator, "camera, image description, image comparison, microphone transcription, speech output, date/time");
    const power = try self.deps.system_senses.power(self.allocator);
    var has_battery = false;
    var has_external = false;
    for (power.supplies) |supply| {
        if (std.mem.eql(u8, supply.kind, "Battery")) {
            has_battery = true;
        } else if (supply.online != null) {
            has_external = true;
        }
    }
    if (has_battery) try out.appendSlice(self.allocator, ", battery level");
    if (has_external) try out.appendSlice(self.allocator, ", plugged-in power state");
    const storage = try self.deps.system_senses.storage(self.allocator);
    if (storage.volumes.len > 0) try out.appendSlice(self.allocator, ", storage fullness");
    const database = try self.deps.system_senses.database(self.allocator);
    if (database.databases.len > 0) try out.appendSlice(self.allocator, ", database statistics");
    try out.appendSlice(self.allocator, ", Nano Banana image generation");
    if (capabilityAvailable(self, .email_delivery)) try out.appendSlice(self.allocator, ", email delivery");
    return out.toOwnedSlice(self.allocator);
}

pub fn timeObservation(self: *Brain) ![]const u8 {
    const datetime = try self.deps.system_senses.datetime(self.allocator);
    _ = try self.observeSenseStimulus(.{
        .kind = .time,
        .source = "system_senses",
        .signature = "datetime",
        .raw_magnitude = 0.15,
        .curiosity = 0.05,
        .metadata = "time sense read",
    });
    return system_senses_mod.formatDateTime(self.allocator, datetime);
}

pub fn powerObservation(self: *Brain) ![]const u8 {
    const power = try self.deps.system_senses.power(self.allocator);
    const metrics = powerSenseMetrics(power);
    const signature = try std.fmt.allocPrint(self.allocator, "power:battery:external={any}", .{metrics.external_online});
    _ = try self.observeSenseStimulus(.{
        .kind = .power,
        .source = "system_senses",
        .signature = signature,
        .raw_magnitude = metrics.raw_magnitude,
        .threat = metrics.threat,
        .curiosity = 0.12,
        .safety_relevant = metrics.threat >= 0.35,
        .metadata = "power sense read",
    });
    return system_senses_mod.formatPower(self.allocator, power);
}

pub fn storageObservation(self: *Brain) ![]const u8 {
    const storage = try self.deps.system_senses.storage(self.allocator);
    const max_used = maxStorageUsedPercent(storage);
    const signature = "storage:max_used";
    _ = try self.observeSenseStimulus(.{
        .kind = .storage,
        .source = "system_senses",
        .signature = signature,
        .raw_magnitude = @as(f32, @floatFromInt(max_used)) / 100.0,
        .threat = storageThreat(max_used),
        .curiosity = 0.10,
        .safety_relevant = max_used >= 90,
        .metadata = "storage sense read",
    });
    return system_senses_mod.formatStorage(self.allocator, storage);
}

pub fn databaseObservation(self: *Brain) ![]const u8 {
    const database = try self.deps.system_senses.database(self.allocator);
    const total_bytes = totalDatabaseBytes(database);
    const signature = try std.fmt.allocPrint(self.allocator, "database:count={d}:mb={d}", .{ database.databases.len, total_bytes / (1024 * 1024) });
    _ = try self.observeSenseStimulus(.{
        .kind = .database,
        .source = "system_senses",
        .signature = signature,
        .raw_magnitude = @min(1.0, @as(f32, @floatFromInt(@min(total_bytes, 512 * 1024 * 1024))) / @as(f32, @floatFromInt(512 * 1024 * 1024))),
        .threat = if (total_bytes >= 512 * 1024 * 1024) 0.30 else 0,
        .curiosity = 0.10,
        .metadata = "database sense read",
    });
    return system_senses_mod.formatDatabase(self.allocator, database);
}

const PowerMetrics = struct {
    min_battery_percent: ?u8 = null,
    external_online: bool = false,
    raw_magnitude: f32 = 0.15,
    threat: f32 = 0,
};

fn powerSenseMetrics(power: system_senses_mod.PowerSnapshot) PowerMetrics {
    var out = PowerMetrics{};
    for (power.supplies) |supply| {
        if (supply.online) |online| out.external_online = out.external_online or online;
        if (!std.mem.eql(u8, supply.kind, "Battery")) continue;
        const capacity = supply.capacity_percent orelse continue;
        out.min_battery_percent = if (out.min_battery_percent) |current| @min(current, capacity) else capacity;
    }
    if (out.min_battery_percent) |capacity| {
        out.raw_magnitude = 1.0 - (@as(f32, @floatFromInt(capacity)) / 100.0);
        if (!out.external_online and capacity <= 5) out.threat = 0.95 else if (!out.external_online and capacity <= 15) out.threat = 0.65 else if (!out.external_online and capacity <= 30) out.threat = 0.35;
    }
    return out;
}

fn maxStorageUsedPercent(storage: system_senses_mod.StorageSnapshot) u8 {
    var max_used: u8 = 0;
    for (storage.volumes) |volume| max_used = @max(max_used, volume.used_percent);
    return max_used;
}

fn storageThreat(max_used: u8) f32 {
    if (max_used >= 98) return 0.85;
    if (max_used >= 90) return 0.55;
    if (max_used >= 80) return 0.25;
    return 0;
}

fn totalDatabaseBytes(database: system_senses_mod.DatabaseSnapshot) u64 {
    var total: u64 = 0;
    for (database.databases) |db| total += db.total_bytes;
    return total;
}

pub fn selfFactsSummary(self: *Brain) ![]const u8 {
    const records = try self.deps.store.loadFactRecords(self.allocator);
    return facts.formatSummary(self.allocator, records, self.now_seconds);
}

pub fn activeNeedsSummary(self: *Brain) ![]const u8 {
    const summaries = try self.deps.store.loadConversationSummaries(self.allocator);
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    const power = try self.deps.system_senses.power(self.allocator);
    const autonomy_state = try brain_autonomy.autonomyStateForNeeds(self);
    const active_needs = try needs_mod.evaluate(self.allocator, .{
        .now_seconds = self.now_seconds,
        .conversation_summaries = summaries,
        .memory_records = memories,
        .relationship_graph = try self.deps.graph.summary(self.allocator, 8),
        .power = power,
        .autonomy_energy_remaining = if (autonomy_state) |state| state.energy_remaining else null,
        .autonomy_daily_energy = self.cfg.autonomy_daily_energy,
        .autonomy_sleeping = if (autonomy_state) |state| state.sleeping else null,
    });
    return needs_mod.formatNeeds(self.allocator, active_needs);
}

pub fn flexibleIdentitySummary(self: *Brain, memories: []const schema.MemoryRecord) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.allocator, "flexible_identity_box:\n");
    var count: usize = 0;
    for (memories) |memory| {
        if (!helpers.tagInSlice(memory.tags, "flexible_identity") or !helpers.tagInSlice(memory.tags, "pending_dream_reconciliation")) continue;
        count += 1;
        try out.print(self.allocator, "- {s}: salience={d:.3}; score={d}; text={s}\n", .{ memory.memory_id, memory.salience, memory.score, helpers.memoryInterpretation(memory) });
    }
    if (count == 0) try out.appendSlice(self.allocator, "- none\n");
    return out.toOwnedSlice(self.allocator);
}

pub fn superegoSelfModelSummary(self: *Brain, memories: []const schema.MemoryRecord) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var count: usize = 0;
    for (memories) |memory| {
        if (!helpers.tagInSlice(memory.tags, "superego_principle")) continue;
        if (helpers.tagInSlice(memory.tags, "pending_dream_reconciliation")) continue;
        count += 1;
        try out.print(self.allocator, "- principle:{s}: {s}; confidence={d:.2}; salience={d:.2}\n", .{
            memory.memory_id,
            helpers.memoryInterpretation(memory),
            memory.confidence,
            memory.salience,
        });
    }
    if (count == 0) try out.appendSlice(self.allocator, "- none\n");
    return out.toOwnedSlice(self.allocator);
}
