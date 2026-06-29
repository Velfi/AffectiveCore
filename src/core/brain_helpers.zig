const std = @import("std");
const brain_mod = @import("brain.zig");
const config_mod = @import("config.zig");
const events = @import("events.zig");
const facts = @import("facts.zig");
const greeting = @import("greeting_policy.zig");
const identity = @import("identity.zig");
const interrupt_mod = @import("interrupt.zig");
const state_mod = @import("state.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const store_mod = ports.store;
const graph_store = ports.graph_store;
const openai = ports.openai;
const speech_mod = ports.speech;
const chat_mod = ports.chat;
const skills_mod = ports.skills;
const email_mod = ports.email;
const autonomy_mod = ports.autonomy;
const psyche_client = ports.psyche;
const want_achievement_mod = ports.want_achievement;
const image_mod = ports.image;
const audio_mod = ports.audio;
const camera_mod = ports.camera;
const speaker_mod = ports.speaker;
const input_mod = ports.input;
const button_mod = ports.button;
const event_log_mod = ports.event_log;
const facial_expression = ports.facial_expression;
const system_senses_mod = ports.system_senses;
const time_mod = @import("time.zig");
const maintenance = @import("maintenance.zig");
const id_monitor = @import("id_monitor.zig");
const needs_mod = @import("needs.zig");
const psyche_mod = @import("psyche.zig");
const seed_mod = @import("seed.zig");
const vector_index = @import("vector_index.zig");
const emotion = @import("emotion.zig");
const process = ports.process;

const Brain = brain_mod.Brain;
const BrainDeps = brain_mod.BrainDeps;
const ActionPressureBatchResult = brain_mod.ActionPressureBatchResult;
const ConversationTurnResult = brain_mod.ConversationTurnResult;
const ConversationSpeakerContext = brain_mod.Brain.ConversationSpeakerContext;
const QuietHours = brain_mod.Brain.QuietHours;
const SelfDirectiveKind = brain_mod.Brain.SelfDirectiveKind;
const SpeechArtifactSweepResult = brain_mod.SpeechArtifactSweepResult;
const speech_artifact_ttl_seconds = brain_mod.speech_artifact_ttl_seconds;
const speech_artifact_prefix = brain_mod.speech_artifact_prefix;
const speech_audio_suffix = brain_mod.speech_audio_suffix;
const speech_transcription_json_suffix = brain_mod.speech_transcription_json_suffix;

pub const remote_thinking_failure_message = "I'm unable to continue thinking due to a remote error.";

pub fn nullableJsonString(allocator: std.mem.Allocator, value: ?[]const u8) ![]const u8 {
    if (value) |v| return std.fmt.allocPrint(allocator, "\"{s}\"", .{v});
    return allocator.dupe(u8, "null");
}

pub fn isNotableChange(change_summary: []const u8) bool {
    const change = std.mem.trim(u8, change_summary, " \t\r\n.!");
    if (change.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(change, "no change")) return false;
    if (std.ascii.eqlIgnoreCase(change, "unchanged")) return false;
    if (std.ascii.startsWithIgnoreCase(change, "no change ")) return false;
    if (std.ascii.startsWithIgnoreCase(change, "no visible change")) return false;
    if (std.ascii.startsWithIgnoreCase(change, "nothing changed")) return false;
    return true;
}

pub fn normalizeMatchText(out: []u8, text: []const u8) []const u8 {
    var len: usize = 0;
    var previous_space = true;
    for (text) |ch| {
        if (len >= out.len) break;
        const lower: u8 = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) {
            out[len] = lower;
            len += 1;
            previous_space = false;
        } else if (!previous_space) {
            out[len] = ' ';
            len += 1;
            previous_space = true;
        }
    }
    if (len > 0 and out[len - 1] == ' ') len -= 1;
    return out[0..len];
}

