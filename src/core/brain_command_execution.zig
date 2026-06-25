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
pub fn interruptPoint(self: *Brain, observations: *std.ArrayList(u8)) !?interrupt_mod.Stimulus {
    if (try serviceDueMaintenanceInterrupt(self, observations)) return null;
    const source = self.deps.interrupt_source orelse return null;
    const stimulus = (try source.poll(self.allocator)) orelse return null;
    const line = try std.fmt.allocPrint(self.allocator, "interrupt_stimulus: {s}\n", .{@tagName(stimulus.kind)});
    try observations.appendSlice(self.allocator, line);
    try self.recordRuntimeEvent(.{
        .kind = .autonomy,
        .source = "interrupt",
        .title = "interrupt_stimulus",
        .body = line,
        .subject = @tagName(stimulus.kind),
        .raw = @tagName(stimulus.kind),
        .interpretation = line,
        .developer_log_kind = "state",
        .developer_log_title = "interrupt",
        .developer_log_body = line,
        .tags = @constCast(&[_][]const u8{ "interrupt", @tagName(stimulus.kind), "audit" }),
    });
    return stimulus;
}

pub fn serviceDueMaintenanceInterrupt(self: *Brain, observations: *std.ArrayList(u8)) !bool {
    const io = self.deps.io orelse return false;
    const tasks = try maintenance.dueTasks(self.allocator, io, self.cfg.maintenance_schedule_path, self.cfg.maintenance_state_path, self.now_seconds);
    if (tasks.len == 0) return false;
    const task = tasks[0];
    const line = try std.fmt.allocPrint(self.allocator, "interrupt_reminder: {s}\n", .{task.command});
    try observations.appendSlice(self.allocator, line);
    try self.recordRuntimeEvent(.{
        .kind = .reminder,
        .source = "maintenance",
        .title = "interrupt_reminder",
        .body = line,
        .command = task.command,
        .subject = task.task_id,
        .raw = task.command,
        .interpretation = line,
        .developer_log_kind = "state",
        .developer_log_title = "interrupt",
        .developer_log_body = line,
        .tags = @constCast(&[_][]const u8{ "interrupt", "reminder", "audit" }),
    });
    if (try self.runMaintenanceCommand(task.command)) {
        try maintenance.markRun(self.allocator, io, self.cfg.maintenance_state_path, task.task_id, self.now_seconds);
        return true;
    }
    return false;
}

pub fn handleInterruptStimulus(self: *Brain, stimulus: interrupt_mod.Stimulus) anyerror!void {
    switch (stimulus.kind) {
        .face_memory => try self.handleFaceMemoryActivation(),
        .held_input => try self.handleHoldActivation(),
        .conversation => try self.handleConversationTurn(),
    }
}

