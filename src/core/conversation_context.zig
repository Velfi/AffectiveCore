const std = @import("std");
const brain_mod = @import("brain.zig");
const chat = @import("port_chat.zig");
const ports = @import("ports.zig");
const input_mod = ports.input;
const memory_selection_mod = @import("memory_selection.zig");
const context_composition = @import("context_composition.zig");
const context_salience = @import("context_salience.zig");
const present_moment = @import("present_moment.zig");
const brain_process = @import("brain_process.zig");
const conversation_cotext = @import("conversation_cotext.zig");
const experiential_observations = @import("experiential_observations.zig");
const host_capability_activation = @import("host_capability_activation.zig");
const subsystems = @import("subsystems.zig");
const awaited_host_request_mod = @import("awaited_host_request.zig");
const brain_dream_memory = @import("brain_dream_memory.zig");
const brain_introspection_autonomy = @import("brain_introspection_autonomy.zig");
const brain_action_execution = @import("brain_action_execution.zig");
const brain_observation_append = @import("brain_observation_append.zig");
const stimulus_ingest_mod = @import("stimulus_ingest.zig");

const Brain = brain_mod.Brain;
const ContextBlock = context_composition.ContextBlock;

pub const HostDeliveryOpts = struct {
    delivered_line: []const u8,
    assessment: present_moment.DeliveryAssessment,
    bind: ?awaited_host_request_mod.BoundSnapshot,
    include_checkpoint: bool = true,
};

pub const ComposeOptions = struct {
    stimulus: chat.StimulusKind,
    user_text: ?[]const u8 = null,
    heard_speech: ?input_mod.HeardSpeech = null,
    speaker_memory_line: ?[]const u8 = null,
    memory_selection: ?memory_selection_mod.ResolvedMemorySelection = null,
    host_delivery: ?HostDeliveryOpts = null,
    preamble: ?[]const u8 = null,
    subsystem_event_ids: []const []const u8 = &.{},
    overlap_nudge: bool = false,
    pending_hard_error: bool = false,
    stimulus_response_nudge_initial: bool = false,
    timer_fired_intent: ?[]const u8 = null,
    extra_preamble: ?[]const u8 = null,
    include_heard_speech: bool = false,
    include_pending_interrupt_coalesce: bool = false,
    include_uploaded_media: bool = false,
    include_affordances: bool = false,
    include_social_context: bool = false,
    include_read_models: bool = false,
    include_active_activity: bool = false,
    include_conversation_cotext: bool = false,
    include_present_moment: bool = false,
    include_stimulus_continuity: bool = false,
    include_stimulus_inbox: bool = false,
    include_waiting_for: bool = false,
    include_memory_selection_obs: bool = false,
    include_associative_recall: bool = false,
    include_host_capability: bool = false,
    include_host_capability_activation: bool = false,
    include_subsystems: bool = false,
};

fn observationKindFromPreamble(text: []const u8) context_salience.ObservationKind {
    if (std.mem.startsWith(u8, text, "salient_sense_during_conversation:")) return .salient_sense_during_conversation;
    if (std.mem.startsWith(u8, text, "salient_sense:")) return .salient_sense;
    if (std.mem.startsWith(u8, text, "emoji_reaction_during_conversation:")) return .emoji_reaction_during_conversation;
    if (std.mem.startsWith(u8, text, "emoji_reaction:")) return .emoji_reaction;
    return .other;
}

fn appendOwnedBlock(
    allocator: std.mem.Allocator,
    blocks: *std.ArrayList(ContextBlock),
    kind: context_salience.ContextSectionKind,
    text: []const u8,
    stimulus: chat.StimulusKind,
    contact_open: bool,
    order: *usize,
    count: ?usize,
) !void {
    if (text.len == 0) return;
    try blocks.append(allocator, .{
        .kind = kind,
        .text = try allocator.dupe(u8, text),
        .rank = context_salience.sectionRank(kind, stimulus, contact_open),
        .protected = context_salience.isProtected(kind),
        .order_index = order.*,
        .count = count,
    });
    order.* += 1;
}

fn captureObservation(
    allocator: std.mem.Allocator,
    blocks: *std.ArrayList(ContextBlock),
    kind: context_salience.ObservationKind,
    stimulus: chat.StimulusKind,
    contact_open: bool,
    order: *usize,
    build: *const fn (*Brain, *std.ArrayList(u8)) anyerror!void,
    brain: *Brain,
) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try build(brain, &buf);
    try appendOwnedBlock(allocator, blocks, .{ .observation = kind }, buf.items, stimulus, contact_open, order, null);
}

