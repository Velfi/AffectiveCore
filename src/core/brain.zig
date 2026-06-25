const std = @import("std");
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
const stimulus_mod = @import("stimulus.zig");

const brain_types = @import("brain_types.zig");
pub const BrainDeps = brain_types.BrainDeps;
pub const CommandBatchResult = brain_types.CommandBatchResult;
pub const ConversationTurnResult = brain_types.ConversationTurnResult;
pub const PsycheHabituation = brain_types.PsycheHabituation;
pub const PendingHardError = brain_types.PendingHardError;
pub const SenseStimulusState = brain_types.SenseStimulusState;
pub const speech_artifact_ttl_seconds = brain_types.speech_artifact_ttl_seconds;
pub const speech_artifact_prefix = brain_types.speech_artifact_prefix;
pub const speech_audio_suffix = brain_types.speech_audio_suffix;
pub const speech_transcription_json_suffix = brain_types.speech_transcription_json_suffix;
pub const SpeechArtifactSweepResult = brain_types.SpeechArtifactSweepResult;

const brain_command_execution = @import("brain_command_execution.zig");
const brain_dream_memory = @import("brain_dream_memory.zig");
const brain_introspection_autonomy = @import("brain_introspection_autonomy.zig");
const brain_lifecycle = @import("brain_lifecycle.zig");
const brain_logging_events = @import("brain_logging_events.zig");
const brain_person_memory = @import("brain_person_memory.zig");
const brain_psyche_memory = @import("brain_psyche_memory.zig");
const brain_recognition = @import("brain_recognition.zig");

