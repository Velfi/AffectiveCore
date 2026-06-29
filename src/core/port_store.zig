const std = @import("std");
const schema = @import("port_schema.zig");

pub const MemoryStore = struct {
    ctx: *anyopaque,
    upsertBeliefFn: *const fn (*anyopaque, schema.Belief) anyerror!void,
    loadBeliefsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Belief,
    invalidateBeliefFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!bool,
    upsertSubjectFn: *const fn (*anyopaque, schema.Subject) anyerror!void,
    loadSubjectsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Subject,
    addArtifactFn: *const fn (*anyopaque, schema.Artifact) anyerror!void,
    loadArtifactsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Artifact,
    loadPeopleFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Person,
    savePersonFn: *const fn (*anyopaque, schema.Person) anyerror!void,
    addSightingFn: *const fn (*anyopaque, schema.Sighting) anyerror!void,
    loadSightingsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Sighting,
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
    sweepExpiredExperiencesFn: *const fn (*anyopaque, i64) anyerror!usize,
    sweepUnreferencedCapturesFn: *const fn (*anyopaque) anyerror!usize,
    pruneTombstonedCognitiveRecordsFn: *const fn (*anyopaque, []const u8) anyerror!schema.CognitivePruneResult,
    retainCaptureFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror![]const u8,
    addExperienceEventFn: *const fn (*anyopaque, schema.ExperienceEvent) anyerror!void,
    loadExperienceEventsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.ExperienceEvent,
    setBrainModeFn: *const fn (*anyopaque, schema.BrainMode) anyerror!void,
    loadBrainModeFn: *const fn (*anyopaque) anyerror!schema.BrainMode,
    upsertHostBindingFn: *const fn (*anyopaque, schema.HostBinding) anyerror!void,
    loadHostBindingsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.HostBinding,
    upsertCapabilityStatusFn: *const fn (*anyopaque, schema.CapabilityStatus) anyerror!void,
    loadCapabilityStatusesFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.CapabilityStatus,
    addCapabilityRequestFn: *const fn (*anyopaque, schema.CapabilityRequest) anyerror!void,
    addCapabilityResultFn: *const fn (*anyopaque, schema.CapabilityResult) anyerror!void,
    upsertSelfTrustFn: *const fn (*anyopaque, schema.SelfTrustEntry) anyerror!void,
    loadSelfTrustFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.SelfTrustEntry,
    upsertDispositionFn: *const fn (*anyopaque, schema.Disposition) anyerror!void,
    loadDispositionsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.Disposition,
    addActionPressureFn: *const fn (*anyopaque, schema.ActionPressure) anyerror!void,
    loadActionPressuresFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.ActionPressure,
    addActionOutcomeFn: *const fn (*anyopaque, schema.ActionOutcome) anyerror!void,
    loadActionOutcomesFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.ActionOutcome,
    upsertActionOutcomeFn: *const fn (*anyopaque, schema.ActionOutcome) anyerror!void,
    loadCapabilityResultsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.CapabilityResult,
    loadCapabilityRequestsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.CapabilityRequest,
    addDreamTimeRecordFn: *const fn (*anyopaque, schema.DreamTimeRecord) anyerror!void,
    loadDreamTimeRecordsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.DreamTimeRecord,
    addMailboxItemFn: *const fn (*anyopaque, schema.MailboxItem) anyerror!void,
    loadMailboxItemsFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.MailboxItem,
    markMailboxItemReadFn: *const fn (*anyopaque, []const u8, i64) anyerror!schema.MailboxItem,
    addIdentityHypothesisFn: *const fn (*anyopaque, schema.IdentityHypothesis) anyerror!void,
    loadIdentityHypothesesFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.IdentityHypothesis,
    saveActiveActivityFn: *const fn (*anyopaque, ?schema.ActivityRecord) anyerror!void,
    loadActiveActivityFn: *const fn (*anyopaque, std.mem.Allocator) anyerror!?schema.ActivityRecord,
    saveActivityStackFn: *const fn (*anyopaque, []const schema.ActivityRecord) anyerror!void,
    loadActivityStackFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.ActivityRecord,
    appendActivityHistoryFn: *const fn (*anyopaque, schema.ActivityRecord) anyerror!void,
    loadActivityHistoryFn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]schema.ActivityRecord,
    beginDeferredPersistFn: *const fn (*anyopaque) anyerror!void,
    endDeferredPersistFn: *const fn (*anyopaque) anyerror!void,
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

    pub fn loadPeople(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.Person {
        return self.loadPeopleFn(self.ctx, allocator);
    }

    pub fn savePerson(self: MemoryStore, person: schema.Person) !void {
        return self.savePersonFn(self.ctx, person);
    }

    pub fn addSighting(self: MemoryStore, sighting: schema.Sighting) !void {
        return self.addSightingFn(self.ctx, sighting);
    }

    pub fn loadSightings(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.Sighting {
        return self.loadSightingsFn(self.ctx, allocator);
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

    pub fn sweepExpiredExperiences(self: MemoryStore, now_seconds: i64) !usize {
        return self.sweepExpiredExperiencesFn(self.ctx, now_seconds);
    }

    pub fn sweepUnreferencedCaptures(self: MemoryStore) !usize {
        return self.sweepUnreferencedCapturesFn(self.ctx);
    }

    pub fn pruneTombstonedCognitiveRecords(self: MemoryStore, now: []const u8) !schema.CognitivePruneResult {
        return self.pruneTombstonedCognitiveRecordsFn(self.ctx, now);
    }

    pub fn retainCapture(self: MemoryStore, allocator: std.mem.Allocator, source_path: []const u8, label: []const u8) ![]const u8 {
        return self.retainCaptureFn(self.ctx, allocator, source_path, label);
    }


    pub fn addExperienceEvent(self: MemoryStore, event: schema.ExperienceEvent) !void { return self.addExperienceEventFn(self.ctx, event); }
    pub fn loadExperienceEvents(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.ExperienceEvent { return self.loadExperienceEventsFn(self.ctx, allocator); }
    pub fn setBrainMode(self: MemoryStore, mode: schema.BrainMode) !void { return self.setBrainModeFn(self.ctx, mode); }
    pub fn loadBrainMode(self: MemoryStore) !schema.BrainMode { return self.loadBrainModeFn(self.ctx); }
    pub fn upsertHostBinding(self: MemoryStore, binding: schema.HostBinding) !void { return self.upsertHostBindingFn(self.ctx, binding); }
    pub fn loadHostBindings(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.HostBinding { return self.loadHostBindingsFn(self.ctx, allocator); }
    pub fn upsertCapabilityStatus(self: MemoryStore, status: schema.CapabilityStatus) !void { return self.upsertCapabilityStatusFn(self.ctx, status); }
    pub fn loadCapabilityStatuses(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.CapabilityStatus { return self.loadCapabilityStatusesFn(self.ctx, allocator); }
    pub fn addCapabilityRequest(self: MemoryStore, request: schema.CapabilityRequest) !void { return self.addCapabilityRequestFn(self.ctx, request); }
    pub fn addCapabilityResult(self: MemoryStore, result: schema.CapabilityResult) !void { return self.addCapabilityResultFn(self.ctx, result); }
    pub fn upsertSelfTrust(self: MemoryStore, entry: schema.SelfTrustEntry) !void { return self.upsertSelfTrustFn(self.ctx, entry); }
    pub fn loadSelfTrust(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.SelfTrustEntry { return self.loadSelfTrustFn(self.ctx, allocator); }
    pub fn upsertDisposition(self: MemoryStore, disposition: schema.Disposition) !void { return self.upsertDispositionFn(self.ctx, disposition); }
    pub fn loadDispositions(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.Disposition { return self.loadDispositionsFn(self.ctx, allocator); }
    pub fn addActionPressure(self: MemoryStore, pressure: schema.ActionPressure) !void { return self.addActionPressureFn(self.ctx, pressure); }
    pub fn loadActionPressures(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.ActionPressure { return self.loadActionPressuresFn(self.ctx, allocator); }
    pub fn addActionOutcome(self: MemoryStore, outcome: schema.ActionOutcome) !void { return self.addActionOutcomeFn(self.ctx, outcome); }
    pub fn loadActionOutcomes(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.ActionOutcome { return self.loadActionOutcomesFn(self.ctx, allocator); }
    pub fn upsertActionOutcome(self: MemoryStore, outcome: schema.ActionOutcome) !void { return self.upsertActionOutcomeFn(self.ctx, outcome); }
    pub fn loadCapabilityResults(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.CapabilityResult { return self.loadCapabilityResultsFn(self.ctx, allocator); }
    pub fn loadCapabilityRequests(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.CapabilityRequest { return self.loadCapabilityRequestsFn(self.ctx, allocator); }
    pub fn addDreamTimeRecord(self: MemoryStore, dream: schema.DreamTimeRecord) !void { return self.addDreamTimeRecordFn(self.ctx, dream); }
    pub fn loadDreamTimeRecords(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.DreamTimeRecord { return self.loadDreamTimeRecordsFn(self.ctx, allocator); }
    pub fn addMailboxItem(self: MemoryStore, item: schema.MailboxItem) !void { return self.addMailboxItemFn(self.ctx, item); }
    pub fn loadMailboxItems(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.MailboxItem { return self.loadMailboxItemsFn(self.ctx, allocator); }
    pub fn markMailboxItemRead(self: MemoryStore, mailbox_id: []const u8, read_at_ms: i64) !schema.MailboxItem { return self.markMailboxItemReadFn(self.ctx, mailbox_id, read_at_ms); }
    pub fn addIdentityHypothesis(self: MemoryStore, hypothesis: schema.IdentityHypothesis) !void { return self.addIdentityHypothesisFn(self.ctx, hypothesis); }
    pub fn loadIdentityHypotheses(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.IdentityHypothesis { return self.loadIdentityHypothesesFn(self.ctx, allocator); }
    pub fn saveActiveActivity(self: MemoryStore, record: ?schema.ActivityRecord) !void { return self.saveActiveActivityFn(self.ctx, record); }
    pub fn loadActiveActivity(self: MemoryStore, allocator: std.mem.Allocator) !?schema.ActivityRecord { return self.loadActiveActivityFn(self.ctx, allocator); }
    pub fn saveActivityStack(self: MemoryStore, stack: []const schema.ActivityRecord) !void { return self.saveActivityStackFn(self.ctx, stack); }
    pub fn loadActivityStack(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.ActivityRecord { return self.loadActivityStackFn(self.ctx, allocator); }
    pub fn appendActivityHistory(self: MemoryStore, record: schema.ActivityRecord) !void { return self.appendActivityHistoryFn(self.ctx, record); }
    pub fn loadActivityHistory(self: MemoryStore, allocator: std.mem.Allocator) ![]schema.ActivityRecord { return self.loadActivityHistoryFn(self.ctx, allocator); }
    pub fn beginDeferredPersist(self: MemoryStore) !void { return self.beginDeferredPersistFn(self.ctx); }
    pub fn endDeferredPersist(self: MemoryStore) !void { return self.endDeferredPersistFn(self.ctx); }
};