pub fn executeCommands(self: *Brain, commands: []chat_mod.ChatCommand, observations: *std.ArrayList(u8)) !CommandBatchResult {
    const ActiveCommand = struct {
        index: usize,
        command: chat_mod.ChatCommandType,
    };

    self.traceCount("commands.batch.start", commands.len);
    var active_command: ?ActiveCommand = null;
    errdefer |err| {
        if (active_command) |active| {
            self.traceCommandError("commands.batch.error", active.index, active.command, err);
        } else {
            self.traceError("commands.batch.error", err);
        }
    }
    var spoken_text: ?[]const u8 = null;
    for (commands, 0..) |command, command_index| {
        active_command = .{ .index = command_index, .command = command.command };
        self.traceCommand("commands.command.start", command_index, command.command);
        try self.logCommandSent(command);
        errdefer |err| {
            self.traceCommandError("commands.command.error", command_index, command.command, err);
            recordSkillFailure(self, command, observations, err) catch {};
            rememberHardCommandError(self, command, err) catch {};
        }
        if (try self.commandUnavailableReason(command.command)) |reason| {
            const hint = skills_mod.failureHint(command.command);
            const line = if (hint.len > 0)
                try std.fmt.allocPrint(self.allocator, "skill_failed: {s}: unavailable: {s}\nresolution: {s}\n", .{ skills_mod.name(command.command), reason, hint })
            else
                try std.fmt.allocPrint(self.allocator, "skill_failed: {s}: unavailable: {s}\n", .{ skills_mod.name(command.command), reason });
            try observations.appendSlice(self.allocator, line);
            try self.logCommandResult(command, line);
            self.traceCommand("commands.command.unavailable", command_index, command.command);
            if (try interruptPoint(self, observations)) |stimulus| {
                return .{
                    .spoken_text = spoken_text,
                    .ended_with_speech = false,
                    .interrupted_by = stimulus,
                };
            }
            continue;
        }
        switch (command.command) {
            .say => {
                const text = command.text orelse "";
                std.debug.print("\nBRAIN:\n{s}\n", .{text});
                self.traceCommand("commands.say.start", command_index, command.command);
                try self.say(text);
                self.traceCommand("commands.say.done", command_index, command.command);
                try self.logCommandResult(command, text);
                spoken_text = text;
            },
            .take_picture => {
                try self.logState(.Capture);
                const capture = try self.deps.camera.capture(self.allocator);
                self.rememberVisualUpdate(capture.path);
                self.last_visual_observation_uploaded = false;
                const description = try self.deps.description_service.describePerson(self.allocator, capture.path, "");
                const line = try std.fmt.allocPrint(self.allocator, "picture: {s}\n", .{description.description});
                try observations.appendSlice(self.allocator, line);
                try self.logCommandResult(command, line);
            },
            .describe_image => {
                const line = try self.describeImageForObservation(command.query orelse command.text orelse "");
                try observations.appendSlice(self.allocator, line);
                try self.logCommandResult(command, line);
            },
            .compare_images => {
                const line = try self.compareImagesForObservation(command.query orelse command.text orelse "");
                try observations.appendSlice(self.allocator, line);
                try self.logCommandResult(command, line);
            },
            .recognize => {
                const line = try self.recognizeForObservation();
                try observations.appendSlice(self.allocator, line);
                try self.logCommandResult(command, line);
            },
            .get_time => {
                const line = try self.timeObservation();
                try observations.appendSlice(self.allocator, line);
                try self.logCommandResult(command, line);
            },
            .request_orientation => {
                const query = self.deps.orientation_query orelse return error.MissingOrientationQuery;
                try query.request(
                    "device orientation",
                    "The frontend should ask permission, sample orientation once, and send back a bounded orientation observation.",
                );
                const line = try std.fmt.allocPrint(self.allocator, "sense_requested: orientation\n", .{});
                try observations.appendSlice(self.allocator, line);
                try self.logCommandResult(command, line);
            },
            .get_power => {
                const line = try self.powerObservation();
                try observations.appendSlice(self.allocator, line);
                try self.logCommandResult(command, line);
            },
            .get_storage => {
                const line = try self.storageObservation();
                try observations.appendSlice(self.allocator, line);
                try self.logCommandResult(command, line);
            },
            .get_database_stats => {
                const line = try self.databaseObservation();
                try observations.appendSlice(self.allocator, line);
                try self.logCommandResult(command, line);
            },
            .remember_memory => {
                const text = command.text orelse "";
                if (text.len > 0) {
                    const memory = try self.createMemoryRecord(text, command.tags);
                    try self.deps.store.saveMemoryRecord(memory);
                    try self.recordRuntimeEvent(.{
                        .kind = .memory_mutation,
                        .source = "memory",
                        .title = "remember_memory",
                        .body = memory.interpretation,
                        .command = @tagName(command.command),
                        .subject = "remember_memory",
                        .raw = text,
                        .interpretation = memory.interpretation,
                        .experience_source = .memory,
                        .experience_kind = .memory_update,
                        .experience_retention = .keep_fact,
                        .derived_memory_ids = @constCast(&[_][]const u8{memory.memory_id}),
                        .created_memory_id = memory.memory_id,
                        .tags = memory.tags,
                    });
                    const line = try std.fmt.allocPrint(self.allocator, "memory_saved: {s}\n", .{memory.memory_id});
                    try observations.appendSlice(self.allocator, line);
                    try self.logCommandResult(command, line);
                } else {
                    try self.logCommandResult(command, "memory_saved: skipped empty text\n");
                }
            },
            .recall_memory => {
                const recalled = try self.recallMemories(command.query orelse "", command.tags);
                try observations.appendSlice(self.allocator, recalled);
                try self.logCommandResult(command, recalled);
            },
            .forget_memory => {
                const memory_id = command.memory_id orelse "";
                const forgotten = if (memory_id.len > 0) try self.deps.store.forgetMemoryRecord(memory_id) else false;
                try self.recordRuntimeEvent(.{
                    .kind = .memory_mutation,
                    .source = "memory",
                    .title = "forget_memory",
                    .body = if (forgotten) "memory forgotten" else "memory not found",
                    .command = @tagName(command.command),
                    .subject = "forget_memory",
                    .raw = memory_id,
                    .interpretation = if (forgotten) "Deleted the target memory." else "No memory was deleted.",
                    .forgotten_memory_id = if (memory_id.len > 0) memory_id else null,
                    .tags = @constCast(&[_][]const u8{ "memory", "forgotten", "audit" }),
                });
                const line = try std.fmt.allocPrint(self.allocator, "memory_forgotten: {s} {any}\n", .{ memory_id, forgotten });
                try observations.appendSlice(self.allocator, line);
                try self.logCommandResult(command, line);
            },
            .set_fact => {
                const updated = try self.setFact(command.name orelse "", command.text orelse command.query orelse "", command.tags);
                try observations.appendSlice(self.allocator, updated);
                try self.logCommandResult(command, updated);
            },
            .recall_fact => {
                const recalled = try self.recallFacts(command.query orelse command.name orelse "", command.tags);
                try observations.appendSlice(self.allocator, recalled);
                try self.logCommandResult(command, recalled);
            },
            .invalidate_fact => {
                const invalidated = try self.invalidateFact(command.memory_id orelse "", command.name orelse command.query orelse "");
                try observations.appendSlice(self.allocator, invalidated);
                try self.logCommandResult(command, invalidated);
            },
            .sweep_memory => {
                const swept = try self.sweepShortTermMemories();
                try observations.appendSlice(self.allocator, swept);
                try self.logCommandResult(command, swept);
            },
            .set_reminder => {
                const schedule = command.schedule orelse "";
                const text = command.text orelse "";
                if (schedule.len > 0 and text.len > 0) {
                    const io = self.deps.io orelse {
                        const line = "reminder_set: io unavailable\n";
                        try observations.appendSlice(self.allocator, line);
                        try self.logCommandResult(command, line);
                        if (try interruptPoint(self, observations)) |stimulus| {
                            return .{
                                .spoken_text = spoken_text,
                                .ended_with_speech = false,
                                .interrupted_by = stimulus,
                            };
                        }
                        continue;
                    };
                    const normalized_schedule = try maintenance.addReminder(self.allocator, io, self.cfg.maintenance_schedule_path, schedule, text, self.now_seconds);
                    const line = try std.fmt.allocPrint(self.allocator, "reminder_set: {s} -> {s}\n", .{ normalized_schedule, text });
                    try observations.appendSlice(self.allocator, line);
                    try self.logCommandResult(command, line);
                } else {
                    const line = "reminder_set: missing schedule or text\n";
                    try observations.appendSlice(self.allocator, line);
                    try self.logCommandResult(command, line);
                }
            },
            .introspect => {
                self.trace("commands.introspect.start");
                const reflection = try self.introspect();
                self.traceText("commands.introspect.done", reflection);
                try observations.appendSlice(self.allocator, reflection);
                self.traceText("commands.introspect.observation_appended", observations.items);
                try self.logCommandResult(command, reflection);
                self.trace("commands.introspect.logged");
            },
            .dream => {
                const dream_text = try self.dream(command.text, command.tags, command.heat_bias);
                try observations.appendSlice(self.allocator, dream_text);
                try self.logCommandResult(command, dream_text);
            },
            .appraise_event => {
                const appraisal = try self.appraiseEvent(command.text orelse "", command.tags);
                try observations.appendSlice(self.allocator, appraisal);
                try self.logCommandResult(command, appraisal);
            },
            .feel_about => {
                const feeling = try self.feelAbout(command.query orelse command.text orelse "", command.tags);
                try observations.appendSlice(self.allocator, feeling);
                try self.logCommandResult(command, feeling);
            },
            .think_about => {
                const thought = try self.thinkAbout(command.query orelse command.text orelse "", command.tags);
                try observations.appendSlice(self.allocator, thought);
                try self.logCommandResult(command, thought);
            },
            .define_need => {
                const defined = try self.defineSelf(.need, command.text orelse command.query orelse "", command.tags);
                try observations.appendSlice(self.allocator, defined);
                try self.logCommandResult(command, defined);
            },
            .define_want => {
                const defined = try self.defineSelf(.want, command.text orelse command.query orelse "", command.tags);
                try observations.appendSlice(self.allocator, defined);
                try self.logCommandResult(command, defined);
            },
            .edit_need => {
                const edited = try self.editSelf(.need, command.memory_id orelse "", command.text orelse command.query orelse "", command.tags);
                try observations.appendSlice(self.allocator, edited);
                try self.logCommandResult(command, edited);
            },
            .edit_want => {
                const edited = try self.editSelf(.want, command.memory_id orelse "", command.text orelse command.query orelse "", command.tags);
                try observations.appendSlice(self.allocator, edited);
                try self.logCommandResult(command, edited);
            },
            .imagine_image => {
                const imagined = try self.imagineImage(command.text orelse command.query orelse "");
                try observations.appendSlice(self.allocator, imagined);
                try self.logCommandResult(command, imagined);
            },
            .remember_person => {
                const remembered = try self.rememberPersonForObservation(command);
                try observations.appendSlice(self.allocator, remembered);
                try self.logCommandResult(command, remembered);
            },
            .update_face_picture => {
                const updated = try self.updateFacePictureForObservation(command);
                try observations.appendSlice(self.allocator, updated);
                try self.logCommandResult(command, updated);
            },
            .send_email => {
                const email = self.deps.email_service orelse return error.MissingEmailService;
                const sent = try email.send(self.allocator, .{
                    .to = command.to orelse return error.MissingEmailRecipient,
                    .subject = command.subject orelse return error.MissingEmailSubject,
                    .body = command.text orelse return error.MissingEmailBody,
                });
                try observations.appendSlice(self.allocator, sent);
                try self.logCommandResult(command, sent);
            },
            .choose_attention => {
                const attention = try self.chooseAttention();
                try observations.appendSlice(self.allocator, attention);
                try self.logCommandResult(command, attention);
            },
            .ask_human => {
                const help = try self.askHuman(command.text orelse "");
                try observations.appendSlice(self.allocator, help);
                try self.logCommandResult(command, help);
                spoken_text = command.text orelse "";
            },
            .consolidate_memory => {
                const consolidated = try self.consolidateMemory();
                try observations.appendSlice(self.allocator, consolidated);
                try self.logCommandResult(command, consolidated);
            },
            .facial_expression => {
                const shown = try showFacialExpression(self, command);
                try observations.appendSlice(self.allocator, shown);
                try self.logCommandResult(command, shown);
            },
            .unknown => {
                const line = try std.fmt.allocPrint(self.allocator, "unknown_command: ignored\n", .{});
                try observations.appendSlice(self.allocator, line);
                try self.logCommandResult(command, line);
            },
        }
        self.traceCommand("commands.command.done", command_index, command.command);
        active_command = null;
        if (try interruptPoint(self, observations)) |stimulus| {
            return .{
                .spoken_text = spoken_text,
                .ended_with_speech = false,
                .interrupted_by = stimulus,
            };
        }
    }
    self.trace("commands.batch.done");
    return .{ .spoken_text = spoken_text, .ended_with_speech = Brain.chatCommandsEndWithSpeech(commands) };
}

