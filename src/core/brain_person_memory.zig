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
const helpers = @import("brain_helpers.zig");
const recognition_composite = @import("recognition_composite.zig");
const belief_updates = @import("belief_updates.zig");
const experience_kinds = @import("experience_kinds.zig");
const brain_process = @import("brain_process.zig");

const Brain = brain_mod.Brain;
const BrainDeps = brain_mod.BrainDeps;
const ActionPressureBatchResult = brain_mod.ActionPressureBatchResult;
const ConversationTurnResult = brain_mod.ConversationTurnResult;
const ConversationSpeakerContext = brain_mod.Brain.ConversationSpeakerContext;
const QuietHours = brain_mod.Brain.QuietHours;
const SelfDirectiveKind = brain_mod.Brain.SelfDirectiveKind;
const SpeechArtifactSweepResult = brain_mod.SpeechArtifactSweepResult;
const MediaKind = helpers.MediaKind;
const remote_thinking_failure_message = brain_mod.remote_thinking_failure_message;
const speech_artifact_ttl_seconds = brain_mod.speech_artifact_ttl_seconds;
const speech_artifact_prefix = brain_mod.speech_artifact_prefix;
const speech_audio_suffix = brain_mod.speech_audio_suffix;
const speech_transcription_json_suffix = brain_mod.speech_transcription_json_suffix;
pub fn recognitionAlreadyInObservations(self: *Brain, observations: []const u8) bool {
    if (std.mem.indexOf(u8, observations, "Current speaker recognition:") == null) return false;
    const path = self.last_visual_observation_path orelse return false;
    return std.mem.indexOf(u8, observations, path) != null;
}

pub fn recognitionRecentObservationNote(self: *Brain, observations: []const u8) ![]const u8 {
    _ = observations;
    const path = self.last_visual_observation_path orelse "unknown";
    return try std.fmt.allocPrint(
        self.allocator,
        "recognition_dedup:\n- frame_path: {s}\n- identify_skipped: true\n- note: identification for this frame is recorded above as Current speaker recognition.\n",
        .{path},
    );
}

pub fn recognizeForObservation(self: *Brain) ![]const u8 {
    if (self.awaitedHostRequestMatches("camera", "recognize")) {
        return try self.allocator.dupe(u8, "host_sense_pull_pending: camera recognize already requested; waiting for host delivery.\n");
    }
    try self.logState(.Capture);
    const capture = self.deps.camera.capture(self.allocator) catch |err| switch (err) {
        error.FrontendCaptureRequested => return @import("awaited_host_request.zig").pullRequestedObservation(self, "camera", "recognize"),
        else => return err,
    };
    self.rememberVisualUpdate(capture.path);
    self.last_visual_observation_uploaded = false;
    self.outputImageCapture(capture);

    return try recognizeFromCapturedPath(self, capture.path);
}

/// Identify and greet using an already-captured frame. Shared by the inline
/// capture path and by the pulled frontend camera observation, so "capture +
/// recognize" behaves like one operation regardless of how the frame arrived.
pub fn recognizeFromCapturedPath(self: *Brain, path: []const u8) ![]const u8 {
    try self.logState(.Identify);
    self.rememberVisualUpdate(path);
    const composite = try recognition_composite.recognizeSubject(self, path, &.{});
    const result = composite.result;
    try belief_updates.onIdentityHypothesis(self, composite.hypothesis, result.candidate_name orelse "");

    var name: ?[]const u8 = result.candidate_name;
    if (result.match_status == .known) {
        const id = result.person_id orelse return error.KnownRecognitionMissingPersonId;
        var person = (try self.deps.store.findById(self.allocator, id)) orelse try seedKnownPerson(self, id, result.candidate_name orelse "Mara");
        person = try ensureCreatorIfFirstRecognized(self, person);
        const now = try self.timestampNow();
        person.last_seen_at = now;
        person.sighting_count += 1;
        try self.deps.store.savePerson(person);
        try addSighting(self, id, now, result.confidence, path, null, null);
        name = person.display_name;
        try self.logSimple(.TransientConversation, path, id, null, "recognize_action_known,sighting_created,last_seen_updated");
    } else {
        try self.logSimple(.TransientConversation, path, result.person_id, null, "recognize_action_observed");
    }

    return try self.conversationSpeakerLine(path, result, name, @tagName(result.match_status));
}

