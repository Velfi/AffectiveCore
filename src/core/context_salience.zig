const chat = @import("port_chat.zig");

pub const ObservationKind = enum {
    present_moment,
    deferred_coherence,
    user_text,
    heard_speech,
    host_sense_delivered,
    subsystem_pressure_selected,
    subsystem_pressure_suppressed,
    overlap_nudge,
    stimulus_response_nudge,
    orchestration_nudge,
    speaker_recognition,
    pending_user_interrupt_coalesce,
    uploaded_media,
    checkpoint_resume,
    pending_hard_error,
    active_activity,
    waiting_for,
    memory_selection,
    skill_library,
    host_capability_summary,
    conversation_cotext,
    salient_sense,
    salient_sense_during_conversation,
    emoji_reaction,
    emoji_reaction_during_conversation,
    host_sense_pull_requested,
    host_capability_activations,
    read_models_snapshot,
    attention_capacity,
    recent_experience,
    stimulus_continuity,
    associative_recall,
    social_context,
    recognition_dedup,
    memory_retrieval,
    introspect_result,
    skill_result,
    skill_failed,
    prior_outward_reply,
    action_suppressed,
    facial_expression_catalog,
    capability_execution,
    other,

    pub fn name(self: ObservationKind) []const u8 {
        return @tagName(self);
    }
};

pub const MemoryKind = enum {
    focus,
    speaker,
    relevant_memories,
    needs,
    self_facts,
    persona_directive,
    relationship_graph,
    day_arc,
    memory_index,
    conversation_summaries,
    known_processes,

    pub fn name(self: MemoryKind) []const u8 {
        return @tagName(self);
    }
};

pub const ContextSectionKind = union(enum) {
    observation: ObservationKind,
    memory: MemoryKind,

    pub fn sectionName(self: ContextSectionKind) []const u8 {
        return switch (self) {
            .observation => |kind| kind.name(),
            .memory => |kind| kind.name(),
        };
    }
};

const max_rank: u16 = 100;
const contact_open_demote: u16 = 30;

fn clampRank(rank: i32) u16 {
    if (rank <= 0) return 0;
    if (rank >= max_rank) return max_rank;
    return @intCast(rank);
}

fn observationBaseRank(kind: ObservationKind) struct { rank: u16, protected: bool } {
    return switch (kind) {
        .present_moment => .{ .rank = 100, .protected = true },
        .deferred_coherence => .{ .rank = 98, .protected = true },
        .user_text => .{ .rank = 97, .protected = true },
        .heard_speech => .{ .rank = 96, .protected = true },
        .host_sense_delivered => .{ .rank = 95, .protected = true },
        .subsystem_pressure_selected => .{ .rank = 94, .protected = true },
        .overlap_nudge => .{ .rank = 93, .protected = true },
        .stimulus_response_nudge => .{ .rank = 92, .protected = true },
        .orchestration_nudge => .{ .rank = 91, .protected = true },
        .speaker_recognition => .{ .rank = 90, .protected = true },
        .pending_user_interrupt_coalesce => .{ .rank = 88, .protected = false },
        .uploaded_media => .{ .rank = 85, .protected = false },
        .checkpoint_resume => .{ .rank = 84, .protected = false },
        .pending_hard_error => .{ .rank = 99, .protected = true },
        .active_activity => .{ .rank = 70, .protected = false },
        .waiting_for => .{ .rank = 68, .protected = false },
        .memory_selection => .{ .rank = 65, .protected = false },
        .skill_library => .{ .rank = 62, .protected = false },
        .host_capability_summary => .{ .rank = 60, .protected = false },
        .conversation_cotext => .{ .rank = 58, .protected = false },
        .salient_sense => .{ .rank = 75, .protected = false },
        .salient_sense_during_conversation => .{ .rank = 74, .protected = false },
        .emoji_reaction => .{ .rank = 72, .protected = false },
        .emoji_reaction_during_conversation => .{ .rank = 71, .protected = false },
        .host_sense_pull_requested => .{ .rank = 55, .protected = false },
        .host_capability_activations => .{ .rank = 35, .protected = false },
        .read_models_snapshot => .{ .rank = 30, .protected = false },
        .attention_capacity => .{ .rank = 28, .protected = false },
        .recent_experience => .{ .rank = 25, .protected = false },
        .stimulus_continuity => .{ .rank = 22, .protected = false },
        .associative_recall => .{ .rank = 20, .protected = false },
        .social_context => .{ .rank = 18, .protected = false },
        .recognition_dedup => .{ .rank = 50, .protected = false },
        .memory_retrieval => .{ .rank = 52, .protected = false },
        .introspect_result => .{ .rank = 80, .protected = false },
        .skill_result => .{ .rank = 78, .protected = false },
        .skill_failed => .{ .rank = 76, .protected = false },
        .prior_outward_reply => .{ .rank = 45, .protected = false },
        .action_suppressed => .{ .rank = 77, .protected = false },
        .facial_expression_catalog => .{ .rank = 40, .protected = false },
        .capability_execution => .{ .rank = 42, .protected = false },
        .subsystem_pressure_suppressed => .{ .rank = 48, .protected = false },
        .other => .{ .rank = 10, .protected = false },
    };
}

