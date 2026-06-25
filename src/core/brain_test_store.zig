const std = @import("std");
const brain_mod = @import("brain.zig");
const config_mod = @import("config.zig");
const events = @import("events.zig");
const identity = @import("identity.zig");
const interrupt_mod = @import("interrupt.zig");
const schema = @import("../storage/schema.zig");
const store_mod = @import("../storage/store.zig");
const intent_mod = @import("../api/intent_client.zig");
const openai = @import("../api/openai_client.zig");
const chat_mod = @import("../api/chat_client.zig");
const audio_mod = @import("../api/audio_client.zig");
const want_achievement_mod = @import("../api/want_achievement_client.zig");
const camera_mod = @import("../platform/common/camera.zig");
const input_mod = @import("../platform/common/input.zig");
const command_log_mod = @import("../platform/common/command_log.zig");
const facial_expression = @import("../platform/common/facial_expression.zig");
const id_monitor = @import("id_monitor.zig");
const maintenance = @import("maintenance.zig");

const Brain = brain_mod.Brain;
const BrainDeps = brain_mod.BrainDeps;

pub const TestStore = struct {
    allocator: std.mem.Allocator,
    people: std.ArrayList(schema.Person),
    sightings: std.ArrayList(schema.Sighting),
    conversation_summaries: std.ArrayList(schema.ConversationSummary),
    memories: std.ArrayList(schema.MemoryRecord),
    facts: std.ArrayList(schema.FactRecord),
    traces: std.ArrayList(schema.Trace),
    beliefs: std.ArrayList(schema.Belief),
    subjects: std.ArrayList(schema.Subject),
    artifacts: std.ArrayList(schema.Artifact),
    cognitive_dreams: std.ArrayList(schema.Dream),
    impressions: std.ArrayList(schema.Impression),
    appraisals: std.ArrayList(schema.Appraisal),
    dreams: std.ArrayList(schema.DreamRecord),
    experiences: std.ArrayList(schema.Experience),
    runtime_events: std.ArrayList([]const u8),
    want_detector: want_achievement_mod.ScriptedWantAchievementDetector,
    log_count: usize = 0,
    runtime_event_sweep_count: usize = 0,
    retain_prefix: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) TestStore {
        return .{
            .allocator = allocator,
            .people = .empty,
            .sightings = .empty,
            .conversation_summaries = .empty,
            .memories = .empty,
            .facts = .empty,
            .traces = .empty,
            .beliefs = .empty,
            .subjects = .empty,
            .artifacts = .empty,
            .cognitive_dreams = .empty,
            .impressions = .empty,
            .appraisals = .empty,
            .dreams = .empty,
            .experiences = .empty,
            .runtime_events = .empty,
            .want_detector = .{},
        };
    }

    pub fn store(self: *TestStore) store_mod.MemoryStore {
        return .{
            .ctx = self,
            .addTraceFn = addTrace,
            .updateTraceFn = updateTrace,
            .loadTracesFn = loadTraces,
            .forgetTraceFn = forgetTrace,
            .upsertBeliefFn = upsertBelief,
            .loadBeliefsFn = loadBeliefs,
            .invalidateBeliefFn = invalidateBelief,
            .upsertSubjectFn = upsertSubject,
            .loadSubjectsFn = loadSubjects,
            .addArtifactFn = addArtifact,
            .loadArtifactsFn = loadArtifacts,
            .addDreamFn = addDream,
            .loadDreamsFn = loadDreams,
            .loadPeopleFn = loadPeople,
            .savePersonFn = savePerson,
            .addSightingFn = addSighting,
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
            .loadDreamRecordsFn = loadDreamRecords,
            .addDreamRecordFn = addDreamRecord,
            .loadExperiencesFn = loadExperiences,
            .addExperienceFn = addExperience,
            .sweepExpiredExperiencesFn = sweepExpiredExperiences,
            .sweepUnreferencedCapturesFn = sweepUnreferencedCaptures,
            .sweepRuntimeEventsFn = sweepRuntimeEvents,
            .retainCaptureFn = retainCapture,
            .logEventFn = logEvent,
        };
    }

    pub fn addTrace(ctx: *anyopaque, trace: schema.Trace) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        try self.traces.append(self.allocator, trace);
    }

    pub fn updateTrace(ctx: *anyopaque, trace: schema.Trace) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.traces.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.trace_id, trace.trace_id)) {
                self.traces.items[i] = trace;
                return;
            }
        }
        try self.traces.append(self.allocator, trace);
    }

    pub fn loadTraces(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.Trace {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.traces.items;
    }

    pub fn forgetTrace(ctx: *anyopaque, trace_id: []const u8) !bool {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.traces.items, 0..) |trace, i| {
            if (std.mem.eql(u8, trace.trace_id, trace_id)) {
                _ = self.traces.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn upsertBelief(ctx: *anyopaque, belief: schema.Belief) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.beliefs.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.belief_id, belief.belief_id)) {
                self.beliefs.items[i] = belief;
                return;
            }
        }
        try self.beliefs.append(self.allocator, belief);
    }

    pub fn loadBeliefs(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.Belief {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.beliefs.items;
    }

    pub fn invalidateBelief(ctx: *anyopaque, belief_id: []const u8, invalidated_at: []const u8) !bool {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.beliefs.items, 0..) |belief, i| {
            if (std.mem.eql(u8, belief.belief_id, belief_id)) {
                self.beliefs.items[i].lifecycle.status = .invalidated;
                self.beliefs.items[i].lifecycle.updated_at = invalidated_at;
                self.beliefs.items[i].lifecycle.invalidated_at = invalidated_at;
                return true;
            }
        }
        return false;
    }

    pub fn upsertSubject(ctx: *anyopaque, subject: schema.Subject) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.subjects.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.subject_id, subject.subject_id)) {
                self.subjects.items[i] = subject;
                return;
            }
        }
        try self.subjects.append(self.allocator, subject);
    }

    pub fn loadSubjects(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.Subject {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.subjects.items;
    }

    pub fn addArtifact(ctx: *anyopaque, artifact: schema.Artifact) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        try self.artifacts.append(self.allocator, artifact);
    }

    pub fn loadArtifacts(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.Artifact {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.artifacts.items;
    }

    pub fn addDream(ctx: *anyopaque, dream: schema.Dream) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        try self.cognitive_dreams.append(self.allocator, dream);
    }

    pub fn loadDreams(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.Dream {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.cognitive_dreams.items;
    }

    pub fn loadPeople(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.Person {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.people.items;
    }

    pub fn savePerson(ctx: *anyopaque, person: schema.Person) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.people.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.person_id, person.person_id)) {
                self.people.items[i] = person;
                return;
            }
        }
        try self.people.append(self.allocator, person);
    }

    pub fn addSighting(ctx: *anyopaque, sighting: schema.Sighting) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        try self.sightings.append(self.allocator, sighting);
    }

    pub fn findByName(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8) !?schema.Person {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.people.items) |p| {
            if (p.relationship_status != .forgotten and std.ascii.eqlIgnoreCase(p.display_name, name)) return p;
        }
        return null;
    }

    pub fn findById(ctx: *anyopaque, _: std.mem.Allocator, id: []const u8) !?schema.Person {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.people.items) |p| if (std.mem.eql(u8, p.person_id, id)) return p;
        return null;
    }

    pub fn forgetPerson(ctx: *anyopaque, person_id: []const u8) !bool {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.people.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.person_id, person_id) or std.ascii.eqlIgnoreCase(p.display_name, person_id)) {
                self.people.items[i].relationship_status = .forgotten;
                self.people.items[i].embeddings = &.{};
                return true;
            }
        }
        return false;
    }

    pub fn loadConversationSummaries(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.ConversationSummary {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.conversation_summaries.items;
    }

    pub fn addConversationSummary(ctx: *anyopaque, summary: schema.ConversationSummary) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        try self.conversation_summaries.append(self.allocator, summary);
    }

    pub fn loadMemoryRecords(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.MemoryRecord {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.memories.items;
    }

    pub fn saveMemoryRecord(ctx: *anyopaque, memory: schema.MemoryRecord) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.memories.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.memory_id, memory.memory_id)) {
                self.memories.items[i] = memory;
                try updateTrace(ctx, .{
                    .trace_id = memory.memory_id,
                    .source = .memory,
                    .kind = .memory_update,
                    .scope = switch (memory.scope) {
                        .short_term => .short_term,
                        .long_term => .long_term,
                    },
                    .text = memory.text,
                    .interpretation = memory.interpretation,
                    .confidence = memory.confidence,
                    .salience = memory.salience,
                    .valence = memory.valence,
                    .access_count = memory.access_count,
                    .score = memory.score,
                    .vector = memory.vector,
                    .tags = memory.tags,
                    .lifecycle = .{
                        .status = .active,
                        .created_at = memory.created_at,
                        .updated_at = memory.last_accessed_at orelse memory.created_at,
                        .revisions = memory.revisions,
                    },
                });
                return;
            }
        }
        try self.memories.append(self.allocator, memory);
        try addTrace(ctx, .{
            .trace_id = memory.memory_id,
            .source = .memory,
            .kind = .memory_update,
            .scope = switch (memory.scope) {
                .short_term => .short_term,
                .long_term => .long_term,
            },
            .text = memory.text,
            .interpretation = memory.interpretation,
            .confidence = memory.confidence,
            .salience = memory.salience,
            .valence = memory.valence,
            .access_count = memory.access_count,
            .score = memory.score,
            .vector = memory.vector,
            .tags = memory.tags,
            .lifecycle = .{
                .status = .active,
                .created_at = memory.created_at,
                .updated_at = memory.last_accessed_at orelse memory.created_at,
                .revisions = memory.revisions,
            },
        });
    }

    pub fn forgetMemoryRecord(ctx: *anyopaque, memory_id: []const u8) !bool {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.memories.items, 0..) |memory, i| {
            if (std.mem.eql(u8, memory.memory_id, memory_id)) {
                _ = self.memories.swapRemove(i);
                _ = try forgetTrace(ctx, memory_id);
                return true;
            }
        }
        return false;
    }

    pub fn loadFactRecords(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.FactRecord {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.facts.items;
    }

    pub fn saveFactRecord(ctx: *anyopaque, fact: schema.FactRecord) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.facts.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.fact_id, fact.fact_id)) {
                self.facts.items[i] = fact;
                try upsertBelief(ctx, .{
                    .belief_id = fact.fact_id,
                    .key = fact.key,
                    .proposition = fact.value,
                    .confidence = fact.confidence,
                    .tags = fact.tags,
                    .lifecycle = .{
                        .status = if (!fact.active) .invalidated else if (fact.confidence < 0.75) .doubted else .active,
                        .created_at = fact.created_at,
                        .updated_at = fact.updated_at,
                        .invalidated_at = fact.invalidated_at,
                        .revisions = fact.revisions,
                    },
                });
                return;
            }
        }
        try self.facts.append(self.allocator, fact);
        try upsertBelief(ctx, .{
            .belief_id = fact.fact_id,
            .key = fact.key,
            .proposition = fact.value,
            .confidence = fact.confidence,
            .tags = fact.tags,
            .lifecycle = .{
                .status = if (!fact.active) .invalidated else if (fact.confidence < 0.75) .doubted else .active,
                .created_at = fact.created_at,
                .updated_at = fact.updated_at,
                .invalidated_at = fact.invalidated_at,
                .revisions = fact.revisions,
            },
        });
    }

    pub fn invalidateFactRecord(ctx: *anyopaque, fact_id: []const u8, invalidated_at: []const u8) !bool {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.facts.items, 0..) |fact, i| {
            if (std.mem.eql(u8, fact.fact_id, fact_id)) {
                self.facts.items[i].active = false;
                self.facts.items[i].updated_at = invalidated_at;
                self.facts.items[i].invalidated_at = invalidated_at;
                _ = try invalidateBelief(ctx, fact_id, invalidated_at);
                return true;
            }
        }
        return false;
    }

    pub fn loadImpressions(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.Impression {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.impressions.items;
    }

    pub fn addImpression(ctx: *anyopaque, impression: schema.Impression) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        try self.impressions.append(self.allocator, impression);
    }

    pub fn loadAppraisals(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.Appraisal {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.appraisals.items;
    }

    pub fn addAppraisal(ctx: *anyopaque, appraisal: schema.Appraisal) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        try self.appraisals.append(self.allocator, appraisal);
    }

    pub fn loadDreamRecords(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.DreamRecord {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.dreams.items;
    }

    pub fn addDreamRecord(ctx: *anyopaque, dream: schema.DreamRecord) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        try self.dreams.append(self.allocator, dream);
    }

    pub fn loadExperiences(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.Experience {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.experiences.items;
    }

    pub fn addExperience(ctx: *anyopaque, experience: schema.Experience) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        try self.experiences.append(self.allocator, experience);
    }

    pub fn sweepExpiredExperiences(ctx: *anyopaque, now_seconds: i64) !usize {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.experiences.items.len) {
            const experience = self.experiences.items[i];
            const expires_at = experience.expires_at orelse {
                i += 1;
                continue;
            };
            const expires = std.fmt.parseInt(i64, expires_at, 10) catch {
                i += 1;
                continue;
            };
            if ((experience.retention == .raw_ephemeral or experience.retention == .discard) and expires <= now_seconds) {
                _ = self.experiences.swapRemove(i);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }

    pub fn sweepUnreferencedCaptures(_: *anyopaque) !usize {
        return 0;
    }

    pub fn sweepRuntimeEvents(ctx: *anyopaque) !usize {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        self.runtime_event_sweep_count += 1;
        return 0;
    }

    pub fn retainCapture(ctx: *anyopaque, allocator: std.mem.Allocator, source_path: []const u8, _: []const u8) ![]const u8 {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        if (self.retain_prefix) |prefix| {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, std.fs.path.basename(source_path) });
        }
        return allocator.dupe(u8, source_path);
    }

    pub fn logEvent(ctx: *anyopaque, json_line: []const u8) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        self.log_count += 1;
        try self.runtime_events.append(self.allocator, try self.allocator.dupe(u8, json_line));
    }
};