pub fn textSubstantiallyMatches(a: []const u8, b: []const u8) bool {
    var a_buf: [512]u8 = undefined;
    var b_buf: [512]u8 = undefined;
    const na = normalizeMatchText(&a_buf, a);
    const nb = normalizeMatchText(&b_buf, b);
    if (na.len == 0 or nb.len == 0) return false;
    if (std.mem.eql(u8, na, nb)) return true;
    if (na.len >= 12 and std.mem.indexOf(u8, nb, na) != null) return true;
    if (nb.len >= 12 and std.mem.indexOf(u8, na, nb) != null) return true;
    return false;
}

pub const MediaKind = enum {
    image,
    audio,
    animation,
    video,
    unsupported,
};

pub const UploadedMedia = struct {
    path: []const u8,
    mime_type: []const u8,
    source: []const u8 = "user_upload",
};

pub fn parseUploadedMedia(text: []const u8) ?UploadedMedia {
    if (parseUploadedMediaMarker(text, "[uploaded_media ")) |media| return media;
    const image_path = parseUploadedImagePath(text) orelse return null;
    return .{ .path = image_path, .mime_type = mimeTypeForMediaPath(image_path) };
}

pub fn parseUploadedMediaMarker(text: []const u8, marker: []const u8) ?UploadedMedia {
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    const rest = text[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
    const fields = rest[0..end];
    const path = parseMarkerAttribute(fields, "path") orelse return null;
    const mime_type = parseMarkerAttribute(fields, "mime_type") orelse parseMarkerAttribute(fields, "mimeType") orelse mimeTypeForMediaPath(path);
    const source = parseMarkerAttribute(fields, "source") orelse "user_upload";
    return .{ .path = path, .mime_type = mime_type, .source = source };
}

pub fn parseMarkerAttribute(fields: []const u8, name: []const u8) ?[]const u8 {
    var pattern_buffer: [64]u8 = undefined;
    if (name.len + "=\"".len > pattern_buffer.len) return null;
    @memcpy(pattern_buffer[0..name.len], name);
    pattern_buffer[name.len] = '=';
    pattern_buffer[name.len + 1] = '"';
    const pattern = pattern_buffer[0 .. name.len + 2];
    const start = std.mem.indexOf(u8, fields, pattern) orelse return null;
    const value_start = start + pattern.len;
    const rest = fields[value_start..];
    const value_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    if (value_end == 0) return null;
    return rest[0..value_end];
}

pub fn parseUploadedImagePath(text: []const u8) ?[]const u8 {
    const marker = "[uploaded_image path=\"";
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    const path_start = start + marker.len;
    const rest = text[path_start..];
    const path_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    if (path_end == 0) return null;
    return rest[0..path_end];
}

pub fn mediaKindFor(mime_type: []const u8, path: []const u8) MediaKind {
    if (std.ascii.startsWithIgnoreCase(mime_type, "image/gif")) return .animation;
    if (std.ascii.startsWithIgnoreCase(mime_type, "image/")) return .image;
    if (std.ascii.startsWithIgnoreCase(mime_type, "audio/")) return .audio;
    if (std.ascii.startsWithIgnoreCase(mime_type, "video/")) return .video;
    if (endsWithIgnoreCase(path, ".gif") or endsWithIgnoreCase(path, ".apng")) return .animation;
    if (endsWithIgnoreCase(path, ".png") or endsWithIgnoreCase(path, ".jpg") or endsWithIgnoreCase(path, ".jpeg") or endsWithIgnoreCase(path, ".webp")) return .image;
    if (endsWithIgnoreCase(path, ".wav") or endsWithIgnoreCase(path, ".mp3") or endsWithIgnoreCase(path, ".m4a") or endsWithIgnoreCase(path, ".aac") or endsWithIgnoreCase(path, ".flac") or endsWithIgnoreCase(path, ".ogg")) return .audio;
    if (endsWithIgnoreCase(path, ".mp4") or endsWithIgnoreCase(path, ".mov") or endsWithIgnoreCase(path, ".webm") or endsWithIgnoreCase(path, ".mkv")) return .video;
    return .unsupported;
}

pub fn mimeTypeForMediaPath(path: []const u8) []const u8 {
    if (endsWithIgnoreCase(path, ".jpg") or endsWithIgnoreCase(path, ".jpeg")) return "image/jpeg";
    if (endsWithIgnoreCase(path, ".webp")) return "image/webp";
    if (endsWithIgnoreCase(path, ".png")) return "image/png";
    if (endsWithIgnoreCase(path, ".gif")) return "image/gif";
    if (endsWithIgnoreCase(path, ".wav")) return "audio/wav";
    if (endsWithIgnoreCase(path, ".mp3")) return "audio/mpeg";
    if (endsWithIgnoreCase(path, ".m4a")) return "audio/mp4";
    if (endsWithIgnoreCase(path, ".aac")) return "audio/aac";
    if (endsWithIgnoreCase(path, ".flac")) return "audio/flac";
    if (endsWithIgnoreCase(path, ".ogg")) return "audio/ogg";
    if (endsWithIgnoreCase(path, ".mp4")) return "video/mp4";
    if (endsWithIgnoreCase(path, ".mov")) return "video/quicktime";
    if (endsWithIgnoreCase(path, ".webm")) return "video/webm";
    return "application/octet-stream";
}

pub fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (suffix.len > text.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

pub const ActionMemoryPolicy = struct {
    source: schema.MemoryExperienceSource,
    kind: schema.MemoryExperienceKind,
    retention: schema.MemoryExperienceRetention,
};

pub fn actionMemoryPolicy(action: chat_mod.ActionProposalType) ?ActionMemoryPolicy {
    return switch (action) {
        .take_picture, .describe_image, .compare_images, .recognize => .{ .source = .environment, .kind = .perception, .retention = .summarize },
        .schedule_reminder => .{ .source = .brain, .kind = .reminder, .retention = .keep_episode },
        .send_email => .{ .source = .brain, .kind = .action, .retention = .keep_episode },
        .imagine_image => .{ .source = .brain, .kind = .action, .retention = .keep_episode },
        else => null,
    };
}

pub fn actionTypeFromName(name: []const u8) ?chat_mod.ActionProposalType {
    return @import("capability_synonyms.zig").resolveAction(name);
}

pub fn idMonitorExperienceLogSeverityThreshold(text: []const u8) schema.ExperienceLogSeverity {
    inline for (@typeInfo(schema.ExperienceLogSeverity).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(text, field.name)) return @field(schema.ExperienceLogSeverity, field.name);
    }
    return .concern;
}

pub fn psycheKeySlice(text: []const u8) []const u8 {
    return text[0..@min(text.len, 48)];
}

pub fn appendEmbedding(allocator: std.mem.Allocator, embeddings: []schema.FaceEmbeddingRef, now: []const u8) ![]schema.FaceEmbeddingRef {
    var out = try allocator.alloc(schema.FaceEmbeddingRef, embeddings.len + 1);
    @memcpy(out[0..embeddings.len], embeddings);
    out[embeddings.len] = .{
        .embedding_id = try std.fmt.allocPrint(allocator, "emb_{d}", .{embeddings.len + 1}),
        .quality_score = 0.80,
        .created_at = now,
        .source = .local_reference,
    };
    return out;
}

pub const RepresentativePhotoScore = struct {
    score: f32,
};

pub fn representativePhotoScore(image_path: []const u8, confidence: f32) RepresentativePhotoScore {
    var score = clamp01(confidence);
    if (containsIgnoreCase(image_path, "empty")) score = 0;
    if (containsIgnoreCase(image_path, "multiple")) score -= 0.30;
    if (containsIgnoreCase(image_path, "unknown")) score -= 0.20;
    if (containsIgnoreCase(image_path, "blur")) score -= 0.25;
    if (containsIgnoreCase(image_path, "dark")) score -= 0.15;
    if (containsIgnoreCase(image_path, "low")) score -= 0.10;
    if (containsIgnoreCase(image_path, "good") or containsIgnoreCase(image_path, "clear")) score += 0.05;
    return .{ .score = clamp01(score) };
}

pub fn shouldRetainSightingImage(person_id: ?[]const u8, confidence: f32, description: ?[]const u8, change_summary: ?[]const u8) bool {
    if (person_id != null) return true;
    if (confidence >= 0.60) return true;
    if (change_summary) |change| {
        if (isNotableChange(change)) return true;
    }
    if (description) |text| return std.mem.trim(u8, text, " \r\n\t").len > 0;
    return false;
}

test "sighting image retention is decided from observation value" {
    try std.testing.expect(shouldRetainSightingImage("person_1", 0.10, null, null));
    try std.testing.expect(shouldRetainSightingImage(null, 0.60, null, null));
    try std.testing.expect(shouldRetainSightingImage(null, 0.10, null, "wearing a red scarf"));
    try std.testing.expect(shouldRetainSightingImage(null, 0.10, "a person is standing near the desk", null));
    try std.testing.expect(!shouldRetainSightingImage(null, 0.10, null, null));
    try std.testing.expect(!shouldRetainSightingImage(null, 0.10, null, "no visible change"));
}

pub fn clamp01(value: f32) f32 {
    return @max(0, @min(1, value));
}

pub fn cloneConstStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, i| out[i] = try allocator.dupe(u8, value);
    return out;
}

