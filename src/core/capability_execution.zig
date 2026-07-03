const std = @import("std");
const brain_mod = @import("brain.zig");
const ports = @import("ports.zig");
const chat_mod = ports.chat;
const maintenance = @import("maintenance.zig");
const facial_expression = ports.facial_expression;
const emote_mod = ports.emote;
const display_budget_mod = @import("display_budget.zig");
const interrupt_mod = @import("interrupt.zig");
const helpers = @import("brain_helpers.zig");
const brain_activity = @import("brain_activity.zig");
const mise_en_scene = @import("mise_en_scene.zig");
const awaited_host_request = @import("awaited_host_request.zig");

const Brain = brain_mod.Brain;

pub const CapabilityActionFlow = union(enum) {
    ok,
    next_action,
    interrupt: interrupt_mod.Stimulus,
};

pub fn executeCapabilityAction(
    self: *Brain,
    proposal: chat_mod.ActionProposal,
    proposal_index: usize,
    observations: *std.ArrayList(u8),
    spoken_text: *?[]const u8,
    check_interrupt: *const fn (*Brain, *std.ArrayList(u8)) anyerror!?interrupt_mod.Stimulus,
) !CapabilityActionFlow {
    switch (proposal.action) {
        .say => {
            const text = proposal.text orelse "";
            self.outputBrain(text);
            self.traceActionPressure("capability_execution.say.start", proposal_index, proposal.action);
            try self.say(text);
            self.traceActionPressure("capability_execution.say.done", proposal_index, proposal.action);
            try self.logCapabilityResult(proposal, text);
            spoken_text.* = text;
        },
        .take_picture => {
            try self.logState(.Capture);
            if (self.deps.camera.capture(self.allocator)) |capture| {
                self.rememberVisualUpdate(capture.path);
                self.last_visual_observation_uploaded = false;
                const description = try self.deps.description_service.describePerson(self.allocator, capture.path, "");
                const line = try std.fmt.allocPrint(self.allocator, "picture: {s}\n", .{description.description});
                try observations.appendSlice(self.allocator, line);
                try self.logCapabilityResult(proposal, line);
            } else |err| switch (err) {
                error.FrontendCaptureRequested => {
                    const line = try awaited_host_request.pullRequestedObservation(self, "camera", "take_picture");
                    try observations.appendSlice(self.allocator, line);
                    try self.logCapabilityResult(proposal, line);
                },
                else => return err,
            }
        },
        .describe_image => {
            const line = try self.describeImageForObservation(proposal.query orelse proposal.text orelse "");
            try observations.appendSlice(self.allocator, line);
            try self.logCapabilityResult(proposal, line);
        },
        .compare_images => {
            const line = try self.compareImagesForObservation(proposal.query orelse proposal.text orelse "");
            try observations.appendSlice(self.allocator, line);
            try self.logCapabilityResult(proposal, line);
        },
        .recognize => {
            const line = if (self.awaitedHostRequestMatches("camera", "recognize"))
                try self.allocator.dupe(u8, "recognition_in_flight:\n- identify_skipped: true\n- note: recognize already awaiting host delivery.\n")
            else if (self.recognitionAlreadyInObservations(observations.items))
                try self.recognitionRecentObservationNote(observations.items)
            else
                try self.recognizeForObservation();
            try observations.appendSlice(self.allocator, line);
            try self.logCapabilityResult(proposal, line);
        },
        .get_time => {
            const line = try self.timeObservation();
            try observations.appendSlice(self.allocator, line);
            try self.logCapabilityResult(proposal, line);
        },
        .request_orientation => {
            const query = self.deps.orientation_query orelse return error.MissingOrientationQuery;
            if (query.request(
                "device orientation",
                "The frontend should ask permission, sample orientation once, and send back a bounded orientation observation.",
            )) {
                const line = try std.fmt.allocPrint(self.allocator, "sense_request: orientation\n", .{});
                try observations.appendSlice(self.allocator, line);
                try self.logCapabilityResult(proposal, line);
            } else |err| switch (err) {
                error.FrontendOrientationRequested => {
                    const line = try awaited_host_request.pullRequestedObservation(self, "orientation", "sample");
                    try observations.appendSlice(self.allocator, line);
                    try self.logCapabilityResult(proposal, line);
                },
                else => return err,
            }
        },
        .get_power => {
            const line = try self.powerObservation();
            try observations.appendSlice(self.allocator, line);
            try self.logCapabilityResult(proposal, line);
        },
        .get_storage => {
            const line = try self.storageObservation();
            try observations.appendSlice(self.allocator, line);
            try self.logCapabilityResult(proposal, line);
        },
        .get_database_stats => {
            const line = try self.databaseObservation();
            try observations.appendSlice(self.allocator, line);
            try self.logCapabilityResult(proposal, line);
        },
        .forget_memory => {
            const memory_id = proposal.memory_id orelse "";
            const forgotten = if (memory_id.len > 0) try self.deps.store.forgetMemoryRecord(memory_id) else false;
            _ = try self.recordExperienceLogEvent(.{
                .kind = .memory_mutation,
                .source = "memory",
                .title = "forget_memory",
                .body = if (forgotten) "memory forgotten" else "memory not found",
                .action = @tagName(proposal.action),
                .subject = "forget_memory",
                .raw = memory_id,
                .interpretation = if (forgotten) "Deleted the target memory." else "No memory was deleted.",
                .forgotten_memory_id = if (memory_id.len > 0) memory_id else null,
                .tags = @constCast(&[_][]const u8{ "memory", "forgotten", "audit" }),
            });
            const line = try std.fmt.allocPrint(self.allocator, "memory_forgotten: {s} {any}\n", .{ memory_id, forgotten });
            try observations.appendSlice(self.allocator, line);
            try self.logCapabilityResult(proposal, line);
        },
        .forget_person => {
            const forgotten = try self.forgetPersonForObservation(proposal);
            try observations.appendSlice(self.allocator, forgotten);
            try self.logCapabilityResult(proposal, forgotten);
        },
        .set_fact => {
            const key = proposal.name orelse "";
            const updated = try self.setFact(key, proposal.text orelse proposal.query orelse "", proposal.tags);
            try mise_en_scene.refreshAfterPresentationFactChange(self, key);
            try observations.appendSlice(self.allocator, updated);
            try self.logCapabilityResult(proposal, updated);
        },
        .recall_fact => {
            const recalled = try self.recallFacts(proposal.query orelse proposal.name orelse "", proposal.tags);
            try observations.appendSlice(self.allocator, recalled);
            try self.logCapabilityResult(proposal, recalled);
        },
        .invalidate_fact => {
            const invalidated = try self.invalidateFact(proposal.memory_id orelse "", proposal.name orelse proposal.query orelse "");
            try observations.appendSlice(self.allocator, invalidated);
            try self.logCapabilityResult(proposal, invalidated);
        },
        .sweep_memory => {
            const swept = try self.sweepShortTermMemories();
            try observations.appendSlice(self.allocator, swept);
            try self.logCapabilityResult(proposal, swept);
        },
        .schedule_reminder => {
            const schedule = proposal.schedule orelse "";
            const text = proposal.text orelse "";
            if (schedule.len > 0 and text.len > 0) {
                const io = self.deps.io orelse {
                    const line = "reminder_set: io unavailable\n";
                    try observations.appendSlice(self.allocator, line);
                    try self.logCapabilityResult(proposal, line);
                    if (try check_interrupt(self, observations)) |stimulus| return .{ .interrupt = stimulus };
                    return .next_action;
                };
                const fs = self.deps.filesystem orelse return error.MissingFileSystem;
                const normalized_schedule = try maintenance.addReminder(self.allocator, fs, io, self.cfg.maintenance_schedule_path, schedule, text, self.now_seconds);
                const line = try std.fmt.allocPrint(self.allocator, "reminder_set: {s} -> {s}\n", .{ normalized_schedule, text });
                try observations.appendSlice(self.allocator, line);
                try self.logCapabilityResult(proposal, line);
                try self.setWaitingFor(.timer, text);
            } else {
                const line = "reminder_set: missing schedule or text\n";
                try observations.appendSlice(self.allocator, line);
                try self.logCapabilityResult(proposal, line);
            }
        },
        .introspect => {
            self.trace("capability_execution.introspect.start");
            const reflection = try self.introspect(proposal.query orelse proposal.text);
            self.traceText("capability_execution.introspect.done", reflection);
            try observations.appendSlice(self.allocator, reflection);
            self.traceText("capability_execution.introspect.observation_appended", observations.items);
            try self.logCapabilityResult(proposal, reflection);
            self.trace("capability_execution.introspect.logged");
        },
        .appraise_event => {
            const appraisal = try self.appraiseEvent(proposal.text orelse "", proposal.tags);
            try observations.appendSlice(self.allocator, appraisal);
            try self.logCapabilityResult(proposal, appraisal);
        },
        .feel_about => {
            const feeling = try self.feelAbout(proposal.query orelse proposal.text orelse "", proposal.tags);
            try observations.appendSlice(self.allocator, feeling);
            try self.logCapabilityResult(proposal, feeling);
        },
        .think_about => {
            const thought = try self.thinkAbout(proposal.query orelse proposal.text orelse "", proposal.tags);
            try observations.appendSlice(self.allocator, thought);
            try self.logCapabilityResult(proposal, thought);
        },
        .define_need => {
            const defined = try self.defineSelf(.need, proposal.text orelse proposal.query orelse "", proposal.tags);
            try observations.appendSlice(self.allocator, defined);
            try self.logCapabilityResult(proposal, defined);
        },
        .define_want => {
            const defined = try self.defineSelf(.want, proposal.text orelse proposal.query orelse "", proposal.tags);
            try observations.appendSlice(self.allocator, defined);
            try self.logCapabilityResult(proposal, defined);
        },
        .define_goal => {
            const defined = try self.defineSelf(.goal, proposal.text orelse proposal.query orelse "", proposal.tags);
            try observations.appendSlice(self.allocator, defined);
            try self.logCapabilityResult(proposal, defined);
        },
        .edit_need => {
            const edited = try self.editSelf(.need, proposal.memory_id orelse "", proposal.text orelse proposal.query orelse "", proposal.tags);
            try observations.appendSlice(self.allocator, edited);
            try self.logCapabilityResult(proposal, edited);
        },
        .edit_want => {
            const edited = try self.editSelf(.want, proposal.memory_id orelse "", proposal.text orelse proposal.query orelse "", proposal.tags);
            try observations.appendSlice(self.allocator, edited);
            try self.logCapabilityResult(proposal, edited);
        },
        .edit_goal => {
            const edited = try self.editSelf(.goal, proposal.memory_id orelse "", proposal.text orelse proposal.query orelse "", proposal.tags);
            try observations.appendSlice(self.allocator, edited);
            try self.logCapabilityResult(proposal, edited);
        },
        .imagine_image => {
            const imagined = try self.imagineImage(proposal.text orelse proposal.query orelse "");
            try observations.appendSlice(self.allocator, imagined);
            try self.logCapabilityResult(proposal, imagined);
        },
        .remember_person => {
            const remembered = try self.rememberPersonForObservation(proposal);
            try observations.appendSlice(self.allocator, remembered);
            try self.logCapabilityResult(proposal, remembered);
        },
        .update_face_picture => {
            const updated = try self.updateFacePictureForObservation(proposal);
            try observations.appendSlice(self.allocator, updated);
            try self.logCapabilityResult(proposal, updated);
        },
        .send_email => {
            const email = self.deps.email_service orelse return error.MissingEmailService;
            const sent = try email.send(self.allocator, .{
                .to = proposal.to orelse return error.MissingEmailRecipient,
                .subject = proposal.subject orelse return error.MissingEmailSubject,
                .body = proposal.text orelse return error.MissingEmailBody,
            });
            try observations.appendSlice(self.allocator, sent);
            try self.logCapabilityResult(proposal, sent);
        },
        .choose_attention => {
            const attention = try self.chooseAttention();
            try observations.appendSlice(self.allocator, attention);
            try self.logCapabilityResult(proposal, attention);
        },
        .set_focus => {
            const focus = try self.setFocus(proposal.text orelse "");
            try observations.appendSlice(self.allocator, focus);
            try self.logCapabilityResult(proposal, focus);
        },
        .clear_focus => {
            const cleared = try self.clearFocus();
            try observations.appendSlice(self.allocator, cleared);
            try self.logCapabilityResult(proposal, cleared);
        },
        .begin_subtask => {
            const line = try brain_activity.beginSubtask(self, proposal.text orelse "");
            defer self.allocator.free(line);
            try observations.appendSlice(self.allocator, line);
            try self.logCapabilityResult(proposal, line);
        },
        .resume_parent => {
            const line = try brain_activity.resumeParentTask(self);
            defer self.allocator.free(line);
            try observations.appendSlice(self.allocator, line);
            try self.logCapabilityResult(proposal, line);
        },
        .consolidate_memory => {
            const text = try self.consolidateMemory();
            defer self.allocator.free(text);
            try observations.appendSlice(self.allocator, text);
            try self.logCapabilityResult(proposal, text);
        },
        .sleep_autonomy => {
            const reason = proposal.text orelse "user requested sleep";
            if (try self.sleepDeclineRemainingSeconds()) |remaining| {
                const line = try std.fmt.allocPrint(self.allocator, "autonomy_sleep_declined: a salient stimulus woke me recently; sleep available again in {d}s\n", .{remaining});
                try observations.appendSlice(self.allocator, line);
                try self.logCapabilityResult(proposal, line);
            } else {
                try self.setAutonomySleeping(true, reason);
                const line = try std.fmt.allocPrint(self.allocator, "autonomy_sleeping: true reason={s}\n", .{reason});
                try observations.appendSlice(self.allocator, line);
                try self.logCapabilityResult(proposal, line);
            }
        },
        .wake_autonomy => {
            const reason = proposal.text orelse "user requested wake";
            try self.setAutonomySleeping(false, reason);
            const line = try std.fmt.allocPrint(self.allocator, "autonomy_sleeping: false reason={s}\n", .{reason});
            try observations.appendSlice(self.allocator, line);
            try self.logCapabilityResult(proposal, line);
        },
        .facial_expression => {
            const shown = try showFacialExpression(self, proposal);
            try observations.appendSlice(self.allocator, shown);
            try self.logCapabilityResult(proposal, shown);
        },
        .emote => {
            const shown = try showEmote(self, proposal);
            try observations.appendSlice(self.allocator, shown);
            try self.logCapabilityResult(proposal, shown);
        },
        .unknown => {
            const line = try std.fmt.allocPrint(self.allocator, "unknown_action: ignored\n", .{});
            try observations.appendSlice(self.allocator, line);
            try self.logCapabilityResult(proposal, line);
        },
    }
    return .ok;
}

