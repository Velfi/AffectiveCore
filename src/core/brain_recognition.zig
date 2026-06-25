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
pub fn handleKnown(self: *Brain, capture: events.ImageCapture, result: identity.IdentityResult) !void {
    try self.logState(.KnownGreeting);
    const id = result.person_id orelse return handleUnknown(self, capture, result, "known match did not include a stored person id; curiosity is active; if the person offers a name or identity, remember_person is an available skill");
    var person = (try self.deps.store.findById(self.allocator, id)) orelse try self.seedKnownPerson(id, result.candidate_name orelse "Mara");
    person = try self.ensureCreatorIfFirstRecognized(person);

    const description = try self.deps.description_service.describePerson(self.allocator, capture.path, "");
    try recordKnownGreetingInteriorEvent(self, person, result, description);
    const text = try generateKnownGreeting(self, person, description);

    const now = try time_mod.nowTimestamp(self.allocator);
    person.last_seen_at = now;
    person.sighting_count += 1;
    try self.deps.store.savePerson(person);
    try self.addSighting(id, now, result.confidence, capture.path, description.description, description.change_summary);

    std.debug.print("\nBRAIN:\n{s}\n", .{text});
    try self.say(text);
    try self.logSimple(.KnownGreeting, capture.path, id, text, "sighting_created,last_seen_updated");
}

pub fn generateKnownGreeting(self: *Brain, person: schema.Person, description: openai.VisualDescription) ![]const u8 {
    const senses_text = try currentSensesText(self);
    const recent_note_texts = try helpers.visualNoteTexts(self.allocator, person.recent_notes);
    const interior_state = try greetingInteriorState(self, person);
    const days = time_mod.daysBetweenUnixish(person.last_seen_at, self.now_seconds);
    return self.deps.greeting_service.generate(self.allocator, .{
        .intent = .known_person,
        .person_name = person.display_name,
        .elapsed_days = if (days >= 2 and days < 9999) days else null,
        .visual_description = description.description,
        .change_summary = if (helpers.isNotableChange(description.change_summary)) description.change_summary else "",
        .senses = senses_text,
        .interior_state = interior_state,
        .stable_notes = person.stable_notes,
        .recent_notes = recent_note_texts,
    });
}

pub fn generateSimpleGreeting(self: *Brain, intent: greeting_client.GreetingIntent) ![]const u8 {
    return self.deps.greeting_service.generate(self.allocator, .{
        .intent = intent,
        .visual_description = "",
        .change_summary = "",
        .senses = try currentSensesText(self),
        .interior_state = try generalGreetingInteriorState(self),
        .stable_notes = &.{},
        .recent_notes = &.{},
    });
}

pub fn generalGreetingInteriorState(self: *Brain) ![]const u8 {
    const appraisals = try self.deps.store.loadAppraisals(self.allocator);
    const impressions = try self.deps.store.loadImpressions(self.allocator);
    const recent_appraisal = if (appraisals.len > 0) appraisals[appraisals.len - 1].freeform else "none yet";
    const recent_impression = if (impressions.len > 0) impressions[impressions.len - 1].text else "none yet";
    return std.fmt.allocPrint(
        self.allocator,
        "{s}{s}{s}current_person:\n- recognition_status: unknown_or_unspecified\nrecent_impression: {s}\nrecent_appraisal: {s}\n",
        .{
            try self.selfFactsSummary(),
            try self.deps.graph.summary(self.allocator, 8),
            try self.activeNeedsSummary(),
            recent_impression,
            recent_appraisal,
        },
    );
}

pub fn recordKnownGreetingInteriorEvent(self: *Brain, person: schema.Person, result: identity.IdentityResult, description: openai.VisualDescription) !void {
    const text = try std.fmt.allocPrint(
        self.allocator,
        "Recognized {s} as a known person with confidence {d:.2}. Visual observation: {s}. Visible change: {s}.",
        .{ person.display_name, result.confidence, description.description, if (helpers.isNotableChange(description.change_summary)) description.change_summary else "none" },
    );
    const tags = &[_][]const u8{ "recognition", "greeting", "known_person" };
    const impression = try self.createImpression(.visual_observation, text, tags);
    try self.deps.store.addImpression(impression);
    const appraisal = try self.createAppraisal(text, impression.impression_id, tags);
    try self.deps.store.addAppraisal(appraisal);
}

