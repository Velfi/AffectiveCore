const std = @import("std");
const brain_mod = @import("brain.zig");
const events = @import("events.zig");
const identity = @import("identity.zig");
const ports = @import("ports.zig");
const input_mod = ports.input;

const Brain = brain_mod.Brain;

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
    const recorded = try self.recordSenseStimulusPacket(packet, suffix);
    return .{
        .stimulus_context = recorded.text,
        .curiosity_score = curiosity_score,
        .should_look = should_look,
        .packet = packet,
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

pub fn conversationSpeakerLine(self: *Brain, image_path: []const u8, result: identity.IdentityResult, name: ?[]const u8, status: []const u8) ![]const u8 {
    const display = name orelse result.candidate_name orelse "unknown";
    const id = result.person_id orelse "none";
    const interpretation = recognitionInterpretation(result);
    return std.fmt.allocPrint(
        self.allocator,
        "Current speaker recognition: {s}; name={s}; person_id={s}; confidence={d:.2}; people_count={d}; image={s}; interpretation={s}.\n",
        .{ status, display, id, result.confidence, result.people_count, image_path, interpretation },
    );
}

fn recognitionInterpretation(result: identity.IdentityResult) []const u8 {
    if (result.people_count == 0 or !result.person_present) {
        return "no_face_in_frame";
    }
    return switch (result.match_status) {
        .unknown, .none => "face_unmatched",
        .uncertain => "face_match_uncertain",
        .multiple => "multiple_faces_in_frame",
        .known => "face_known",
    };
}

pub fn retainCaptureForPersonMemory(self: *Brain, capture: *events.ImageCapture) !void {
    if (!capture.temporary) return;
    const retained_path = try self.deps.store.retainCapture(self.allocator, capture.path, "activation");
    capture.path = retained_path;
    capture.temporary = false;
    self.rememberVisualUpdate(retained_path);
}
