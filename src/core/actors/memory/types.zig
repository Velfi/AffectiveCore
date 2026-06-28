const std = @import("std");
const ports = @import("../../ports.zig");
const schema = ports.schema;

pub const CandidateKind = enum {
    belief,
    preference,
    relationship,
    episode,
    fact,
    observation,
};

pub const MemoryCandidate = struct {
    candidate_id: []const u8 = "",
    key: []const u8,
    proposition: []const u8,
    evidence: []const u8,
    kind: CandidateKind = .belief,
    confidence: f32 = 0.50,
    salience: f32 = 0.40,
    status: schema.MemoryRecordStatus = .candidate,
    source_event_ids: []const []const u8 = &.{},
    tags: []const []const u8 = &.{},
    source_references: []const []const u8 = &.{},
};

pub const ReconciliationAction = enum {
    create,
    merge,
    reinforce,
    contradict,
    correct,
    reject,
};

pub const ReconciliationResult = struct {
    action: ReconciliationAction,
    belief_id: ?[]const u8 = null,
    reason: []const u8 = "",
};

pub const RetrievalMatch = struct {
    memory_id: []const u8,
    status: schema.MemoryRecordStatus,
    confidence: f32,
    salience: f32,
    text: []const u8,
};

pub const AuditReport = struct {
    belief_id: []const u8,
    provenance: []const u8,
    source_event_ids: []const []const u8,
    revision_history: []const schema.MemoryRevision,
};

pub const ConsolidationRequest = struct {
    activity: schema.ActivityRecord,
    reason: []const u8,
};

pub const ConsolidatedEvent = struct {
    activity_id: []const u8,
    activity_status: []const u8,
    reason: []const u8,
    episode_candidate: MemoryCandidate,
};

pub const ExtractionRequest = struct {
    episode_id: []const u8,
    episode_summary: []const u8,
    source_event_ids: []const []const u8 = &.{},
};

pub const RetrievalRequest = struct {
    query: []const u8,
    status: ?schema.MemoryRecordStatus = null,
    limit: usize = 5,
};

pub const RetrievalEvent = struct {
    query: []const u8,
    status: ?schema.MemoryRecordStatus = null,
    matches: []const RetrievalMatch,
    match_count: usize,
    status_label: []const u8,
};

pub const DecayRequest = struct {
    trigger: []const u8,
    kind_tag: ?[]const u8 = null,
};

pub const DecayedEvent = struct {
    trigger: []const u8,
    kind_tag: ?[]const u8 = null,
    touched: usize,
    dormant: usize,
    retracted: usize,
};

pub const AuditRequest = struct {
    belief_id: []const u8,
};

pub const AuditEvent = struct {
    report: AuditReport,
};

pub fn hasTag(tags: []const []const u8, needle: []const u8) bool {
    for (tags) |tag| {
        if (std.mem.eql(u8, tag, needle)) return true;
    }
    return false;
}
