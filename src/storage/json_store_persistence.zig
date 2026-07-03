const std = @import("std");
const schema = @import("schema.zig");
const files = @import("../platform/common/files.zig");

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern fn sqlite3_busy_timeout(db: *sqlite3, ms: c_int) c_int;
extern fn sqlite3_close(db: *sqlite3) c_int;
extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const fn (?*anyopaque, c_int, ?[*]?[*:0]u8, ?[*]?[*:0]u8) callconv(.c) c_int, arg: ?*anyopaque, errmsg: *?[*:0]u8) c_int;
extern fn sqlite3_free(ptr: ?*anyopaque) void;
extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*:0]const u8, nByte: c_int, stmt: *?*sqlite3_stmt, tail: ?*[*:0]const u8) c_int;
extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_bind_int(stmt: *sqlite3_stmt, index: c_int, value: c_int) c_int;
extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, index: c_int, value: [*:0]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
extern fn sqlite3_column_int(stmt: *sqlite3_stmt, index: c_int) c_int;
extern fn sqlite3_column_text(stmt: *sqlite3_stmt, index: c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(stmt: *sqlite3_stmt, index: c_int) c_int;

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;

pub fn validateCognitiveFile(data: schema.CognitiveFile) !void {
    for (data.events, 0..) |event, index| {
        if (event.id.len == 0) return error.EmptyExperienceEventId;
        if (hasDuplicateExperienceEvent(data, event.id, index)) return error.DuplicateExperienceEventId;
        if (event.brain_id.len == 0) return error.EmptyExperienceEventBrainId;
        if (event.host_id.len == 0) return error.EmptyExperienceEventHostId;
        if (!hasHostBinding(data, event.host_id)) return error.UnknownExperienceEventHostId;
        if (event.kind.len == 0) return error.EmptyExperienceEventKind;
        try validateConfidence(event.confidence);
        try validateConfidence(event.salience);
        try validateConfidence(event.uncertainty);
        for (event.causal_parent_ids) |parent_id| {
            if (parent_id.len == 0) return error.EmptyCausalParentId;
            if (!hasExperienceEvent(data, parent_id)) return error.UnknownCausalParentId;
        }
    }
    for (data.host_bindings, 0..) |binding, index| {
        if (binding.host_id.len == 0) return error.EmptyHostBindingId;
        if (hasDuplicateHostBinding(data, binding.host_id, index)) return error.DuplicateHostBindingId;
        if (binding.attached_at_ms <= 0) return error.InvalidHostBindingTimestamp;
    }
    for (data.capability_statuses) |status| {
        if (status.capability_id.len == 0) return error.EmptyCapabilityStatusId;
        if (status.host_id.len == 0) return error.EmptyCapabilityStatusHostId;
        if (!hasHostBinding(data, status.host_id)) return error.UnknownCapabilityStatusHostId;
        try validateConfidence(status.quality);
        try validateConfidence(status.reliability);
        try validateConfidence(status.cost);
        try validateConfidence(status.risk);
        if (status.updated_at_ms <= 0) return error.InvalidCapabilityStatusTimestamp;
    }
    for (data.capability_requests, 0..) |request, index| {
        if (request.request_id.len == 0) return error.EmptyCapabilityRequestId;
        if (hasDuplicateCapabilityRequest(data, request.request_id, index)) return error.DuplicateCapabilityRequestId;
        if (request.capability_id.len == 0) return error.EmptyCapabilityRequestCapabilityId;
        if (request.host_id.len == 0) return error.EmptyCapabilityRequestHostId;
        if (!hasHostBinding(data, request.host_id)) return error.UnknownCapabilityRequestHostId;
        if (request.created_at_ms <= 0) return error.InvalidCapabilityRequestTimestamp;
        for (request.causal_parent_ids) |parent_id| {
            if (parent_id.len == 0) return error.EmptyCapabilityRequestCausalParentId;
            if (!hasExperienceEvent(data, parent_id)) return error.UnknownCapabilityRequestCausalParentId;
        }
    }
    for (data.capability_results, 0..) |result, index| {
        if (result.request_id.len == 0) return error.EmptyCapabilityResultRequestId;
        if (hasDuplicateCapabilityResult(data, result.request_id, index)) return error.DuplicateCapabilityResultRequestId;
        if (result.capability_id.len == 0) return error.EmptyCapabilityResultCapabilityId;
        if (result.host_id.len == 0) return error.EmptyCapabilityResultHostId;
        if (!hasHostBinding(data, result.host_id)) return error.UnknownCapabilityResultHostId;
        if (!hasCapabilityRequest(data, result.request_id)) return error.UnknownCapabilityResultRequestId;
        if (result.outcome_event_id.len != 0 and !hasExperienceEvent(data, result.outcome_event_id)) return error.UnknownCapabilityResultOutcomeEventId;
        if (result.pressure_id.len != 0 and !hasActionPressure(data, result.pressure_id)) return error.UnknownCapabilityResultPressureId;
        if (result.outcome_id.len != 0 and !hasActionOutcome(data, result.outcome_id)) return error.UnknownCapabilityResultOutcomeId;
        if (result.completed_at_ms <= 0) return error.InvalidCapabilityResultTimestamp;
    }
    for (data.beliefs) |belief| {
        try validateConfidence(belief.confidence);
        for (belief.evidence_event_ids) |event_id| {
            if (event_id.len == 0) return error.EmptyBeliefEvidenceEventId;
            if (!hasExperienceEvent(data, event_id)) return error.UnknownBeliefEvidenceEventId;
        }
        for (belief.counterevidence_event_ids) |event_id| {
            if (event_id.len == 0) return error.EmptyBeliefCounterevidenceEventId;
            if (!hasExperienceEvent(data, event_id)) return error.UnknownBeliefCounterevidenceEventId;
        }
    }
    for (data.memories) |memory| {
        if (memory.memory_id.len == 0) return error.EmptyMemoryId;
        try validateConfidence(memory.confidence);
        try validateConfidence(memory.salience);
        try validateValence(memory.valence);
        try validateValence(memory.prediction_error);
        try validateValence(memory.reinforcement_value);
        for (memory.source_event_ids) |event_id| {
            if (event_id.len == 0) return error.EmptyMemorySourceEventId;
            if (!hasExperienceEvent(data, event_id)) return error.UnknownMemorySourceEventId;
        }
    }
    for (data.action_pressures) |pressure| {
        if (pressure.pressure_id.len == 0) return error.EmptyActionPressureId;
        if (pressure.subsystem.len == 0) return error.EmptyActionPressureSubsystem;
        if (pressure.proposed_action.len == 0) return error.EmptyActionPressureProposal;
        try validateConfidence(pressure.strength);
        try validateConfidence(pressure.urgency);
        try validateConfidence(pressure.risk);
        try validateValence(pressure.valence);
        for (pressure.causal_parent_ids) |parent_id| {
            if (parent_id.len == 0) return error.EmptyActionPressureCausalParentId;
            if (!hasExperienceEvent(data, parent_id)) return error.UnknownActionPressureCausalParentId;
        }
    }
    for (data.action_outcomes) |outcome| {
        if (outcome.outcome_id.len == 0) return error.EmptyActionOutcomeId;
        if (outcome.pressure_id.len != 0 and !hasActionPressure(data, outcome.pressure_id)) return error.UnknownActionOutcomePressureId;
        if (outcome.result_event_id.len != 0 and !hasExperienceEvent(data, outcome.result_event_id)) return error.UnknownActionOutcomeResultEventId;
        for (outcome.source_event_ids) |event_id| {
            if (event_id.len == 0) return error.EmptyActionOutcomeSourceEventId;
            if (!hasExperienceEvent(data, event_id)) return error.UnknownActionOutcomeSourceEventId;
        }
        try validateValence(outcome.prediction_error);
        try validateValence(outcome.reinforcement_value);
    }
    for (data.self_trust) |entry| {
        if (entry.self_trust_id.len == 0) return error.EmptySelfTrustId;
        if (entry.faculty.len == 0) return error.EmptySelfTrustFaculty;
        try validateConfidence(entry.confidence);
        for (entry.evidence_event_ids) |event_id| {
            if (event_id.len == 0) return error.EmptySelfTrustEvidenceEventId;
            if (!hasExperienceEvent(data, event_id)) return error.UnknownSelfTrustEvidenceEventId;
        }
        for (entry.counterevidence_event_ids) |event_id| {
            if (event_id.len == 0) return error.EmptySelfTrustCounterevidenceEventId;
            if (!hasExperienceEvent(data, event_id)) return error.UnknownSelfTrustCounterevidenceEventId;
        }
    }
    for (data.dispositions) |disposition| {
        if (disposition.disposition_id.len == 0) return error.EmptyDispositionId;
        if (disposition.context_pattern.len == 0) return error.EmptyDispositionContext;
        if (disposition.action_tendency.len == 0) return error.EmptyDispositionActionTendency;
        try validateConfidence(disposition.strength);
        for (disposition.source_event_ids) |event_id| {
            if (event_id.len == 0) return error.EmptyDispositionSourceEventId;
            if (!hasExperienceEvent(data, event_id)) return error.UnknownDispositionSourceEventId;
        }
    }
    for (data.identity_hypotheses) |hypothesis| {
        if (hypothesis.hypothesis_id.len == 0) return error.EmptyIdentityHypothesisId;
        try validateConfidence(hypothesis.confidence);
        for (hypothesis.evidence_event_ids) |event_id| {
            if (event_id.len == 0) return error.EmptyIdentityHypothesisEvidenceEventId;
            if (!hasExperienceEvent(data, event_id)) return error.UnknownIdentityHypothesisEvidenceEventId;
        }
    }
    for (data.artifacts) |artifact| {
        if (artifact.artifact_id.len == 0) return error.EmptyArtifactId;
        for (artifact.source_event_ids) |event_id| {
            if (event_id.len == 0) return error.EmptyArtifactSourceEventId;
            if (!hasExperienceEvent(data, event_id)) return error.UnknownArtifactSourceEventId;
        }
    }
    for (data.subjects) |subject| {
        if (subject.subject_id.len == 0) return error.EmptySubjectId;
        if (subject.display_name.len == 0) return error.EmptySubjectName;
        for (subject.source_event_ids) |event_id| {
            if (event_id.len == 0) return error.EmptySubjectSourceEventId;
            if (!hasExperienceEvent(data, event_id)) return error.UnknownSubjectSourceEventId;
        }
        for (subject.belief_ids) |belief_id| {
            if (belief_id.len == 0) return error.EmptySubjectBeliefId;
            if (!hasBelief(data, belief_id)) return error.UnknownSubjectBeliefId;
        }
        for (subject.artifact_ids) |artifact_id| {
            if (artifact_id.len == 0) return error.EmptySubjectArtifactId;
            if (!hasArtifact(data, artifact_id)) return error.UnknownSubjectArtifactId;
        }
        if (subject.representative_artifact_id) |artifact_id| {
            if (artifact_id.len == 0) return error.EmptySubjectRepresentativeArtifactId;
            if (!hasArtifact(data, artifact_id)) return error.UnknownSubjectRepresentativeArtifactId;
        }
    }
    for (data.dream_time_records) |dream| {
        if (dream.dream_id.len == 0) return error.EmptyDreamTimeId;
        for (dream.source_event_ids) |event_id| {
            if (event_id.len == 0) return error.EmptyDreamTimeSourceEventId;
            if (!hasExperienceEvent(data, event_id)) return error.UnknownDreamTimeSourceEventId;
        }
        for (dream.source_memory_ids) |memory_id| {
            if (memory_id.len == 0) return error.EmptyDreamTimeSourceMemoryId;
            if (!hasMemory(data, memory_id)) return error.UnknownDreamTimeSourceMemoryId;
        }
        for (dream.updated_belief_ids) |belief_id| {
            if (belief_id.len == 0) return error.EmptyDreamTimeBeliefId;
            if (!hasBelief(data, belief_id)) return error.UnknownDreamTimeBeliefId;
        }
        for (dream.self_trust_change_ids) |self_trust_id| {
            if (self_trust_id.len == 0) return error.EmptyDreamTimeSelfTrustId;
            if (!hasSelfTrust(data, self_trust_id)) return error.UnknownDreamTimeSelfTrustId;
        }
        for (dream.disposition_change_ids) |disposition_id| {
            if (disposition_id.len == 0) return error.EmptyDreamTimeDispositionId;
            if (!hasDisposition(data, disposition_id)) return error.UnknownDreamTimeDispositionId;
        }
        if (dream.generated_artifact_id) |artifact_id| {
            if (artifact_id.len == 0) return error.EmptyDreamTimeArtifactId;
            if (!hasArtifact(data, artifact_id)) return error.UnknownDreamTimeArtifactId;
        }
        if (dream.delivered_mailbox_id) |mailbox_id| {
            if (mailbox_id.len == 0) return error.EmptyDreamTimeMailboxId;
            if (!hasMailboxItem(data, mailbox_id)) return error.UnknownDreamTimeMailboxId;
        }
    }
    for (data.mailbox_items) |item| {
        if (item.mailbox_id.len == 0) return error.EmptyMailboxId;
        for (item.source_event_ids) |event_id| {
            if (event_id.len == 0) return error.EmptyMailboxSourceEventId;
            if (!hasExperienceEvent(data, event_id)) return error.UnknownMailboxSourceEventId;
        }
        if (item.image_artifact_id) |artifact_id| {
            if (artifact_id.len == 0) return error.EmptyMailboxArtifactId;
            if (!hasArtifact(data, artifact_id)) return error.UnknownMailboxArtifactId;
        }
        if (item.source_dream_id) |dream_id| {
            if (dream_id.len == 0) return error.EmptyMailboxDreamId;
            if (!hasDreamTimeRecord(data, dream_id)) return error.UnknownMailboxDreamId;
        }
    }
    if (data.active_activity) |active| {
        if (active.id.len == 0) return error.EmptyActivityId;
        if (active.goal.len == 0) return error.EmptyActivityGoal;
    }
    for (data.activity_history) |record| {
        if (record.id.len == 0) return error.EmptyActivityId;
        if (record.goal.len == 0) return error.EmptyActivityGoal;
    }
}

fn validateConfidence(value: f32) !void {
    if (value < 0 or value > 1) return error.InvalidConfidence;
}

fn validateValence(value: f32) !void {
    if (value < -1 or value > 1) return error.InvalidValence;
}

fn hasExperienceEvent(data: schema.CognitiveFile, id: []const u8) bool {
    for (data.events) |event| if (std.mem.eql(u8, event.id, id)) return true;
    return false;
}

fn hasDuplicateExperienceEvent(data: schema.CognitiveFile, id: []const u8, current_index: usize) bool {
    for (data.events, 0..) |event, index| {
        if (index != current_index and std.mem.eql(u8, event.id, id)) return true;
    }
    return false;
}

fn hasMemory(data: schema.CognitiveFile, id: []const u8) bool {
    for (data.memories) |memory| if (std.mem.eql(u8, memory.memory_id, id)) return true;
    return false;
}

fn hasBelief(data: schema.CognitiveFile, id: []const u8) bool {
    for (data.beliefs) |belief| if (std.mem.eql(u8, belief.belief_id, id)) return true;
    return false;
}

fn hasArtifact(data: schema.CognitiveFile, id: []const u8) bool {
    for (data.artifacts) |artifact| if (std.mem.eql(u8, artifact.artifact_id, id)) return true;
    return false;
}

fn hasSelfTrust(data: schema.CognitiveFile, id: []const u8) bool {
    for (data.self_trust) |entry| if (std.mem.eql(u8, entry.self_trust_id, id)) return true;
    return false;
}

fn hasDisposition(data: schema.CognitiveFile, id: []const u8) bool {
    for (data.dispositions) |disposition| if (std.mem.eql(u8, disposition.disposition_id, id)) return true;
    return false;
}

fn hasDreamTimeRecord(data: schema.CognitiveFile, id: []const u8) bool {
    for (data.dream_time_records) |dream| if (std.mem.eql(u8, dream.dream_id, id)) return true;
    return false;
}

fn hasMailboxItem(data: schema.CognitiveFile, id: []const u8) bool {
    for (data.mailbox_items) |item| if (std.mem.eql(u8, item.mailbox_id, id)) return true;
    return false;
}

fn hasActionPressure(data: schema.CognitiveFile, id: []const u8) bool {
    for (data.action_pressures) |pressure| if (std.mem.eql(u8, pressure.pressure_id, id)) return true;
    return false;
}

fn hasActionOutcome(data: schema.CognitiveFile, id: []const u8) bool {
    for (data.action_outcomes) |outcome| if (std.mem.eql(u8, outcome.outcome_id, id)) return true;
    return false;
}

fn hasHostBinding(data: schema.CognitiveFile, id: []const u8) bool {
    for (data.host_bindings) |binding| if (std.mem.eql(u8, binding.host_id, id)) return true;
    return false;
}

fn hasDuplicateHostBinding(data: schema.CognitiveFile, id: []const u8, current_index: usize) bool {
    for (data.host_bindings, 0..) |binding, index| {
        if (index != current_index and std.mem.eql(u8, binding.host_id, id)) return true;
    }
    return false;
}

fn hasCapabilityRequest(data: schema.CognitiveFile, id: []const u8) bool {
    for (data.capability_requests) |request| if (std.mem.eql(u8, request.request_id, id)) return true;
    return false;
}

fn hasDuplicateCapabilityRequest(data: schema.CognitiveFile, id: []const u8, current_index: usize) bool {
    for (data.capability_requests, 0..) |request, index| {
        if (index != current_index and std.mem.eql(u8, request.request_id, id)) return true;
    }
    return false;
}

fn hasDuplicateCapabilityResult(data: schema.CognitiveFile, id: []const u8, current_index: usize) bool {
    for (data.capability_results, 0..) |result, index| {
        if (index != current_index and std.mem.eql(u8, result.request_id, id)) return true;
    }
    return false;
}

pub fn readCognitiveJson(store_allocator: std.mem.Allocator, io: std.Io, path: []const u8, out_allocator: std.mem.Allocator) ![]u8 {
    const db = try openMemoryDb(store_allocator, io, path);
    defer _ = sqlite3_close(db);
    try initMemorySchema(store_allocator, db);
    const stmt = try prepareSql(store_allocator, db, "SELECT data_json FROM cognitive_memory WHERE id = 1");
    defer finalizeSql(stmt);
    const rc = sqlite3_step(stmt);
    if (rc == SQLITE_DONE) {
        return std.json.Stringify.valueAlloc(out_allocator, schema.CognitiveFile{}, .{ .whitespace = .indent_2 });
    }
    if (rc != SQLITE_ROW) return error.SqliteStepFailed;
    return columnText(out_allocator, stmt, 0);
}

pub fn writeCognitiveJson(allocator: std.mem.Allocator, io: std.Io, path: []const u8, json: []const u8) !void {
    const db = try openMemoryDb(allocator, io, path);
    defer _ = sqlite3_close(db);
    try initMemorySchema(allocator, db);
    try writeCognitiveJsonToDb(allocator, db, json);
}

fn openMemoryDb(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*sqlite3 {
    if (!std.mem.eql(u8, path, ":memory:")) try files.ensureParentDir(io, path);
    const path_z = try allocator.dupeZ(u8, path);
    var maybe_db: ?*sqlite3 = null;
    if (sqlite3_open(path_z.ptr, &maybe_db) != SQLITE_OK) return error.SqliteOpenFailed;
    const db = maybe_db orelse return error.SqliteOpenFailed;
    _ = sqlite3_busy_timeout(db, 5000);
    return db;
}

fn initMemorySchema(allocator: std.mem.Allocator, db: *sqlite3) !void {
    try execSql(allocator, db,
        \\PRAGMA foreign_keys = ON;
        \\PRAGMA user_version = 1;
        \\CREATE TABLE IF NOT EXISTS cognitive_memory (
        \\  id INTEGER PRIMARY KEY CHECK(id = 1),
        \\  data_json TEXT NOT NULL
        \\);
    );
    try execSql(allocator, db, "PRAGMA journal_mode=WAL;");
}

fn writeCognitiveJsonToDb(allocator: std.mem.Allocator, db: *sqlite3, json: []const u8) !void {
    const stmt = try prepareSql(allocator, db,
        \\INSERT INTO cognitive_memory (id, data_json)
        \\VALUES (1, ?)
        \\ON CONFLICT(id) DO UPDATE SET data_json = excluded.data_json
    );
    defer finalizeSql(stmt);
    try bindText(stmt, 1, json, allocator);
    try stepDone(stmt);
}

fn execSql(allocator: std.mem.Allocator, db: *sqlite3, sql: []const u8) !void {
    const sql_z = try allocator.dupeZ(u8, sql);
    var errmsg: ?[*:0]u8 = null;
    if (sqlite3_exec(db, sql_z.ptr, null, null, &errmsg) != SQLITE_OK) {
        if (errmsg) |msg| sqlite3_free(@ptrCast(msg));
        return error.SqliteExecFailed;
    }
}

fn prepareSql(allocator: std.mem.Allocator, db: *sqlite3, sql: []const u8) !*sqlite3_stmt {
    const sql_z = try allocator.dupeZ(u8, sql);
    var maybe_stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql_z.ptr, -1, &maybe_stmt, null) != SQLITE_OK) return error.SqlitePrepareFailed;
    return maybe_stmt orelse error.SqlitePrepareFailed;
}