fn memoryBaseRank(kind: MemoryKind) struct { rank: u16, protected: bool } {
    return switch (kind) {
        .focus => .{ .rank = 95, .protected = true },
        .speaker => .{ .rank = 92, .protected = true },
        .relevant_memories => .{ .rank = 90, .protected = true },
        .needs => .{ .rank = 65, .protected = false },
        .self_facts => .{ .rank = 60, .protected = false },
        .known_processes => .{ .rank = 58, .protected = false },
        .persona_directive => .{ .rank = 110, .protected = true },
        .relationship_graph => .{ .rank = 35, .protected = false },
        .day_arc => .{ .rank = 25, .protected = false },
        .memory_index => .{ .rank = 20, .protected = false },
        .conversation_summaries => .{ .rank = 15, .protected = false },
    };
}

fn observationStimulusBoost(kind: ObservationKind, stimulus: chat.StimulusKind) i16 {
    return switch (stimulus) {
        .heard_speech => switch (kind) {
            .user_text, .heard_speech, .speaker_recognition, .memory_selection, .present_moment => 8,
            else => 0,
        },
        .host_sense_delivery => switch (kind) {
            .deferred_coherence, .host_sense_delivered, .present_moment => 10,
            else => 0,
        },
        .orchestration => switch (kind) {
            .salient_sense, .present_moment, .active_activity => 10,
            else => 0,
        },
        .reconsideration => switch (kind) {
            .salient_sense, .salient_sense_during_conversation, .present_moment, .active_activity, .emoji_reaction, .emoji_reaction_during_conversation => 10,
            else => 0,
        },
    };
}

fn memoryStimulusBoost(kind: MemoryKind, stimulus: chat.StimulusKind) i16 {
    return switch (stimulus) {
        .heard_speech => switch (kind) {
            .speaker, .relevant_memories, .focus => 8,
            else => 0,
        },
        .host_sense_delivery => switch (kind) {
            .relevant_memories, .focus => 5,
            else => 0,
        },
        .orchestration, .reconsideration => switch (kind) {
            .focus, .needs => 5,
            else => 0,
        },
    };
}

fn contactOpenDemotion(kind: ContextSectionKind) i16 {
    return switch (kind) {
        .memory => |mem| switch (mem) {
            .conversation_summaries, .day_arc => @intCast(contact_open_demote),
            else => 0,
        },
        .observation => 0,
    };
}

pub fn observationRank(kind: ObservationKind, stimulus: chat.StimulusKind, contact_open: bool) u16 {
    const base = observationBaseRank(kind);
    var rank: i32 = @as(i32, base.rank) + observationStimulusBoost(kind, stimulus);
    if (contact_open) {
        rank -= contactOpenDemotion(.{ .observation = kind });
    }
    return clampRank(rank);
}

pub fn memoryRank(kind: MemoryKind, stimulus: chat.StimulusKind, contact_open: bool) u16 {
    const base = memoryBaseRank(kind);
    var rank: i32 = @as(i32, base.rank) + memoryStimulusBoost(kind, stimulus);
    if (contact_open) {
        rank -= contactOpenDemotion(.{ .memory = kind });
    }
    return clampRank(rank);
}

pub fn sectionRank(kind: ContextSectionKind, stimulus: chat.StimulusKind, contact_open: bool) u16 {
    return switch (kind) {
        .observation => |obs| observationRank(obs, stimulus, contact_open),
        .memory => |mem| memoryRank(mem, stimulus, contact_open),
    };
}

pub fn isObservationProtected(kind: ObservationKind) bool {
    return observationBaseRank(kind).protected;
}

pub fn isMemoryProtected(kind: MemoryKind) bool {
    return memoryBaseRank(kind).protected;
}

pub fn isProtected(kind: ContextSectionKind) bool {
    return switch (kind) {
        .observation => |obs| isObservationProtected(obs),
        .memory => |mem| isMemoryProtected(mem),
    };
}

pub fn makeObservationBlock(
    kind: ObservationKind,
    text: []const u8,
    stimulus: chat.StimulusKind,
    contact_open: bool,
) struct { kind: ContextSectionKind, text: []const u8, rank: u16, protected: bool } {
    return .{
        .kind = .{ .observation = kind },
        .text = text,
        .rank = observationRank(kind, stimulus, contact_open),
        .protected = isObservationProtected(kind),
    };
}

pub fn makeMemoryBlock(
    kind: MemoryKind,
    text: []const u8,
    stimulus: chat.StimulusKind,
    contact_open: bool,
) struct { kind: ContextSectionKind, text: []const u8, rank: u16, protected: bool } {
    return .{
        .kind = .{ .memory = kind },
        .text = text,
        .rank = memoryRank(kind, stimulus, contact_open),
        .protected = isMemoryProtected(kind),
    };
}