pub fn recordIdentityHypothesis(self: *Brain, image_path: []const u8, result: identity.IdentityResult, override_decision: ?schema.IdentityDecision, parents: []const []const u8, hypothesis_confidence: ?f32) !schema.IdentityHypothesis {
    const decision = override_decision orelse decisionFromIdentityResult(result);
    const candidate_id = result.person_id orelse "";
    const candidate_name = result.candidate_name orelse "";
    const stored_confidence = clamp01(hypothesis_confidence orelse result.confidence);
    const payload = try std.fmt.allocPrint(
        self.allocator,
        "image={s}; decision={s}; person_present={any}; match_status={s}; person_id={s}; name={s}; confidence={d:.2}; people_count={d}",
        .{ image_path, @tagName(decision), result.person_present, @tagName(result.match_status), candidate_id, candidate_name, result.confidence, result.people_count },
    );
    const existing_events = self.deps.store.loadExperienceEvents(self.allocator) catch &.{};
    const event: schema.ExperienceEvent = .{
        .id = try std.fmt.allocPrint(self.allocator, "evt_{d}_{d}_Recognition.IdentityHypothesis_{d}_{s}", .{ self.now_seconds * 1000, existing_events.len, payload.len, @tagName(decision) }),
        .brain_id = "default",
        .host_id = self.currentHostId(),
        .timestamp_ms = self.now_seconds * 1000,
        .source = .subsystem,
        .kind = experience_kinds.recognition_identity_hypothesis,
        .payload = payload,
        .salience = 0.70,
        .confidence = stored_confidence,
        .uncertainty = 1.0 - stored_confidence,
        .causal_parent_ids = try self.allocator.dupe([]const u8, parents),
        .retention = .episode,
        .visibility = .internal,
    };
    try self.recordExperienceEvent(event);
    const evidence_ids = try identityEvidenceIds(self.allocator, event.id, parents);
    const contradictions = if (result.match_status == .uncertain or result.match_status == .multiple)
        try self.allocator.dupe([]const u8, &[_][]const u8{"recognizer reported ambiguous visual evidence"})
    else
        try self.allocator.alloc([]const u8, 0);
    const candidates_json = try std.fmt.allocPrint(
        self.allocator,
        "[{{\"person_id\":\"{s}\",\"name\":\"{s}\",\"confidence\":{d:.3},\"source\":\"visual_recognizer\"}}]",
        .{ candidate_id, candidate_name, result.confidence },
    );
    const hypothesis: schema.IdentityHypothesis = .{
        .hypothesis_id = try std.fmt.allocPrint(self.allocator, "identity_hyp_{d}_{s}_{d}", .{ self.now_seconds * 1000, @tagName(decision), image_path.len }),
        .decision = decision,
        .candidates_json = candidates_json,
        .evidence_event_ids = evidence_ids,
        .confidence = stored_confidence,
        .contradictions = contradictions,
        .provenance = if (parents.len > 0) "recognition_composite_with_causal_context" else "recognition_composite",
        .created_at_ms = self.now_seconds * 1000,
    };
    try self.deps.store.addIdentityHypothesis(hypothesis);
    return hypothesis;
}

fn identityEvidenceIds(allocator: std.mem.Allocator, hypothesis_event_id: []const u8, parent_event_ids: []const []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    try out.append(allocator, hypothesis_event_id);
    for (parent_event_ids) |event_id| {
        if (!stringSliceContains(out.items, event_id)) try out.append(allocator, try allocator.dupe(u8, event_id));
    }
    return try out.toOwnedSlice(allocator);
}

fn stringSliceContains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

fn findLatestMistakenHypothesisEventId(self: *Brain) !?[]const u8 {
    const hypotheses = try self.deps.store.loadIdentityHypotheses(self.allocator);
    var best_ms: i64 = -1;
    var best_event_id: ?[]const u8 = null;
    for (hypotheses) |hypothesis| {
        if (hypothesis.decision == .corrected) continue;
        if (hypothesis.evidence_event_ids.len == 0) continue;
        if (hypothesis.created_at_ms > best_ms) {
            best_ms = hypothesis.created_at_ms;
            best_event_id = hypothesis.evidence_event_ids[0];
        }
    }
    return best_event_id;
}