pub fn greetingInteriorState(self: *Brain, person: schema.Person) ![]const u8 {
    const appraisals = try self.deps.store.loadAppraisals(self.allocator);
    const impressions = try self.deps.store.loadImpressions(self.allocator);
    const recent_appraisal = if (appraisals.len > 0) appraisals[appraisals.len - 1].freeform else "none yet";
    const recent_impression = if (impressions.len > 0) impressions[impressions.len - 1].text else "none yet";
    return std.fmt.allocPrint(
        self.allocator,
        "{s}{s}{s}current_person:\n- name: {s}\n- relationship_status: {s}\n- sighting_count_before_this_greeting: {d}\nrecent_impression: {s}\nrecent_appraisal: {s}\n",
        .{
            try self.selfFactsSummary(),
            try self.deps.graph.summary(self.allocator, 8),
            try self.activeNeedsSummary(),
            person.display_name,
            @tagName(person.relationship_status),
            person.sighting_count,
            recent_impression,
            recent_appraisal,
        },
    );
}

pub fn currentSensesText(self: *Brain) ![]const u8 {
    const snapshot = system_senses_mod.Snapshot{
        .datetime = try self.deps.system_senses.datetime(self.allocator),
        .power = try self.deps.system_senses.power(self.allocator),
        .storage = try self.deps.system_senses.storage(self.allocator),
        .database = try self.deps.system_senses.database(self.allocator),
    };
    return system_senses_mod.formatSnapshot(self.allocator, snapshot);
}

pub fn handleUnknown(self: *Brain, capture: events.ImageCapture, result: identity.IdentityResult, status: []const u8) !void {
    try self.logState(.UnknownGreeting);
    const curiosity_prompt = try generateSimpleGreeting(self, .unknown_person);
    try self.say(curiosity_prompt);
    const heard_speech = try self.deps.input.ask(self.allocator, curiosity_prompt);
    try continueFromRecognitionPrompt(self, capture, result, heard_speech, status);
}

pub fn handleUncertain(self: *Brain, capture: events.ImageCapture, result: identity.IdentityResult) !void {
    try self.logState(.UncertainConfirmation);
    const uncertain_prompt = try generateSimpleGreeting(self, .uncertain_person);
    try self.say(uncertain_prompt);
    const name_text = (try self.deps.input.ask(self.allocator, uncertain_prompt)).text;
    const name_intent = try self.deps.intent_service.classify(self.allocator, .name_prompt, name_text);
    if (try handleImmediateIntent(self, name_intent)) return;
    if (name_intent.action == .claim_identity) {
        const speaker_context = try speakerContextFromCapture(self, capture, result, result.candidate_name, "uncertain match");
        if (try handleIdentityClaim(self, name_intent, speaker_context)) return;
    }
    const name = name_intent.value orelse name_text;
    if (name.len == 0 or name_intent.action == .unknown) {
        try continueFromRecognitionPrompt(self, capture, result, try input_mod.HeardSpeech.typed(self.allocator, name_text), "uncertain match");
        return;
    }

    if (try self.deps.store.findByName(self.allocator, name)) |person| {
        const prompt = try std.fmt.allocPrint(self.allocator, "I know someone named {s}, but I am not certain you are the same person. Have we met here before?", .{name});
        try self.say(prompt);
        const confirmation_text = (try self.deps.input.ask(self.allocator, prompt)).text;
        const confirmation = try self.deps.intent_service.classify(self.allocator, .identity_confirmation, confirmation_text);
        if (try handleImmediateIntent(self, confirmation)) return;
        if (confirmation.action == .grant_memory_permission) {
            try self.logState(.MergeOrConfirm);
            var updated = try self.ensureCreatorIfFirstRecognized(person);
            const now = try time_mod.nowTimestamp(self.allocator);
            const description = try self.deps.description_service.describePerson(self.allocator, capture.path, try helpers.personProfileDescription(self.allocator, updated));
            updated.last_seen_at = now;
            updated.sighting_count += 1;
            updated.embeddings = try helpers.appendEmbedding(self.allocator, updated.embeddings, now);
            updated = try helpers.addVisualDescriptionToPerson(self.allocator, updated, now, description);
            try self.deps.store.savePerson(updated);
            try self.addSighting(updated.person_id, now, result.confidence, capture.path, description.description, description.change_summary);
            const text = try std.fmt.allocPrint(self.allocator, "Thank you, {s}. I will update your memory.", .{updated.display_name});
            std.debug.print("\nBRAIN:\n{s}\n", .{text});
            try self.say(text);
            try self.logSimple(.MergeOrConfirm, capture.path, updated.person_id, text, "confirmed_sighting,embedding_reference_added,last_seen_updated");
            return;
        }
    }

    try handleUnknown(self, capture, result, "person present but not recognized; touch stimulus made this person salient; curiosity is active; if the person offers a name or identity, remember_person is an available skill");
}

