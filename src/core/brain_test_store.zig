const std = @import("std");
const brain_mod = @import("brain.zig");
const config_mod = @import("config.zig");
const events = @import("events.zig");
const identity = @import("identity.zig");
const interrupt_mod = @import("interrupt.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const store_mod = ports.store;
const openai = ports.openai;
const chat_mod = ports.chat;
const audio_mod = ports.audio;
const want_achievement_mod = ports.want_achievement;
const persona_directive_mod = ports.persona_directive;
const camera_mod = ports.camera;
const input_mod = ports.input;
const event_log_mod = ports.event_log;
const facial_expression = ports.facial_expression;
const id_monitor = @import("id_monitor.zig");
const maintenance = @import("maintenance.zig");
const cognitive_clone = @import("../storage/json_store_cognitive.zig");

const Brain = brain_mod.Brain;
const BrainDeps = brain_mod.BrainDeps;

pub const TestStore = struct {
    allocator: std.mem.Allocator,
    people: std.ArrayList(schema.Person),
    sightings: std.ArrayList(schema.Sighting),
    conversation_summaries: std.ArrayList(schema.ConversationSummary),
    memories: std.ArrayList(schema.MemoryRecord),
    facts: std.ArrayList(schema.FactRecord),
    beliefs: std.ArrayList(schema.Belief),
    subjects: std.ArrayList(schema.Subject),
    artifacts: std.ArrayList(schema.Artifact),
    impressions: std.ArrayList(schema.Impression),
    appraisals: std.ArrayList(schema.Appraisal),
    experience_events: std.ArrayList(schema.ExperienceEvent),
    host_bindings: std.ArrayList(schema.HostBinding),
    capability_statuses: std.ArrayList(schema.CapabilityStatus),
    capability_requests: std.ArrayList(schema.CapabilityRequest),
    capability_results: std.ArrayList(schema.CapabilityResult),
    self_trust: std.ArrayList(schema.SelfTrustEntry),
    dispositions: std.ArrayList(schema.Disposition),
    action_pressures: std.ArrayList(schema.ActionPressure),
    action_outcomes: std.ArrayList(schema.ActionOutcome),
    dream_time_records: std.ArrayList(schema.DreamTimeRecord),
    mailbox_items: std.ArrayList(schema.MailboxItem),
    identity_hypotheses: std.ArrayList(schema.IdentityHypothesis),
    active_activity: ?schema.ActivityRecord = null,
    activity_stack: std.ArrayList(schema.ActivityRecord),
    activity_history: std.ArrayList(schema.ActivityRecord),
    brain_mode: schema.BrainMode = .waking,
    want_detector: want_achievement_mod.ScriptedWantAchievementDetector,
    persona_synthesizer: persona_directive_mod.ScriptedPersonaDirectiveSynthesizer,
    retain_prefix: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) TestStore {
        return .{
            .allocator = allocator,
            .people = .empty,
            .sightings = .empty,
            .conversation_summaries = .empty,
            .memories = .empty,
            .facts = .empty,
            .beliefs = .empty,
            .subjects = .empty,
            .artifacts = .empty,
            .impressions = .empty,
            .appraisals = .empty,
            .experience_events = .empty,
            .host_bindings = .empty,
            .capability_statuses = .empty,
            .capability_requests = .empty,
            .capability_results = .empty,
            .self_trust = .empty,
            .dispositions = .empty,
            .action_pressures = .empty,
            .action_outcomes = .empty,
            .dream_time_records = .empty,
            .mailbox_items = .empty,
            .identity_hypotheses = .empty,
            .activity_stack = .empty,
            .activity_history = .empty,
            .want_detector = .{},
            .persona_synthesizer = .{
                .directive = .{
                    .persona = "You are a thoughtful companion learning to ask before acting certain.",
                    .short_term = "Keep clarifying uncertain recognition and stay present with greetings.",
                    .long_term = "Figure out who you are while staying honest about uncertainty.",
                },
            },
        };
    }

    pub fn store(self: *TestStore) store_mod.MemoryStore {
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
            .beginDeferredPersistFn = beginDeferredPersist,
            .endDeferredPersistFn = endDeferredPersist,
        };
    }

    pub fn beginDeferredPersist(_: *anyopaque) !void {}

    pub fn endDeferredPersist(_: *anyopaque) !void {}

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


    pub fn addExperienceEvent(ctx: *anyopaque, event: schema.ExperienceEvent) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        try self.experience_events.append(self.allocator, event);
    }

    pub fn loadExperienceEvents(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.ExperienceEvent {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.experience_events.items;
    }

    pub fn setBrainMode(ctx: *anyopaque, mode: schema.BrainMode) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        self.brain_mode = mode;
    }

    pub fn loadBrainMode(ctx: *anyopaque) !schema.BrainMode {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.brain_mode;
    }

    pub fn upsertHostBinding(ctx: *anyopaque, binding: schema.HostBinding) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.host_bindings.items, 0..) |existing, i| if (std.mem.eql(u8, existing.host_id, binding.host_id)) { self.host_bindings.items[i] = binding; return; };
        try self.host_bindings.append(self.allocator, binding);
    }

    pub fn loadHostBindings(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.HostBinding { const self: *TestStore = @ptrCast(@alignCast(ctx)); return self.host_bindings.items; }

    pub fn upsertCapabilityStatus(ctx: *anyopaque, status: schema.CapabilityStatus) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.capability_statuses.items, 0..) |existing, i| if (std.mem.eql(u8, existing.capability_id, status.capability_id) and std.mem.eql(u8, existing.host_id, status.host_id)) { self.capability_statuses.items[i] = status; return; };
        try self.capability_statuses.append(self.allocator, status);
    }

    pub fn loadCapabilityStatuses(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.CapabilityStatus { const self: *TestStore = @ptrCast(@alignCast(ctx)); return self.capability_statuses.items; }
    pub fn addCapabilityRequest(ctx: *anyopaque, request: schema.CapabilityRequest) !void { const self: *TestStore = @ptrCast(@alignCast(ctx)); try self.capability_requests.append(self.allocator, request); }
    pub fn addCapabilityResult(ctx: *anyopaque, result: schema.CapabilityResult) !void { const self: *TestStore = @ptrCast(@alignCast(ctx)); try self.capability_results.append(self.allocator, result); }

    pub fn upsertSelfTrust(ctx: *anyopaque, entry: schema.SelfTrustEntry) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.self_trust.items, 0..) |existing, i| if (std.mem.eql(u8, existing.self_trust_id, entry.self_trust_id)) { self.self_trust.items[i] = entry; return; };
        try self.self_trust.append(self.allocator, entry);
    }

    pub fn loadSelfTrust(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.SelfTrustEntry { const self: *TestStore = @ptrCast(@alignCast(ctx)); return self.self_trust.items; }

    pub fn upsertDisposition(ctx: *anyopaque, disposition: schema.Disposition) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.dispositions.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.disposition_id, disposition.disposition_id)) {
                freeDispositionOwned(self.allocator, existing);
                self.dispositions.items[i] = disposition;
                return;
            }
        }
        try self.dispositions.append(self.allocator, disposition);
    }

    fn freeDispositionOwned(allocator: std.mem.Allocator, disposition: schema.Disposition) void {
        allocator.free(disposition.disposition_id);
        allocator.free(disposition.context_pattern);
        allocator.free(disposition.action_tendency);
        for (disposition.source_event_ids) |event_id| allocator.free(event_id);
        for (disposition.source_dream_ids) |dream_id| allocator.free(dream_id);
    }

    pub fn loadDispositions(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.Disposition { const self: *TestStore = @ptrCast(@alignCast(ctx)); return self.dispositions.items; }
    pub fn addActionPressure(ctx: *anyopaque, pressure: schema.ActionPressure) !void { const self: *TestStore = @ptrCast(@alignCast(ctx)); try self.action_pressures.append(self.allocator, pressure); }
    pub fn loadActionPressures(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.ActionPressure { const self: *TestStore = @ptrCast(@alignCast(ctx)); return self.action_pressures.items; }
    pub fn addActionOutcome(ctx: *anyopaque, outcome: schema.ActionOutcome) !void { const self: *TestStore = @ptrCast(@alignCast(ctx)); try self.action_outcomes.append(self.allocator, outcome); }
    pub fn loadActionOutcomes(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.ActionOutcome { const self: *TestStore = @ptrCast(@alignCast(ctx)); return self.action_outcomes.items; }
    pub fn upsertActionOutcome(ctx: *anyopaque, outcome: schema.ActionOutcome) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.action_outcomes.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.outcome_id, outcome.outcome_id)) {
                self.action_outcomes.items[i] = outcome;
                return;
            }
        }
        try self.action_outcomes.append(self.allocator, outcome);
    }
    pub fn loadCapabilityResults(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.CapabilityResult { const self: *TestStore = @ptrCast(@alignCast(ctx)); return self.capability_results.items; }
    pub fn loadCapabilityRequests(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.CapabilityRequest { const self: *TestStore = @ptrCast(@alignCast(ctx)); return self.capability_requests.items; }
    pub fn addDreamTimeRecord(ctx: *anyopaque, dream: schema.DreamTimeRecord) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.dream_time_records.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.dream_id, dream.dream_id)) {
                self.dream_time_records.items[i] = dream;
                return;
            }
        }
        try self.dream_time_records.append(self.allocator, dream);
    }
    pub fn loadDreamTimeRecords(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.DreamTimeRecord { const self: *TestStore = @ptrCast(@alignCast(ctx)); return self.dream_time_records.items; }
    pub fn addMailboxItem(ctx: *anyopaque, item: schema.MailboxItem) !void { const self: *TestStore = @ptrCast(@alignCast(ctx)); try self.mailbox_items.append(self.allocator, item); }
    pub fn loadMailboxItems(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.MailboxItem { const self: *TestStore = @ptrCast(@alignCast(ctx)); return self.mailbox_items.items; }
    pub fn markMailboxItemRead(ctx: *anyopaque, mailbox_id: []const u8, read_at_ms: i64) !schema.MailboxItem {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.mailbox_items.items) |*item| {
            if (std.mem.eql(u8, item.mailbox_id, mailbox_id)) {
                item.read_at_ms = read_at_ms;
                return item.*;
            }
        }
        return error.UnknownMailboxItem;
    }
    pub fn addIdentityHypothesis(ctx: *anyopaque, hypothesis: schema.IdentityHypothesis) !void { const self: *TestStore = @ptrCast(@alignCast(ctx)); try self.identity_hypotheses.append(self.allocator, hypothesis); }
    pub fn loadIdentityHypotheses(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.IdentityHypothesis { const self: *TestStore = @ptrCast(@alignCast(ctx)); return self.identity_hypotheses.items; }

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

    pub fn loadSightings(ctx: *anyopaque, _: std.mem.Allocator) ![]schema.Sighting {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        return self.sightings.items;
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
                return;
            }
        }
        try self.memories.append(self.allocator, memory);
    }

    pub fn forgetMemoryRecord(ctx: *anyopaque, memory_id: []const u8) !bool {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.memories.items, 0..) |memory, i| {
            if (std.mem.eql(u8, memory.memory_id, memory_id)) {
                _ = self.memories.swapRemove(i);
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

    pub fn sweepExpiredExperiences(_: *anyopaque, _: i64) !usize {
        return 0;
    }

    pub fn sweepUnreferencedCaptures(_: *anyopaque) !usize {
        return 0;
    }

    pub fn pruneTombstonedCognitiveRecords(_: *anyopaque, _: []const u8) !schema.CognitivePruneResult {
        return .{};
    }


    pub fn retainCapture(ctx: *anyopaque, allocator: std.mem.Allocator, source_path: []const u8, _: []const u8) ![]const u8 {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        if (self.retain_prefix) |prefix| {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, std.fs.path.basename(source_path) });
        }
        return allocator.dupe(u8, source_path);
    }

    pub fn saveActiveActivity(ctx: *anyopaque, record: ?schema.ActivityRecord) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        self.active_activity = if (record) |active| try cognitive_clone.cloneActivityRecord(self.allocator, active) else null;
    }

    pub fn loadActiveActivity(ctx: *anyopaque, allocator: std.mem.Allocator) !?schema.ActivityRecord {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        const active = self.active_activity orelse return null;
        return try cognitive_clone.cloneActivityRecord(allocator, active);
    }

    pub fn saveActivityStack(ctx: *anyopaque, stack: []const schema.ActivityRecord) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        for (self.activity_stack.items) |previous| cognitive_clone.freeActivityRecord(self.allocator, previous);
        self.activity_stack.clearRetainingCapacity();
        for (stack) |record| {
            try self.activity_stack.append(self.allocator, try cognitive_clone.cloneActivityRecord(self.allocator, record));
        }
    }

    pub fn loadActivityStack(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.ActivityRecord {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        var copied = try allocator.alloc(schema.ActivityRecord, self.activity_stack.items.len);
        for (self.activity_stack.items, 0..) |record, i| {
            copied[i] = try cognitive_clone.cloneActivityRecord(allocator, record);
        }
        return copied;
    }

    pub fn appendActivityHistory(ctx: *anyopaque, record: schema.ActivityRecord) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        try self.activity_history.append(self.allocator, try cognitive_clone.cloneActivityRecord(self.allocator, record));
    }

    pub fn loadActivityHistory(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.ActivityRecord {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        var copied = try allocator.alloc(schema.ActivityRecord, self.activity_history.items.len);
        for (self.activity_history.items, 0..) |record, i| {
            copied[i] = try cognitive_clone.cloneActivityRecord(allocator, record);
        }
        return copied;
    }

};
