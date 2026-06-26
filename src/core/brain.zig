const std = @import("std");
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
const intent_mod = ports.intent;
const openai = ports.openai;
const greeting_client = ports.greeting;
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
const command_log_mod = ports.command_log;
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
const stimulus_mod = @import("stimulus.zig");

const brain_types = @import("brain_types.zig");
pub const BrainDeps = brain_types.BrainDeps;
pub const CommandBatchResult = brain_types.CommandBatchResult;
pub const ConversationTurnResult = brain_types.ConversationTurnResult;
pub const HeardSpeech = input_mod.HeardSpeech;
pub const PsycheHabituation = brain_types.PsycheHabituation;
pub const PendingHardError = brain_types.PendingHardError;
pub const SenseStimulusState = brain_types.SenseStimulusState;
pub const speech_artifact_ttl_seconds = brain_types.speech_artifact_ttl_seconds;
pub const speech_artifact_prefix = brain_types.speech_artifact_prefix;
pub const speech_audio_suffix = brain_types.speech_audio_suffix;
pub const speech_transcription_json_suffix = brain_types.speech_transcription_json_suffix;
pub const SpeechArtifactSweepResult = brain_types.SpeechArtifactSweepResult;

const brain_command_execution = @import("brain_command_execution.zig");
const brain_autonomy = @import("brain_autonomy.zig");
const brain_dream_memory = @import("brain_dream_memory.zig");
const brain_introspection_autonomy = @import("brain_introspection_autonomy.zig");
const brain_lifecycle = @import("brain_lifecycle.zig");
const brain_logging_events = @import("brain_logging_events.zig");
const brain_person_memory = @import("brain_person_memory.zig");
const brain_psyche_memory = @import("brain_psyche_memory.zig");
const brain_recognition = @import("brain_recognition.zig");