pub fn handleImmediateIntent(self: *Brain, intent: intent_mod.IntentResult) !bool {
    switch (intent.action) {
        .quit => return error.UserQuit,
        .forget_me => {
            _ = try self.forgetByNameOrId(intent.value orelse "");
            return true;
        },
        .sleep_autonomy => {
            try self.setAutonomySleeping(true, "user requested sleep");
            const text = "I will sleep my self-directed actions for now.";
            std.debug.print("\nBRAIN:\n{s}\n", .{text});
            try self.say(text);
            return true;
        },
        .wake_autonomy => {
            try self.setAutonomySleeping(false, "user requested wake");
            const text = "I am awake for self-directed actions again.";
            std.debug.print("\nBRAIN:\n{s}\n", .{text});
            try self.say(text);
            return true;
        },
        else => return false,
    }
}

pub fn continueFromRecognitionPrompt(self: *Brain, capture: events.ImageCapture, result: identity.IdentityResult, heard_speech: input_mod.HeardSpeech, status: []const u8) !void {
    const user_text = heard_speech.text;
    const heard_speech_raw = try self.heardSpeechRaw(heard_speech);
    try self.recordMemoryCandidateEvent(.user_utterance, "human", "recognition_prompt_reply", user_text, .human, .utterance, .summarize, "recognition_prompt_reply", heard_speech_raw, user_text, &.{}, &[_][]const u8{ "conversation", "heard_speech" });

    var observations = std.ArrayList(u8).empty;
    try self.appendHeardSpeechObservation(&observations, heard_speech);
    try observations.appendSlice(self.allocator, try conversationSpeakerLine(self, capture.path, result, result.candidate_name, status));
    try self.appendAffordanceObservation(&observations);
    const had_pending_hard_error = self.pending_hard_error != null;
    try self.appendPendingHardErrorObservation(&observations);
    if (had_pending_hard_error) self.pending_hard_error = null;

    const memory = try self.buildConversationMemoryWithSpeaker(observations.items);
    var spoken_text: []const u8 = "";
    var final_turn: ?chat_mod.ChatTurn = null;
    var pending_interrupt: ?interrupt_mod.Stimulus = null;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const turn = try self.deps.chat_service.respond(self.allocator, memory, user_text, observations.items);
        final_turn = turn;
        const batch = self.executeChatCommands(turn.commands, &observations) catch |err| {
            spoken_text = try self.handleHardCommandError(err);
            final_turn = turn;
            break;
        };
        if (batch.spoken_text) |text| {
            spoken_text = text;
        }
        if (batch.interrupted_by) |stimulus| {
            pending_interrupt = stimulus;
            break;
        }
        if (turn.conversation_done or batch.ended_with_speech) break;
    }

    if (spoken_text.len == 0 and pending_interrupt == null) {
        spoken_text = "I am listening. Tell me what I should know or check next.";
        std.debug.print("\nBRAIN:\n{s}\n", .{spoken_text});
        try self.say(spoken_text);
    }

    const summary_turn = final_turn orelse try self.deps.chat_service.respond(self.allocator, memory, user_text, observations.items);
    try self.deps.store.addConversationSummary(.{
        .summary_id = try std.fmt.allocPrint(self.allocator, "recognition_conversation_{d}_{d}", .{ self.now_seconds, self.now_seconds + @as(i64, @intCast(user_text.len)) }),
        .time = try time_mod.nowTimestamp(self.allocator),
        .user_summary = summary_turn.user_summary,
        .brain_summary = summary_turn.brain_summary,
    });
    try self.logSimple(.TransientConversation, capture.path, result.person_id, spoken_text, "recognition_prompt_continued_as_conversation");
    if (had_pending_hard_error and self.pending_hard_error == null) {
        try self.appendCommandLog("state", "Hard error recovery", "pending hard error resolved by follow-up conversation");
    }
    if (pending_interrupt) |stimulus| try self.handleInterruptStimulus(stimulus);
}

