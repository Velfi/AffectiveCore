const std = @import("std");
const brain_mod = @import("brain.zig");
const config_mod = @import("config.zig");
const events = @import("events.zig");
const facts = @import("facts.zig");
const greeting = @import("greeting_policy.zig");
const identity = @import("identity.zig");
const interrupt_mod = @import("interrupt.zig");
const state_mod = @import("state.zig");
const schema = @import("../storage/schema.zig");
const store_mod = @import("../storage/store.zig");
const graph_store = @import("../storage/graph_store.zig");
const intent_mod = @import("../api/intent_client.zig");
const openai = @import("../api/openai_client.zig");
const greeting_client = @import("../api/greeting_client.zig");
const speech_mod = @import("../api/speech_client.zig");
const chat_mod = @import("../api/chat_client.zig");
const skills_mod = @import("../api/skills.zig");
const email_mod = @import("../api/email_client.zig");
const autonomy_mod = @import("../api/autonomy_client.zig");
const psyche_client = @import("../api/psyche_client.zig");
const want_achievement_mod = @import("../api/want_achievement_client.zig");
const image_mod = @import("../api/image_client.zig");
const audio_mod = @import("../api/audio_client.zig");
const camera_mod = @import("../platform/common/camera.zig");
const speaker_mod = @import("../platform/common/speaker.zig");
const input_mod = @import("../platform/common/input.zig");
const button_mod = @import("../platform/common/button.zig");
const command_log_mod = @import("../platform/common/command_log.zig");
const facial_expression = @import("../platform/common/facial_expression.zig");
const system_senses_mod = @import("../platform/common/system_senses.zig");
const time_mod = @import("time.zig");
const maintenance = @import("maintenance.zig");
const id_monitor = @import("id_monitor.zig");
const needs_mod = @import("needs.zig");
const psyche_mod = @import("psyche.zig");
const seed_mod = @import("seed.zig");
const vector_index = @import("vector_index.zig");
const emotion = @import("emotion.zig");
const process = @import("../platform/common/process.zig");
const helpers = @import("brain_helpers.zig");

const Brain = brain_mod.Brain;
const BrainDeps = brain_mod.BrainDeps;
const CommandBatchResult = brain_mod.CommandBatchResult;
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
pub fn recognizeForObservation(self: *Brain) ![]const u8 {
    try self.logState(.Capture);
    const capture = try self.deps.camera.capture(self.allocator);
    self.rememberVisualUpdate(capture.path);
    std.debug.print("Image: {s}\n", .{capture.path});

    try self.logState(.Identify);
    const result = try self.deps.recognizer.identify(self.allocator, capture.path);
    std.debug.print("Recognition: {s}, confidence={d:.2}", .{ @tagName(result.match_status), result.confidence });
    if (result.candidate_name) |candidate| std.debug.print(", candidate={s}", .{candidate});
    std.debug.print("\n", .{});

    var name: ?[]const u8 = result.candidate_name;
    if (result.match_status == .known) {
        const id = result.person_id orelse return error.KnownRecognitionMissingPersonId;
        var person = (try self.deps.store.findById(self.allocator, id)) orelse try seedKnownPerson(self, id, result.candidate_name orelse "Mara");
        person = try ensureCreatorIfFirstRecognized(self, person);
        const now = try time_mod.nowTimestamp(self.allocator);
        person.last_seen_at = now;
        person.sighting_count += 1;
        try self.deps.store.savePerson(person);
        try addSighting(self, id, now, result.confidence, capture.path, null, null);
        name = person.display_name;
        try self.logSimple(.TransientConversation, capture.path, id, null, "recognize_command_known,sighting_created,last_seen_updated");
    } else {
        try self.logSimple(.TransientConversation, capture.path, result.person_id, null, "recognize_command_observed");
    }

    return try self.conversationSpeakerLine(capture.path, result, name, @tagName(result.match_status));
}