pub fn proposalIncompleteReason(proposal: chat_mod.ActionProposal) ?[]const u8 {
    return switch (proposal.action) {
        .facial_expression => facialExpressionIncompleteReason(proposal),
        .emote => emoteIncompleteReason(proposal),
        .set_focus => if (std.mem.trim(u8, proposal.text orelse "", " \r\n\t").len == 0) "missing focus text" else null,
        .set_fact => setFactIncompleteReason(proposal),
        else => null,
    };
}

pub fn proposalIncompleteReasonForBrain(self: *Brain, proposal: chat_mod.ActionProposal) ?[]const u8 {
    if (proposalIncompleteReason(proposal)) |reason| return reason;
    return switch (proposal.action) {
        .facial_expression => facialExpressionCatalogIncompleteReason(self, proposal),
        else => null,
    };
}

fn setFactIncompleteReason(proposal: chat_mod.ActionProposal) ?[]const u8 {
    const key = std.mem.trim(u8, proposal.name orelse "", " \r\n\t");
    const value = std.mem.trim(u8, proposal.text orelse proposal.query orelse "", " \r\n\t");
    if (key.len == 0) return "missing fact key (name)";
    if (value.len == 0) return "missing fact value (text)";
    return null;
}

fn emoteIncompleteReason(proposal: chat_mod.ActionProposal) ?[]const u8 {
    if (proposal.duration_ms) |duration| {
        if (duration > emote_mod.max_duration_ms) return "duration_ms exceeds maximum";
    }
    const text = proposal.text orelse "";
    if (std.mem.trim(u8, text, " \r\n\t").len == 0) return "missing emote text";
    return null;
}