pub const Brain = struct {
    allocator: std.mem.Allocator,
    cfg: config_mod.Config,
    deps: BrainDeps,
    now_seconds: i64,
    conversation_speaker_context: ?ConversationSpeakerContext = null,
    last_conversation_turn_seconds: ?i64 = null,
    last_visual_observation_path: ?[]const u8 = null,
    last_visual_update_seconds: ?i64 = null,
    last_visual_observation_uploaded: bool = false,
    current_stimulus_context: ?[]const u8 = null,
    current_stimulus_seconds: ?i64 = null,
    last_autonomous_facial_expression_at: ?i64 = null,
    pending_hard_error: ?PendingHardError = null,
    id_monitor_manager: id_monitor.Manager = .{},
    psyche_habituation: PsycheHabituation = .{},
    sense_stimulus_state: SenseStimulusState = .{},
    last_trace_stage: []const u8 = "init",

    pub const ConversationSpeakerContext = struct {
        capture: events.ImageCapture,
        result: identity.IdentityResult,
        memory_line: []const u8,
        chat_label: []const u8,
    };

    pub const SpeechStimulusAssignment = struct {
        speaker_context: ?ConversationSpeakerContext,
        stimulus_context: []const u8,
    };

    pub const TouchStimulusAssignment = struct {
        stimulus_context: []const u8,
        curiosity_score: u8,
        should_look: bool,
    };

    pub const SenseStimulusInput = stimulus_mod.Input;
    pub const SenseStimulusPacket = stimulus_mod.Packet;

    pub const QuietHours = struct {
        start_minute: u32,
        end_minute: u32,
    };

    pub const SelfDirectiveKind = enum {
        need,
        want,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: config_mod.Config, deps: BrainDeps) Brain {
        return brain_lifecycle.init(allocator, cfg, deps);
    }

    pub fn seedFromFile(self: *Brain, io: std.Io, path: []const u8) !void {
        return brain_lifecycle.seedFromFile(self, io, path);
    }

    pub fn seedDocument(self: *Brain, doc: seed_mod.SeedDocument) !void {
        return brain_lifecycle.seedDocument(self, doc);
    }

    pub fn handleFaceMemoryActivation(self: *Brain) !void {
        return brain_lifecycle.handleFaceMemoryActivation(self);
    }

    pub fn performFaceMemoryActivation(self: *Brain) !void {
        return brain_lifecycle.performFaceMemoryActivation(self);
    }

    pub fn handleLongTouchActivation(self: *Brain) !void {
        return brain_lifecycle.handleLongTouchActivation(self);
    }

    pub fn forgetByNameOrId(self: *Brain, name_or_id: []const u8) !bool {
        return brain_lifecycle.forgetByNameOrId(self, name_or_id);
    }

    pub fn handleConversationTurn(self: *Brain) !void {
        return brain_lifecycle.handleConversationTurn(self);
    }

    pub fn handleButtonAction(self: *Brain, action: button_mod.ButtonAction) !void {
        return brain_lifecycle.handleButtonAction(self, action);
    }

    pub fn handleTouchStimulusError(self: *Brain, err: anyerror) !bool {
        return brain_lifecycle.handleTouchStimulusError(self, err);
    }

    pub fn handleHoldActivation(self: *Brain) !void {
        return brain_lifecycle.handleHoldActivation(self);
    }

    pub fn handleConversationText(self: *Brain, heard_speech: input_mod.HeardSpeech) !ConversationTurnResult {
        return brain_lifecycle.handleConversationText(self, heard_speech);
    }

    pub fn rememberVisualUpdate(self: *Brain, path: []const u8) void {
        self.last_visual_observation_path = path;
        self.last_visual_update_seconds = self.now_seconds;
        _ = self.observeSenseStimulus(.{
            .kind = .visual,
            .source = "visual_observation",
            .signature = path,
            .raw_magnitude = 0.55,
            .threat = 0,
            .curiosity = 0.35,
            .metadata = "visual observation updated",
        }) catch |err| self.traceError("visual.stimulus.error", err);
    }

    pub fn clearCurrentStimulusContext(self: *Brain) void {
        self.current_stimulus_context = null;
        self.current_stimulus_seconds = null;
    }

    pub fn setCurrentStimulusContext(self: *Brain, text: []const u8) void {
        self.current_stimulus_context = text;
        self.current_stimulus_seconds = self.now_seconds;
    }

    pub fn observeSenseStimulus(self: *Brain, input: SenseStimulusInput) !SenseStimulusPacket {
        const packet = try self.scoreSenseStimulus(input);
        _ = try self.recordSenseStimulusPacket(packet, "");
        return packet;
    }

    pub fn scoreSenseStimulus(self: *Brain, input: SenseStimulusInput) !SenseStimulusPacket {
        return self.sense_stimulus_state.observe(self.allocator, self.now_seconds, input);
    }

    pub fn recordSenseStimulusPacket(self: *Brain, packet: SenseStimulusPacket, suffix: []const u8) ![]const u8 {
        const text = try stimulus_mod.formatPacket(self.allocator, packet);
        const final_text = if (suffix.len == 0) text else try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ text, suffix });
        self.setCurrentStimulusContext(final_text);
        try self.recordRuntimeEvent(.{
            .kind = .observation,
            .source = "sense",
            .title = "sense_stimulus",
            .body = final_text,
            .subject = @tagName(packet.kind),
            .raw = packet.signature,
            .interpretation = final_text,
            .developer_log_kind = "sense",
            .developer_log_title = "Sense stimulus",
            .developer_log_body = final_text,
            .tags = @constCast(&[_][]const u8{ "sense", "stimulus", @tagName(packet.kind) }),
        });
        return final_text;
    }

    pub fn reportRemoteThinkingFailure(self: *Brain) !void {
        return brain_lifecycle.reportRemoteThinkingFailure(self);
    }

    pub fn dryRunConversationPrompt(self: *Brain, user_text: []const u8) !chat_mod.ChatPrompt {
        return brain_lifecycle.dryRunConversationPrompt(self, user_text);
    }

    pub fn syncClock(self: *Brain, io: std.Io) void {
        return brain_lifecycle.syncClock(self, io);
    }

    pub fn runMaintenance(self: *Brain, io: std.Io) !void {
        return brain_lifecycle.runMaintenance(self, io);
    }

    pub fn runIdMonitors(self: *Brain, io: std.Io) !void {
        return brain_lifecycle.runIdMonitors(self, io);
    }

    pub fn recordPowerSourceChange(self: *Brain, previous_external_power: bool, current_external_power: bool) !void {
        return brain_lifecycle.recordPowerSourceChange(self, previous_external_power, current_external_power);
    }

    pub fn recordCriticalPowerShutdown(self: *Brain, power: system_senses_mod.PowerSnapshot, critical_percent: u8) !void {
        return brain_lifecycle.recordCriticalPowerShutdown(self, power, critical_percent);
    }

    pub fn recordSignalShutdown(self: *Brain, signal_name: []const u8) !void {
        return brain_lifecycle.recordSignalShutdown(self, signal_name);
    }

    pub fn runAutonomyTick(self: *Brain, io: std.Io) !void {
        return brain_lifecycle.runAutonomyTick(self, io);
    }

    pub fn runStimulusAutonomy(self: *Brain, io: std.Io) !void {
        return brain_lifecycle.runStimulusAutonomy(self, io);
    }

    pub fn handleKnown(self: *Brain, capture: events.ImageCapture, result: identity.IdentityResult) !void {
        return brain_recognition.handleKnown(self, capture, result);
    }

    pub fn generateSimpleGreeting(self: *Brain, intent: greeting_client.GreetingIntent) ![]const u8 {
        return brain_recognition.generateSimpleGreeting(self, intent);
    }

    pub fn handleUnknown(self: *Brain, capture: events.ImageCapture, result: identity.IdentityResult, status: []const u8) !void {
        return brain_recognition.handleUnknown(self, capture, result, status);
    }

    pub fn handleUncertain(self: *Brain, capture: events.ImageCapture, result: identity.IdentityResult) !void {
        return brain_recognition.handleUncertain(self, capture, result);
    }

    pub fn handleImmediateIntent(self: *Brain, intent: intent_mod.IntentResult) !bool {
        return brain_recognition.handleImmediateIntent(self, intent);
    }

    pub fn conversationSpeakerContext(self: *Brain) !ConversationSpeakerContext {
        return brain_recognition.conversationSpeakerContext(self);
    }

    pub fn assignSpeechStimulus(self: *Brain, heard_speech: input_mod.HeardSpeech) !SpeechStimulusAssignment {
        return brain_recognition.assignSpeechStimulus(self, heard_speech);
    }

    pub fn assignTouchStimulus(self: *Brain, touch_kind: []const u8) !TouchStimulusAssignment {
        return brain_recognition.assignTouchStimulus(self, touch_kind);
    }

    pub fn handleIdentityClaim(self: *Brain, intent: intent_mod.IntentResult, speaker_context: ConversationSpeakerContext) !bool {
        return brain_recognition.handleIdentityClaim(self, intent, speaker_context);
    }

    pub fn conversationSpeakerLine(self: *Brain, image_path: []const u8, result: identity.IdentityResult, name: ?[]const u8, status: []const u8) ![]const u8 {
        return brain_recognition.conversationSpeakerLine(self, image_path, result, name, status);
    }

    pub fn retainCaptureForPersonMemory(self: *Brain, capture: *events.ImageCapture) !void {
        return brain_recognition.retainCaptureForPersonMemory(self, capture);
    }

    pub fn recognizeForObservation(self: *Brain) ![]const u8 {
        return brain_person_memory.recognizeForObservation(self);
    }

    pub fn describeImageForObservation(self: *Brain, prompt: []const u8) ![]const u8 {
        return brain_person_memory.describeImageForObservation(self, prompt);
    }

    pub fn rememberPersonForObservation(self: *Brain, command: chat_mod.ChatCommand) ![]const u8 {
        return brain_person_memory.rememberPersonForObservation(self, command);
    }

    pub fn updateFacePictureForObservation(self: *Brain, command: chat_mod.ChatCommand) ![]const u8 {
        return brain_person_memory.updateFacePictureForObservation(self, command);
    }

    pub fn uploadedMediaObservation(self: *Brain, user_text: []const u8) !?[]const u8 {
        return brain_person_memory.uploadedMediaObservation(self, user_text);
    }

    pub fn compareImagesForObservation(self: *Brain, prompt: []const u8) ![]const u8 {
        return brain_person_memory.compareImagesForObservation(self, prompt);
    }

    pub fn createPerson(self: *Brain, name: []const u8, relationship: schema.RelationshipStatus, description: openai.VisualDescription) !schema.Person {
        return brain_person_memory.createPerson(self, name, relationship, description);
    }

    pub fn seedKnownPerson(self: *Brain, id: []const u8, name: []const u8) !schema.Person {
        return brain_person_memory.seedKnownPerson(self, id, name);
    }

    pub fn hasCreator(self: *Brain) !bool {
        return brain_person_memory.hasCreator(self);
    }

    pub fn ensureCreatorIfFirstRecognized(self: *Brain, person: schema.Person) !schema.Person {
        return brain_person_memory.ensureCreatorIfFirstRecognized(self, person);
    }

    pub fn syncPersonGraph(self: *Brain, person: schema.Person) !void {
        return brain_person_memory.syncPersonGraph(self, person);
    }

    pub fn rememberCreatorAttachment(self: *Brain, person: schema.Person) !void {
        return brain_person_memory.rememberCreatorAttachment(self, person);
    }

    pub fn addSighting(self: *Brain, person_id: ?[]const u8, seen_at: []const u8, confidence: f32, image_path: []const u8, description: ?[]const u8, change_summary: ?[]const u8) !void {
        return brain_person_memory.addSighting(self, person_id, seen_at, confidence, image_path, description, change_summary);
    }

    pub fn say(self: *Brain, text: []const u8) !void {
        return brain_person_memory.say(self, text);
    }

    pub fn setSendEnabled(self: *Brain, enabled: bool) !void {
        return brain_logging_events.setSendEnabled(self, enabled);
    }

    pub fn logUserUtterance(self: *Brain, title: []const u8, text: []const u8) !void {
        return brain_logging_events.logUserUtterance(self, title, text);
    }

    pub fn logCommandSent(self: *Brain, command: chat_mod.ChatCommand) !void {
        return brain_logging_events.logCommandSent(self, command);
    }

    pub fn logCommandResult(self: *Brain, command: chat_mod.ChatCommand, result: []const u8) !void {
        return brain_logging_events.logCommandResult(self, command, result);
    }

    pub fn logMaintenanceCommandSent(self: *Brain, command: []const u8) !void {
        return brain_logging_events.logMaintenanceCommandSent(self, command);
    }

    pub fn logMaintenanceCommandResult(self: *Brain, command: []const u8, result: []const u8) !void {
        return brain_logging_events.logMaintenanceCommandResult(self, command, result);
    }

    pub fn logState(self: *Brain, state: state_mod.BrainState) !void {
        return brain_logging_events.logState(self, state);
    }

    pub fn trace(self: *Brain, stage: []const u8) void {
        return brain_logging_events.trace(self, stage);
    }

    pub fn traceError(self: *Brain, stage: []const u8, err: anyerror) void {
        return brain_logging_events.traceError(self, stage, err);
    }

    pub fn traceText(self: *Brain, stage: []const u8, text: []const u8) void {
        return brain_logging_events.traceText(self, stage, text);
    }

    pub fn traceCount(self: *Brain, stage: []const u8, count: usize) void {
        return brain_logging_events.traceCount(self, stage, count);
    }

    pub fn traceIntent(self: *Brain, stage: []const u8, action: intent_mod.IntentAction) void {
        return brain_logging_events.traceIntent(self, stage, action);
    }

    pub fn traceTurn(self: *Brain, stage: []const u8, turn_index: usize, observation_bytes: usize) void {
        return brain_logging_events.traceTurn(self, stage, turn_index, observation_bytes);
    }

    pub fn traceTurnCommands(self: *Brain, stage: []const u8, turn_index: usize, command_count: usize, conversation_done: bool) void {
        return brain_logging_events.traceTurnCommands(self, stage, turn_index, command_count, conversation_done);
    }

    pub fn traceCommandBatch(self: *Brain, stage: []const u8, turn_index: usize, batch: CommandBatchResult, observation_bytes: usize) void {
        return brain_logging_events.traceCommandBatch(self, stage, turn_index, batch, observation_bytes);
    }

    pub fn traceCommand(self: *Brain, stage: []const u8, command_index: usize, command: chat_mod.ChatCommandType) void {
        return brain_logging_events.traceCommand(self, stage, command_index, command);
    }

    pub fn traceCommandError(self: *Brain, stage: []const u8, command_index: usize, command: chat_mod.ChatCommandType, err: anyerror) void {
        return brain_logging_events.traceCommandError(self, stage, command_index, command, err);
    }

    pub fn appendCommandLog(self: *Brain, kind: []const u8, title: []const u8, body: []const u8) !void {
        return brain_logging_events.appendCommandLog(self, kind, title, body);
    }

    pub fn recordRuntimeEvent(self: *Brain, event: schema.RuntimeEvent) anyerror!void {
        return brain_logging_events.recordRuntimeEvent(self, event);
    }

    pub fn recordIdMonitorEvent(self: *Brain, event: schema.RuntimeEvent) !void {
        return brain_logging_events.recordIdMonitorEvent(self, event);
    }

    pub fn recordIdMonitorCrashEvent(self: *Brain, monitor_id: []const u8, err: anyerror) !void {
        return brain_logging_events.recordIdMonitorCrashEvent(self, monitor_id, err);
    }

    pub fn recordMemoryCandidateEvent(
        self: *Brain,
        event_kind: schema.RuntimeEventKind,
        event_source: []const u8,
        title: []const u8,
        body: []const u8,
        experience_source: schema.ExperienceSource,
        experience_kind: schema.ExperienceKind,
        retention: schema.ExperienceRetention,
        subject: []const u8,
        raw: []const u8,
        interpretation: []const u8,
        derived_memory_ids: []const []const u8,
        tags: []const []const u8,
    ) !void {
        return brain_logging_events.recordMemoryCandidateEvent(self, event_kind, event_source, title, body, experience_source, experience_kind, retention, subject, raw, interpretation, derived_memory_ids, tags);
    }

    pub fn formatCommand(self: *Brain, command: chat_mod.ChatCommand) ![]const u8 {
        return brain_logging_events.formatCommand(self, command);
    }

    pub fn handleInterruptStimulus(self: *Brain, stimulus: interrupt_mod.Stimulus) anyerror!void {
        return brain_command_execution.handleInterruptStimulus(self, stimulus);
    }

    pub fn executeCommands(self: *Brain, commands: []chat_mod.ChatCommand, observations: *std.ArrayList(u8)) !CommandBatchResult {
        return brain_command_execution.executeCommands(self, commands, observations);
    }

    pub fn appendPendingHardErrorObservation(self: *Brain, observations: *std.ArrayList(u8)) !void {
        return brain_command_execution.appendPendingHardErrorObservation(self, observations);
    }

    pub fn handleHardCommandError(self: *Brain, err: anyerror) ![]const u8 {
        return brain_command_execution.handleHardCommandError(self, err);
    }

    pub fn executeChatCommands(self: *Brain, commands: []chat_mod.ChatCommand, observations: *std.ArrayList(u8)) !CommandBatchResult {
        return brain_command_execution.executeChatCommands(self, commands, observations);
    }

    pub fn commandIsCallable(self: *Brain, command: chat_mod.ChatCommandType) !bool {
        return brain_command_execution.commandIsCallable(self, command);
    }

    pub fn chatCommandsEndWithSpeech(commands: []const chat_mod.ChatCommand) bool {
        return brain_command_execution.chatCommandsEndWithSpeech(commands);
    }

    pub fn introspect(self: *Brain) ![]const u8 {
        return brain_introspection_autonomy.introspect(self);
    }

    pub fn memoryOneLineSummary(self: *Brain, memory: schema.MemoryRecord) ![]const u8 {
        return brain_introspection_autonomy.memoryOneLineSummary(self, memory);
    }

    pub fn appendAffordanceObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
        return brain_introspection_autonomy.appendAffordanceObservation(self, out);
    }

    pub fn affordanceCatalog(self: *Brain) ![]const u8 {
        return brain_introspection_autonomy.affordanceCatalog(self);
    }

    pub fn commandUnavailableReason(self: *Brain, command: chat_mod.ChatCommandType) !?[]const u8 {
        return brain_introspection_autonomy.commandUnavailableReason(self, command);
    }

    pub fn senseAvailable(self: *Brain, capability: chat_mod.Capability) bool {
        return brain_introspection_autonomy.senseAvailable(self, capability);
    }

    pub fn timeObservation(self: *Brain) ![]const u8 {
        return brain_introspection_autonomy.timeObservation(self);
    }

    pub fn powerObservation(self: *Brain) ![]const u8 {
        return brain_introspection_autonomy.powerObservation(self);
    }

    pub fn storageObservation(self: *Brain) ![]const u8 {
        return brain_introspection_autonomy.storageObservation(self);
    }

    pub fn databaseObservation(self: *Brain) ![]const u8 {
        return brain_introspection_autonomy.databaseObservation(self);
    }

    pub fn selfFactsSummary(self: *Brain) ![]const u8 {
        return brain_introspection_autonomy.selfFactsSummary(self);
    }

    pub fn activeNeedsSummary(self: *Brain) ![]const u8 {
        return brain_introspection_autonomy.activeNeedsSummary(self);
    }

    pub fn autonomyStateForNeeds(self: *Brain) !?maintenance.AutonomyState {
        return brain_introspection_autonomy.autonomyStateForNeeds(self);
    }

    pub fn autonomyEnabled(self: *Brain) bool {
        return brain_introspection_autonomy.autonomyEnabled(self);
    }

    pub fn defaultAutonomySleeping(self: *Brain) bool {
        return brain_introspection_autonomy.defaultAutonomySleeping(self);
    }

    pub fn autonomyPlannerCost() u32 {
        return brain_introspection_autonomy.autonomyPlannerCost();
    }

    pub fn autonomyCommandCost(command: chat_mod.ChatCommandType) !u32 {
        return brain_introspection_autonomy.autonomyCommandCost(command);
    }

    pub fn buildAutonomyContext(self: *Brain, io: std.Io, state: maintenance.AutonomyState) ![]const u8 {
        return brain_introspection_autonomy.buildAutonomyContext(self, io, state);
    }

    pub fn executeAutonomyTurn(self: *Brain, io: std.Io, state: *maintenance.AutonomyState, turn: autonomy_mod.AutonomyTurn) !void {
        return brain_introspection_autonomy.executeAutonomyTurn(self, io, state, turn);
    }

    pub fn setAutonomySleeping(self: *Brain, sleeping: bool, reason: []const u8) !void {
        return brain_introspection_autonomy.setAutonomySleeping(self, sleeping, reason);
    }

    pub fn parseQuietHours(text: []const u8) !QuietHours {
        return brain_introspection_autonomy.parseQuietHours(text);
    }

    pub fn parseClockMinute(text: []const u8) !u32 {
        return brain_introspection_autonomy.parseClockMinute(text);
    }

    pub fn localDayKey(self: *Brain, io: std.Io) ![]const u8 {
        return brain_introspection_autonomy.localDayKey(self, io);
    }

    pub fn dream(self: *Brain, optional_text: ?[]const u8, tags: []const []const u8, heat_bias: ?[]const u8) ![]const u8 {
        return brain_dream_memory.dream(self, optional_text, tags, heat_bias);
    }

    pub fn dreamImagePrompt(allocator: std.mem.Allocator, style: []const u8, connection: []const u8, optional_text: ?[]const u8) ![]const u8 {
        return brain_dream_memory.dreamImagePrompt(allocator, style, connection, optional_text);
    }

    pub fn imagineImage(self: *Brain, prompt: []const u8) ![]const u8 {
        return brain_dream_memory.imagineImage(self, prompt);
    }

    pub fn runMaintenanceCommand(self: *Brain, command: []const u8) !bool {
        return brain_dream_memory.runMaintenanceCommand(self, command);
    }

    pub fn buildConversationMemory(self: *Brain) ![]const u8 {
        return brain_dream_memory.buildConversationMemory(self);
    }

    pub fn buildConversationMemoryWithSpeaker(self: *Brain, speaker_context: ?[]const u8) ![]const u8 {
        return brain_dream_memory.buildConversationMemoryWithSpeaker(self, speaker_context);
    }

    pub fn formatConversationSummaryForMemory(allocator: std.mem.Allocator, user_summary: []const u8, brain_summary: []const u8) ![]const u8 {
        return brain_dream_memory.formatConversationSummaryForMemory(allocator, user_summary, brain_summary);
    }

    pub fn setFact(self: *Brain, key_text: []const u8, value_text: []const u8, tags: []const []const u8) ![]const u8 {
        return brain_dream_memory.setFact(self, key_text, value_text, tags);
    }

    pub fn recallFacts(self: *Brain, query_text: []const u8, tags: []const []const u8) ![]const u8 {
        return brain_dream_memory.recallFacts(self, query_text, tags);
    }

    pub fn invalidateFact(self: *Brain, fact_id_text: []const u8, key_text: []const u8) ![]const u8 {
        return brain_dream_memory.invalidateFact(self, fact_id_text, key_text);
    }

    pub fn createMemoryRecord(self: *Brain, text: []const u8, tags: []const []const u8) !schema.MemoryRecord {
        return brain_dream_memory.createMemoryRecord(self, text, tags);
    }

    pub fn seedEntryMemory(self: *Brain, doc: seed_mod.SeedDocument, entry: seed_mod.SeedEntry) !schema.MemoryRecord {
        return brain_dream_memory.seedEntryMemory(self, doc, entry);
    }

    pub fn addExperience(
        self: *Brain,
        source: schema.ExperienceSource,
        kind: schema.ExperienceKind,
        subject: []const u8,
        raw: []const u8,
        interpretation: []const u8,
        retention: schema.ExperienceRetention,
        derived_memory_ids: []const []const u8,
        tags: []const []const u8,
    ) ![]const u8 {
        return brain_dream_memory.addExperience(self, source, kind, subject, raw, interpretation, retention, derived_memory_ids, tags);
    }

    pub fn heardSpeechRaw(self: *Brain, heard_speech: input_mod.HeardSpeech) ![]const u8 {
        return brain_dream_memory.heardSpeechRaw(self, heard_speech);
    }

    pub fn appendHeardSpeechObservation(self: *Brain, observations: *std.ArrayList(u8), heard_speech: input_mod.HeardSpeech) !void {
        return brain_dream_memory.appendHeardSpeechObservation(self, observations, heard_speech);
    }

    pub fn experienceExpiry(self: *Brain, retention: schema.ExperienceRetention) !?[]const u8 {
        return brain_psyche_memory.experienceExpiry(self, retention);
    }

    pub fn sweepSpeechArtifacts(self: *Brain) !SpeechArtifactSweepResult {
        return brain_psyche_memory.sweepSpeechArtifacts(self);
    }

    pub fn createImpression(self: *Brain, source: schema.ImpressionSource, text: []const u8, tags: []const []const u8) !schema.Impression {
        return brain_psyche_memory.createImpression(self, source, text, tags);
    }

    pub fn createAppraisal(self: *Brain, query: []const u8, impression_id: ?[]const u8, tags: []const []const u8) !schema.Appraisal {
        return brain_psyche_memory.createAppraisal(self, query, impression_id, tags);
    }

    pub fn appraiseEvent(self: *Brain, text: []const u8, tags: []const []const u8) ![]const u8 {
        return brain_psyche_memory.appraiseEvent(self, text, tags);
    }

    pub fn feelAbout(self: *Brain, query: []const u8, tags: []const []const u8) ![]const u8 {
        return brain_psyche_memory.feelAbout(self, query, tags);
    }

    pub fn detectWantAchievements(self: *Brain, event_text: []const u8) !usize {
        return brain_psyche_memory.detectWantAchievements(self, event_text);
    }

    pub fn thinkAbout(self: *Brain, query: []const u8, tags: []const []const u8) ![]const u8 {
        return brain_psyche_memory.thinkAbout(self, query, tags);
    }

    pub fn defineSelf(self: *Brain, kind: SelfDirectiveKind, text: []const u8, tags: []const []const u8) ![]const u8 {
        return brain_psyche_memory.defineSelf(self, kind, text, tags);
    }

    pub fn editSelf(self: *Brain, kind: SelfDirectiveKind, memory_id: []const u8, text: []const u8, tags: []const []const u8) ![]const u8 {
        return brain_psyche_memory.editSelf(self, kind, memory_id, text, tags);
    }

    pub fn chooseAttention(self: *Brain) ![]const u8 {
        return brain_psyche_memory.chooseAttention(self);
    }

    pub fn askHuman(self: *Brain, text: []const u8) ![]const u8 {
        return brain_psyche_memory.askHuman(self, text);
    }

    pub fn consolidateMemory(self: *Brain) ![]const u8 {
        return brain_psyche_memory.consolidateMemory(self);
    }

    pub fn recallMemories(self: *Brain, query: []const u8, tags: []const []const u8) ![]const u8 {
        return brain_psyche_memory.recallMemories(self, query, tags);
    }

    pub fn sweepShortTermMemories(self: *Brain) ![]const u8 {
        return brain_psyche_memory.sweepShortTermMemories(self);
    }

    pub fn logSimple(self: *Brain, state: state_mod.BrainState, image: ?[]const u8, person_id: ?[]const u8, brain_text: ?[]const u8, update: []const u8) !void {
        return brain_psyche_memory.logSimple(self, state, image, person_id, brain_text, update);
    }
};

pub const remote_thinking_failure_message = "I'm unable to continue thinking due to a remote error.";