pub fn recognizeConversationSpeaker(self: *Brain) !ConversationSpeakerContext {
    try self.logState(.Capture);
    var capture = try self.deps.camera.capture(self.allocator);
    self.rememberVisualUpdate(capture.path);
    self.last_visual_observation_uploaded = false;
    std.debug.print("Image: {s}\n", .{capture.path});

    try self.logState(.Identify);
    const result = try self.deps.recognizer.identify(self.allocator, capture.path);
    std.debug.print("Recognition: {s}, confidence={d:.2}", .{ @tagName(result.match_status), result.confidence });
    if (result.candidate_name) |candidate| std.debug.print(", candidate={s}", .{candidate});
    std.debug.print("\n", .{});

    if (!result.person_present or result.match_status == .none) {
        try self.logSimple(.DetectPerson, capture.path, null, null, "conversation_no_person");
        return .{ .capture = capture, .result = result, .memory_line = "Current speaker recognition: no person recognized before this speech turn.\n", .chat_label = "Unknown speaker" };
    }
    try retainCaptureForPersonMemory(self, &capture);

    switch (result.match_status) {
        .known => {
            const id = result.person_id orelse return .{ .capture = capture, .result = result, .memory_line = try conversationSpeakerLine(self, capture.path, result, null, "known match without a stored person id"), .chat_label = result.candidate_name orelse "Unknown speaker" };
            var person = (try self.deps.store.findById(self.allocator, id)) orelse try self.seedKnownPerson(id, result.candidate_name orelse "Mara");
            person = try self.ensureCreatorIfFirstRecognized(person);
            const now = try time_mod.nowTimestamp(self.allocator);
            person.last_seen_at = now;
            person.sighting_count += 1;
            try self.deps.store.savePerson(person);
            try self.addSighting(id, now, result.confidence, capture.path, null, null);
            try self.logSimple(.TransientConversation, capture.path, id, null, "conversation_speaker_recognized,sighting_created,last_seen_updated");
            return .{ .capture = capture, .result = result, .memory_line = try conversationSpeakerLine(self, capture.path, result, person.display_name, "known person"), .chat_label = person.display_name };
        },
        .unknown => {
            try self.logSimple(.TransientConversation, capture.path, null, null, "conversation_speaker_unknown");
            return .{ .capture = capture, .result = result, .memory_line = try conversationSpeakerLine(self, capture.path, result, null, "person present but not recognized"), .chat_label = "Unknown speaker" };
        },
        .uncertain => {
            try self.logSimple(.TransientConversation, capture.path, result.person_id, null, "conversation_speaker_uncertain");
            return .{ .capture = capture, .result = result, .memory_line = try conversationSpeakerLine(self, capture.path, result, result.candidate_name, "uncertain match"), .chat_label = result.candidate_name orelse "Uncertain speaker" };
        },
        .multiple => {
            try self.logSimple(.TransientConversation, capture.path, null, null, "conversation_multiple_people");
            return .{ .capture = capture, .result = result, .memory_line = try conversationSpeakerLine(self, capture.path, result, null, "multiple people present"), .chat_label = "Multiple people" };
        },
        .none => return .{ .capture = capture, .result = result, .memory_line = "Current speaker recognition: no person recognized before this speech turn.\n", .chat_label = "Unknown speaker" },
    }
}

pub fn conversationSpeakerContext(self: *Brain) !ConversationSpeakerContext {
    if (self.conversation_speaker_context) |context| return context;
    const context = try recognizeConversationSpeaker(self);
    self.conversation_speaker_context = context;
    return context;
}