fn facialExpressionIncompleteReason(proposal: chat_mod.ActionProposal) ?[]const u8 {
    if (proposal.duration_ms) |duration| {
        if (duration > facial_expression.max_duration_ms) return "duration_ms exceeds maximum";
    }
    const eyes_present = std.mem.trim(u8, proposal.eyes orelse "", " \r\n\t").len > 0;
    const mouth_present = std.mem.trim(u8, proposal.mouth orelse "", " \r\n\t").len > 0;
    if (eyes_present or mouth_present) return null;
    if (proposal.text != null and std.mem.trim(u8, proposal.text.?, " \r\n\t").len > 0) return null;
    return "missing eyes and mouth sprite names";
}

fn facialExpressionCatalogIncompleteReason(self: *Brain, proposal: chat_mod.ActionProposal) ?[]const u8 {
    const catalog = self.facialExpressionCatalogView() orelse return "missing facial expression catalog";
    return facial_expression.proposalCatalogIncompleteReason(
        proposal.eyes,
        proposal.mouth,
        proposal.text,
        proposal.duration_ms,
        catalog,
    );
}

pub fn showFacialExpression(self: *Brain, proposal: chat_mod.ActionProposal) ![]const u8 {
    const output = self.deps.facial_expression_output orelse return error.MissingFacialExpressionOutput;
    const expression = try resolveFacialExpression(self, proposal);
    try self.validateFacialExpression(expression);
    try display_budget_mod.tryConsume(&self.display_budget, self.now_seconds, expression.duration_ms);
    try output.show(expression);
    return std.fmt.allocPrint(
        self.allocator,
        "facial_expression_shown: eyes={s} mouth={s} duration_ms={d}\n",
        .{ expression.eyes, expression.mouth, expression.duration_ms },
    );
}

