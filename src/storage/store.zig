const std = @import("std");
const schema = @import("schema.zig");

pub const MemoryStore = struct {
    ctx: *anyopaque,
    addTraceFn: *const fn (*anyopaque, schema.Trace) anyerror!void,
    updateTraceFn: *const fn (*anyopaque, schema.Trace) anyerror!void,
    loadTracesFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Trace,
    forgetTraceFn: *const fn (*anyopaque, []const u8) anyerror!bool,
    upsertBeliefFn: *const fn (*anyopaque, schema.Belief) anyerror!void,
    loadBeliefsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Belief,
    invalidateBeliefFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!bool,
    upsertSubjectFn: *const fn (*anyopaque, schema.Subject) anyerror!void,
    loadSubjectsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Subject,
    addArtifactFn: *const fn (*anyopaque, schema.Artifact) anyerror!void,
    loadArtifactsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Artifact,
    addDreamFn: *const fn (*anyopaque, schema.Dream) anyerror!void,
    loadDreamsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Dream,
    loadPeopleFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Person,
    savePersonFn: *const fn (*anyopaque, schema.Person) anyerror!void,
    addSightingFn: *const fn (*anyopaque, schema.Sighting) anyerror!void,
    findByNameFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?schema.Person,
    findByIdFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?schema.Person,
    forgetPersonFn: *const fn (*anyopaque, []const u8) anyerror!bool,
    loadConversationSummariesFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.ConversationSummary,
    addConversationSummaryFn: *const fn (*anyopaque, schema.ConversationSummary) anyerror!void,
    loadMemoryRecordsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.MemoryRecord,
    saveMemoryRecordFn: *const fn (*anyopaque, schema.MemoryRecord) anyerror!void,
    forgetMemoryRecordFn: *const fn (*anyopaque, []const u8) anyerror!bool,
    loadFactRecordsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.FactRecord,
    saveFactRecordFn: *const fn (*anyopaque, schema.FactRecord) anyerror!void,
    invalidateFactRecordFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!bool,
    loadImpressionsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Impression,
    addImpressionFn: *const fn (*anyopaque, schema.Impression) anyerror!void,
    loadAppraisalsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Appraisal,
    addAppraisalFn: *const fn (*anyopaque, schema.Appraisal) anyerror!void,
    loadDreamRecordsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.DreamRecord,
    addDreamRecordFn: *const fn (*anyopaque, schema.DreamRecord) anyerror!void,
    loadExperiencesFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Experience,
    addExperienceFn: *const fn (*anyopaque, schema.Experience) anyerror!void,
    sweepExpiredExperiencesFn: *const fn (*anyopaque, i64) anyerror!usize,
    sweepUnreferencedCapturesFn: *const fn (*anyopaque) anyerror!usize,
    sweepRuntimeEventsFn: *const fn (*anyopaque) anyerror!usize,
    retainCaptureFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror![]const u8,
    logEventFn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn addTrace(self: MemoryStore, trace: schema.Trace) !void {
        return self.addTraceFn(self.ctx, trace);
    }

    pub fn updateTrace(self: MemoryStore, trace: schema.Trace) !void {
        return self.updateTraceFn(self.ctx, trace);
    }

    pub fn loadTraces(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.Trace {
        return self.loadTracesFn(self.ctx, allocator);
    }

    pub fn forgetTrace(self: MemoryStore, trace_id: []const u8) !bool {
        return self.forgetTraceFn(self.ctx, trace_id);
    }

    pub fn upsertBelief(self: MemoryStore, belief: schema.Belief) !void {
        return self.upsertBeliefFn(self.ctx, belief);
    }

    pub fn loadBeliefs(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.Belief {
        return self.loadBeliefsFn(self.ctx, allocator);
    }

    pub fn invalidateBelief(self: MemoryStore, belief_id: []const u8, invalidated_at: []const u8) !bool {
        return self.invalidateBeliefFn(self.ctx, belief_id, invalidated_at);
    }

    pub fn upsertSubject(self: MemoryStore, subject: schema.Subject) !void {
        return self.upsertSubjectFn(self.ctx, subject);
    }

    pub fn loadSubjects(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.Subject {
        return self.loadSubjectsFn(self.ctx, allocator);
    }

    pub fn addArtifact(self: MemoryStore, artifact: schema.Artifact) !void {
        return self.addArtifactFn(self.ctx, artifact);
    }

    pub fn loadArtifacts(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.Artifact {
        return self.loadArtifactsFn(self.ctx, allocator);
    }

    pub fn addDream(self: MemoryStore, dream: schema.Dream) !void {
        return self.addDreamFn(self.ctx, dream);
    }

    pub fn loadDreams(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.Dream {
        return self.loadDreamsFn(self.ctx, allocator);
    }

    pub fn loadPeople(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.Person {
        return self.loadPeopleFn(self.ctx, allocator);
    }

    pub fn savePerson(self: MemoryStore, person: schema.Person) !void {
        return self.savePersonFn(self.ctx, person);
    }

    pub fn addSighting(self: MemoryStore, sighting: schema.Sighting) !void {
        return self.addSightingFn(self.ctx, sighting);
    }

    pub fn findByName(self: MemoryStore, allocator: std.mem.Allocator, name: []const u8) !?schema.Person {
        return self.findByNameFn(self.ctx, allocator, name);
    }

    pub fn findById(self: MemoryStore, allocator: std.mem.Allocator, id: []const u8) !?schema.Person {
        return self.findByIdFn(self.ctx, allocator, id);
    }

    pub fn forgetPerson(self: MemoryStore, person_id: []const u8) !bool {
        return self.forgetPersonFn(self.ctx, person_id);
    }

    pub fn loadConversationSummaries(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.ConversationSummary {
        return self.loadConversationSummariesFn(self.ctx, allocator);
    }

    pub fn addConversationSummary(self: MemoryStore, summary: schema.ConversationSummary) !void {
        return self.addConversationSummaryFn(self.ctx, summary);
    }

    pub fn loadMemoryRecords(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.MemoryRecord {
        return self.loadMemoryRecordsFn(self.ctx, allocator);
    }

    pub fn saveMemoryRecord(self: MemoryStore, memory: schema.MemoryRecord) !void {
        return self.saveMemoryRecordFn(self.ctx, memory);
    }

    pub fn forgetMemoryRecord(self: MemoryStore, memory_id: []const u8) !bool {
        return self.forgetMemoryRecordFn(self.ctx, memory_id);
    }

    pub fn loadFactRecords(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.FactRecord {
        return self.loadFactRecordsFn(self.ctx, allocator);
    }

    pub fn saveFactRecord(self: MemoryStore, fact: schema.FactRecord) !void {
        return self.saveFactRecordFn(self.ctx, fact);
    }

    pub fn invalidateFactRecord(self: MemoryStore, fact_id: []const u8, invalidated_at: []const u8) !bool {
        return self.invalidateFactRecordFn(self.ctx, fact_id, invalidated_at);
    }

    pub fn loadImpressions(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.Impression {
        return self.loadImpressionsFn(self.ctx, allocator);
    }

    pub fn addImpression(self: MemoryStore, impression: schema.Impression) !void {
        return self.addImpressionFn(self.ctx, impression);
    }

    pub fn loadAppraisals(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.Appraisal {
        return self.loadAppraisalsFn(self.ctx, allocator);
    }

    pub fn addAppraisal(self: MemoryStore, appraisal: schema.Appraisal) !void {
        return self.addAppraisalFn(self.ctx, appraisal);
    }

    pub fn loadDreamRecords(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.DreamRecord {
        return self.loadDreamRecordsFn(self.ctx, allocator);
    }

    pub fn addDreamRecord(self: MemoryStore, dream: schema.DreamRecord) !void {
        return self.addDreamRecordFn(self.ctx, dream);
    }

    pub fn loadExperiences(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.Experience {
        return self.loadExperiencesFn(self.ctx, allocator);
    }

    pub fn addExperience(self: MemoryStore, experience: schema.Experience) !void {
        return self.addExperienceFn(self.ctx, experience);
    }

    pub fn sweepExpiredExperiences(self: MemoryStore, now_seconds: i64) !usize {
        return self.sweepExpiredExperiencesFn(self.ctx, now_seconds);
    }

    pub fn sweepUnreferencedCaptures(self: MemoryStore) !usize {
        return self.sweepUnreferencedCapturesFn(self.ctx);
    }

    pub fn sweepRuntimeEvents(self: MemoryStore) !usize {
        return self.sweepRuntimeEventsFn(self.ctx);
    }

    pub fn retainCapture(self: MemoryStore, allocator: std.mem.Allocator, source_path: []const u8, label: []const u8) ![]const u8 {
        return self.retainCaptureFn(self.ctx, allocator, source_path, label);
    }

    pub fn logEvent(self: MemoryStore, json_line: []const u8) !void {
        return self.logEventFn(self.ctx, json_line);
    }
};