pub fn visualNoteTexts(allocator: std.mem.Allocator, notes: []const schema.VisualNote) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, notes.len);
    for (notes, 0..) |note, i| {
        out[i] = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ note.time, note.text });
    }
    return out;
}

pub fn appendVisualNote(allocator: std.mem.Allocator, out: *std.ArrayList(schema.VisualNote), now: []const u8, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return;
    try out.append(allocator, .{
        .time = try allocator.dupe(u8, now),
        .text = try allocator.dupe(u8, trimmed),
    });
}

pub fn appendVisualNotes(allocator: std.mem.Allocator, existing: []schema.VisualNote, now: []const u8, description: openai.VisualDescription) ![]schema.VisualNote {
    var out = std.ArrayList(schema.VisualNote).empty;
    for (existing) |note| {
        try out.append(allocator, .{
            .time = try allocator.dupe(u8, note.time),
            .text = try allocator.dupe(u8, note.text),
        });
    }
    try appendVisualNote(allocator, &out, now, description.description);
    try appendVisualNote(allocator, &out, now, description.change_summary);
    for (description.temporary_notes) |note| try appendVisualNote(allocator, &out, now, note);
    return try out.toOwnedSlice(allocator);
}

pub fn visualNotesFromDescription(allocator: std.mem.Allocator, now: []const u8, description: openai.VisualDescription) ![]schema.VisualNote {
    var out = std.ArrayList(schema.VisualNote).empty;
    try appendVisualNote(allocator, &out, now, description.description);
    try appendVisualNote(allocator, &out, now, description.change_summary);
    for (description.temporary_notes) |note| try appendVisualNote(allocator, &out, now, note);
    return try out.toOwnedSlice(allocator);
}