pub fn assignSpeechStimulus(self: *Brain, heard_speech: input_mod.HeardSpeech) !Brain.SpeechStimulusAssignment {
    const cached = self.conversation_speaker_context;
    const observed = cached;

    const last_message_seconds = secondsSince(self, self.last_conversation_turn_seconds);
    const last_visual_seconds = secondsSince(self, self.last_visual_update_seconds);
    const score = speakerContinuityScore(self, cached, observed, last_message_seconds, last_visual_seconds);
    const hint = speakerContinuityHint(cached, observed, score);
    const reason = speakerContinuityReason(cached, observed, last_message_seconds, last_visual_seconds);
    const context = observed orelse cached;
    const metadata = try std.fmt.allocPrint(
        self.allocator,
        "speech_stimulus source={s} text_bytes={d} continuity_score={d} continuity_hint={s} last_message_seconds={d} last_visual_update_seconds={d} cached_speaker={s} visual_status={s} visual_speaker={s} visual_confidence={d:.2} reason={s}",
        .{
            @tagName(heard_speech.source),
            heard_speech.text.len,
            score,
            hint,
            last_message_seconds,
            last_visual_seconds,
            speakerLabel(cached),
            if (observed) |value| @tagName(value.result.match_status) else "not_checked",
            speakerLabel(observed),
            if (observed) |value| value.result.confidence else 0,
            reason,
        },
    );
    const signature = try std.fmt.allocPrint(self.allocator, "speech:{s}:{s}:{d}", .{ @tagName(heard_speech.source), hint, @divTrunc(heard_speech.text.len, 24) });
    _ = try self.observeSenseStimulus(.{
        .kind = .speech,
        .source = @tagName(heard_speech.source),
        .signature = signature,
        .raw_magnitude = @min(1.0, 0.25 + @as(f32, @floatFromInt(@min(240, heard_speech.text.len))) / 320.0),
        .threat = 0,
        .curiosity = if (score < 40) 0.55 else 0.25,
        .metadata = metadata,
    });
    return .{ .speaker_context = context, .stimulus_context = self.current_stimulus_context.? };
}

pub fn assignTouchStimulus(self: *Brain, touch_kind: []const u8) !Brain.TouchStimulusAssignment {
    const cached = self.conversation_speaker_context;
    const last_message_seconds = secondsSince(self, self.last_conversation_turn_seconds);
    const last_visual_seconds = secondsSince(self, self.last_visual_update_seconds);
    const curiosity_score = touchCuriosityScore(cached, last_message_seconds, last_visual_seconds);
    const pre_metadata = try std.fmt.allocPrint(
        self.allocator,
        "touch_stimulus kind={s} curiosity_score={d} may_look=true last_message_seconds={d} last_visual_update_seconds={d} cached_speaker={s} visual_status={s} reason={s}",
        .{
            touch_kind,
            curiosity_score,
            last_message_seconds,
            last_visual_seconds,
            speakerLabel(cached),
            if (cached) |value| @tagName(value.result.match_status) else "not_checked",
            touchCuriosityReason(cached, last_message_seconds, last_visual_seconds),
        },
    );
    const packet = try self.scoreSenseStimulus(.{
        .kind = .touch,
        .source = "button",
        .signature = touch_kind,
        .raw_magnitude = if (std.mem.eql(u8, touch_kind, "long_touch")) 0.65 else 0.45,
        .threat = 0.05,
        .curiosity = @as(f32, @floatFromInt(curiosity_score)) / 100.0,
        .metadata = pre_metadata,
    });
    const should_look = touchStimulusShouldLook(packet.attention_intensity, last_visual_seconds);
    const suffix = try std.fmt.allocPrint(
        self.allocator,
        "attention_hint={s} chosen_look={any}",
        .{ touchAttentionHint(packet.attention_intensity, should_look), should_look },
    );
    const stimulus_context = try self.recordSenseStimulusPacket(packet, suffix);
    return .{
        .stimulus_context = stimulus_context,
        .curiosity_score = curiosity_score,
        .should_look = should_look,
    };
}

pub fn speakerContextFromCapture(self: *Brain, capture: events.ImageCapture, result: identity.IdentityResult, name: ?[]const u8, status: []const u8) !ConversationSpeakerContext {
    return .{
        .capture = capture,
        .result = result,
        .memory_line = try conversationSpeakerLine(self, capture.path, result, name, status),
        .chat_label = name orelse "Unknown speaker",
    };
}