pub fn showFacialExpression(self: *Brain, command: chat_mod.ChatCommand) ![]const u8 {
    const output = self.deps.facial_expression_output orelse return error.MissingFacialExpressionOutput;
    const eyes = command.eyes orelse return error.MissingFacialExpressionEyes;
    const mouth = command.mouth orelse return error.MissingFacialExpressionMouth;
    const duration_ms = try facial_expression.normalizeDuration(command.duration_ms);
    try output.show(.{ .eyes = eyes, .mouth = mouth, .duration_ms = duration_ms });
    return std.fmt.allocPrint(
        self.allocator,
        "facial_expression_shown: eyes={s} mouth={s} duration_ms={d}\n",
        .{ eyes, mouth, duration_ms },
    );
}

pub fn recordSkillFailure(self: *Brain, command: chat_mod.ChatCommand, observations: *std.ArrayList(u8), err: anyerror) !void {
    const hint = skills_mod.failureHint(command.command);
    const line = if (hint.len > 0)
        try std.fmt.allocPrint(self.allocator, "skill_failed: {s}: {s}\nresolution: {s}\n", .{ skills_mod.name(command.command), @errorName(err), hint })
    else
        try std.fmt.allocPrint(self.allocator, "skill_failed: {s}: {s}\n", .{ skills_mod.name(command.command), @errorName(err) });
    try observations.appendSlice(self.allocator, line);
    try self.logCommandResult(command, line);
}