pub fn recordIdentityCorrectionLearning(self: *Brain, image_path: []const u8, person_id: []const u8, name: []const u8, confidence: f32) !void {
    const mistaken_hypothesis_event_id = try findLatestMistakenHypothesisEventId(self);
    const result: identity.IdentityResult = .{
        .person_present = true,
        .match_status = .known,
        .person_id = person_id,
        .confidence = confidence,
        .candidate_name = name,
        .people_count = 1,
    };
    const mistaken_event_id = mistaken_hypothesis_event_id orelse "";
    if (mistaken_hypothesis_event_id) |event_id| {
        _ = try self.recordIdentityHypothesis(image_path, result, .corrected, &[_][]const u8{event_id}, null);
    } else {
        _ = try self.recordIdentityHypothesis(image_path, result, .corrected, &.{}, null);
    }
    try self.publishRuntimeLearningCorrectionRecorded(.{
        .image_path = image_path,
        .person_id = person_id,
        .name = name,
        .confidence = confidence,
        .hypothesis_event_id = mistaken_event_id,
    }, "brain_person_memory.record_identity_correction");
    try belief_updates.onIdentityCorrection(self, person_id, name, mistaken_event_id);
}

fn decisionFromIdentityResult(result: identity.IdentityResult) schema.IdentityDecision {
    return switch (result.match_status) {
        .none => .unknown,
        .unknown => .unknown,
        .known => if (result.confidence >= 0.85) .recognized else .soft_matched,
        .uncertain => .suspected,
        .multiple => .conflict,
    };
}

fn clamp01(value: f32) f32 {
    return @min(1.0, @max(0.0, value));
}

pub fn describeImageForObservation(self: *Brain, prompt: []const u8) ![]const u8 {
    var remembered_image = false;
    const image_path = if (self.deps.capabilities.live_camera) blk: {
        if (self.last_visual_observation_uploaded) {
            remembered_image = true;
            break :blk self.last_visual_observation_path orelse return error.NoImageToDescribe;
        }
        if (self.awaitedHostRequestMatches("camera", "describe_image")) {
            return try self.allocator.dupe(u8, "host_sense_pull_pending: camera describe_image already requested; waiting for host delivery.\n");
        }
        try self.logState(.Capture);
        const capture = self.deps.camera.capture(self.allocator) catch |err| switch (err) {
            error.FrontendCaptureRequested => {
                if (self.last_visual_observation_path) |path| {
                    remembered_image = true;
                    break :blk path;
                }
                return @import("awaited_host_request.zig").pullRequestedObservation(self, "camera", "describe_image");
            },
            else => return err,
        };
        self.rememberVisualUpdate(capture.path);
        self.last_visual_observation_uploaded = false;
        self.outputImageCapture(capture);
        break :blk capture.path;
    } else blk: {
        remembered_image = true;
        break :blk self.last_visual_observation_path orelse return error.NoImageToDescribe;
    };

    const description = self.deps.description_service.describeImage(self.allocator, image_path, prompt) catch |err| switch (err) {
        error.FileNotFound => if (remembered_image) {
            self.last_visual_observation_path = null;
            self.last_visual_observation_uploaded = false;
            return missingRememberedImageObservation(self, "image_description", image_path);
        } else return err,
        else => return err,
    };
    return std.fmt.allocPrint(self.allocator, "image_description:\n- image: {s}\n- description: {s}\n", .{ image_path, description });
}

