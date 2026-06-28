const std = @import("std");
const chat = @import("../port_chat.zig");
const context_composition = @import("../context_composition.zig");
const context_tokens = @import("../context_tokens.zig");
const brain_actor = @import("brain_actor.zig");
const payloads = @import("payloads.zig");

pub const TurnInput = struct {
    memory: []const u8,
    user_text: []const u8,
    observations: []const u8,
    now_ms: i64,
    turn_index: usize = 0,
    composition_sections: []const context_composition.SectionStat = &.{},
    system_prompt_bytes: ?usize = null,
    compact_memory_bytes: usize = 0,
    observations_bytes: usize = 0,
    user_prompt_bytes: usize = 0,
    user_prompt_tokens: usize = 0,
};

pub const InterpretationSectionPayload = struct {
    name: []const u8,
    bytes: usize,
    count: ?usize = null,
};

pub const InterpretationPayload = struct {
    user_summary: []const u8,
    brain_summary: []const u8,
    reasoning_effort: ?chat.ReasoningEffort,
    turn_complete: bool,
    system_prompt_bytes: usize,
    compact_memory_bytes: usize,
    observations_bytes: usize,
    user_prompt_bytes: usize,
    turn_index: usize = 0,
    sections: []const InterpretationSectionPayload = &.{},
};

pub const LanguageMindActor = struct {
    allocator: std.mem.Allocator,
    sink: brain_actor.EventSink,

    pub fn init(allocator: std.mem.Allocator, sink: brain_actor.EventSink) LanguageMindActor {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn interpretTurn(self: *const LanguageMindActor, service: chat.ChatService, input: TurnInput) !chat.ChatTurn {
        const prompt_audit = if (input.user_prompt_bytes > 0)
            chat.ChatPromptAudit{
                .system_prompt_bytes = input.system_prompt_bytes orelse chat.chatSystemPrompt().len,
                .compact_memory_bytes = input.compact_memory_bytes,
                .observations_bytes = input.observations_bytes,
                .user_prompt_bytes = input.user_prompt_bytes,
                .user_prompt_tokens = if (input.user_prompt_tokens > 0)
                    input.user_prompt_tokens
                else
                    context_tokens.estimateTokensFromByteLength(input.user_prompt_bytes),
            }
        else
            try chat.auditChatPrompt(self.allocator, input.memory, input.user_text, input.observations);

        const section_payloads = try self.sectionPayloads(input.composition_sections);
        defer self.allocator.free(section_payloads);

        const turn = try service.respond(self.allocator, input.memory, input.user_text, input.observations);
        try self.sink.emitStruct(self.allocator, "interpretation.created", InterpretationPayload{
            .user_summary = turn.user_summary,
            .brain_summary = turn.brain_summary,
            .reasoning_effort = turn.reasoning_effort,
            .turn_complete = turn.turn_complete,
            .system_prompt_bytes = prompt_audit.system_prompt_bytes,
            .compact_memory_bytes = prompt_audit.compact_memory_bytes,
            .observations_bytes = prompt_audit.observations_bytes,
            .user_prompt_bytes = prompt_audit.user_prompt_bytes,
            .turn_index = input.turn_index,
            .sections = section_payloads,
        });
        return turn;
    }

    pub fn emitProposals(self: *const LanguageMindActor, now_ms: i64, proposals: []const chat.ActionProposal) !void {
        for (proposals, 0..) |proposal, index| {
            try self.emitProposalCreated(now_ms, index, proposal);
        }
    }

    pub fn interpretAndPropose(self: *const LanguageMindActor, service: chat.ChatService, input: TurnInput) !chat.ChatTurn {
        const turn = try self.interpretTurn(service, input);
        try self.emitProposals(input.now_ms, turn.action_pressures);
        return turn;
    }

    fn sectionPayloads(self: *const LanguageMindActor, sections: []const context_composition.SectionStat) ![]InterpretationSectionPayload {
        const out = try self.allocator.alloc(InterpretationSectionPayload, sections.len);
        for (sections, 0..) |section, index| {
            out[index] = .{
                .name = section.name,
                .bytes = section.bytes,
                .count = section.count,
            };
        }
        return out;
    }

    fn emitProposalCreated(self: *const LanguageMindActor, now_ms: i64, index: usize, proposal: chat.ActionProposal) !void {
        var id_buf: [96]u8 = undefined;
        const proposal_id = try std.fmt.bufPrint(&id_buf, "proposal_{d}_{d}", .{ now_ms, index });
        const body_text = proposal.text orelse proposal.query orelse proposal.name orelse @tagName(proposal.action);
        const risk = proposalRisk(proposal);
        const strength = proposalStrength(proposal);
        const urgency = proposalUrgency(proposal);
        const payload = payloads.ProposalEventPayload{
            .proposal_id = proposal_id,
            .kind = @tagName(proposal.action),
            .origin = @tagName(proposal.origin),
            .scale = @tagName(proposal.scale),
            .delay_ms = proposal.delay_ms,
            .strength = strength,
            .urgency = urgency,
            .expected_value = payloads.expectedValue(strength, urgency, risk),
            .risk = risk,
            .alternatives = .{
                .full = body_text,
                .short = payloads.boundedSlice(body_text, 96),
                .tiny = payloads.boundedSlice(body_text, 32),
                .noop = "noop",
            },
            .text = proposal.text,
            .query = proposal.query,
            .memory_id = proposal.memory_id,
            .person_id = proposal.person_id,
            .name = proposal.name,
            .image_path = proposal.image_path,
            .schedule = proposal.schedule,
            .to = proposal.to,
            .subject = proposal.subject,
            .heat_bias = proposal.heat_bias,
            .eyes = proposal.eyes,
            .mouth = proposal.mouth,
            .duration_ms = proposal.duration_ms,
            .keep_existing = proposal.keep_existing,
            .tags = proposal.tags,
        };
        try self.sink.emitStruct(self.allocator, "proposal.created", payload);
    }
};

fn proposalStrength(proposal: chat.ActionProposal) f32 {
    const base: f32 = if (proposal.origin == .interaction) 0.80 else 0.62;
    return std.math.clamp(base * scaleMultiplier(proposal.scale), 0.0, 1.0);
}

fn proposalUrgency(proposal: chat.ActionProposal) f32 {
    var urgency: f32 = if (proposal.origin == .interaction) 0.72 else 0.48;
    if (proposal.delay_ms != null) urgency = @max(0.2, urgency - 0.15);
    return urgency;
}

fn proposalRisk(proposal: chat.ActionProposal) f32 {
    return switch (proposal.action) {
        .send_email => 0.85,
        .remember_person, .update_face_picture, .recognize => 0.60,
        .take_picture, .request_orientation => 0.52,
        .forget_memory, .forget_person, .invalidate_fact => 0.58,
        .unknown => 0.95,
        else => 0.20,
    };
}

fn scaleMultiplier(scale: chat.ActionScale) f32 {
    return switch (scale) {
        .full => 1.0,
        .medium => 0.75,
        .tiny => 0.45,
    };
}