pub fn composeObservations(self: *Brain, opts: ComposeOptions) ![]ContextBlock {
    const contact_open = present_moment.contactWindowOpen(self);
    var blocks = std.ArrayList(ContextBlock).empty;
    errdefer freeObservationBlocks(self.allocator, blocks.items);
    var order: usize = 0;
    const allocator = self.allocator;
    self.trace("conversation.compose_observations.start");

    if (opts.preamble) |preamble| {
        const kind = observationKindFromPreamble(preamble);
        try appendOwnedBlock(allocator, &blocks, .{ .observation = kind }, preamble, opts.stimulus, contact_open, &order, null);
    }
    if (opts.extra_preamble) |preamble| {
        const kind = observationKindFromPreamble(preamble);
        try appendOwnedBlock(allocator, &blocks, .{ .observation = kind }, preamble, opts.stimulus, contact_open, &order, null);
    }
    if (opts.timer_fired_intent) |intent| {
        const line = try std.fmt.allocPrint(allocator, "timer_fired:\n- intent: {s}\n- note: you scheduled this wait; reconsider whether to speak, continue focus, or wait again.\n", .{intent});
        try appendOwnedBlock(allocator, &blocks, .{ .observation = .waiting_for }, line, opts.stimulus, contact_open, &order, null);
    }

    if (opts.include_heard_speech) {
        const heard = opts.heard_speech orelse return error.MissingHeardSpeechForObservation;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try brain_dream_memory.appendHeardSpeechObservation(self, &buf, heard);
        try appendOwnedBlock(allocator, &blocks, .{ .observation = .heard_speech }, buf.items, opts.stimulus, contact_open, &order, null);
        self.trace("conversation.compose_observations.heard_speech.done");
    }

    if (opts.include_pending_interrupt_coalesce) {
        try captureObservation(allocator, &blocks, .pending_user_interrupt_coalesce, opts.stimulus, contact_open, &order, brain_observation_append.appendPendingUserInterruptCoalesceObservation, self);
    }

    if (opts.speaker_memory_line) |line| {
        try appendOwnedBlock(allocator, &blocks, .{ .observation = .speaker_recognition }, line, opts.stimulus, contact_open, &order, null);
    }

    if (opts.include_uploaded_media) {
        const user_text = opts.user_text orelse return error.MissingUserTextForUploadedMedia;
        if (try self.uploadedMediaObservation(user_text)) |line| {
            try appendOwnedBlock(allocator, &blocks, .{ .observation = .uploaded_media }, line, opts.stimulus, contact_open, &order, null);
        }
    }

    if (opts.host_delivery) |delivery| {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try brain_observation_append.appendHostSenseDeliveredObservation(self, &buf, delivery.delivered_line);
        try appendOwnedBlock(allocator, &blocks, .{ .observation = .host_sense_delivered }, buf.items, opts.stimulus, contact_open, &order, null);

        buf.clearRetainingCapacity();
        try present_moment.appendDeferredCoherenceObservation(self, &buf, delivery.delivered_line, delivery.assessment, delivery.bind);
        try appendOwnedBlock(allocator, &blocks, .{ .observation = .deferred_coherence }, buf.items, opts.stimulus, contact_open, &order, null);

        if (delivery.include_checkpoint) {
            if (self.active_activity) |active| {
                if (active.checkpoint) |checkpoint| {
                    const slice_len = @min(checkpoint.observations.len, 512);
                    const checkpoint_text = try std.fmt.allocPrint(allocator, "checkpoint_resume:\n{s}\n", .{checkpoint.observations[0..slice_len]});
                    try appendOwnedBlock(allocator, &blocks, .{ .observation = .checkpoint_resume }, checkpoint_text, opts.stimulus, contact_open, &order, null);
                }
            }
        }
    }

    if (opts.include_affordances) {
        try captureObservation(allocator, &blocks, .skill_library, opts.stimulus, contact_open, &order, brain_introspection_autonomy.appendAffordanceObservation, self);
        self.trace("conversation.compose_observations.affordances.done");
    }
    if (opts.include_social_context) {
        try captureObservation(allocator, &blocks, .social_context, opts.stimulus, contact_open, &order, brain_observation_append.appendSocialContextObservation, self);
    }
    if (opts.include_read_models) {
        try captureObservation(allocator, &blocks, .read_models_snapshot, opts.stimulus, contact_open, &order, brain_observation_append.appendReadModelsObservation, self);
        self.trace("conversation.compose_observations.read_models.done");
    }
    if (opts.include_active_activity) {
        try captureObservation(allocator, &blocks, .active_activity, opts.stimulus, contact_open, &order, brain_process.appendActivityObservation, self);
    }
    if (opts.include_conversation_cotext) {
        try captureObservation(allocator, &blocks, .conversation_cotext, opts.stimulus, contact_open, &order, conversation_cotext.appendConversationCotextObservation, self);
    }
    if (opts.include_present_moment) {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        const overlap = if (opts.user_text) |text| present_moment.detectRequestOverlap(self, text) else null;
        try present_moment.appendObservation(self, &buf, opts.user_text, overlap);
        try appendOwnedBlock(allocator, &blocks, .{ .observation = .present_moment }, buf.items, opts.stimulus, contact_open, &order, null);
    }

    if (opts.overlap_nudge) {
        const line = "overlap_nudge: user_request_overlap shows work in flight — acknowledge with a brief say; do not start a duplicate host pull.\n";
        try appendOwnedBlock(allocator, &blocks, .{ .observation = .overlap_nudge }, line, opts.stimulus, contact_open, &order, null);
    }

    if (opts.include_stimulus_inbox) {
        try captureObservation(allocator, &blocks, .other, opts.stimulus, contact_open, &order, stimulus_ingest_mod.appendStimulusInboxObservation, self);
    }
    if (opts.include_stimulus_continuity) {
        const heard = opts.heard_speech orelse return error.MissingHeardSpeechForStimulusContinuity;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try experiential_observations.appendStimulusContinuityObservation(self, &buf, heard);
        try appendOwnedBlock(allocator, &blocks, .{ .observation = .stimulus_continuity }, buf.items, opts.stimulus, contact_open, &order, null);
    }
    if (opts.include_waiting_for) {
        try captureObservation(allocator, &blocks, .waiting_for, opts.stimulus, contact_open, &order, experiential_observations.appendWaitingForObservation, self);
    }
    if (opts.include_memory_selection_obs) {
        const selection = opts.memory_selection orelse return error.MissingMemorySelectionForObservation;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try memory_selection_mod.appendMemorySelectionObservation(allocator, &buf, selection);
        try appendOwnedBlock(allocator, &blocks, .{ .observation = .memory_selection }, buf.items, opts.stimulus, contact_open, &order, null);
    }
    if (opts.include_associative_recall) {
        const user_text = opts.user_text orelse return error.MissingUserTextForAssociativeRecall;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try experiential_observations.appendAssociativeRecallObservation(self, &buf, user_text);
        try appendOwnedBlock(allocator, &blocks, .{ .observation = .associative_recall }, buf.items, opts.stimulus, contact_open, &order, null);
        self.trace("conversation.compose_observations.associative_recall.done");
    }
    if (opts.include_host_capability) {
        try captureObservation(allocator, &blocks, .host_capability_summary, opts.stimulus, contact_open, &order, brain_observation_append.appendHostCapabilityObservationIfChanged, self);
        self.trace("conversation.compose_observations.host_capability.done");
    }
    if (opts.include_host_capability_activation) {
        try captureObservation(allocator, &blocks, .host_capability_activations, opts.stimulus, contact_open, &order, host_capability_activation.appendActivationObservationIfChanged, self);
        self.trace("conversation.compose_observations.host_capability_activation.done");
    }
    if (opts.include_subsystems) {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        var turn_source_event_ids: [1][]const u8 = undefined;
        const source_event_ids: []const []const u8 = if (self.current_turn_event_id) |id| blk: {
            turn_source_event_ids = .{id};
            break :blk turn_source_event_ids[0..];
        } else opts.subsystem_event_ids;
        self.trace("conversation.compose_observations.subsystems.start");
        try subsystems.appendSubsystemObservations(self, allocator, &buf, .{
            .source_event_ids = source_event_ids,
            .focus = if (self.current_focus) |focus| focus.text else null,
        });
        if (buf.items.len > 0) {
            try appendOwnedBlock(allocator, &blocks, .{ .observation = .subsystem_pressure_selected }, buf.items, opts.stimulus, contact_open, &order, null);
        }
        self.trace("conversation.compose_observations.subsystems.done");
    }
    if (opts.pending_hard_error) {
        try captureObservation(allocator, &blocks, .pending_hard_error, opts.stimulus, contact_open, &order, brain_action_execution.appendPendingHardErrorObservation, self);
    }
    if (opts.stimulus_response_nudge_initial) {
        try appendOwnedBlock(allocator, &blocks, .{ .observation = .stimulus_response_nudge }, chat.heard_speech_stimulus_response_nudge_initial, opts.stimulus, contact_open, &order, null);
    }

    self.traceCount("conversation.compose_observations.done", blocks.items.len);
    return try blocks.toOwnedSlice(allocator);
}