fn finalizeSql(stmt: *sqlite3_stmt) void {
    _ = sqlite3_finalize(stmt);
}

fn bindText(stmt: *sqlite3_stmt, index: c_int, value: []const u8, allocator: std.mem.Allocator) !void {
    const value_z = try allocator.dupeZ(u8, value);
    if (sqlite3_bind_text(stmt, index, value_z.ptr, @intCast(value.len), null) != SQLITE_OK) return error.SqliteBindFailed;
}

fn stepDone(stmt: *sqlite3_stmt) !void {
    const rc = sqlite3_step(stmt);
    if (rc != SQLITE_DONE) return error.SqliteStepFailed;
}

fn columnText(allocator: std.mem.Allocator, stmt: *sqlite3_stmt, index: c_int) ![]u8 {
    const ptr = sqlite3_column_text(stmt, index) orelse return allocator.dupe(u8, "");
    const len: usize = @intCast(sqlite3_column_bytes(stmt, index));
    return allocator.dupe(u8, ptr[0..len]);
}

pub fn readFileAllocPath(io: std.Io, path: []const u8, allocator: std.mem.Allocator, limit: std.Io.Limit) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
    }
    const dirname = std.fs.path.dirname(path) orelse return error.MissingParentDirectory;
    const basename = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, dirname, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, basename, allocator, limit);
}

pub fn writeFilePath(io: std.Io, path: []const u8, data: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data, .flags = .{ .truncate = true } });
    }
    const dirname = std.fs.path.dirname(path) orelse return error.MissingParentDirectory;
    const basename = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, dirname, .{});
    defer dir.close(io);
    return dir.writeFile(io, .{ .sub_path = basename, .data = data, .flags = .{ .truncate = true } });
}

pub fn writeRawCognitiveJsonForTest(allocator: std.mem.Allocator, io: std.Io, path: []const u8, json: []const u8) !void {
    const db = try openMemoryDb(allocator, io, path);
    defer _ = sqlite3_close(db);
    try initMemorySchema(allocator, db);
    try writeCognitiveJsonToDb(allocator, db, json);
}