pub const Brain = struct {
    /// Why a frontend camera pull was requested, so the awaited camera
    /// observation can complete the originating skill rather than just
    /// recording a generic visual stimulus.
    pub const CameraIntent = enum {
        none,
        recognize,
    };

    /// Whether the held focus was set deliberately by the bot (a short plan it
    /// chose) or derived automatically from the strongest current attention.
    pub const FocusSource = enum { derived, self_set };

    /// The bot's short-term working memory: what it is attending to / planning
    /// right now. Ephemeral — its attention decays with age (see
    /// currentFocusAttention) and clears past the TTL.
    pub const Focus = struct {
        text: []const u8,
        source: FocusSource,
        set_at: i64,
        base_attention: f32,
    };

    pub const FocusMode = enum { focused, unfocused };

    allocator: std.mem.Allocator,
    cfg: config_mod.Config,
    deps: BrainDeps,
    now_seconds: i64,
    conversation_speaker_context: ?ConversationSpeakerContext = null,
    last_conversation_turn_seconds: ?i64 = null,
    last_visual_observation_path: ?[]const u8 = null,
    last_visual_update_seconds: ?i64 = null,
    last_visual_observation_uploaded: bool = false,
    pending_camera_intent: CameraIntent = .none,
    current_stimulus_context: ?[]const u8 = null,
    current_stimulus_seconds: ?i64 = null,
    current_focus: ?Focus = null,
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

    pub const init = brain_lifecycle.init;

    pub const seedFromFile = brain_lifecycle.seedFromFile;

    pub const seedDocument = brain_lifecycle.seedDocument;

    pub const handleFaceMemoryActivation = brain_lifecycle.handleFaceMemoryActivation;

    pub const performFaceMemoryActivation = brain_lifecycle.performFaceMemoryActivation;

    pub const handleLongTouchActivation = brain_lifecycle.handleLongTouchActivation;

    pub const forgetByNameOrId = brain_lifecycle.forgetByNameOrId;

    pub const handleConversationTurn = brain_lifecycle.handleConversationTurn;

    pub const handleButtonAction = brain_lifecycle.handleButtonAction;

    pub const handleTouchStimulusError = brain_lifecycle.handleTouchStimulusError;

    pub const handleHoldActivation = brain_lifecycle.handleHoldActivation;

    pub const handleConversationText = brain_lifecycle.handleConversationText;

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
        const packet = try self.sense_stimulus_state.observe(self.allocator, self.now_seconds, input);
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

    pub const reportRemoteThinkingFailure = brain_lifecycle.reportRemoteThinkingFailure;

    pub const dryRunConversationPrompt = brain_lifecycle.dryRunConversationPrompt;

    pub const syncClock = brain_lifecycle.syncClock;

    pub fn timestampNow(self: *Brain) ![]u8 {
        return time_mod.timestampFromSeconds(self.allocator, self.now_seconds);
    }

    pub const output = brain_lifecycle.output;

    pub const outputFmt = brain_logging_events.outputFmt;

    pub const outputBrain = brain_logging_events.outputBrain;

    pub const outputImageCapture = brain_logging_events.outputImageCapture;

    pub const outputRecognitionResult = brain_logging_events.outputRecognitionResult;

    pub const runMaintenance = brain_lifecycle.runMaintenance;

    pub const runIdMonitors = brain_lifecycle.runIdMonitors;

    pub const recordPowerSourceChange = brain_lifecycle.recordPowerSourceChange;

    pub const recordCriticalPowerShutdown = brain_lifecycle.recordCriticalPowerShutdown;

    pub const recordSignalShutdown = brain_lifecycle.recordSignalShutdown;

    pub const runAutonomyTick = brain_lifecycle.runAutonomyTick;

    pub const runStimulusAutonomy = brain_lifecycle.runStimulusAutonomy;

    pub const handleKnown = brain_recognition.handleKnown;

    pub const generateSimpleGreeting = brain_recognition.generateSimpleGreeting;

    pub const handleUnknown = brain_recognition.handleUnknown;

    pub const handleUncertain = brain_recognition.handleUncertain;

    pub const handleImmediateIntent = brain_recognition.handleImmediateIntent;

    pub const conversationSpeakerContext = brain_recognition.conversationSpeakerContext;

    pub const assignSpeechStimulus = brain_recognition.assignSpeechStimulus;

    pub const assignTouchStimulus = brain_recognition.assignTouchStimulus;

    pub const handleIdentityClaim = brain_recognition.handleIdentityClaim;

    pub const conversationSpeakerLine = brain_recognition.conversationSpeakerLine;

    pub const retainCaptureForPersonMemory = brain_recognition.retainCaptureForPersonMemory;

    pub const recognizeForObservation = brain_person_memory.recognizeForObservation;

    /// Identify and greet using a frame that has already been captured (for
    /// example a pulled frontend camera observation), skipping a fresh capture.
    pub const recognizeFromCapturedPath = brain_person_memory.recognizeFromCapturedPath;

    pub const describeImageForObservation = brain_person_memory.describeImageForObservation;

    pub const rememberPersonForObservation = brain_person_memory.rememberPersonForObservation;

    pub const updateFacePictureForObservation = brain_person_memory.updateFacePictureForObservation;

    pub const uploadedMediaObservation = brain_person_memory.uploadedMediaObservation;

    pub const compareImagesForObservation = brain_person_memory.compareImagesForObservation;

    pub const createPerson = brain_person_memory.createPerson;

    pub const seedKnownPerson = brain_person_memory.seedKnownPerson;

    pub const hasCreator = brain_person_memory.hasCreator;

    pub const ensureCreatorIfFirstRecognized = brain_person_memory.ensureCreatorIfFirstRecognized;

    pub const syncPersonGraph = brain_person_memory.syncPersonGraph;

    pub const rememberCreatorAttachment = brain_person_memory.rememberCreatorAttachment;

    pub const addSighting = brain_person_memory.addSighting;

    pub const say = brain_person_memory.say;

    pub const setSendEnabled = brain_logging_events.setSendEnabled;

    pub const logUserUtterance = brain_logging_events.logUserUtterance;

    pub const logCommandSent = brain_logging_events.logCommandSent;

    pub const logCommandResult = brain_logging_events.logCommandResult;

    pub const logMaintenanceCommandSent = brain_logging_events.logMaintenanceCommandSent;

    pub const logMaintenanceCommandResult = brain_logging_events.logMaintenanceCommandResult;

    pub const logState = brain_logging_events.logState;

    pub const trace = brain_logging_events.trace;

    pub const traceError = brain_logging_events.traceError;

    pub const traceText = brain_logging_events.traceText;

    pub const traceCount = brain_logging_events.traceCount;

    pub const traceIntent = brain_logging_events.traceIntent;

    pub const traceTurn = brain_logging_events.traceTurn;

    pub const traceTurnCommands = brain_logging_events.traceTurnCommands;

    pub const traceCommandBatch = brain_logging_events.traceCommandBatch;

    pub const traceCommand = brain_logging_events.traceCommand;

    pub const traceCommandError = brain_logging_events.traceCommandError;

    pub const appendCommandLog = brain_logging_events.appendCommandLog;

    pub const recordRuntimeEvent = brain_logging_events.recordRuntimeEvent;

    pub const recordIdMonitorEvent = brain_logging_events.recordIdMonitorEvent;

    pub const recordIdMonitorCrashEvent = brain_logging_events.recordIdMonitorCrashEvent;

    pub const recordMemoryCandidateEvent = brain_logging_events.recordMemoryCandidateEvent;

    pub const formatCommand = brain_logging_events.formatCommand;

    pub const handleInterruptStimulus = brain_command_execution.handleInterruptStimulus;

    pub const executeCommands = brain_command_execution.executeCommands;

    pub const appendPendingHardErrorObservation = brain_command_execution.appendPendingHardErrorObservation;

    pub const handleHardCommandError = brain_command_execution.handleHardCommandError;

    pub const executeChatCommands = brain_command_execution.executeChatCommands;

    pub const commandIsCallable = brain_command_execution.commandIsCallable;

    pub const chatCommandsEndWithSpeech = brain_command_execution.chatCommandsEndWithSpeech;

    pub const introspect = brain_introspection_autonomy.introspect;

    pub const memoryOneLineSummary = brain_introspection_autonomy.memoryOneLineSummary;

    pub const appendAffordanceObservation = brain_introspection_autonomy.appendAffordanceObservation;

    pub const appendSocialContextObservation = brain_lifecycle.appendSocialContextObservation;

    pub const affordanceCatalog = brain_introspection_autonomy.affordanceCatalog;

    pub const commandUnavailableReason = brain_introspection_autonomy.commandUnavailableReason;

    pub const senseAvailable = brain_introspection_autonomy.senseAvailable;

    pub const timeObservation = brain_introspection_autonomy.timeObservation;

    pub const powerObservation = brain_introspection_autonomy.powerObservation;

    pub const storageObservation = brain_introspection_autonomy.storageObservation;

    pub const databaseObservation = brain_introspection_autonomy.databaseObservation;

    pub const selfFactsSummary = brain_introspection_autonomy.selfFactsSummary;

    pub const activeNeedsSummary = brain_introspection_autonomy.activeNeedsSummary;

    pub const autonomyStateForNeeds = brain_autonomy.autonomyStateForNeeds;

    pub const autonomyEnabled = brain_autonomy.autonomyEnabled;

    pub const defaultAutonomySleeping = brain_autonomy.defaultAutonomySleeping;

    pub const autonomyPlannerCost = brain_autonomy.autonomyPlannerCost;

    pub const autonomyCommandCost = brain_autonomy.autonomyCommandCost;

    pub const buildAutonomyContext = brain_autonomy.buildAutonomyContext;

    pub const executeAutonomyTurn = brain_autonomy.executeAutonomyTurn;

    pub const setAutonomySleeping = brain_autonomy.setAutonomySleeping;

    pub const parseQuietHours = brain_autonomy.parseQuietHours;

    pub const parseClockMinute = brain_autonomy.parseClockMinute;

    pub const localDayKey = brain_autonomy.localDayKey;

    pub const dream = brain_dream_memory.dream;

    pub const dreamImagePrompt = brain_dream_memory.dreamImagePrompt;

    pub const imagineImage = brain_dream_memory.imagineImage;

    pub const runMaintenanceCommand = brain_dream_memory.runMaintenanceCommand;

    pub const buildConversationMemory = brain_dream_memory.buildConversationMemory;

    pub const buildConversationMemoryWithSpeaker = brain_dream_memory.buildConversationMemoryWithSpeaker;

    pub const formatConversationSummaryForMemory = brain_dream_memory.formatConversationSummaryForMemory;

    pub const setFact = brain_dream_memory.setFact;

    pub const recallFacts = brain_dream_memory.recallFacts;

    pub const invalidateFact = brain_dream_memory.invalidateFact;

    pub const createMemoryRecord = brain_dream_memory.createMemoryRecord;

    pub const seedEntryMemory = brain_dream_memory.seedEntryMemory;

    pub const addExperience = brain_dream_memory.addExperience;

    pub const heardSpeechRaw = brain_dream_memory.heardSpeechRaw;

    pub const appendHeardSpeechObservation = brain_dream_memory.appendHeardSpeechObservation;

    pub const experienceExpiry = brain_psyche_memory.experienceExpiry;

    pub const sweepSpeechArtifacts = brain_psyche_memory.sweepSpeechArtifacts;

    pub const createImpression = brain_psyche_memory.createImpression;

    pub const createAppraisal = brain_psyche_memory.createAppraisal;

    pub const appraiseEvent = brain_psyche_memory.appraiseEvent;

    pub const feelAbout = brain_psyche_memory.feelAbout;

    pub const detectWantAchievements = brain_psyche_memory.detectWantAchievements;

    pub const thinkAbout = brain_psyche_memory.thinkAbout;

    pub const defineSelf = brain_psyche_memory.defineSelf;

    pub const editSelf = brain_psyche_memory.editSelf;

    pub const chooseAttention = brain_psyche_memory.chooseAttention;

    pub const setFocus = brain_psyche_memory.setFocus;

    pub const clearFocus = brain_psyche_memory.clearFocus;

    /// Refresh the held focus before assembling context: keep a still-fresh
    /// self-set plan, otherwise derive the focus from the strongest attention.
    pub const refreshFocus = brain_psyche_memory.refreshFocus;

    pub const focusMode = brain_psyche_memory.focusMode;

    pub fn currentFocusAttention(self: *Brain) ?f32 {
        return brain_psyche_memory.currentFocusAttention(self.current_focus, self.now_seconds);
    }

    pub const askHuman = brain_psyche_memory.askHuman;

    pub const consolidateMemory = brain_psyche_memory.consolidateMemory;

    pub const recallMemories = brain_psyche_memory.recallMemories;

    pub const sweepShortTermMemories = brain_psyche_memory.sweepShortTermMemories;

    pub const logSimple = brain_psyche_memory.logSimple;
};

pub const remote_thinking_failure_message = "I'm unable to continue thinking due to a remote error.";