pub fn freeObservationBlocks(allocator: std.mem.Allocator, blocks: []ContextBlock) void {
    for (blocks) |block| allocator.free(block.text);
    if (blocks.len > 0) allocator.free(blocks);
}

pub fn freeMemoryBlocks(allocator: std.mem.Allocator, blocks: []ContextBlock) void {
    freeObservationBlocks(allocator, blocks);
}

pub fn finalizeConversationContext(
    allocator: std.mem.Allocator,
    memory_blocks: []ContextBlock,
    observation_blocks: []ContextBlock,
    user_text: []const u8,
    stimulus: chat.StimulusKind,
    max_tokens: usize,
) !context_composition.TrimResult {
    return context_composition.trimToTokenBudget(
        allocator,
        memory_blocks,
        observation_blocks,
        user_text,
        stimulus,
        max_tokens,
    );
}

pub fn heardSpeechComposeOptions(
    _: *Brain,
    heard_speech: input_mod.HeardSpeech,
    speaker_memory_line: ?[]const u8,
    memory_selection: memory_selection_mod.ResolvedMemorySelection,
    overlap_nudge: bool,
    pending_hard_error: bool,
) ComposeOptions {
    return .{
        .stimulus = .heard_speech,
        .user_text = heard_speech.text,
        .heard_speech = heard_speech,
        .speaker_memory_line = speaker_memory_line,
        .memory_selection = memory_selection,
        .overlap_nudge = overlap_nudge,
        .pending_hard_error = pending_hard_error,
        .stimulus_response_nudge_initial = true,
        .include_heard_speech = true,
        .include_pending_interrupt_coalesce = true,
        .include_uploaded_media = true,
        .include_affordances = true,
        .include_social_context = true,
        .include_read_models = true,
        .include_active_activity = true,
        .include_conversation_cotext = true,
        .include_present_moment = true,
        .include_stimulus_inbox = true,
        .include_stimulus_continuity = true,
        .include_waiting_for = true,
        .include_memory_selection_obs = true,
        .include_associative_recall = true,
        .include_host_capability = true,
        .include_host_capability_activation = true,
        .include_subsystems = true,
    };
}

