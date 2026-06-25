const std = @import("std");
const schema = @import("schema.zig");
const store_mod = @import("store.zig");
const files = @import("../platform/common/files.zig");

const default_capture_dir = "data/captures";
const deletion_marker_suffix = ".delete";

const persistence = @import("json_store_persistence.zig");
const cognitive = @import("json_store_cognitive.zig");

const active_event_log_target_bytes: u64 = 1024 * 1024;
const active_event_log_read_limit: u64 = active_event_log_target_bytes * 4;
const active_event_log_recent_lines: usize = 512;
const active_event_log_line_limit: usize = 16 * 1024;

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
            if (err == error.InvalidEnumTag) traceInvalidCognitiveEnumTag(self.allocator, self.memory_path, bytes);
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

        var dir = try std.Io.Dir.cwd().openDir(self.io, self.capture_dir, .{ .iterate = true });
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
        const prefix = if (try eventLogNeedsLineBreak(file, self.io, stat.size)) "\n" else "";
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
        const window = if (offset == 0) bytes[0..read_count] else trimPartialFirstLine(bytes[0..read_count]);

        const compacted = try compactRuntimeEventLines(self.allocator, window);
        defer self.allocator.free(compacted.bytes);
        try persistence.writeFilePath(self.io, self.events_path, compacted.bytes);
        return compacted.dropped;
    }
};

fn traceIsHidden(trace: schema.Trace) bool {
    return trace.lifecycle.status == .invalidated or trace.lifecycle.status == .pending_deletion;
}

pub const CognitiveEnumDiagnostic = struct {
    path: []const u8,
    value: []const u8,
    allowed: []const u8,

    pub fn deinit(self: CognitiveEnumDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.value);
        allocator.free(self.allowed);
    }
};

const relationship_status_tags = [_][]const u8{ "unknown", "visitor", "friend", "creator", "forgotten" };
const greeting_style_tags = [_][]const u8{ "formal", "warm", "playful", "quiet" };
const embedding_source_tags = [_][]const u8{ "enrollment", "confirmed_sighting", "manual_merge", "local_reference" };
const trace_source_tags = [_][]const u8{ "human", "brain", "environment", "model", "maintenance", "autonomy", "memory", "visual", "dream", "command" };
const trace_kind_tags = [_][]const u8{ "perception", "utterance", "action", "command_result", "failure", "memory_update", "appraisal", "dream", "self_definition", "reminder", "summary", "thought", "belief_evidence" };
const trace_scope_tags = [_][]const u8{ "short_term", "long_term" };
const cognitive_status_tags = [_][]const u8{ "active", "doubted", "superseded", "invalidated", "pending_deletion" };
const artifact_kind_tags = [_][]const u8{ "image", "audio", "video", "text", "embedding", "other" };
const cognitive_retention_tags = [_][]const u8{ "ephemeral", "episode", "durable", "disposition", "discard" };

fn traceInvalidCognitiveEnumTag(allocator: std.mem.Allocator, memory_path: []const u8, bytes: []const u8) void {
    const diagnostic = cognitiveEnumDiagnosticAlloc(allocator, bytes) catch |diag_err| {
        std.debug.print(
            "TRACE stage=storage.cognitive.invalid_enum diagnostic_error={s} memory_path=\"{s}\"\n",
            .{ @errorName(diag_err), memory_path },
        );
        return;
    };
    if (diagnostic) |diag| {
        defer diag.deinit(allocator);
        std.debug.print(
            "TRACE stage=storage.cognitive.invalid_enum memory_path=\"{s}\" path={s} value=\"{s}\" allowed=\"{s}\"\n",
            .{ memory_path, diag.path, diag.value, diag.allowed },
        );
    } else {
        std.debug.print(
            "TRACE stage=storage.cognitive.invalid_enum memory_path=\"{s}\" path=unknown value=unknown allowed=unknown\n",
            .{memory_path},
        );
    }
}