pub fn describeImageForObservation(self: *Brain, prompt: []const u8) ![]const u8 {
    var remembered_image = false;
    const image_path = if (self.deps.capabilities.live_camera) blk: {
        if (self.last_visual_observation_uploaded) {
            remembered_image = true;
            break :blk self.last_visual_observation_path orelse return error.NoImageToDescribe;
        }
        try self.logState(.Capture);
        const capture = try self.deps.camera.capture(self.allocator);
        self.rememberVisualUpdate(capture.path);
        self.last_visual_observation_uploaded = false;
        std.debug.print("Image: {s}\n", .{capture.path});
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

pub fn rememberPersonForObservation(self: *Brain, command: chat_mod.ChatCommand) ![]const u8 {
    try self.logState(.RegisterPerson);
    const image_path = command.image_path orelse self.last_visual_observation_path orelse return error.NoImageToRegisterPerson;
    const name_or_id = command.person_id orelse command.name orelse command.query orelse command.text orelse return error.MissingFacePicturePerson;
    const now = try time_mod.nowTimestamp(self.allocator);

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

pub fn updateFacePictureForObservation(self: *Brain, command: chat_mod.ChatCommand) ![]const u8 {
    const io = self.deps.io orelse return error.MissingProcessIo;
    const image_path = command.image_path orelse self.last_visual_observation_path orelse return error.NoImageToRegisterPerson;
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(self.allocator, self.cfg.recognition_command);
    try argv.append(self.allocator, "enroll");
    try argv.append(self.allocator, "--image");
    try argv.append(self.allocator, image_path);
    try argv.append(self.allocator, "--memory");
    try argv.append(self.allocator, self.cfg.memory_path);
    try argv.append(self.allocator, "--embeddings-dir");
    try argv.append(self.allocator, self.cfg.face_embeddings_dir);
    try argv.append(self.allocator, "--detector");
    try argv.append(self.allocator, self.cfg.face_detector_model);
    try argv.append(self.allocator, "--recognizer");
    try argv.append(self.allocator, self.cfg.face_recognition_model);
    if (command.person_id) |person_id| {
        try argv.append(self.allocator, "--person-id");
        try argv.append(self.allocator, person_id);
    } else if (command.name orelse command.query orelse command.text) |name| {
        try argv.append(self.allocator, "--name");
        try argv.append(self.allocator, name);
    } else {
        return error.MissingFacePicturePerson;
    }
    if (command.keep_existing) try argv.append(self.allocator, "--keep-existing");

    const out = try process.runCapture(self.allocator, io, argv.items);
    defer self.allocator.free(out);
    const trimmed = std.mem.trim(u8, out, " \r\n\t");
    try self.recordMemoryCandidateEvent(.memory_mutation, "memory", "face_picture", trimmed, .memory, .memory_update, .keep_fact, "face_picture", image_path, trimmed, &.{}, &[_][]const u8{ "identity", "face_picture" });
    return std.fmt.allocPrint(self.allocator, "face_picture_updated:\n{s}\n", .{trimmed});
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
            "uploaded_audio:\n- path: {s}\n- mime_type: {s}\n- audio_kind: {s}\n- action: ask_human\n- reason: no_configured_non_speech_audio_analysis\n",
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
    std.debug.print("Image: {s}\n", .{capture.path});

    const comparison = try self.deps.description_service.compareImages(self.allocator, before, capture.path, prompt);
    return std.fmt.allocPrint(self.allocator, "image_comparison:\n- before: {s}\n- after: {s}\n- comparison: {s}\n", .{ before, capture.path, comparison });
}

pub fn createPerson(self: *Brain, name: []const u8, relationship: schema.RelationshipStatus, description: openai.VisualDescription) !schema.Person {
    const now = try time_mod.nowTimestamp(self.allocator);
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
    const now = try time_mod.nowTimestamp(self.allocator);
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
    const now = try time_mod.nowTimestamp(self.allocator);
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
        .vector = try vector_index.embedQuery(self.allocator, text, &[_][]const u8{ "identity", "creator", "attachment" }),
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
    self.trace("speech.send.disable.start");
    try self.setSendEnabled(false);
    self.trace("speech.send.disable.done");
    errdefer self.setSendEnabled(true) catch |err| {
        std.debug.panic("failed to re-enable webview send after speech error: {s}", .{@errorName(err)});
    };
    self.trace("speech.synthesize.start");
    const audio = try self.deps.speech_service.synthesize(self.allocator, text);
    self.traceText("speech.synthesize.done", audio.path);
    self.trace("speech.play.start");
    try self.deps.speaker.playFile(self.allocator, audio.path);
    self.trace("speech.play.done");
    self.trace("speech.send.enable.start");
    try self.setSendEnabled(true);
    self.trace("speech.send.enable.done");
    self.trace("speech.log.start");
    try self.appendCommandLog("brain", "Brain", text);
    self.trace("speech.log.done");
}