pub fn addVisualDescriptionToPerson(allocator: std.mem.Allocator, person: schema.Person, now: []const u8, description: openai.VisualDescription) !schema.Person {
    var updated = person;
    updated.stable_notes = try appendStableNotes(allocator, person.stable_notes, description.durable_notes);
    updated.recent_notes = try appendVisualNotes(allocator, person.recent_notes, now, description);
    return updated;
}

pub fn appendStableNotes(allocator: std.mem.Allocator, existing: [][]const u8, new_values: []const []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (existing) |note| try out.append(allocator, try allocator.dupe(u8, note));
    for (new_values) |note| {
        const trimmed = std.mem.trim(u8, note, " \r\n\t");
        if (trimmed.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, trimmed));
    }
    return try out.toOwnedSlice(allocator);
}

pub fn personProfileDescription(allocator: std.mem.Allocator, person: schema.Person) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (person.stable_notes) |note| try appendProfileDescriptionLine(allocator, &out, note);
    for (person.recent_notes) |note| try appendProfileDescriptionLine(allocator, &out, note.text);
    return try out.toOwnedSlice(allocator);
}

pub fn appendProfileDescriptionLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return;
    try out.appendSlice(allocator, trimmed);
    try out.append(allocator, '\n');
}

pub fn selfDirectiveTags(allocator: std.mem.Allocator, kind: Brain.SelfDirectiveKind, tags: []const []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (tags) |tag| {
        if (!tagInSlice(out.items, tag)) try out.append(allocator, try allocator.dupe(u8, tag));
    }
    if (!tagInSlice(out.items, "self_model")) try out.append(allocator, try allocator.dupe(u8, "self_model"));
    const kind_tag = switch (kind) {
        .need => "self_need",
        .want => "self_want",
        .goal => "self_goal",
    };
    if (!tagInSlice(out.items, kind_tag)) try out.append(allocator, try allocator.dupe(u8, kind_tag));
    return out.toOwnedSlice(allocator);
}