pub fn cognitiveEnumDiagnosticAlloc(allocator: std.mem.Allocator, bytes: []const u8) !?CognitiveEnumDiagnostic {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    if (try traceArrayEnumDiagnostic(allocator, parsed.value, "traces")) |diag| return diag;
    if (try lifecycleArrayEnumDiagnostic(allocator, parsed.value, "beliefs")) |diag| return diag;
    if (try subjectArrayEnumDiagnostic(allocator, parsed.value)) |diag| return diag;
    if (try artifactArrayEnumDiagnostic(allocator, parsed.value)) |diag| return diag;
    return null;
}

fn traceArrayEnumDiagnostic(allocator: std.mem.Allocator, root: std.json.Value, field: []const u8) !?CognitiveEnumDiagnostic {
    const value = root.object.get(field) orelse return null;
    if (value != .array) return null;
    for (value.array.items, 0..) |item, i| {
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "{s}[{d}].source", .{ field, i }), "source", &trace_source_tags)) |diag| return diag;
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "{s}[{d}].kind", .{ field, i }), "kind", &trace_kind_tags)) |diag| return diag;
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "{s}[{d}].scope", .{ field, i }), "scope", &trace_scope_tags)) |diag| return diag;
        if (try lifecycleDiagnostic(allocator, item, field, i)) |diag| return diag;
    }
    return null;
}

fn lifecycleArrayEnumDiagnostic(allocator: std.mem.Allocator, root: std.json.Value, field: []const u8) !?CognitiveEnumDiagnostic {
    const value = root.object.get(field) orelse return null;
    if (value != .array) return null;
    for (value.array.items, 0..) |item, i| {
        if (try lifecycleDiagnostic(allocator, item, field, i)) |diag| return diag;
    }
    return null;
}

fn subjectArrayEnumDiagnostic(allocator: std.mem.Allocator, root: std.json.Value) !?CognitiveEnumDiagnostic {
    const value = root.object.get("subjects") orelse return null;
    if (value != .array) return null;
    for (value.array.items, 0..) |item, i| {
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "subjects[{d}].relationship_status", .{i}), "relationship_status", &relationship_status_tags)) |diag| return diag;
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "subjects[{d}].greeting_style", .{i}), "greeting_style", &greeting_style_tags)) |diag| return diag;
        if (try lifecycleDiagnostic(allocator, item, "subjects", i)) |diag| return diag;
        const embeddings = objectField(item, "embeddings") orelse continue;
        if (embeddings != .array) continue;
        for (embeddings.array.items, 0..) |embedding, embedding_index| {
            if (try enumFieldDiagnostic(allocator, embedding, try std.fmt.allocPrint(allocator, "subjects[{d}].embeddings[{d}].source", .{ i, embedding_index }), "source", &embedding_source_tags)) |diag| return diag;
        }
    }
    return null;
}

fn artifactArrayEnumDiagnostic(allocator: std.mem.Allocator, root: std.json.Value) !?CognitiveEnumDiagnostic {
    const value = root.object.get("artifacts") orelse return null;
    if (value != .array) return null;
    for (value.array.items, 0..) |item, i| {
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "artifacts[{d}].kind", .{i}), "kind", &artifact_kind_tags)) |diag| return diag;
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "artifacts[{d}].retention", .{i}), "retention", &cognitive_retention_tags)) |diag| return diag;
        if (try lifecycleDiagnostic(allocator, item, "artifacts", i)) |diag| return diag;
    }
    return null;
}

fn lifecycleDiagnostic(allocator: std.mem.Allocator, item: std.json.Value, field: []const u8, index: usize) !?CognitiveEnumDiagnostic {
    const lifecycle = objectField(item, "lifecycle") orelse return null;
    return enumFieldDiagnostic(
        allocator,
        lifecycle,
        try std.fmt.allocPrint(allocator, "{s}[{d}].lifecycle.status", .{ field, index }),
        "status",
        &cognitive_status_tags,
    );
}

fn enumFieldDiagnostic(allocator: std.mem.Allocator, item: std.json.Value, owned_path: []const u8, field: []const u8, allowed: []const []const u8) !?CognitiveEnumDiagnostic {
    defer allocator.free(owned_path);
    const value = objectField(item, field) orelse return null;
    if (value != .string) return null;
    if (enumTagAllowed(value.string, allowed)) return null;
    return .{
        .path = try allocator.dupe(u8, owned_path),
        .value = try allocator.dupe(u8, value.string),
        .allowed = try allowedListAlloc(allocator, allowed),
    };
}