fn secondsSince(self: *Brain, timestamp: ?i64) i64 {
    const value = timestamp orelse return -1;
    return @max(0, self.now_seconds - value);
}

fn speakerContinuityScore(self: *Brain, cached: ?Brain.ConversationSpeakerContext, observed: ?Brain.ConversationSpeakerContext, last_message_seconds: i64, last_visual_seconds: i64) u8 {
    var score: i32 = 0;
    const timeout: i64 = @intCast(self.cfg.conversation_idle_timeout_seconds);
    if (cached != null) score += 20;
    if (last_message_seconds >= 0 and last_message_seconds <= timeout) score += if (last_message_seconds <= @divTrunc(timeout, 2)) 20 else 10;
    if (last_visual_seconds >= 0 and last_visual_seconds <= timeout) score += if (last_visual_seconds <= @divTrunc(timeout, 2)) 15 else 8;
    if (observed) |current| {
        switch (current.result.match_status) {
            .known => score += if (sameKnownSpeaker(cached, current)) 40 else if (cached != null) -45 else 25,
            .uncertain => score += if (sameKnownSpeaker(cached, current)) 25 else 10,
            .unknown => score += 8,
            .multiple => score -= 25,
            .none => score -= 35,
        }
        if (!current.result.person_present) score -= 20;
    }
    return @intCast(@min(100, @max(0, score)));
}

fn speakerContinuityHint(cached: ?Brain.ConversationSpeakerContext, observed: ?Brain.ConversationSpeakerContext, score: u8) []const u8 {
    if (observed) |current| {
        if (!current.result.person_present or current.result.match_status == .none) return "speaker_not_visible";
        if (current.result.match_status == .multiple) return "ambiguous_multiple_people";
        if (current.result.match_status == .known and cached != null and !sameKnownSpeaker(cached, current)) return "different_known_person";
    }
    if (score >= 70) return "likely_same_speaker";
    if (score >= 40) return "uncertain_speaker_continuity";
    return "new_or_unknown_speaker";
}

fn speakerContinuityReason(cached: ?Brain.ConversationSpeakerContext, observed: ?Brain.ConversationSpeakerContext, last_message_seconds: i64, last_visual_seconds: i64) []const u8 {
    if (observed) |current| {
        if (!current.result.person_present or current.result.match_status == .none) return "available visual evidence has no person";
        if (current.result.match_status == .multiple) return "available visual evidence has multiple people";
        if (current.result.match_status == .known and cached != null and !sameKnownSpeaker(cached, current)) return "available visual evidence points to a different known person";
        if (sameKnownSpeaker(cached, current)) return "cached visual identity matches the active speaker";
    }
    if (cached != null and last_message_seconds >= 0) return "cached speaker plus recent message timing";
    if (last_visual_seconds >= 0) return "visual recency available without a cached speaker";
    return "no speaker continuity evidence yet";
}

fn sameKnownSpeaker(cached: ?Brain.ConversationSpeakerContext, observed: Brain.ConversationSpeakerContext) bool {
    const previous = cached orelse return false;
    const previous_id = previous.result.person_id orelse return false;
    const observed_id = observed.result.person_id orelse return false;
    return std.mem.eql(u8, previous_id, observed_id);
}

fn speakerLabel(context: ?Brain.ConversationSpeakerContext) []const u8 {
    const value = context orelse return "none";
    if (value.result.person_id) |person_id| return person_id;
    if (value.result.candidate_name) |candidate| return candidate;
    return value.chat_label;
}

fn touchCuriosityScore(cached: ?Brain.ConversationSpeakerContext, last_message_seconds: i64, last_visual_seconds: i64) u8 {
    var score: i32 = 45;
    if (last_visual_seconds < 0) score += 35 else if (last_visual_seconds > 30) score += 25 else if (last_visual_seconds <= 10) score -= 25;
    if (last_message_seconds >= 0 and last_message_seconds <= 20) score -= 10;
    if (cached) |context| {
        switch (context.result.match_status) {
            .known => score -= 25,
            .uncertain => score += 5,
            .unknown => score += 15,
            .multiple => score += 20,
            .none => score += 25,
        }
        if (!context.result.person_present) score += 15;
    } else {
        score += 10;
    }
    return @intCast(@min(100, @max(0, score)));
}