pub fn seedEntryTags(allocator: std.mem.Allocator, kind: seed_mod.SeedEntryKind, seed_slug: []const u8) ![][]const u8 {
    const seed_tag = try std.fmt.allocPrint(allocator, "seed:{s}", .{seed_slug});
    return cloneConstStringSlice(allocator, &[_][]const u8{ "self_model", "seed", kind.tag(), seed_tag });
}

pub fn inferWantGoalKind(text: []const u8) want_achievement_mod.WantGoalKind {
    const maintenance_markers = [_][]const u8{ "maintain", "preserve", "keeping", "keep ", "uninterrupted", "quiet focused" };
    for (maintenance_markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(text, marker) != null) return .maintenance;
    }
    return .achievement;
}

pub fn deriveWantFulfillmentCriterion(allocator: std.mem.Allocator, text: []const u8, goal_kind: want_achievement_mod.WantGoalKind) ![]const u8 {
    if (goal_kind == .maintenance and (std.ascii.indexOfIgnoreCase(text, "quiet") != null or std.ascii.indexOfIgnoreCase(text, "focus") != null)) {
        return try allocator.dupe(u8, "quiet focused work or deep work was sustained for a meaningful stretch without meaningful interruption");
    }
    if (goal_kind == .achievement and std.ascii.indexOfIgnoreCase(text, "connect") != null) {
        return try allocator.dupe(u8, "distance, disconnection, loneliness, or feeling like roommates is explicitly addressed and materially reduced in this event");
    }
    if (goal_kind == .achievement and std.ascii.indexOfIgnoreCase(text, "creative") != null) {
        return try allocator.dupe(u8, "substantive progress on a personal creative project was made in this period");
    }
    return switch (goal_kind) {
        .maintenance => try std.fmt.allocPrint(allocator, "the state described by \"{s}\" is sustained for a meaningful period", .{text}),
        .achievement => try std.fmt.allocPrint(allocator, "the gap described by \"{s}\" is materially closed in this event", .{text}),
    };
}

pub fn wantFulfillmentCriterionForMemory(allocator: std.mem.Allocator, memory: schema.MemoryRecord) ![]const u8 {
    if (memory.fulfillment_criterion.len > 0) return try allocator.dupe(u8, memory.fulfillment_criterion);
    const goal_kind = inferWantGoalKind(memory.text);
    return deriveWantFulfillmentCriterion(allocator, memory.text, goal_kind);
}

pub fn assignWantFulfillmentCriterion(self_allocator: std.mem.Allocator, memory: *schema.MemoryRecord) !void {
    if (!tagInSlice(memory.tags, "self_want")) return;
    const goal_kind = inferWantGoalKind(memory.text);
    memory.fulfillment_criterion = try deriveWantFulfillmentCriterion(self_allocator, memory.text, goal_kind);
}