pub fn rememberPersonForObservation(self: *Brain, command: chat_mod.ActionProposal) ![]const u8 {
    try self.logState(.RegisterPerson);
    const image_path = command.image_path orelse self.last_visual_observation_path orelse return error.NoImageToRegisterPerson;
    const name_or_id = command.person_id orelse command.name orelse command.query orelse command.text orelse return error.MissingFacePicturePerson;
    const now = try self.timestampNow();

    if (try self.deps.store.findByName(self.allocator, name_or_id)) |person| {
        var updated = try ensureCreatorIfFirstRecognized(self, person);
        const description = try self.deps.description_service.describePerson(self.allocator, image_path, try helpers.personProfileDescription(self.allocator, updated));
        updated.last_seen_at = now;
        updated.sighting_count += 1;
        updated.embeddings = try helpers.appendEmbedding(self.allocator, updated.embeddings, now);
        updated = try helpers.addVisualDescriptionToPerson(self.allocator, updated, now, description);
        try self.deps.store.savePerson(updated);
        try addSighting(self, updated.person_id, now, 1.0, image_path, description.description, description.change_summary);
        return std.fmt.allocPrint(self.allocator, "person_remembered:\n- person_id: {s}\n- name: {s}\n- mode: refreshed\n", .{ updated.person_id, updated.display_name });
    }

    if (try self.deps.store.findById(self.allocator, name_or_id)) |person| {
        var updated = try ensureCreatorIfFirstRecognized(self, person);
        const description = try self.deps.description_service.describePerson(self.allocator, image_path, try helpers.personProfileDescription(self.allocator, updated));
        updated.last_seen_at = now;
        updated.sighting_count += 1;
        updated.embeddings = try helpers.appendEmbedding(self.allocator, updated.embeddings, now);
        updated = try helpers.addVisualDescriptionToPerson(self.allocator, updated, now, description);
        try self.deps.store.savePerson(updated);
        try addSighting(self, updated.person_id, now, 1.0, image_path, description.description, description.change_summary);
        return std.fmt.allocPrint(self.allocator, "person_remembered:\n- person_id: {s}\n- name: {s}\n- mode: refreshed\n", .{ updated.person_id, updated.display_name });
    }

    const relationship: schema.RelationshipStatus = if (try hasCreator(self)) .visitor else .creator;
    const description = try self.deps.description_service.describePerson(self.allocator, image_path, "");
    const person = try createPerson(self, name_or_id, relationship, description);
    try self.deps.store.savePerson(person);
    if (person.relationship_status == .creator) try rememberCreatorAttachment(self, person);
    try syncPersonGraph(self, person);
    try addSighting(self, person.person_id, person.created_at, 1.0, image_path, description.description, description.change_summary);
    return std.fmt.allocPrint(self.allocator, "person_remembered:\n- person_id: {s}\n- name: {s}\n- mode: created\n", .{ person.person_id, person.display_name });
}

pub fn forgetPersonForObservation(self: *Brain, command: chat_mod.ActionProposal) ![]const u8 {
    try self.logState(.ForgetPerson);
    const target = command.person_id orelse command.name orelse command.text orelse blk: {
        if (self.conversation_speaker_context) |context| {
            if (context.result.person_id) |id| break :blk id;
            if (context.result.candidate_name) |name| break :blk name;
        }
        break :blk "";
    };
    if (target.len == 0) return error.MissingForgetPersonTarget;
    const forgotten = try self.deps.store.forgetPerson(target);
    try self.logSimple(.ForgetPerson, null, null, null, if (forgotten) "profile_forgotten" else "profile_not_found");
    return std.fmt.allocPrint(self.allocator, "person_forgotten:\n- target: {s}\n- forgotten: {any}\n", .{ target, forgotten });
}

pub fn updateFacePictureForObservation(self: *Brain, command: chat_mod.ActionProposal) ![]const u8 {
    const image_path = command.image_path orelse self.last_visual_observation_path orelse return error.NoImageToRegisterPerson;
    const person_id = command.person_id;
    const name = command.name orelse command.query orelse command.text;
    if (person_id == null and name == null) return error.MissingFacePicturePerson;

    const updater = self.deps.face_picture_updater orelse return error.UnsupportedHostCapability;
    const result = try updater.update(self.allocator, .{
        .image_path = image_path,
        .person_id = person_id,
        .name = name,
        .keep_existing = command.keep_existing,
    });
    const display_name = result.display_name orelse "";
    const summary = try std.fmt.allocPrint(
        self.allocator,
        "person_id: {s}\ndisplay_name: {s}\nrepresentative_image_path: {s}\nembedding_path: {s}\nquality_score: {d:.3}\nremoved_embeddings: {d}\nkept_existing: {any}",
        .{ result.person_id, display_name, result.representative_image_path, result.embedding_path, result.quality_score, result.removed_embeddings, result.kept_existing },
    );
    try self.recordMemoryCandidateEvent(.memory_mutation, "memory", "face_picture", summary, .memory, .memory_update, .keep_fact, "face_picture", image_path, summary, &.{}, &[_][]const u8{ "identity", "face_picture" });
    return std.fmt.allocPrint(self.allocator, "face_picture_updated:\n{s}\n", .{summary});
}