fn touchStimulusShouldLook(attention_intensity: f32, last_visual_seconds: i64) bool {
    if (last_visual_seconds >= 0 and last_visual_seconds <= 10) return false;
    return attention_intensity >= 0.55;
}

fn touchAttentionHint(attention_intensity: f32, should_look: bool) []const u8 {
    if (should_look) return "curious_to_identify_actor";
    if (attention_intensity >= 0.40) return "defer_visual_lookup";
    return "acknowledge_without_lookup";
}

fn touchCuriosityReason(cached: ?Brain.ConversationSpeakerContext, last_message_seconds: i64, last_visual_seconds: i64) []const u8 {
    if (last_visual_seconds < 0) return "touch arrived without recent visual evidence";
    if (last_visual_seconds <= 10) return "recent visual evidence is fresh enough to avoid an immediate repeat lookup";
    if (cached) |context| {
        if (context.result.match_status == .known and last_message_seconds >= 0 and last_message_seconds <= 20) return "recent known speaker evidence makes lookup low priority";
        if (!context.result.person_present or context.result.match_status == .none) return "touch conflicts with cached no-person evidence";
        if (context.result.match_status == .unknown or context.result.match_status == .multiple) return "cached visual evidence leaves actor identity unresolved";
    }
    return "visual evidence is stale enough that touch may warrant looking";
}

pub fn handleIdentityClaim(self: *Brain, intent: intent_mod.IntentResult, speaker_context: ConversationSpeakerContext) !bool {
    if (intent.action != .claim_identity) return false;
    const name = (try resolveIdentityClaimName(self, intent)) orelse return true;
    if (name.len == 0) return false;

    const person = (try self.deps.store.findByName(self.allocator, name)) orelse {
        const prompt = try std.fmt.allocPrint(self.allocator, "I do not have a stored profile for {s} yet. Would you like me to create one now?", .{name});
        std.debug.print("\nBRAIN:\n{s}\n", .{prompt});
        try self.say(prompt);
        try self.logSimple(.TransientConversation, speaker_context.capture.path, null, prompt, "identity_claim_profile_not_found,profile_creation_offered");

        const confirmation_text = (try self.deps.input.ask(self.allocator, prompt)).text;
        const confirmation = try self.deps.intent_service.classify(self.allocator, .identity_confirmation, confirmation_text);
        if (try handleImmediateIntent(self, confirmation)) return true;
        if (confirmation.action == .deny_memory_permission) {
            const text = try std.fmt.allocPrint(self.allocator, "Okay. I will not create a profile for {s}.", .{name});
            std.debug.print("\nBRAIN:\n{s}\n", .{text});
            try self.say(text);
            try self.logSimple(.TransientConversation, speaker_context.capture.path, null, text, "identity_claim_profile_creation_declined");
            return true;
        }
        if (confirmation.action != .grant_memory_permission) {
            const text = "I need a clear yes before I create a new profile.";
            std.debug.print("\nBRAIN:\n{s}\n", .{text});
            try self.say(text);
            try self.logSimple(.TransientConversation, speaker_context.capture.path, null, text, "identity_claim_profile_creation_unconfirmed");
            return true;
        }

        try self.logState(.RegisterPerson);
        const relationship: schema.RelationshipStatus = if (try self.hasCreator()) .visitor else .creator;
        const description = try self.deps.description_service.describePerson(self.allocator, speaker_context.capture.path, "");
        const created = try self.createPerson(name, relationship, description);
        try self.deps.store.savePerson(created);
        if (created.relationship_status == .creator) try self.rememberCreatorAttachment(created);
        try self.syncPersonGraph(created);
        try self.addSighting(created.person_id, created.created_at, speaker_context.result.confidence, speaker_context.capture.path, description.description, description.change_summary);

        const created_result = identity.IdentityResult{
            .person_present = true,
            .match_status = .known,
            .person_id = created.person_id,
            .confidence = speaker_context.result.confidence,
            .candidate_name = created.display_name,
            .people_count = speaker_context.result.people_count,
        };
        self.conversation_speaker_context = .{
            .capture = speaker_context.capture,
            .result = created_result,
            .memory_line = try conversationSpeakerLine(self, speaker_context.capture.path, created_result, created.display_name, "known person"),
            .chat_label = created.display_name,
        };

        const text = try std.fmt.allocPrint(self.allocator, "Got it, {s}. I created your profile and will use this sighting to recognize you.", .{created.display_name});
        std.debug.print("\nBRAIN:\n{s}\n", .{text});
        try self.say(text);
        try self.logSimple(.RegisterPerson, speaker_context.capture.path, created.person_id, text, "identity_claim_profile_created,sighting_created");
        return true;
    };

    try self.logState(.MergeOrConfirm);
    var updated = try self.ensureCreatorIfFirstRecognized(person);
    const now = try time_mod.nowTimestamp(self.allocator);
    const description = try self.deps.description_service.describePerson(self.allocator, speaker_context.capture.path, try helpers.personProfileDescription(self.allocator, updated));
    updated.last_seen_at = now;
    updated.sighting_count += 1;
    updated.embeddings = try helpers.appendEmbedding(self.allocator, updated.embeddings, now);
    updated = try helpers.addVisualDescriptionToPerson(self.allocator, updated, now, description);
    try self.deps.store.savePerson(updated);
    try self.addSighting(updated.person_id, now, speaker_context.result.confidence, speaker_context.capture.path, description.description, description.change_summary);
    const updated_result = identity.IdentityResult{
        .person_present = true,
        .match_status = .known,
        .person_id = updated.person_id,
        .confidence = speaker_context.result.confidence,
        .candidate_name = updated.display_name,
        .people_count = speaker_context.result.people_count,
    };
    self.conversation_speaker_context = .{
        .capture = speaker_context.capture,
        .result = updated_result,
        .memory_line = try conversationSpeakerLine(self, speaker_context.capture.path, updated_result, updated.display_name, "known person"),
        .chat_label = updated.display_name,
    };

    const text = try std.fmt.allocPrint(self.allocator, "Got it, {s}. I will use this sighting to recognize you.", .{updated.display_name});
    std.debug.print("\nBRAIN:\n{s}\n", .{text});
    try self.say(text);
    try self.logSimple(.MergeOrConfirm, speaker_context.capture.path, updated.person_id, text, "identity_claim_confirmed,embedding_reference_added,last_seen_updated");
    return true;
}