pub fn rememberHardCommandError(self: *Brain, command: chat_mod.ChatCommand, err: anyerror) !void {
    self.pending_hard_error = .{
        .command = try self.formatCommand(command),
        .error_name = try self.allocator.dupe(u8, @errorName(err)),
        .recovery_hint = try self.allocator.dupe(u8, skills_mod.failureHint(command.command)),
    };
}

pub fn appendPendingHardErrorObservation(self: *Brain, observations: *std.ArrayList(u8)) !void {
    const pending = self.pending_hard_error orelse return;
    const hint_line = if (pending.recovery_hint.len > 0)
        try std.fmt.allocPrint(self.allocator, "- resolution: {s}\n", .{pending.recovery_hint})
    else
        "";
    const line = try std.fmt.allocPrint(
        self.allocator,
        "pending_hard_error:\n- error: {s}\n- failed_command:\n{s}{s}- recovery_context: Treat this as a surprising, concerning event. The user may say to try again, change course, or nevermind; follow that direction using the normal available skills.\n",
        .{ pending.error_name, pending.command, hint_line },
    );
    try observations.appendSlice(self.allocator, line);
}

pub fn handleHardCommandError(self: *Brain, err: anyerror) ![]const u8 {
    const text = try std.fmt.allocPrint(
        self.allocator,
        "Something went wrong while I tried that: {s}. That is a hard error, and I do not want to pretend it worked. Tell me if I should try again, change course, or drop it.",
        .{@errorName(err)},
    );
    std.debug.print("\nBRAIN:\n{s}\n", .{text});
    try self.say(text);
    try self.appendCommandLog("error", "Hard error needs recovery", text);
    return text;
}

pub fn executeChatCommands(self: *Brain, commands: []chat_mod.ChatCommand, observations: *std.ArrayList(u8)) !CommandBatchResult {
    return executeCommands(self, commands, observations);
}

pub fn commandIsCallable(self: *Brain, command: chat_mod.ChatCommandType) !bool {
    return (try self.commandUnavailableReason(command)) == null;
}

pub fn chatCommandsEndWithSpeech(commands: []const chat_mod.ChatCommand) bool {
    if (commands.len == 0) return false;
    return commands[commands.len - 1].command == .say or commands[commands.len - 1].command == .ask_human;
}