pub fn showEmote(self: *Brain, proposal: chat_mod.ActionProposal) ![]const u8 {
    const output = self.deps.emote_output orelse return error.MissingEmoteOutput;
    const raw = proposal.text orelse return error.MissingEmoteText;
    const text = try emote_mod.normalizeText(self.allocator, raw);
    defer self.allocator.free(text);
    const duration_ms = try emote_mod.normalizeDuration(proposal.duration_ms);
    try display_budget_mod.tryConsume(&self.display_budget, self.now_seconds, duration_ms);
    const display_text = try std.fmt.allocPrint(self.allocator, "*{s}*", .{text});
    defer self.allocator.free(display_text);
    try output.show(.{ .text = text, .display_text = display_text, .duration_ms = duration_ms });
    return std.fmt.allocPrint(
        self.allocator,
        "emote_shown: text={s} duration_ms={d}\n",
        .{ text, duration_ms },
    );
}

fn resolveFacialExpression(self: *Brain, proposal: chat_mod.ActionProposal) !facial_expression.Expression {
    const catalog = self.facialExpressionCatalogView() orelse return error.MissingFacialExpressionCatalog;
    const resolved = try facial_expression.resolveFromProposal(
        proposal.eyes,
        proposal.mouth,
        proposal.text,
        proposal.duration_ms,
        catalog,
    );
    return .{
        .eyes = resolved.eyes,
        .mouth = resolved.mouth,
        .duration_ms = resolved.duration_ms,
    };
}

test "set_fact incomplete proposals are rejected before execution" {
    try std.testing.expectEqualStrings(
        "missing fact key (name)",
        proposalIncompleteReason(.{ .action = .set_fact, .text = "value" }).?,
    );
    try std.testing.expectEqualStrings(
        "missing fact value (text)",
        proposalIncompleteReason(.{ .action = .set_fact, .name = "speech_output_issue" }).?,
    );
    try std.testing.expect(proposalIncompleteReason(.{
        .action = .set_fact,
        .name = "speech_output_issue",
        .text = "user cannot hear speech",
    }) == null);
}