pub fn resolveIdentityClaimName(self: *Brain, intent: intent_mod.IntentResult) !?[]const u8 {
    if (intent.value) |name| {
        if (name.len > 0) return name;
    }

    const prompt = "What name would I know you by?";
    try self.say(prompt);
    const name_text = (try self.deps.input.ask(self.allocator, prompt)).text;
    const name_intent = try self.deps.intent_service.classify(self.allocator, .name_prompt, name_text);
    if (try handleImmediateIntent(self, name_intent)) return null;
    if (name_intent.action == .claim_identity) {
        if (name_intent.value) |name| {
            if (name.len > 0) return name;
        }
    }
    if (name_intent.action == .provide_name) {
        return name_intent.value orelse name_text;
    }

    const text = "I need the name I would know you by before I can update that memory.";
    std.debug.print("\nBRAIN:\n{s}\n", .{text});
    try self.say(text);
    return null;
}

pub fn conversationSpeakerLine(self: *Brain, image_path: []const u8, result: identity.IdentityResult, name: ?[]const u8, status: []const u8) ![]const u8 {
    const display = name orelse result.candidate_name orelse "unknown";
    const id = result.person_id orelse "none";
    return std.fmt.allocPrint(
        self.allocator,
        "Current speaker recognition: {s}; name={s}; person_id={s}; confidence={d:.2}; people_count={d}; image={s}.\n",
        .{ status, display, id, result.confidence, result.people_count, image_path },
    );
}

pub fn retainCaptureForPersonMemory(self: *Brain, capture: *events.ImageCapture) !void {
    if (!capture.temporary) return;
    const retained_path = try self.deps.store.retainCapture(self.allocator, capture.path, "activation");
    capture.path = retained_path;
    capture.temporary = false;
    self.rememberVisualUpdate(retained_path);
}