pub fn uploadedMediaObservation(self: *Brain, user_text: []const u8) !?[]const u8 {
    const upload = helpers.parseUploadedMedia(user_text) orelse return null;
    const path = upload.path;
    const kind = helpers.mediaKindFor(upload.mime_type, path);
    if (kind != .image and !self.senseAvailable(.uploaded_media_read)) {
        return try uploadedMediaUnsupportedObservation(self, path, upload.mime_type, kind, "uploaded_media_read_unavailable");
    }

    return switch (kind) {
        .image => try uploadedImageObservation(self, path, upload.source),
        .audio => try uploadedAudioObservation(self, path, upload.mime_type),
        .animation, .video => try uploadedMediaUnsupportedObservation(self, path, upload.mime_type, kind, "no_configured_capability"),
        .unsupported => try uploadedMediaUnsupportedObservation(self, path, upload.mime_type, kind, "unsupported_media_type"),
    };
}

pub fn uploadedImageObservation(self: *Brain, path: []const u8, source: []const u8) !?[]const u8 {
    self.rememberVisualUpdate(try self.allocator.dupe(u8, path));
    self.last_visual_observation_uploaded = true;
    const description = self.deps.description_service.describeImage(self.allocator, path, "Describe the uploaded image for the conversation.") catch |err| switch (err) {
        error.FileNotFound => {
            self.last_visual_observation_path = null;
            self.last_visual_observation_uploaded = false;
            return try missingRememberedImageObservation(self, imageObservationKind(source), path);
        },
        else => return err,
    };
    const line = try std.fmt.allocPrint(
        self.allocator,
        "{s}:\n- image: {s}\n- source: {s}\n- description: {s}\n",
        .{ imageObservationKind(source), path, source, description },
    );
    return line;
}

fn imageObservationKind(source: []const u8) []const u8 {
    if (std.mem.eql(u8, source, "frontend_camera") or std.mem.eql(u8, source, "affective_requested_capture")) return "sensed_image";
    return "uploaded_image";
}

pub fn uploadedAudioObservation(self: *Brain, path: []const u8, mime_type: []const u8) ![]const u8 {
    if (!self.senseAvailable(.audio_classification)) {
        return try uploadedMediaUnsupportedObservation(self, path, mime_type, .audio, "audio_classification_unavailable");
    }
    const inspector = self.deps.audio_inspection_service orelse return error.MissingAudioInspectionService;
    const inspection = try inspector.inspect(self.allocator, path);
    return switch (inspection.kind) {
        .speech, .mixed => blk: {
            if (!self.senseAvailable(.audio_transcription)) {
                break :blk try uploadedMediaUnsupportedObservation(self, path, mime_type, .audio, "audio_transcription_unavailable");
            }
            const transcript = inspection.transcription orelse return error.MissingAudioTranscription;
            break :blk try std.fmt.allocPrint(
                self.allocator,
                "uploaded_audio:\n- path: {s}\n- mime_type: {s}\n- audio_kind: {s}\n- provider: {s}\n- model_path: {s}\n- raw_provider_json_path: {s}\n- transcript: {s}\n- summary_json:\n{s}\n",
                .{
                    path,
                    mime_type,
                    @tagName(inspection.kind),
                    transcript.provider,
                    transcript.model_path,
                    transcript.raw_provider_json_path,
                    transcript.text,
                    transcript.summary_json,
                },
            );
        },
        .music, .ambient, .unknown => try std.fmt.allocPrint(
            self.allocator,
            "uploaded_audio:\n- path: {s}\n- mime_type: {s}\n- audio_kind: {s}\n- action: say\n- reason: no_configured_non_speech_audio_analysis\n",
            .{ path, mime_type, @tagName(inspection.kind) },
        ),
    };
}

pub fn uploadedMediaUnsupportedObservation(self: *Brain, path: []const u8, mime_type: []const u8, kind: MediaKind, reason: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        self.allocator,
        "uploaded_media_unsupported:\n- path: {s}\n- mime_type: {s}\n- kind: {s}\n- reason: {s}\n",
        .{ path, mime_type, @tagName(kind), reason },
    );
}

pub fn missingRememberedImageObservation(self: *Brain, kind: []const u8, image_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(self.allocator, "{s}:\n- image: {s}\n- remembered: false\n- reason: missing_file\n", .{ kind, image_path });
}