fn objectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(field);
}

fn enumTagAllowed(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |tag| {
        if (std.mem.eql(u8, value, tag)) return true;
    }
    return false;
}

fn allowedListAlloc(allocator: std.mem.Allocator, allowed: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (allowed, 0..) |tag, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, tag);
    }
    return out.toOwnedSlice(allocator);
}

const RuntimeEventCompactionResult = struct {
    bytes: []const u8,
    dropped: usize,
};

fn eventLogNeedsLineBreak(file: std.Io.File, io: std.Io, size: u64) !bool {
    if (size == 0) return false;
    var byte: [1]u8 = undefined;
    const read_count = try file.readPositionalAll(io, &byte, size - 1);
    return read_count == 1 and byte[0] != '\n';
}

fn trimPartialFirstLine(bytes: []const u8) []const u8 {
    const newline = std.mem.indexOfScalar(u8, bytes, '\n') orelse return "";
    return bytes[newline + 1 ..];
}

fn compactRuntimeEventLines(allocator: std.mem.Allocator, bytes: []const u8) !RuntimeEventCompactionResult {
    var line_count: usize = 0;
    var iter_count = std.mem.splitScalar(u8, bytes, '\n');
    while (iter_count.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
    }

    var out = std.ArrayList(u8).empty;
    var line_index: usize = 0;
    var dropped: usize = 0;
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const recent = line_count - line_index <= active_event_log_recent_lines;
        const important = runtimeEventLineIsMemoryRelevant(line);
        if ((recent or important) and out.items.len < active_event_log_target_bytes) {
            try appendRuntimeEventLine(allocator, &out, line);
        } else {
            dropped += 1;
        }
        line_index += 1;
    }
    if (dropped > 0) {
        const summary = try std.fmt.allocPrint(allocator, "{{\"kind\":\"system\",\"title\":\"events_compacted\",\"body\":\"dropped={d}\",\"source\":\"storage\",\"tags\":[\"events\",\"compaction\"]}}\n", .{dropped});
        defer allocator.free(summary);
        if (summary.len + out.items.len <= active_event_log_target_bytes) {
            try out.insertSlice(allocator, 0, summary);
        }
    }
    return .{
        .bytes = try out.toOwnedSlice(allocator),
        .dropped = dropped,
    };
}

fn appendRuntimeEventLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    if (line.len <= active_event_log_line_limit) {
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
        return;
    }
    try out.print(
        allocator,
        "{{\"kind\":\"system\",\"title\":\"event_line_compacted\",\"body\":\"original_bytes={d}\",\"source\":\"storage\",\"tags\":[\"events\",\"compaction\"]}}\n",
        .{line.len},
    );
}

fn runtimeEventLineIsMemoryRelevant(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "\"severity\":\"warning\"") != null or
        std.mem.indexOf(u8, line, "\"severity\":\"critical\"") != null or
        std.mem.indexOf(u8, line, "\"severity\":\"concern\"") != null or
        std.mem.indexOf(u8, line, "\"kind\":\"error\"") != null or
        std.mem.indexOf(u8, line, "\"kind\":\"memory_mutation\"") != null or
        std.mem.indexOf(u8, line, "\"kind\":\"reminder\"") != null or
        std.mem.indexOf(u8, line, "\"psyche_role\":") != null or
        std.mem.indexOf(u8, line, "\"attention_candidate\":true") != null or
        std.mem.indexOf(u8, line, "\"experience_retention\":\"summarize\"") != null or
        std.mem.indexOf(u8, line, "\"experience_retention\":\"keep_episode\"") != null or
        std.mem.indexOf(u8, line, "\"experience_retention\":\"keep_fact\"") != null or
        std.mem.indexOf(u8, line, "\"experience_retention\":\"keep_disposition\"") != null or
        std.mem.indexOf(u8, line, "\"created_memory_id\":") != null or
        std.mem.indexOf(u8, line, "\"forgotten_memory_id\":") != null or
        std.mem.indexOf(u8, line, "\"created_fact_id\":") != null or
        std.mem.indexOf(u8, line, "\"invalidated_fact_id\":") != null;
}