pub fn hostDeliveryComposeOptions(user_text: ?[]const u8, delivery: HostDeliveryOpts) ComposeOptions {
    return .{
        .stimulus = .host_sense_delivery,
        .user_text = user_text,
        .host_delivery = delivery,
        .include_affordances = true,
        .include_read_models = true,
        .include_active_activity = true,
        .include_conversation_cotext = true,
        .include_present_moment = true,
        .include_stimulus_inbox = true,
        .include_waiting_for = true,
        .include_host_capability = true,
        .include_host_capability_activation = true,
        .include_subsystems = true,
    };
}

pub fn reconsiderComposeOptions(user_text: ?[]const u8, preamble: ?[]const u8, include_cotext: bool) ComposeOptions {
    return .{
        .stimulus = .reconsideration,
        .user_text = user_text,
        .preamble = preamble,
        .include_affordances = true,
        .include_read_models = true,
        .include_active_activity = true,
        .include_conversation_cotext = include_cotext,
        .include_present_moment = true,
        .include_stimulus_inbox = true,
        .include_waiting_for = true,
        .include_host_capability = true,
        .include_host_capability_activation = true,
        .include_subsystems = true,
    };
}

pub fn orchestrationComposeOptions(preamble: []const u8, user_text: []const u8) ComposeOptions {
    return .{
        .stimulus = .orchestration,
        .user_text = user_text,
        .preamble = preamble,
        .include_affordances = true,
        .include_read_models = true,
        .include_active_activity = true,
        .include_present_moment = true,
        .include_waiting_for = true,
        .include_host_capability = true,
        .include_host_capability_activation = true,
        .include_subsystems = true,
    };
}

pub fn reminderComposeOptions(intent_text: []const u8, user_text: []const u8) ComposeOptions {
    return .{
        .stimulus = .reconsideration,
        .user_text = user_text,
        .timer_fired_intent = intent_text,
        .include_affordances = true,
        .include_read_models = true,
        .include_active_activity = true,
        .include_present_moment = true,
        .include_waiting_for = true,
        .include_host_capability = true,
        .include_host_capability_activation = true,
    };
}

pub fn dryRunComposeOptions(user_text: []const u8) ComposeOptions {
    return .{
        .stimulus = .heard_speech,
        .user_text = user_text,
        .include_affordances = true,
    };
}
