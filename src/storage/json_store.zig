const std = @import("std");
const schema = @import("schema.zig");
const store_mod = @import("store.zig");
const files = @import("../platform/common/files.zig");

const default_capture_dir = "data/captures";
const deletion_marker_suffix = ".delete";

const persistence = @import("json_store_persistence.zig");
const cognitive = @import("json_store_cognitive.zig");
const cognitive_enum_diagnostics = @import("json_store_cognitive_enum_diagnostics.zig");
const runtime_event_compaction = @import("json_store_runtime_event_compaction.zig");

const active_event_log_target_bytes = runtime_event_compaction.active_event_log_target_bytes;
const active_event_log_read_limit = runtime_event_compaction.active_event_log_read_limit;

pub const CognitiveEnumDiagnostic = cognitive_enum_diagnostics.CognitiveEnumDiagnostic;
pub const cognitiveEnumDiagnosticAlloc = cognitive_enum_diagnostics.cognitiveEnumDiagnosticAlloc;

pub const JsonMemoryStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    memory_path: []const u8,
    events_path: []const u8,
    capture_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, memory_path: []const u8, events_path: []const u8) JsonMemoryStore {
        return initWithCaptureDir(allocator, io, memory_path, events_path, default_capture_dir);
    }

    pub fn initWithCaptureDir(allocator: std.mem.Allocator, io: std.Io, memory_path: []const u8, events_path: []const u8, captures_path: []const u8) JsonMemoryStore {
        return .{ .allocator = allocator, .io = io, .memory_path = memory_path, .events_path = events_path, .capture_dir = captures_path };
    }

    pub fn store(self: *JsonMemoryStore) store_mod.MemoryStore {
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

    fn readAll(self: *JsonMemoryStore, allocator: std.mem.Allocator) !schema.CognitiveFile {
        const bytes = try persistence.readCognitiveJson(self.allocator, self.io, self.memory_path, allocator);
        defer allocator.free(bytes);
        const version = try persistence.parseSchemaVersion(allocator, bytes);
        if (version != persistence.current_schema_version) return error.UnsupportedCognitiveSchemaVersion;
        const parsed = std.json.parseFromSlice(schema.CognitiveFile, allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err| {
            if (err == error.InvalidEnumTag) cognitive_enum_diagnostics.traceInvalidCognitiveEnumTag(self.allocator, self.memory_path, bytes);
            return err;
        };
        defer parsed.deinit();
        const data = try cognitive.cloneCognitiveFile(allocator, parsed.value);
        try persistence.validateCognitiveFile(data);
        return data;
    }

    fn writeAll(self: *JsonMemoryStore, data: schema.CognitiveFile) !void {
        if (data.schema_version != persistence.current_schema_version) return error.UnsupportedCognitiveSchemaVersion;
        try persistence.validateCognitiveFile(data);
        const json = try std.json.Stringify.valueAlloc(self.allocator, data, .{ .whitespace = .indent_2 });
        try persistence.writeCognitiveJson(self.allocator, self.io, self.memory_path, json);
    }

    fn addTrace(ctx: *anyopaque, trace: schema.Trace) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        data.traces = try cognitive.appendOne(schema.Trace, self.allocator, data.traces, try cognitive.cloneTrace(self.allocator, trace));
        try self.writeAll(data);
    }

    fn updateTrace(ctx: *anyopaque, trace: schema.Trace) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        for (data.traces, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.trace_id, trace.trace_id)) {
                data.traces[i] = try cognitive.cloneTrace(self.allocator, trace);
                try self.writeAll(data);
                return;
            }
        }
        data.traces = try cognitive.appendOne(schema.Trace, self.allocator, data.traces, try cognitive.cloneTrace(self.allocator, trace));
        try self.writeAll(data);
    }

    fn loadTraces(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Trace {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(allocator);
        return data.traces;
    }

    fn forgetTrace(ctx: *anyopaque, trace_id: []const u8) !bool {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        for (data.traces, 0..) |trace, i| {
            if (std.mem.eql(u8, trace.trace_id, trace_id)) {
                data.traces = try cognitive.removeAt(schema.Trace, self.allocator, data.traces, i);
                try self.writeAll(data);
                return true;
            }
        }
        return false;
    }

    fn upsertBelief(ctx: *anyopaque, belief: schema.Belief) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        for (data.beliefs, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.belief_id, belief.belief_id)) {
                data.beliefs[i] = try cognitive.cloneBelief(self.allocator, belief);
                try self.writeAll(data);
                return;
            }
        }
        data.beliefs = try cognitive.appendOne(schema.Belief, self.allocator, data.beliefs, try cognitive.cloneBelief(self.allocator, belief));
        try self.writeAll(data);
    }

    fn loadBeliefs(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Belief {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(allocator);
        return data.beliefs;
    }

    fn invalidateBelief(ctx: *anyopaque, belief_id: []const u8, invalidated_at: []const u8) !bool {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        for (data.beliefs, 0..) |belief, i| {
            if (std.mem.eql(u8, belief.belief_id, belief_id)) {
                var updated = try cognitive.cloneBelief(self.allocator, belief);
                updated.lifecycle.status = .invalidated;
                updated.lifecycle.updated_at = try cognitive.cloneString(self.allocator, invalidated_at);
                updated.lifecycle.invalidated_at = try cognitive.cloneString(self.allocator, invalidated_at);
                data.beliefs[i] = updated;
                try self.writeAll(data);
                return true;
            }
        }
        return false;
    }

    fn upsertSubject(ctx: *anyopaque, subject: schema.Subject) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        for (data.subjects, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.subject_id, subject.subject_id)) {
                data.subjects[i] = try cognitive.cloneSubject(self.allocator, subject);
                try self.writeAll(data);
                return;
            }
        }
        data.subjects = try cognitive.appendOne(schema.Subject, self.allocator, data.subjects, try cognitive.cloneSubject(self.allocator, subject));
        try self.writeAll(data);
    }

    fn loadSubjects(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Subject {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(allocator);
        return data.subjects;
    }

    fn addArtifact(ctx: *anyopaque, artifact: schema.Artifact) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        data.artifacts = try cognitive.appendOne(schema.Artifact, self.allocator, data.artifacts, try cognitive.cloneArtifact(self.allocator, artifact));
        try self.writeAll(data);
    }

    fn loadArtifacts(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Artifact {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(allocator);
        return data.artifacts;
    }

    fn addDream(ctx: *anyopaque, dream: schema.Dream) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        data.dreams = try cognitive.appendOne(schema.Dream, self.allocator, data.dreams, try cognitive.cloneDream(self.allocator, dream));
        try self.writeAll(data);
    }

    fn loadDreams(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Dream {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(allocator);
        return data.dreams;
    }

    fn loadPeople(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Person {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(allocator);
        return cognitive.subjectsToPeople(allocator, data.subjects);
    }

    fn savePerson(ctx: *anyopaque, person: schema.Person) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        const subject = try cognitive.personToSubject(self.allocator, person);
        for (data.subjects, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.subject_id, subject.subject_id)) {
                data.subjects[i] = subject;
                try self.writeAll(data);
                return;
            }
        }
        data.subjects = try cognitive.appendOne(schema.Subject, self.allocator, data.subjects, subject);
        try self.writeAll(data);
    }

    fn addSighting(ctx: *anyopaque, sighting: schema.Sighting) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        const trace = try cognitive.sightingToTrace(self.allocator, sighting);
        data.traces = try cognitive.appendOne(schema.Trace, self.allocator, data.traces, trace);
        if (sighting.image_path) |path| {
            data.artifacts = try cognitive.appendOne(schema.Artifact, self.allocator, data.artifacts, try cognitive.imageArtifact(self.allocator, sighting.sighting_id, path, sighting.seen_at, &[_][]const u8{sighting.sighting_id}));
        }
        try self.writeAll(data);
    }

    fn loadConversationSummaries(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.ConversationSummary {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(allocator);
        var out = std.ArrayList(schema.ConversationSummary).empty;
        for (data.traces) |trace| {
            if (traceIsHidden(trace)) continue;
            if (trace.kind != .summary) continue;
            try out.append(allocator, .{
                .summary_id = try cognitive.cloneString(allocator, trace.trace_id),
                .time = try cognitive.cloneString(allocator, trace.lifecycle.created_at),
                .user_summary = try cognitive.cloneString(allocator, trace.text),
                .brain_summary = try cognitive.cloneString(allocator, trace.interpretation),
            });
        }
        return out.toOwnedSlice(allocator);
    }

    fn addConversationSummary(ctx: *anyopaque, summary: schema.ConversationSummary) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        data.traces = try cognitive.appendOne(schema.Trace, self.allocator, data.traces, .{
            .trace_id = try cognitive.cloneString(self.allocator, summary.summary_id),
            .source = .memory,
            .kind = .summary,
            .scope = .long_term,
            .text = try cognitive.cloneString(self.allocator, summary.user_summary),
            .interpretation = try cognitive.cloneString(self.allocator, summary.brain_summary),
            .confidence = 0.80,
            .salience = 0.45,
            .tags = try cognitive.cloneStringSliceConst(self.allocator, &[_][]const u8{ "conversation", "summary" }),
            .lifecycle = cognitive.lifecycle(summary.time),
        });
        try self.writeAll(data);
    }

    fn loadMemoryRecords(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.MemoryRecord {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(allocator);
        return cognitive.tracesToMemories(allocator, data.traces);
    }

    fn saveMemoryRecord(ctx: *anyopaque, memory: schema.MemoryRecord) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        const trace = try cognitive.memoryToTrace(self.allocator, memory);
        for (data.traces, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.trace_id, trace.trace_id)) {
                data.traces[i] = trace;
                try self.writeAll(data);
                return;
            }
        }
        data.traces = try cognitive.appendOne(schema.Trace, self.allocator, data.traces, trace);
        try self.writeAll(data);
    }

    fn forgetMemoryRecord(ctx: *anyopaque, memory_id: []const u8) !bool {
        return forgetTrace(ctx, memory_id);
    }

    fn loadFactRecords(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.FactRecord {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(allocator);
        return cognitive.beliefsToFacts(allocator, data.beliefs);
    }

    fn saveFactRecord(ctx: *anyopaque, fact: schema.FactRecord) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        const belief = try cognitive.factToBelief(self.allocator, fact);
        for (data.beliefs, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.belief_id, belief.belief_id)) {
                data.beliefs[i] = belief;
                try self.writeAll(data);
                return;
            }
        }
        data.beliefs = try cognitive.appendOne(schema.Belief, self.allocator, data.beliefs, belief);
        try self.writeAll(data);
    }

    fn invalidateFactRecord(ctx: *anyopaque, fact_id: []const u8, invalidated_at: []const u8) !bool {
        return invalidateBelief(ctx, fact_id, invalidated_at);
    }

    fn loadImpressions(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Impression {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(allocator);
        var out = std.ArrayList(schema.Impression).empty;
        for (data.traces) |trace| {
            if (traceIsHidden(trace)) continue;
            if (trace.kind != .perception and trace.kind != .thought and trace.kind != .belief_evidence) continue;
            try out.append(allocator, .{
                .impression_id = try cognitive.cloneString(allocator, trace.trace_id),
                .source = .self_reflection,
                .text = try cognitive.cloneString(allocator, trace.text),
                .tags = try cognitive.cloneStringSlice(allocator, trace.tags),
                .created_at = try cognitive.cloneString(allocator, trace.lifecycle.created_at),
                .salience = trace.salience,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    fn addImpression(ctx: *anyopaque, impression: schema.Impression) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        data.traces = try cognitive.appendOne(schema.Trace, self.allocator, data.traces, .{
            .trace_id = try cognitive.cloneString(self.allocator, impression.impression_id),
            .source = cognitive.impressionSourceToTraceSource(impression.source),
            .kind = .perception,
            .text = try cognitive.cloneString(self.allocator, impression.text),
            .confidence = 0.65,
            .salience = impression.salience,
            .tags = try cognitive.cloneStringSlice(self.allocator, impression.tags),
            .lifecycle = cognitive.lifecycle(impression.created_at),
        });
        try self.writeAll(data);
    }

    fn loadAppraisals(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Appraisal {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(allocator);
        var out = std.ArrayList(schema.Appraisal).empty;
        for (data.traces) |trace| {
            if (traceIsHidden(trace)) continue;
            if (trace.kind != .appraisal) continue;
            try out.append(allocator, try cognitive.traceToAppraisal(allocator, trace));
        }
        return out.toOwnedSlice(allocator);
    }

    fn addAppraisal(ctx: *anyopaque, appraisal: schema.Appraisal) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        data.traces = try cognitive.appendOne(schema.Trace, self.allocator, data.traces, try cognitive.appraisalToTrace(self.allocator, appraisal));
        try self.writeAll(data);
    }

    fn loadDreamRecords(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.DreamRecord {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(allocator);
        var out = std.ArrayList(schema.DreamRecord).empty;
        for (data.dreams) |dream| {
            try out.append(allocator, .{
                .dream_id = try cognitive.cloneString(allocator, dream.dream_id),
                .heat = dream.heat,
                .confidence = 0.70,
                .connection = try cognitive.cloneString(allocator, dream.reflection),
                .source_memory_ids = try cognitive.cloneStringSlice(allocator, dream.selected_trace_ids),
                .saved_memory_id = null,
                .created_at = try cognitive.cloneString(allocator, dream.created_at),
            });
        }
        return out.toOwnedSlice(allocator);
    }

    fn addDreamRecord(ctx: *anyopaque, dream: schema.DreamRecord) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        data.dreams = try cognitive.appendOne(schema.Dream, self.allocator, data.dreams, .{
            .dream_id = try cognitive.cloneString(self.allocator, dream.dream_id),
            .selected_trace_ids = try cognitive.cloneStringSlice(self.allocator, dream.source_memory_ids),
            .generated_artifact_id = null,
            .reflection = try cognitive.cloneString(self.allocator, dream.connection),
            .heat = dream.heat,
            .created_at = try cognitive.cloneString(self.allocator, dream.created_at),
        });
        try self.writeAll(data);
    }

    fn loadExperiences(ctx: *anyopaque, allocator: std.mem.Allocator) ![]schema.Experience {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(allocator);
        var out = std.ArrayList(schema.Experience).empty;
        for (data.traces) |trace| {
            if (traceIsHidden(trace)) continue;
            try out.append(allocator, try cognitive.traceToExperience(allocator, trace));
        }
        return out.toOwnedSlice(allocator);
    }

    fn addExperience(ctx: *anyopaque, experience: schema.Experience) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        data.traces = try cognitive.appendOne(schema.Trace, self.allocator, data.traces, try cognitive.experienceToTrace(self.allocator, experience));
        try self.writeAll(data);
    }

    fn sweepExpiredExperiences(ctx: *anyopaque, now_seconds: i64) !usize {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var data = try self.readAll(self.allocator);
        var kept = std.ArrayList(schema.Trace).empty;
        var removed: usize = 0;
        for (data.traces) |trace| {
            const expired = trace.lifecycle.status == .invalidated or (trace.scope == .short_term and trace.decay <= 0 and cognitive.parseTimestamp(trace.lifecycle.updated_at) <= now_seconds);
            if (expired) removed += 1 else try kept.append(self.allocator, trace);
        }
        if (removed > 0) {
            data.traces = try kept.toOwnedSlice(self.allocator);
            try self.writeAll(data);
        }
        return removed;
    }

    fn sweepUnreferencedCaptures(ctx: *anyopaque) !usize {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        const data = try self.readAll(self.allocator);
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
        var data = try self.readAll(self.allocator);
        for (data.subjects, 0..) |subject, i| {
            if (std.mem.eql(u8, subject.subject_id, person_id) or std.ascii.eqlIgnoreCase(subject.display_name, person_id)) {
                var updated = try cognitive.cloneSubject(self.allocator, subject);
                updated.relationship_status = .forgotten;
                updated.embeddings = &.{};
                updated.lifecycle.status = .invalidated;
                data.subjects[i] = updated;
                try self.writeAll(data);
                return true;
            }
        }
        return false;
    }

    fn logEvent(ctx: *anyopaque, json_line: []const u8) !void {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        try files.ensureParentDir(self.io, self.events_path);
        var file = std.Io.Dir.cwd().openFile(self.io, self.events_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.cwd().createFile(self.io, self.events_path, .{ .read = true, .truncate = false }),
            else => return err,
        };
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        const prefix = if (try runtime_event_compaction.eventLogNeedsLineBreak(file, self.io, stat.size)) "\n" else "";
        const line = try std.fmt.allocPrint(self.allocator, "{s}{s}\n", .{ prefix, json_line });
        defer self.allocator.free(line);
        try file.writePositionalAll(self.io, line, stat.size);
    }

    fn sweepRuntimeEvents(ctx: *anyopaque) !usize {
        const self: *JsonMemoryStore = @ptrCast(@alignCast(ctx));
        var file = std.Io.Dir.cwd().openFile(self.io, self.events_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.size <= active_event_log_target_bytes) return 0;

        const read_len_u64 = @min(stat.size, active_event_log_read_limit);
        const read_len: usize = @intCast(read_len_u64);
        const offset = stat.size - read_len_u64;
        const bytes = try self.allocator.alloc(u8, read_len);
        defer self.allocator.free(bytes);
        const read_count = try file.readPositionalAll(self.io, bytes, offset);
        const window = if (offset == 0) bytes[0..read_count] else runtime_event_compaction.trimPartialFirstLine(bytes[0..read_count]);

        const compacted = try runtime_event_compaction.compactRuntimeEventLines(self.allocator, window);
        defer self.allocator.free(compacted.bytes);
        try persistence.writeFilePath(self.io, self.events_path, compacted.bytes);
        return compacted.dropped;
    }
};

fn traceIsHidden(trace: schema.Trace) bool {
    return trace.lifecycle.status == .invalidated or trace.lifecycle.status == .pending_deletion;
}