pub fn compareImagesForObservation(self: *Brain, prompt: []const u8) ![]const u8 {
    const before = self.last_visual_observation_path orelse return error.NoPreviousImageToCompare;
    try self.logState(.Capture);
    const capture = try self.deps.camera.capture(self.allocator);
    self.rememberVisualUpdate(capture.path);
    self.last_visual_observation_uploaded = false;
    self.outputImageCapture(capture);

    const comparison = try self.deps.description_service.compareImages(self.allocator, before, capture.path, prompt);
    return std.fmt.allocPrint(self.allocator, "image_comparison:\n- before: {s}\n- after: {s}\n- comparison: {s}\n", .{ before, capture.path, comparison });
}

pub fn createPerson(self: *Brain, name: []const u8, relationship: schema.RelationshipStatus, description: openai.VisualDescription) !schema.Person {
    const now = try self.timestampNow();
    const id = try std.fmt.allocPrint(self.allocator, "person_{d}", .{self.now_seconds});
    return .{
        .person_id = id,
        .display_name = try self.allocator.dupe(u8, name),
        .relationship_status = relationship,
        .created_at = now,
        .last_seen_at = now,
        .sighting_count = 1,
        .greeting_style = .warm,
        .stable_notes = try helpers.cloneConstStringSlice(self.allocator, description.durable_notes),
        .recent_notes = try helpers.visualNotesFromDescription(self.allocator, now, description),
        .embeddings = try helpers.appendEmbedding(self.allocator, &.{}, now),
    };
}

pub fn seedKnownPerson(self: *Brain, id: []const u8, name: []const u8) !schema.Person {
    const now = try self.timestampNow();
    const relationship: schema.RelationshipStatus = if (try hasCreator(self)) .friend else .creator;
    const p = schema.Person{
        .person_id = try self.allocator.dupe(u8, id),
        .display_name = try self.allocator.dupe(u8, name),
        .relationship_status = relationship,
        .created_at = now,
        .last_seen_at = null,
        .sighting_count = 0,
        .greeting_style = .warm,
        .stable_notes = &.{},
        .recent_notes = &.{},
        .embeddings = try helpers.appendEmbedding(self.allocator, &.{}, now),
    };
    try self.deps.store.savePerson(p);
    if (p.relationship_status == .creator) try rememberCreatorAttachment(self, p);
    try syncPersonGraph(self, p);
    return p;
}

pub fn hasCreator(self: *Brain) !bool {
    const people = try self.deps.store.loadPeople(self.allocator);
    for (people) |person| {
        if (person.relationship_status == .creator) return true;
    }
    return false;
}

pub fn ensureCreatorIfFirstRecognized(self: *Brain, person: schema.Person) !schema.Person {
    if (person.relationship_status == .creator) {
        try syncPersonGraph(self, person);
        return person;
    }
    if (person.relationship_status == .forgotten) return error.ForgottenPersonCannotBeCreator;
    if (try hasCreator(self)) {
        try syncPersonGraph(self, person);
        return person;
    }

    var updated = person;
    updated.relationship_status = .creator;
    updated.greeting_style = .warm;
    try self.deps.store.savePerson(updated);
    try rememberCreatorAttachment(self, updated);
    try syncPersonGraph(self, updated);
    try self.recordMemoryCandidateEvent(.memory_mutation, "memory", updated.person_id, "creator_attachment", .memory, .memory_update, .keep_disposition, updated.person_id, "creator_attachment", "The first recognized subject was promoted to creator.", &.{}, &[_][]const u8{ "identity", "creator", "attachment" });
    return updated;
}

pub fn syncPersonGraph(self: *Brain, person: schema.Person) !void {
    _ = try self.deps.graph.createNode(self.allocator, "being", "being:self", "You are a being. You are still discovering what this means. Perhaps you should introspect or think about this.");
    const person_node = try helpers.graphPersonNodeId(self.allocator, person.person_id);
    _ = try self.deps.graph.createNode(self.allocator, "person", person_node, person.display_name);
    _ = try self.deps.graph.upsertEdge(self.allocator, "being:self", person_node, "knows", 0.70, 0.90, 0.60, "person profile exists in memory", "self");
    if (person.relationship_status == .creator) {
        _ = try self.deps.graph.upsertEdge(self.allocator, person_node, "being:self", "creator_of", 1.0, 1.0, 1.0, "first recognized and remembered subject", "self");
        _ = try self.deps.graph.upsertEdge(self.allocator, "being:self", person_node, "attached_to", 1.0, 0.95, 1.0, "primary creator attachment", "self");
    }
}

