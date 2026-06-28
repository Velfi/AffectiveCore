const std = @import("std");

pub const ProposalAlternatives = struct {
    full: []const u8,
    short: []const u8,
    tiny: []const u8,
    noop: []const u8,
};

pub const ProposalEventPayload = struct {
    proposal_id: []const u8,
    kind: []const u8,
    origin: []const u8 = "interaction",
    scale: []const u8 = "full",
    delay_ms: ?u32 = null,
    strength: f32,
    urgency: f32,
    expected_value: f32,
    risk: f32,
    alternatives: ProposalAlternatives,
    text: ?[]const u8 = null,
    query: ?[]const u8 = null,
    memory_id: ?[]const u8 = null,
    person_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    image_path: ?[]const u8 = null,
    schedule: ?[]const u8 = null,
    to: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    heat_bias: ?[]const u8 = null,
    eyes: ?[]const u8 = null,
    mouth: ?[]const u8 = null,
    duration_ms: ?u32 = null,
    keep_existing: bool = false,
    tags: []const []const u8 = &.{},
};

pub const GovernanceDecision = enum {
    allow,
    deny,
    @"defer",
    require_approval,
    downgrade,
};

pub const GovernanceDecisionPayload = struct {
    proposal_id: []const u8,
    decision: GovernanceDecision,
    reason: []const u8,
    replacement_proposal_id: ?[]const u8 = null,
};

pub const LearningCapabilityRecordedPayload = struct {
    result: @import("../ports.zig").schema.CapabilityResult,
    source_event_ids: []const []const u8 = &.{},
    terminal_event_id: []const u8 = "",
};

pub const LearningCorrectionRecordedPayload = struct {
    image_path: []const u8,
    person_id: []const u8,
    name: []const u8,
    confidence: f32,
    hypothesis_event_id: []const u8,
};

pub fn boundedSlice(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    return text[0..max_len];
}

pub fn expectedValue(strength: f32, urgency: f32, risk: f32) f32 {
    const value = strength * 0.6 + urgency * 0.4 - risk * 0.5;
    return std.math.clamp(value, -1.0, 1.0);
}