pub fn wantAchievementCandidates(allocator: std.mem.Allocator, memories: []const schema.MemoryRecord) ![]want_achievement_mod.WantCandidate {
    var out = std.ArrayList(want_achievement_mod.WantCandidate).empty;
    for (memories) |memory| {
        if (!tagInSlice(memory.tags, "self_want")) continue;
        if (tagInSlice(memory.tags, "pending_dream_reconciliation")) continue;
        const goal_kind = inferWantGoalKind(memory.text);
        const fulfillment_criterion = try wantFulfillmentCriterionForMemory(allocator, memory);
        try out.append(allocator, .{
            .memory_id = memory.memory_id,
            .text = memory.text,
            .interpretation = memoryInterpretation(memory),
            .goal_kind = goal_kind,
            .fulfillment_criterion = fulfillment_criterion,
            .salience = memory.salience,
            .confidence = memory.confidence,
            .score = memory.score,
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn findSelfWantById(memories: []const schema.MemoryRecord, memory_id: []const u8) ?schema.MemoryRecord {
    const memory = findMemoryById(memories, memory_id) orelse return null;
    if (!tagInSlice(memory.tags, "self_want")) return null;
    return memory;
}

pub fn wantReinforcementStrength(want: schema.MemoryRecord) f32 {
    const score_unit = @min(1.0, @max(0.0, @as(f32, @floatFromInt(want.score)) / 10.0));
    return @min(1.0, @max(0.20, want.salience * 0.65 + score_unit * 0.35));
}

pub fn pendingFlexibleIdentityMemories(allocator: std.mem.Allocator, memories: []const schema.MemoryRecord) ![]schema.MemoryRecord {
    var out = std.ArrayList(schema.MemoryRecord).empty;
    for (memories) |memory| {
        if (tagInSlice(memory.tags, "flexible_identity") and tagInSlice(memory.tags, "pending_dream_reconciliation")) {
            try out.append(allocator, memory);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn flexibleIdentityDreamText(allocator: std.mem.Allocator, memories: []const schema.MemoryRecord) ![]const u8 {
    if (memories.len == 0) return "";
    var out = std.ArrayList(u8).empty;
    for (memories, 0..) |memory, i| {
        if (i > 0) try out.appendSlice(allocator, " | ");
        try out.print(allocator, "{s}: {s}", .{ memory.memory_id, memoryInterpretation(memory) });
    }
    return out.toOwnedSlice(allocator);
}

pub fn dreamSourceIds(allocator: std.mem.Allocator, sampled_memory_id: ?[]const u8, pending: []const schema.MemoryRecord) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    if (sampled_memory_id) |id| try out.append(allocator, try allocator.dupe(u8, id));
    for (pending) |memory| {
        if (!tagInSlice(out.items, memory.memory_id)) try out.append(allocator, try allocator.dupe(u8, memory.memory_id));
    }
    return out.toOwnedSlice(allocator);
}

pub fn appendRevision(allocator: std.mem.Allocator, revisions: []schema.MemoryRevision, revision: schema.MemoryRevision) ![]schema.MemoryRevision {
    var out = try allocator.alloc(schema.MemoryRevision, revisions.len + 1);
    @memcpy(out[0..revisions.len], revisions);
    out[revisions.len] = revision;
    return out;
}

pub fn joinTags(allocator: std.mem.Allocator, tags: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (tags, 0..) |tag, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, tag);
    }
    return out.toOwnedSlice(allocator);
}

pub fn memoryInterpretation(memory: schema.MemoryRecord) []const u8 {
    if (memory.interpretation.len > 0) return memory.interpretation;
    return memory.text;
}

pub fn memoryIsMoreSalient(candidate: schema.MemoryRecord, current: schema.MemoryRecord) bool {
    if (candidate.salience != current.salience) return candidate.salience > current.salience;
    if (candidate.score != current.score) return candidate.score > current.score;
    return candidate.access_count > current.access_count;
}

pub fn graphPersonNodeId(allocator: std.mem.Allocator, person_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "person:{s}", .{person_id});
}

pub fn findMemoryById(memories: []const schema.MemoryRecord, memory_id: []const u8) ?schema.MemoryRecord {
    for (memories) |memory| {
        if (std.mem.eql(u8, memory.memory_id, memory_id)) return memory;
    }
    return null;
}

pub fn findMemoryWithTagForTest(memories: []const schema.MemoryRecord, tag: []const u8) ?schema.MemoryRecord {
    for (memories) |memory| {
        if (tagInSlice(memory.tags, tag)) return memory;
    }
    return null;
}

pub fn experienceEventsContain(experience_events: []const schema.ExperienceEvent, needle: []const u8) bool {
    for (experience_events) |event| {
        if (std.mem.indexOf(u8, event.kind, needle) != null) return true;
        if (std.mem.indexOf(u8, event.payload, needle) != null) return true;
    }
    return false;
}

pub fn seedEntryAlreadyPresent(memories: []const schema.MemoryRecord, entry: seed_mod.SeedEntry) bool {
    for (memories) |memory| {
        if (std.mem.eql(u8, memory.text, entry.text) and tagInSlice(memory.tags, entry.kind.tag())) return true;
    }
    return false;
}

pub fn tagInSlice(tags: []const []const u8, candidate: []const u8) bool {
    for (tags) |tag| {
        if (std.ascii.eqlIgnoreCase(tag, candidate)) return true;
    }
    return false;
}

pub fn factMatches(record: schema.FactRecord, query: []const u8, tags: []const []const u8) bool {
    if (query.len > 0 and std.ascii.indexOfIgnoreCase(record.key, query) == null and std.ascii.indexOfIgnoreCase(record.value, query) == null and std.ascii.indexOfIgnoreCase(record.fact_id, query) == null) return false;
    for (tags) |tag| {
        if (!tagInSlice(record.tags, tag)) return false;
    }
    return true;
}

pub fn slugify(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var last_separator = true;
    for (text) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try out.append(allocator, std.ascii.toLower(char));
            last_separator = false;
        } else if (!last_separator and out.items.len > 0) {
            try out.append(allocator, '_');
            last_separator = true;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '_') _ = out.pop();
    if (out.items.len == 0) return error.EmptySeedSlug;
    return out.toOwnedSlice(allocator);
}

pub fn contextShuffleSeed(now_seconds: i64, count: usize) u64 {
    const base: u64 = if (now_seconds >= 0) @intCast(now_seconds) else @intCast(-now_seconds);
    return base ^ (@as(u64, @intCast(count + 1)) *% 0x9E3779B185EBCA87);
}

pub fn containsIgnoreCase(text: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, needle) != null;
}

pub fn previewText(text: []const u8) []const u8 {
    const max_len: usize = 96;
    return text[0..@min(text.len, max_len)];
}

pub fn isBlankText(text: []const u8) bool {
    return std.mem.trim(u8, text, " \r\n\t").len == 0;
}

pub fn dreamStyle(heat: f32) []const u8 {
    if (heat < 0.34) return "grounded_replay";
    if (heat < 0.67) return "associative_synthesis";
    return "surreal_symbolic";
}

pub fn dreamConfidence(heat: f32) f32 {
    return @max(0.20, 0.85 - heat * 0.55);
}

pub fn rollDreamHeat(random: std.Random, heat_bias: ?[]const u8) f32 {
    const raw = random.float(f32);
    if (heat_bias) |bias| {
        if (std.ascii.eqlIgnoreCase(bias, "low")) return raw * 0.34;
        if (std.ascii.eqlIgnoreCase(bias, "high")) return 0.67 + raw * 0.33;
        if (std.ascii.eqlIgnoreCase(bias, "grounded")) return raw * 0.34;
        if (std.ascii.eqlIgnoreCase(bias, "surreal")) return 0.67 + raw * 0.33;
    }
    return raw;
}

pub const SpeechArtifactKind = enum {
    audio,
    transcription_json,
};

pub fn speechArtifactKind(name: []const u8) ?SpeechArtifactKind {
    if (std.mem.startsWith(u8, name, speech_artifact_prefix) and std.mem.endsWith(u8, name, speech_audio_suffix)) return .audio;
    if (std.mem.startsWith(u8, name, speech_artifact_prefix) and std.mem.endsWith(u8, name, speech_transcription_json_suffix)) return .transcription_json;
    return null;
}

pub fn speechArtifactTimestampMs(name: []const u8) ?i64 {
    const suffix_len = if (std.mem.endsWith(u8, name, speech_transcription_json_suffix))
        speech_transcription_json_suffix.len
    else if (std.mem.endsWith(u8, name, speech_audio_suffix))
        speech_audio_suffix.len
    else
        return null;
    if (!std.mem.startsWith(u8, name, speech_artifact_prefix)) return null;
    if (name.len <= speech_artifact_prefix.len + suffix_len) return null;
    const timestamp_text = name[speech_artifact_prefix.len .. name.len - suffix_len];
    return std.fmt.parseInt(i64, timestamp_text, 10) catch null;
}