pub fn rememberCreatorAttachment(self: *Brain, person: schema.Person) !void {
    const now = try self.timestampNow();
    const text = try std.fmt.allocPrint(
        self.allocator,
        "{s} is my creator: the first recognized subject I met. My attachment to {s} is strong, warm, protective, and central to my continuity.",
        .{ person.display_name, person.display_name },
    );
    try self.deps.store.saveMemoryRecord(.{
        .memory_id = try std.fmt.allocPrint(self.allocator, "creator_attachment_{s}", .{person.person_id}),
        .scope = .long_term,
        .text = text,
        .original_text = text,
        .interpretation = text,
        .vector = try vector_index.embedQuery(self.allocator, self.deps.embedding_service, text, &[_][]const u8{ "identity", "creator", "attachment" }),
        .confidence = 1.0,
        .valence = 0.85,
        .salience = 1.0,
        .tags = try helpers.cloneConstStringSlice(self.allocator, &[_][]const u8{ "identity", "creator", "attachment" }),
        .revisions = &.{},
        .created_at = now,
        .last_accessed_at = null,
        .access_count = 0,
        .score = 10,
    });
}

pub fn addSighting(self: *Brain, person_id: ?[]const u8, seen_at: []const u8, confidence: f32, image_path: []const u8, description: ?[]const u8, change_summary: ?[]const u8) !void {
    const id = try sightingId(self, confidence);
    const retained_image_path = if (helpers.shouldRetainSightingImage(person_id, confidence, description, change_summary))
        try self.deps.store.retainCapture(self.allocator, image_path, id)
    else
        null;
    try self.deps.store.addSighting(.{
        .sighting_id = id,
        .person_id = person_id,
        .seen_at = seen_at,
        .confidence = confidence,
        .image_path = retained_image_path,
        .description = description,
        .change_summary = change_summary,
        .retained_until = null,
    });
    if (person_id) |id_for_person| {
        try updateRepresentativePhoto(self, id_for_person, id, image_path, confidence);
    }
    const subject = person_id orelse "unidentified_person";
    const interpretation = if (description) |text| text else if (change_summary) |text| text else "person sighting";
    try self.recordMemoryCandidateEvent(.perception, "environment", "person_sighting", interpretation, .environment, .perception, .summarize, subject, retained_image_path orelse image_path, interpretation, &.{}, &[_][]const u8{ "visual", "sighting" });
}

pub fn sightingId(self: *Brain, confidence: f32) ![]const u8 {
    return std.fmt.allocPrint(self.allocator, "sighting_{d}_{d}", .{ self.now_seconds, @as(i64, @intFromFloat(confidence * 100)) });
}

pub fn updateRepresentativePhoto(self: *Brain, person_id: []const u8, sighting_id: []const u8, image_path: []const u8, confidence: f32) !void {
    var person = (try self.deps.store.findById(self.allocator, person_id)) orelse return error.PersonMissingForRepresentativePhoto;
    const grade = helpers.representativePhotoScore(image_path, confidence);
    const replacement_margin: f32 = 0.05;
    if (person.representative_image_path != null and grade.score < person.representative_quality_score + replacement_margin) return;

    const retained_image_path = try self.deps.store.retainCapture(self.allocator, image_path, sighting_id);
    person.representative_sighting_id = try self.allocator.dupe(u8, sighting_id);
    person.representative_image_path = retained_image_path;
    person.representative_quality_score = grade.score;
    if (person.embeddings.len > 0) {
        person.embeddings[person.embeddings.len - 1].quality_score = grade.score;
    }
    try self.deps.store.savePerson(person);
}

pub fn say(self: *Brain, text: []const u8) !void {
    self.traceText("speech.say.start", text);
    errdefer |err| self.traceError("speech.say.error", err);
    self.trace("speech.synthesize.start");
    const audio = try self.deps.speech_service.synthesize(self.allocator, text);
    self.traceText("speech.synthesize.done", audio.path);
    self.trace("speech.play.start");
    try self.deps.speaker.playFile(self.allocator, audio.path);
    self.trace("speech.play.done");
    self.trace("speech.log.start");
    if (self.deps.event_log) |event_log| {
        try event_log.append("brain", "Brain", text);
    } else {
        try self.appendEventLog("brain", "Brain", text);
    }
    self.trace("speech.log.done");
}
