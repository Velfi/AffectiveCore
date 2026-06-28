const std = @import("std");
const schema = @import("schema.zig");
const store_mod = @import("store.zig");
const files = @import("../platform/common/files.zig");

const default_capture_dir = "data/captures";
const deletion_marker_suffix = ".delete";

const persistence = @import("json_store_persistence.zig");
const cognitive = @import("json_store_cognitive.zig");
const cognitive_pruning = @import("cognitive_pruning.zig");
const cognitive_enum_diagnostics = @import("json_store_cognitive_enum_diagnostics.zig");
pub const CognitiveEnumDiagnostic = cognitive_enum_diagnostics.CognitiveEnumDiagnostic;
pub const cognitiveEnumDiagnosticAlloc = cognitive_enum_diagnostics.cognitiveEnumDiagnosticAlloc;

pub const JsonMemoryStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    memory_path: []const u8,
    capture_dir: []const u8,
    cached: ?schema.CognitiveFile = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, memory_path: []const u8) JsonMemoryStore {
        return initWithCaptureDir(allocator, io, memory_path, default_capture_dir);
    }

    pub fn initWithCaptureDir(allocator: std.mem.Allocator, io: std.Io, memory_path: []const u8, captures_path: []const u8) JsonMemoryStore {
        return .{ .allocator = allocator, .io = io, .memory_path = memory_path, .capture_dir = captures_path };
    }

    pub fn store(self: *JsonMemoryStore) store_mod.MemoryStore {
        return .{
            .ctx = self,
            .upsertBeliefFn = upsertBelief,
            .loadBeliefsFn = loadBeliefs,
            .invalidateBeliefFn = invalidateBelief,
            .upsertSubjectFn = upsertSubject,
            .loadSubjectsFn = loadSubjects,
            .addArtifactFn = addArtifact,
            .loadArtifactsFn = loadArtifacts,
            .loadPeopleFn = loadPeople,
            .savePersonFn = savePerson,
            .addSightingFn = addSighting,
            .loadSightingsFn = loadSightings,
            .findByNameFn = findByName,
            .findByIdFn = findById,
            .forgetPersonFn = forgetPerson,
            .loadConversationSummariesFn = loadConversationSummaries,
            .addConversationSummaryFn = addConversationSummary,
            .loadMemoryRecordsFn = loadMemoryRecords,
            .saveMemoryRecordFn = saveMemoryRecord,
            .forgetMemoryRecordFn = forgetMemoryRecord,
            .loadFactRecordsFn = loadFactRecords,
            .saveFactRecordFn = saveFactRecord,
            .invalidateFactRecordFn = invalidateFactRecord,
            .loadImpressionsFn = loadImpressions,
            .addImpressionFn = addImpression,
            .loadAppraisalsFn = loadAppraisals,
            .addAppraisalFn = addAppraisal,
            .sweepExpiredExperiencesFn = sweepExpiredExperiences,
            .sweepUnreferencedCapturesFn = sweepUnreferencedCaptures,
            .pruneTombstonedCognitiveRecordsFn = pruneTombstonedCognitiveRecords,
            .retainCaptureFn = retainCapture,
            .addExperienceEventFn = addExperienceEvent,
            .loadExperienceEventsFn = loadExperienceEvents,
            .setBrainModeFn = setBrainMode,
            .loadBrainModeFn = loadBrainMode,
            .upsertHostBindingFn = upsertHostBinding,
            .loadHostBindingsFn = loadHostBindings,
            .upsertCapabilityStatusFn = upsertCapabilityStatus,
            .loadCapabilityStatusesFn = loadCapabilityStatuses,
            .addCapabilityRequestFn = addCapabilityRequest,
            .addCapabilityResultFn = addCapabilityResult,
            .upsertSelfTrustFn = upsertSelfTrust,
            .loadSelfTrustFn = loadSelfTrust,
            .upsertDispositionFn = upsertDisposition,
            .loadDispositionsFn = loadDispositions,
            .addActionPressureFn = addActionPressure,
            .loadActionPressuresFn = loadActionPressures,
            .addActionOutcomeFn = addActionOutcome,
            .loadActionOutcomesFn = loadActionOutcomes,
            .upsertActionOutcomeFn = upsertActionOutcome,
            .loadCapabilityResultsFn = loadCapabilityResults,
            .loadCapabilityRequestsFn = loadCapabilityRequests,
            .addDreamTimeRecordFn = addDreamTimeRecord,
            .loadDreamTimeRecordsFn = loadDreamTimeRecords,
            .addMailboxItemFn = addMailboxItem,
            .loadMailboxItemsFn = loadMailboxItems,
            .markMailboxItemReadFn = markMailboxItemRead,
            .addIdentityHypothesisFn = addIdentityHypothesis,
            .loadIdentityHypothesesFn = loadIdentityHypotheses,
            .saveActiveActivityFn = saveActiveActivity,
            .loadActiveActivityFn = loadActiveActivity,
            .saveActivityStackFn = saveActivityStack,
            .loadActivityStackFn = loadActivityStack,
            .appendActivityHistoryFn = appendActivityHistory,
            .loadActivityHistoryFn = loadActivityHistory,
        };
    }

    fn loadCachedFromDisk(self: *JsonMemoryStore) !void {
        const bytes = try persistence.readCognitiveJson(self.allocator, self.io, self.memory_path, self.allocator);
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(schema.CognitiveFile, self.allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err| {
            if (err == error.InvalidEnumTag) cognitive_enum_diagnostics.traceInvalidCognitiveEnumTag(self.allocator, self.memory_path, bytes);
            return err;
        };
        defer parsed.deinit();
        const data = try cognitive.cloneCognitiveFile(self.allocator, parsed.value);
        try persistence.validateCognitiveFile(data);
        self.cached = data;
    }

    fn ensureCached(self: *JsonMemoryStore) !void {
        if (self.cached != null) return;
        try self.loadCachedFromDisk();
    }

    fn mutateCached(self: *JsonMemoryStore) !*schema.CognitiveFile {
        try self.ensureCached();
        return &self.cached.?;
    }

    fn persistCached(self: *JsonMemoryStore) !void {
        const data = self.cached orelse return error.MissingCachedCognitiveFile;
        try persistence.validateCognitiveFile(data);
        const json = try std.json.Stringify.valueAlloc(self.allocator, data, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json);
        try persistence.writeCognitiveJson(self.allocator, self.io, self.memory_path, json);
    }


    fn addExperienceEvent(ctx: *anyopaque, event: schema.ExperienceEvent) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        data.events = try cognitive.appendOne(schema.ExperienceEvent, self.allocator, data.events, try cognitive.cloneExperienceEvent(self.allocator, event));
        try self.persistCached();
    }

    fn loadExperienceEvents(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.ExperienceEvent {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.events;
    }

    fn setBrainMode(ctx: *anyopaque, mode: schema.BrainMode) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        data.brain_mode = mode;
        try self.persistCached();
    }

    fn loadBrainMode(ctx: *anyopaque) !schema.BrainMode {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        return self.cached.?.brain_mode;
    }

    fn upsertHostBinding(ctx: *anyopaque, binding: schema.HostBinding) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        for (data.host_bindings, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.host_id, binding.host_id)) {
                data.host_bindings[i] = try cognitive.cloneHostBinding(self.allocator, binding);
                try self.persistCached();
                return;
            }
        }
        data.host_bindings = try cognitive.appendOne(schema.HostBinding, self.allocator, data.host_bindings, try cognitive.cloneHostBinding(self.allocator, binding));
        try self.persistCached();
    }

    fn loadHostBindings(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.HostBinding {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.host_bindings;
    }

    fn upsertCapabilityStatus(ctx: *anyopaque, status: schema.CapabilityStatus) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        for (data.capability_statuses, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.capability_id, status.capability_id) and std.mem.eql(u8, existing.host_id, status.host_id)) {
                data.capability_statuses[i] = try cognitive.cloneCapabilityStatus(self.allocator, status);
                try self.persistCached();
                return;
            }
        }
        data.capability_statuses = try cognitive.appendOne(schema.CapabilityStatus, self.allocator, data.capability_statuses, try cognitive.cloneCapabilityStatus(self.allocator, status));
        try self.persistCached();
    }

    fn loadCapabilityStatuses(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.CapabilityStatus {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.capability_statuses;
    }

    fn addCapabilityRequest(ctx: *anyopaque, request: schema.CapabilityRequest) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        data.capability_requests = try cognitive.appendOne(schema.CapabilityRequest, self.allocator, data.capability_requests, try cognitive.cloneCapabilityRequest(self.allocator, request));
        try self.persistCached();
    }

    fn addCapabilityResult(ctx: *anyopaque, result: schema.CapabilityResult) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        data.capability_results = try cognitive.appendOne(schema.CapabilityResult, self.allocator, data.capability_results, try cognitive.cloneCapabilityResult(self.allocator, result));
        try self.persistCached();
    }

    fn upsertSelfTrust(ctx: *anyopaque, entry: schema.SelfTrustEntry) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        for (data.self_trust, 0..) |existing, i| if (std.mem.eql(u8, existing.self_trust_id, entry.self_trust_id)) {
            data.self_trust[i] = try cognitive.cloneSelfTrustEntry(self.allocator, entry);
            try self.persistCached();
            return;
        };
        data.self_trust = try cognitive.appendOne(schema.SelfTrustEntry, self.allocator, data.self_trust, try cognitive.cloneSelfTrustEntry(self.allocator, entry));
        try self.persistCached();
    }

    fn loadSelfTrust(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.SelfTrustEntry {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.self_trust;
    }

    fn upsertDisposition(ctx: *anyopaque, disposition: schema.Disposition) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        for (data.dispositions, 0..) |existing, i| if (std.mem.eql(u8, existing.disposition_id, disposition.disposition_id)) {
            data.dispositions[i] = try cognitive.cloneDisposition(self.allocator, disposition);
            try self.persistCached();
            return;
        };
        data.dispositions = try cognitive.appendOne(schema.Disposition, self.allocator, data.dispositions, try cognitive.cloneDisposition(self.allocator, disposition));
        try self.persistCached();
    }

    fn loadDispositions(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Disposition {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.dispositions;
    }

    fn addActionPressure(ctx: *anyopaque, pressure: schema.ActionPressure) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        data.action_pressures = try cognitive.appendOne(schema.ActionPressure, self.allocator, data.action_pressures, try cognitive.cloneActionPressure(self.allocator, pressure));
        try self.persistCached();
    }

    fn loadActionPressures(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.ActionPressure {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.action_pressures;
    }

    fn addActionOutcome(ctx: *anyopaque, outcome: schema.ActionOutcome) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        data.action_outcomes = try cognitive.appendOne(schema.ActionOutcome, self.allocator, data.action_outcomes, try cognitive.cloneActionOutcome(self.allocator, outcome));
        try self.persistCached();
    }

    fn loadActionOutcomes(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.ActionOutcome {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.action_outcomes;
    }

    fn upsertActionOutcome(ctx: *anyopaque, outcome: schema.ActionOutcome) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        for (data.action_outcomes, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.outcome_id, outcome.outcome_id)) {
                data.action_outcomes[i] = try cognitive.cloneActionOutcome(self.allocator, outcome);
                try self.persistCached();
                return;
            }
        }
        data.action_outcomes = try cognitive.appendOne(schema.ActionOutcome, self.allocator, data.action_outcomes, try cognitive.cloneActionOutcome(self.allocator, outcome));
        try self.persistCached();
    }

    fn loadCapabilityResults(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.CapabilityResult {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.capability_results;
    }

    fn loadCapabilityRequests(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.CapabilityRequest {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.capability_requests;
    }

    fn addDreamTimeRecord(ctx: *anyopaque, dream: schema.DreamTimeRecord) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        for (data.dream_time_records, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.dream_id, dream.dream_id)) {
                data.dream_time_records[i] = try cognitive.cloneDreamTimeRecord(self.allocator, dream);
                try self.persistCached();
                return;
            }
        }
        data.dream_time_records = try cognitive.appendOne(schema.DreamTimeRecord, self.allocator, data.dream_time_records, try cognitive.cloneDreamTimeRecord(self.allocator, dream));
        try self.persistCached();
    }

    fn loadDreamTimeRecords(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.DreamTimeRecord {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.dream_time_records;
    }

    fn addMailboxItem(ctx: *anyopaque, item: schema.MailboxItem) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        data.mailbox_items = try cognitive.appendOne(schema.MailboxItem, self.allocator, data.mailbox_items, try cognitive.cloneMailboxItem(self.allocator, item));
        try self.persistCached();
    }

    fn loadMailboxItems(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.MailboxItem {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.mailbox_items;
    }

    fn markMailboxItemRead(ctx: *anyopaque, mailbox_id: []const u8, read_at_ms: i64) !schema.MailboxItem {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        for (0..data.mailbox_items.len) |i| {
            if (std.mem.eql(u8, data.mailbox_items[i].mailbox_id, mailbox_id)) {
                data.mailbox_items[i].read_at_ms = read_at_ms;
                const updated = try cognitive.cloneMailboxItem(self.allocator, data.mailbox_items[i]);
                try self.persistCached();
                return updated;
            }
        }
        return error.UnknownMailboxItem;
    }

    fn addIdentityHypothesis(ctx: *anyopaque, hypothesis: schema.IdentityHypothesis) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        data.identity_hypotheses = try cognitive.appendOne(schema.IdentityHypothesis, self.allocator, data.identity_hypotheses, try cognitive.cloneIdentityHypothesis(self.allocator, hypothesis));
        try self.persistCached();
    }

    fn loadIdentityHypotheses(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.IdentityHypothesis {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.identity_hypotheses;
    }

    fn upsertBelief(ctx: *anyopaque, belief: schema.Belief) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        for (data.beliefs, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.belief_id, belief.belief_id)) {
                data.beliefs[i] = try cognitive.cloneBelief(self.allocator, belief);
                try self.persistCached();
                return;
            }
        }
        data.beliefs = try cognitive.appendOne(schema.Belief, self.allocator, data.beliefs, try cognitive.cloneBelief(self.allocator, belief));
        try self.persistCached();
    }

    fn loadBeliefs(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Belief {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.beliefs;
    }

    fn invalidateBelief(ctx: *anyopaque, belief_id: []const u8, invalidated_at: []const u8) !bool {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        for (data.beliefs, 0..) |belief, i| {
            if (std.mem.eql(u8, belief.belief_id, belief_id)) {
                var updated = try cognitive.cloneBelief(self.allocator, belief);
                updated.lifecycle.status = .invalidated;
                updated.lifecycle.updated_at = try cognitive.cloneString(self.allocator, invalidated_at);
                data.beliefs[i] = updated;
                try self.persistCached();
                return true;
            }
        }
        return false;
    }

    fn upsertSubject(ctx: *anyopaque, subject: schema.Subject) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        for (data.subjects, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.subject_id, subject.subject_id)) {
                data.subjects[i] = try cognitive.cloneSubject(self.allocator, subject);
                try self.persistCached();
                return;
            }
        }
        data.subjects = try cognitive.appendOne(schema.Subject, self.allocator, data.subjects, try cognitive.cloneSubject(self.allocator, subject));
        try self.persistCached();
    }

    fn loadSubjects(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Subject {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.subjects;
    }

    fn addArtifact(ctx: *anyopaque, artifact: schema.Artifact) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        data.artifacts = try cognitive.appendOne(schema.Artifact, self.allocator, data.artifacts, try cognitive.cloneArtifact(self.allocator, artifact));
        try self.persistCached();
    }

    fn loadArtifacts(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Artifact {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.artifacts;
    }

    fn loadPeople(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Person {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        return cognitive.subjectsToPeople(allocator, self.cached.?.subjects);
    }

    fn savePerson(ctx: *anyopaque, person: schema.Person) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        const subject = try cognitive.personToSubject(self.allocator, person);
        for (data.subjects, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.subject_id, subject.subject_id)) {
                data.subjects[i] = subject;
                try self.persistCached();
                return;
            }
        }
        data.subjects = try cognitive.appendOne(schema.Subject, self.allocator, data.subjects, subject);
        try self.persistCached();
    }

    fn addSighting(ctx: *anyopaque, sighting: schema.Sighting) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        data.sightings = try cognitive.appendOne(schema.Sighting, self.allocator, data.sightings, try cognitive.cloneSighting(self.allocator, sighting));
        if (sighting.image_path) |path| {
            data.artifacts = try cognitive.appendOne(schema.Artifact, self.allocator, data.artifacts, try cognitive.imageArtifact(self.allocator, sighting.sighting_id, path, sighting.seen_at, sighting.source_event_ids));
        }
        try self.persistCached();
    }

    fn loadSightings(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Sighting {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.sightings;
    }

    fn loadConversationSummaries(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.ConversationSummary {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.conversation_summaries;
    }

    fn addConversationSummary(ctx: *anyopaque, summary: schema.ConversationSummary) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        data.conversation_summaries = try cognitive.appendOne(schema.ConversationSummary, self.allocator, data.conversation_summaries, try cognitive.cloneConversationSummary(self.allocator, summary));
        try self.persistCached();
    }

    fn loadMemoryRecords(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.MemoryRecord {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.memories;
    }

    fn saveMemoryRecord(ctx: *anyopaque, memory: schema.MemoryRecord) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        const cloned = try cognitive.cloneMemoryRecord(self.allocator, memory);
        for (data.memories, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.memory_id, cloned.memory_id)) {
                data.memories[i] = cloned;
                try self.persistCached();
                return;
            }
        }
        data.memories = try cognitive.appendOne(schema.MemoryRecord, self.allocator, data.memories, cloned);
        try self.persistCached();
    }

    fn forgetMemoryRecord(ctx: *anyopaque, memory_id: []const u8) !bool {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        for (data.memories, 0..) |memory, i| {
            if (std.mem.eql(u8, memory.memory_id, memory_id)) {
                data.memories = try cognitive.removeAt(schema.MemoryRecord, self.allocator, data.memories, i);
                try self.persistCached();
                return true;
            }
        }
        return false;
    }

    fn loadFactRecords(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.FactRecord {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        return cognitive.beliefsToFacts(allocator, self.cached.?.beliefs);
    }

    fn saveFactRecord(ctx: *anyopaque, fact: schema.FactRecord) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        const belief = try cognitive.factToBelief(self.allocator, fact);
        for (data.beliefs, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.belief_id, belief.belief_id)) {
                data.beliefs[i] = belief;
                try self.persistCached();
                return;
            }
        }
        data.beliefs = try cognitive.appendOne(schema.Belief, self.allocator, data.beliefs, belief);
        try self.persistCached();
    }

    fn invalidateFactRecord(ctx: *anyopaque, fact_id: []const u8, invalidated_at: []const u8) !bool {
        return invalidateBelief(ctx, fact_id, invalidated_at);
    }

    fn loadImpressions(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Impression {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.impressions;
    }

    fn addImpression(ctx: *anyopaque, impression: schema.Impression) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        data.impressions = try cognitive.appendOne(schema.Impression, self.allocator, data.impressions, try cognitive.cloneImpression(self.allocator, impression));
        try self.persistCached();
    }

    fn loadAppraisals(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Appraisal {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        _ = allocator;
        return self.cached.?.appraisals;
    }

    fn addAppraisal(ctx: *anyopaque, appraisal: schema.Appraisal) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        data.appraisals = try cognitive.appendOne(schema.Appraisal, self.allocator, data.appraisals, try cognitive.cloneAppraisal(self.allocator, appraisal));
        try self.persistCached();
    }

    fn sweepExpiredExperiences(ctx: *anyopaque, now_seconds: i64) !usize {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        var kept = std.ArrayList(schema.MemoryRecord).empty;
        var removed: usize = 0;
        for (data.memories) |memory| {
            const decayed = memory.scope == .short_term and memory.score <= 0 and cognitive.parseTimestamp(memory.last_accessed_at orelse memory.created_at) <= now_seconds;
            if (decayed) removed += 1 else try kept.append(self.allocator, memory);
        }
        if (removed > 0) {
            data.memories = try kept.toOwnedSlice(self.allocator);
            try self.persistCached();
        }
        return removed;
    }

    fn sweepUnreferencedCaptures(ctx: *anyopaque) !usize {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        const data = self.cached.?;
        var referenced = std.StringHashMap(void).init(self.allocator);
        try cognitive.collectCaptureReferences(self.allocator, &referenced, self.capture_dir, data);

        var dir = std.Io.Dir.cwd().openDir(self.io, self.capture_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer dir.close(self.io);
        var iter = dir.iterate();
        var removed: usize = 0;
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, deletion_marker_suffix)) continue;
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.capture_dir, entry.name });
            if (referenced.contains(path)) continue;
            const marker_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ path, deletion_marker_suffix });
            const had_marker = blk: {
                std.Io.Dir.cwd().access(self.io, marker_path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
                break :blk true;
            };
            if (had_marker) {
                try std.Io.Dir.cwd().deleteFile(self.io, path);
                std.Io.Dir.cwd().deleteFile(self.io, marker_path) catch {};
                removed += 1;
            } else {
                try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = marker_path, .data = "unreferenced capture\n", .flags = .{ .truncate = true } });
            }
        }
        return removed;
    }

    fn pruneTombstonedCognitiveRecords(ctx: *anyopaque, now: []const u8) !schema.CognitivePruneResult {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        const result = try cognitive_pruning.pruneCognitiveFile(self.allocator, data, now);
        try self.persistCached();
        return .{ .tombstoned = result.tombstoned, .purged = result.purged };
    }

    fn retainCapture(ctx: *anyopaque, allocator: std.mem.Allocator, source_path: []const u8, label: []const u8) ![]const u8 {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        if (std.mem.startsWith(u8, source_path, self.capture_dir)) return allocator.dupe(u8, source_path);
        if (label.len == 0) return error.EmptyCaptureLabel;

        const source_basename = std.fs.path.basename(source_path);
        const destination = try std.fmt.allocPrint(self.allocator, "{s}/{s}_{s}", .{ self.capture_dir, label, source_basename });
        const bytes = try persistence.readFileAllocPath(self.io, source_path, self.allocator, .limited(64 * 1024 * 1024));
        defer self.allocator.free(bytes);
        try files.ensureParentDir(self.io, destination);
        try persistence.writeFilePath(self.io, destination, bytes);
        return allocator.dupe(u8, destination);
    }

    fn findByName(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) !?schema.Person {
        const people = try loadPeople(ctx, allocator);
        for (people) |p| {
            if (p.relationship_status != .forgotten and std.ascii.eqlIgnoreCase(p.display_name, name)) return p;
        }
        return null;
    }

    fn findById(ctx: *anyopaque, allocator: std.mem.Allocator, id: []const u8) !?schema.Person {
        const people = try loadPeople(ctx, allocator);
        for (people) |p| {
            if (std.mem.eql(u8, p.person_id, id)) return p;
        }
        return null;
    }

    fn forgetPerson(ctx: *anyopaque, person_id: []const u8) !bool {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        for (data.subjects, 0..) |subject, i| {
            if (std.mem.eql(u8, subject.subject_id, person_id) or std.ascii.eqlIgnoreCase(subject.display_name, person_id)) {
                var updated = try cognitive.cloneSubject(self.allocator, subject);
                updated.relationship_status = .forgotten;
                updated.embeddings = &.{};
                updated.lifecycle.status = .invalidated;
                data.subjects[i] = updated;
                try self.persistCached();
                return true;
            }
        }
        return false;
    }

    fn saveActiveActivity(ctx: *anyopaque, record: ?schema.ActivityRecord) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        if (record) |active| {
            if (data.active_activity) |previous| cognitive.freeActivityRecord(self.allocator, previous);
            data.active_activity = try cognitive.cloneActivityRecord(self.allocator, active);
        } else {
            if (data.active_activity) |previous| cognitive.freeActivityRecord(self.allocator, previous);
            data.active_activity = null;
        }
        try self.persistCached();
    }

    fn loadActiveActivity(ctx: *anyopaque, allocator: std.mem.Allocator) !?schema.ActivityRecord {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        const active = self.cached.?.active_activity orelse return null;
        return try cognitive.cloneActivityRecord(allocator, active);
    }

    fn saveActivityStack(ctx: *anyopaque, stack: []const schema.ActivityRecord) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        for (data.activity_stack) |previous| cognitive.freeActivityRecord(self.allocator, previous);
        self.allocator.free(data.activity_stack);
        var copied = try self.allocator.alloc(schema.ActivityRecord, stack.len);
        for (stack, 0..) |record, i| copied[i] = try cognitive.cloneActivityRecord(self.allocator, record);
        data.activity_stack = copied;
        try self.persistCached();
    }

    fn loadActivityStack(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.ActivityRecord {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        var copied = try allocator.alloc(schema.ActivityRecord, self.cached.?.activity_stack.len);
        for (self.cached.?.activity_stack, 0..) |record, i| {
            copied[i] = try cognitive.cloneActivityRecord(allocator, record);
        }
        return copied;
    }

    const max_activity_history: usize = 50;

    fn appendActivityHistory(ctx: *anyopaque, record: schema.ActivityRecord) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.mutateCached();
        const cloned = try cognitive.cloneActivityRecord(self.allocator, record);
        data.activity_history = try cognitive.appendOne(schema.ActivityRecord, self.allocator, data.activity_history, cloned);
        if (data.activity_history.len > max_activity_history) {
            const drop = data.activity_history.len - max_activity_history;
            for (data.activity_history[0..drop]) |previous| cognitive.freeActivityRecord(self.allocator, previous);
            const trimmed = try self.allocator.alloc(schema.ActivityRecord, max_activity_history);
            @memcpy(trimmed, data.activity_history[drop..]);
            self.allocator.free(data.activity_history);
            data.activity_history = trimmed;
        }
        try self.persistCached();
    }

    fn loadActivityHistory(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.ActivityRecord {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try self.ensureCached();
        var copied = try allocator.alloc(schema.ActivityRecord, self.cached.?.activity_history.len);
        for (self.cached.?.activity_history, 0..) |record, i| {
            copied[i] = try cognitive.cloneActivityRecord(allocator, record);
        }
        return copied;
    }


};
