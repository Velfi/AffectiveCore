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
const openai = ports.openai;
const speech_mod = ports.speech;
const chat_mod = ports.chat;
const skills_mod = ports.skills;
const email_mod = ports.email;
const autonomy_mod = ports.autonomy;
const psyche_client = ports.psyche;
const want_achievement_mod = ports.want_achievement;
const persona_directive_mod = ports.persona_directive;
const image_mod = ports.image;
const audio_mod = ports.audio;
const camera_mod = ports.camera;
const speaker_mod = ports.speaker;
const input_mod = ports.input;
const button_mod = ports.button;
const event_log_mod = ports.event_log;
const facial_expression = ports.facial_expression;
const display_budget_mod = @import("display_budget.zig");
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
const request_timings = @import("request_timings.zig");

const brain_types = @import("brain_types.zig");
pub const BrainDeps = brain_types.BrainDeps;
pub const ActionPressureBatchResult = brain_types.ActionPressureBatchResult;
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
pub const HostVisualObservationResult = brain_lifecycle.HostVisualObservationResult;

const brain_action_execution = @import("brain_action_execution.zig");
const brain_autonomy = @import("brain_autonomy.zig");
const brain_context_stats = @import("brain_context_stats.zig");
const context_dispatch_report = @import("context_dispatch_report.zig");
const brain_dream_memory = @import("brain_dream_memory.zig");
const brain_introspection_autonomy = @import("brain_introspection_autonomy.zig");
const brain_lifecycle = @import("brain_lifecycle.zig");
const brain_logging_events = @import("brain_logging_events.zig");
const brain_person_memory = @import("brain_person_memory.zig");
const brain_psyche_memory = @import("brain_psyche_memory.zig");
const brain_recognition = @import("brain_recognition.zig");
const experience_pipeline = @import("experience_pipeline.zig");
const capabilities = @import("capabilities.zig");
const capability_registry = @import("capability_registry.zig");
const read_models = @import("read_models.zig");
const dream_time = @import("dream_time.zig");
const action_selection = @import("action_selection.zig");
const subsystems = @import("subsystems.zig");
const actors = @import("actors/mod.zig");
const learning_mod = @import("learning.zig");
const belief_updates = @import("belief_updates.zig");
const recognition_composite = @import("recognition_composite.zig");
const activity_mod = @import("activity.zig");
const brain_process = @import("brain_process.zig");
const brain_event = @import("brain_event.zig");
const brain_actor = @import("brain_actor.zig");
const brain_runtime = @import("brain_runtime.zig");

pub const BrainEvent = brain_event.BrainEvent;
pub const BrainEventTypes = brain_event.EventTypes;
pub const BrainActor = brain_actor.BrainActor;
pub const BrainActorContext = brain_actor.HandleContext;
pub const BrainRuntime = brain_runtime.BrainRuntime;
pub const BrainRuntimePhase = brain_runtime.Phase;
pub const Actors = actors;

pub const Brain = struct {
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

    pub const WaitingKind = enum { timer, human, host_sense };

    pub const WaitingFor = struct {
        kind: WaitingKind,
        intent: []const u8,
        since: i64,
    };

    allocator: std.mem.Allocator,
    cfg: config_mod.Config,
    deps: BrainDeps,
    runtime: BrainRuntime,
    runtime_bootstrapped: bool = false,
    runtime_turn_ctx: ?*anyopaque = null,
    now_seconds: i64,
    conversation_speaker_context: ?ConversationSpeakerContext = null,
    last_conversation_turn_seconds: ?i64 = null,
    last_conversation_effort_tier: ?chat_mod.EffortTier = null,
    last_visual_observation_path: ?[]const u8 = null,
    last_visual_update_seconds: ?i64 = null,
    last_visual_observation_uploaded: bool = false,
    /// Host sense the brain is waiting on to finish an in-flight turn or skill.
    awaited_host_request: ?@import("awaited_host_request.zig").Request = null,
    /// Ongoing goal-directed activity currently in flight.
    active_activity: ?activity_mod.Active = null,
    /// Explicit multi-step process currently driving conversation execution.
    active_process: ?@import("process_runtime.zig").ActiveProcess = null,
    /// Paused parent activities waiting for the current subtask to finish (root-first).
    activity_stack: std.ArrayList(activity_mod.Active) = .empty,
    /// Dispatch request id for the current host turn; used when the brain opens a process.
    current_dispatch_request_id: ?[]const u8 = null,
    /// Monotonic counter for brain-generated dispatch ids when the host omits request_id.
    dispatch_serial: u64 = 0,
    /// Monotonic counter for operation ids (process, manifest, store, etc.).
    operation_serial: u64 = 0,
    request_timings: request_timings.Collector = .{},
    /// User speech received while a turn was paused for host sense; processed
    /// after the paused turn finishes so stimuli are not dropped.
    pending_deferred_heard_speech: ?input_mod.HeardSpeech = null,
    /// Coalesced interrupt observation injected on the next user_text turn; superseded by a later interrupt.
    pending_user_interrupt_coalesce: ?[]const u8 = null,
    current_stimulus_context: ?[]const u8 = null,
    /// When set, equals current_stimulus_context and must be freed on replace/clear.
    owned_current_stimulus_context: ?[]const u8 = null,
    current_stimulus_seconds: ?i64 = null,
    current_focus: ?Focus = null,
    display_budget: display_budget_mod.State = .{},
    facial_expression_catalog: ?facial_expression.OwnedCatalog = null,
    cached_conversation_json_schema: ?[]const u8 = null,
    cached_autonomy_json_schema: ?[]const u8 = null,
    pending_hard_error: ?PendingHardError = null,
    id_monitor_manager: id_monitor.Manager = .{},
    psyche_habituation: PsycheHabituation = .{},
    sense_stimulus_state: SenseStimulusState = .{},
    last_trace_stage: []const u8 = "init",
    current_turn_event_id: ?[]const u8 = null,
    last_host_capability_digest: ?[]const u8 = null,
    last_host_activation_digest: ?[]const u8 = null,
    waiting_for: ?WaitingFor = null,
    conversation_user_text: ?[]const u8 = null,
    conversation_turn_stimulus_kind: chat_mod.StimulusKind = .heard_speech,
    context_stats: brain_context_stats.State,
    context_stats_loaded: bool = false,
    dispatch_context_report: ?context_dispatch_report.OwnedReport = null,
    /// Last invalid conversation LLM payload, kept for hard-error detail on this brain only.
    chat_parse_failure_body: ?[]const u8 = null,
    /// Voice section bullets from the seed document, loaded at connect or seed time.
    persona_voice_lines: []const []const u8 = &.{},
    /// Waking-period persona directive; defaults until first dream synthesis.
    persona_directive: ?persona_directive_mod.PersonaDirective = null,

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
        packet: SenseStimulusPacket,
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
        goal,
    };

    pub const init = brain_lifecycle.init;

    pub const clearChatParseFailure = brain_lifecycle.clearChatParseFailure;
    pub const rememberChatParseFailure = brain_lifecycle.rememberChatParseFailure;
    pub const chatParseFailureBody = brain_lifecycle.chatParseFailureBody;

    pub const seedFromFile = brain_lifecycle.seedFromFile;
    pub const refreshPersonaVoiceFromSeed = brain_lifecycle.refreshPersonaVoiceFromSeed;

    pub const seedDocument = brain_lifecycle.seedDocument;

    pub const applyNewBrainDefaults = @import("brain_defaults.zig").applyNewBrainDefaults;

    pub const handleFaceMemoryActivation = brain_lifecycle.handleFaceMemoryActivation;

    pub const handleLongTouchActivation = brain_lifecycle.handleLongTouchActivation;

    pub const forgetByNameOrId = brain_lifecycle.forgetByNameOrId;

    pub const handleConversationTurn = brain_lifecycle.handleConversationTurn;

    pub const expireConversationIfIdle = brain_lifecycle.expireConversationIfIdle;

    pub const handleButtonAction = brain_lifecycle.handleButtonAction;

    pub const handleTouchStimulusError = brain_lifecycle.handleTouchStimulusError;

    pub const handleTouchStimulus = brain_lifecycle.handleTouchStimulus;
    pub const handleUserInterruptFromHost = brain_lifecycle.handleUserInterruptFromHost;

    pub const handleHoldActivation = brain_lifecycle.handleHoldActivation;

    pub const handleConversationText = brain_lifecycle.handleConversationText;

    pub const StimulusDispatch = brain_process.StimulusDispatch;
    pub const reactToSalientSense = brain_lifecycle.reactToSalientSense;
    pub const handleEmojiReaction = brain_lifecycle.handleEmojiReaction;
    pub const conversationAwaitingHost = brain_process.conversationAwaitingHost;
    pub const activityAwaitingHost = brain_process.activityAwaitingHost;
    pub const activeActivityId = brain_process.activeActivityId;
    pub const continueConversationAfterAwaitedVisual = brain_lifecycle.continueConversationAfterAwaitedVisual;
    pub const handleHostVisualObservation = brain_lifecycle.handleHostVisualObservation;
    pub const clearActiveActivity = brain_process.clearActiveActivity;
    pub const restorePersistedActivity = brain_process.restorePersistedActivity;
    /// Deprecated alias for tests migrating to active_activity.
    pub const clearPendingConversationPause = brain_process.clearActiveActivity;

    pub const drainPendingDeferredConversation = brain_lifecycle.drainPendingDeferredConversation;

    pub const reconsiderFromReminder = brain_lifecycle.reconsiderFromReminder;

    pub const setWaitingFor = brain_lifecycle.setWaitingFor;

    pub const clearWaitingFor = brain_lifecycle.clearWaitingFor;

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
        if (self.owned_current_stimulus_context) |owned| {
            self.allocator.free(owned);
            self.owned_current_stimulus_context = null;
        }
        self.current_stimulus_context = null;
        self.current_stimulus_seconds = null;
    }

    pub fn setCurrentStimulusContext(self: *Brain, text: []const u8) void {
        if (self.owned_current_stimulus_context) |owned| {
            if (owned.ptr != text.ptr) {
                self.allocator.free(owned);
                self.owned_current_stimulus_context = null;
            }
        }
        self.current_stimulus_context = text;
        self.current_stimulus_seconds = self.now_seconds;
    }

    pub fn setOwnedCurrentStimulusContext(self: *Brain, text: []const u8) !void {
        if (self.owned_current_stimulus_context) |owned| {
            self.allocator.free(owned);
        }
        const owned = try self.allocator.dupe(u8, text);
        self.owned_current_stimulus_context = owned;
        self.current_stimulus_context = owned;
        self.current_stimulus_seconds = self.now_seconds;
    }

    pub const SenseStimulusRecord = struct {
        packet: SenseStimulusPacket,
        log_text: []const u8,
        event_id: []const u8,
    };

    pub fn observeSenseStimulus(self: *Brain, input: SenseStimulusInput) !SenseStimulusRecord {
        const packet = try self.sense_stimulus_state.observe(self.allocator, self.now_seconds, input);
        const recorded = try self.recordSenseStimulusPacket(packet, "");
        return .{
            .packet = packet,
            .log_text = recorded.text,
            .event_id = recorded.event_id,
        };
    }

    pub fn scoreSenseStimulus(self: *Brain, input: SenseStimulusInput) !SenseStimulusPacket {
        return self.sense_stimulus_state.observe(self.allocator, self.now_seconds, input);
    }

    pub const SenseStimulusLogRecord = struct {
        text: []const u8,
        event_id: []const u8,
    };

    pub fn recordSenseStimulusPacket(self: *Brain, packet: SenseStimulusPacket, suffix: []const u8) !SenseStimulusLogRecord {
        const text = try stimulus_mod.formatPacket(self.allocator, packet);
        const final_text = if (suffix.len == 0) text else try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ text, suffix });
        self.setCurrentStimulusContext(final_text);
        const event_id = try self.recordExperienceLogEvent(.{
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
        return .{ .text = final_text, .event_id = event_id };
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

    pub const runAutonomyReplenish = brain_lifecycle.runAutonomyReplenish;

    pub const runAutonomyReplenishFromPush = brain_lifecycle.runAutonomyReplenishFromPush;

    pub const runStimulusAutonomy = brain_lifecycle.runStimulusAutonomy;

    pub const assignSpeechStimulus = brain_recognition.assignSpeechStimulus;

    pub const assignTouchStimulus = brain_recognition.assignTouchStimulus;

    pub const clearAwaitedHostRequest = @import("awaited_host_request.zig").clear;
    pub const setAwaitedHostRequest = @import("awaited_host_request.zig").set;
    pub const awaitedHostRequestActive = @import("awaited_host_request.zig").active;
    pub const awaitedHostRequestMatches = @import("awaited_host_request.zig").matches;
    pub const awaitingHostSense = @import("awaited_host_request.zig").awaitingSense;
    pub const fulfillAwaitedHostRequestIfMatches = @import("awaited_host_request.zig").fulfillIfMatches;

    pub const conversationSpeakerLine = brain_recognition.conversationSpeakerLine;

    pub const retainCaptureForPersonMemory = brain_recognition.retainCaptureForPersonMemory;

    pub const recognizeForObservation = brain_person_memory.recognizeForObservation;
    pub const recognitionAlreadyInObservations = brain_person_memory.recognitionAlreadyInObservations;
    pub const recognitionRecentObservationNote = brain_person_memory.recognitionRecentObservationNote;

    /// Identify and greet using a frame that has already been captured (for
    /// example a pulled frontend camera observation), skipping a fresh capture.
    pub const recognizeFromCapturedPath = brain_person_memory.recognizeFromCapturedPath;

    pub const describeImageForObservation = brain_person_memory.describeImageForObservation;

    pub const rememberPersonForObservation = brain_person_memory.rememberPersonForObservation;

    pub const forgetPersonForObservation = brain_person_memory.forgetPersonForObservation;

    pub const updateFacePictureForObservation = brain_person_memory.updateFacePictureForObservation;

    pub const uploadedMediaObservation = brain_person_memory.uploadedMediaObservation;
    pub const uploadedImageObservation = brain_person_memory.uploadedImageObservation;

    pub const compareImagesForObservation = brain_person_memory.compareImagesForObservation;

    pub const createPerson = brain_person_memory.createPerson;

    pub const seedKnownPerson = brain_person_memory.seedKnownPerson;

    pub const hasCreator = brain_person_memory.hasCreator;

    pub const ensureCreatorIfFirstRecognized = brain_person_memory.ensureCreatorIfFirstRecognized;

    pub const syncPersonGraph = brain_person_memory.syncPersonGraph;

    pub const rememberCreatorAttachment = brain_person_memory.rememberCreatorAttachment;

    pub const addSighting = brain_person_memory.addSighting;

    pub const recordIdentityHypothesis = brain_person_memory.recordIdentityHypothesis;

    pub const recordIdentityCorrectionLearning = brain_person_memory.recordIdentityCorrectionLearning;

    pub const say = brain_person_memory.say;

    pub const setSendEnabled = brain_logging_events.setSendEnabled;

    pub const logUserUtterance = brain_logging_events.logUserUtterance;

    pub const logCapabilityRequested = brain_logging_events.logCapabilityRequested;

    pub const logActionSuppressed = brain_logging_events.logActionSuppressed;

    pub const logAutonomyStatus = brain_logging_events.logAutonomyStatus;

    pub const logCapabilityResult = brain_logging_events.logCapabilityResult;

    pub const logMaintenanceCapabilityRequested = brain_logging_events.logMaintenanceCapabilityRequested;

    pub const logMaintenanceCapabilityResult = brain_logging_events.logMaintenanceCapabilityResult;

    pub const logState = brain_logging_events.logState;

    pub const trace = brain_logging_events.trace;

    pub const traceError = brain_logging_events.traceError;

    pub const traceText = brain_logging_events.traceText;

    pub const traceCount = brain_logging_events.traceCount;

    pub const traceContextComposition = brain_logging_events.traceContextComposition;
    pub const clearDispatchContextReport = brain_logging_events.clearDispatchContextReport;
    pub const dispatchContextReportView = brain_logging_events.dispatchContextReportView;
    pub const setDispatchContextFromComposition = brain_logging_events.setDispatchContextFromComposition;
    pub const recordComposeTimingSpan = brain_logging_events.recordComposeTimingSpan;
    pub const traceConversationContextBudgetExceeded = brain_logging_events.traceConversationContextBudgetExceeded;
    pub const ensureContextStatsLoaded = brain_logging_events.ensureContextStatsLoaded;
    pub const maybeFlushContextStats = brain_logging_events.maybeFlushContextStats;
    pub const flushContextStatsIfDirty = brain_logging_events.flushContextStatsIfDirty;
    pub const recordContextBudgetExceeded = brain_logging_events.recordContextBudgetExceeded;
    pub const recordProcessGoalComposition = brain_logging_events.recordProcessGoalComposition;
    pub const recordLlmCompletion = brain_logging_events.recordLlmCompletion;
    pub const llmStatsRecorder = brain_logging_events.llmStatsRecorder;
    pub const wireLlmStatsRecorder = brain_logging_events.wireLlmStatsRecorder;
    pub const beginRequestTimings = brain_logging_events.beginRequestTimings;
    pub const finishRequestTimings = brain_logging_events.finishRequestTimings;
    pub const resetRequestTimings = brain_logging_events.resetRequestTimings;
    pub const requestTimingsAllocSpanId = brain_logging_events.requestTimingsAllocSpanId;
    pub const requestTimingsAllocLlmCallId = brain_logging_events.requestTimingsAllocLlmCallId;
    pub const requestTimingsAllocOperationId = brain_logging_events.requestTimingsAllocOperationId;
    pub const currentTimingDispatchId = brain_logging_events.currentTimingDispatchId;
    pub const currentTimingActivityId = brain_logging_events.currentTimingActivityId;
    pub const currentTimingProcessId = brain_logging_events.currentTimingProcessId;
    pub const currentTimingStepContext = brain_logging_events.currentTimingStepContext;
    pub const recordRequestSpan = brain_logging_events.recordRequestSpan;
    pub const ownedTimingDispatchId = brain_logging_events.ownedTimingDispatchId;
    pub const ownedTimingActivityId = brain_logging_events.ownedTimingActivityId;

    pub const traceIntent = brain_logging_events.traceIntent;

    pub const traceTurn = brain_logging_events.traceTurn;

    pub const traceTurnActionPressures = brain_logging_events.traceTurnActionPressures;

    pub const traceActionPressureBatch = brain_logging_events.traceActionPressureBatch;

    pub const traceActionPressure = brain_logging_events.traceActionPressure;

    pub const traceActionPressureError = brain_logging_events.traceActionPressureError;

    pub const traceActionPressureDeferred = brain_logging_events.traceActionPressureDeferred;

    pub const appendEventLog = brain_logging_events.appendEventLog;

    pub const recordExperienceLogEvent = brain_logging_events.recordExperienceLogEvent;

    pub const recordIdMonitorEvent = brain_logging_events.recordIdMonitorEvent;

    pub const recordIdMonitorCrashEvent = brain_logging_events.recordIdMonitorCrashEvent;

    pub const recordMemoryCandidateEvent = brain_logging_events.recordMemoryCandidateEvent;

    pub const recordMemoryExperience = experience_pipeline.recordMemoryExperience;
    pub const ExperiencePipeline = experience_pipeline.ExperiencePipeline;
    pub const recordExperienceEvent = experience_pipeline.recordExperienceEvent;
    pub const currentHostId = experience_pipeline.currentHostId;
    pub const ensureHostBinding = experience_pipeline.ensureHostBinding;

    pub const recordSimpleExperienceEvent = experience_pipeline.recordSimpleExperienceEvent;

    pub const recordExperienceLogMirrorEvent = experience_pipeline.recordExperienceLogMirrorEvent;

    pub const recordCapabilityStatus = capabilities.recordCapabilityStatus;

    pub const recordCapabilityRequest = capabilities.recordCapabilityRequest;

    pub const recordCapabilityResult = capabilities.recordCapabilityResult;
    pub const markMailboxRead = capabilities.markMailboxRead;
    pub const recordManifestStatuses = capabilities.recordManifestStatuses;
    pub const CapabilityRegistry = capability_registry;
    pub const CapabilitySynonyms = @import("capability_synonyms.zig");
    pub const registered_subsystems = subsystems.registered_subsystems;
    pub const collectSubsystemPressures = subsystems.collectSubsystemPressures;
    pub const arbitrateSubsystemPressures = subsystems.arbitrateSubsystemPressures;
    pub const appendSubsystemObservations = subsystems.appendSubsystemObservations;
    pub const Subsystem = action_selection.Subsystem;
    pub const SubsystemContext = action_selection.SubsystemContext;
    pub const proposeActionPressure = action_selection.proposeActionPressure;
    pub const selectActionPressure = action_selection.selectActionPressure;
    pub const suppressActionPressure = action_selection.suppressActionPressure;

    pub const readModelsSnapshot = read_models.readModelsSnapshot;

    pub const requestDreamTime = dream_time.requestDreamTime;
    pub const enterDrowsy = dream_time.enterDrowsy;
    pub const recoverStuckBrainMode = dream_time.recoverStuckBrainMode;

    pub const facultyForCapability = learning_mod.facultyForCapability;
    pub const selfTrustForFaculty = learning_mod.selfTrustForFaculty;
    pub const recognizeSubjectComposite = recognition_composite.recognizeSubject;

    pub const formatActionPressure = brain_logging_events.formatActionPressure;

    pub const handleInterruptStimulus = brain_action_execution.handleInterruptStimulus;

    pub const executeActionProposals = brain_lifecycle.executeRuntimeProposalBatch;
    pub const executeRuntimeAutonomyBatch = brain_lifecycle.executeRuntimeAutonomyBatch;
    pub const executeActionProposalsDirect = brain_action_execution.executeActionProposalsDirect;
    pub const publishRuntimeMemoryCandidate = brain_lifecycle.publishRuntimeMemoryCandidate;
    pub const publishRuntimeMemoryConsolidation = brain_lifecycle.publishRuntimeMemoryConsolidation;
    pub const publishRuntimeLearningCapabilityRecorded = brain_lifecycle.publishRuntimeLearningCapabilityRecorded;
    pub const publishRuntimeLearningCorrectionRecorded = brain_lifecycle.publishRuntimeLearningCorrectionRecorded;
    pub const queryRuntimeMemoryAudit = brain_lifecycle.queryRuntimeMemoryAudit;

    pub const appendPendingHardErrorObservation = brain_action_execution.appendPendingHardErrorObservation;

    pub const handleHardActionError = brain_action_execution.handleHardActionError;

    pub const actionIsCallable = brain_action_execution.actionIsCallable;

    pub const actionProposalsEndWithSpeech = brain_action_execution.actionProposalsEndWithSpeech;

    pub const introspect = brain_introspection_autonomy.introspect;

    pub const memoryOneLineSummary = brain_introspection_autonomy.memoryOneLineSummary;

    pub const appendAffordanceObservation = brain_introspection_autonomy.appendAffordanceObservation;
    pub const reloadFacialExpressionCatalog = @import("brain_facial_expression.zig").reloadFacialExpressionCatalog;
    pub const refreshFacialExpressionCatalog = @import("brain_facial_expression.zig").refreshFacialExpressionCatalog;
    pub const facialExpressionCatalogView = @import("brain_facial_expression.zig").facialExpressionCatalogView;
    pub const validateFacialExpression = @import("brain_facial_expression.zig").validateFacialExpression;
    pub const appendFacialExpressionCatalogObservation = @import("brain_facial_expression.zig").appendFacialExpressionCatalogObservation;
    pub const conversationJsonSchema = @import("brain_facial_expression.zig").conversationJsonSchema;
    pub const autonomyJsonSchema = @import("brain_facial_expression.zig").autonomyJsonSchema;
    pub const facialExpressionAvailable = @import("brain_facial_expression.zig").facialExpressionAvailable;
    pub const facialExpressionCatalogReady = @import("brain_facial_expression.zig").facialExpressionCatalogReady;

    pub const appendSocialContextObservation = brain_lifecycle.appendSocialContextObservation;

    pub const appendReadModelsObservation = brain_lifecycle.appendReadModelsObservation;

    pub const appendHostCapabilityObservationIfChanged = brain_lifecycle.appendHostCapabilityObservationIfChanged;

    pub const affordanceCatalog = brain_introspection_autonomy.affordanceCatalog;

    pub const actionUnavailableReason = brain_introspection_autonomy.actionUnavailableReason;

    pub const actionIsAvailable = brain_introspection_autonomy.actionIsAvailable;

    pub const senseAvailable = brain_introspection_autonomy.senseAvailable;

    pub const timeObservation = brain_introspection_autonomy.timeObservation;

    pub const powerObservation = brain_introspection_autonomy.powerObservation;

    pub const storageObservation = brain_introspection_autonomy.storageObservation;

    pub const databaseObservation = brain_introspection_autonomy.databaseObservation;

    pub const selfFactsSummary = brain_introspection_autonomy.selfFactsSummary;
    pub const selfFactsConversationSummary = brain_introspection_autonomy.selfFactsConversationSummary;
    pub const personaConversationSummary = brain_dream_memory.personaConversationSummary;
    pub const personaDirectiveConversationSummary = brain_dream_memory.personaDirectiveConversationSummary;
    pub const refreshPersonaDirectiveFromStore = brain_dream_memory.refreshPersonaDirectiveFromStore;
    pub const setPersonaDirective = brain_dream_memory.setPersonaDirective;
    pub const synthesizeDreamPersonaDirective = brain_dream_memory.synthesizeDreamPersonaDirective;

    pub const activeNeedsSummary = brain_introspection_autonomy.activeNeedsSummary;

    pub const autonomyStateForNeeds = brain_autonomy.autonomyStateForNeeds;

    pub const autonomyEnabled = brain_autonomy.autonomyEnabled;

    pub const defaultAutonomySleeping = brain_autonomy.defaultAutonomySleeping;

    pub const autonomyPlannerCost = brain_autonomy.autonomyPlannerCost;

    pub const autonomyActionCost = brain_autonomy.autonomyActionCost;

    pub const buildAutonomyContext = brain_autonomy.buildAutonomyContext;

    pub const executeAutonomyTurn = brain_autonomy.executeAutonomyTurn;

    pub const setAutonomySleeping = brain_autonomy.setAutonomySleeping;

    pub const parseQuietHours = brain_autonomy.parseQuietHours;

    pub const parseClockMinute = brain_autonomy.parseClockMinute;

    pub const localDayKey = brain_autonomy.localDayKey;

    pub const dreamImagePrompt = brain_dream_memory.dreamImagePrompt;

    pub const imagineImage = brain_dream_memory.imagineImage;
    pub const saveFlexibleIdentityReconciliation = brain_dream_memory.saveFlexibleIdentityReconciliation;

    pub const runMaintenanceCapability = brain_dream_memory.runMaintenanceCapability;

    pub const buildConversationMemory = brain_dream_memory.buildConversationMemory;

    pub const buildConversationMemoryBlocks = brain_dream_memory.buildConversationMemoryBlocks;
    pub const buildConversationMemoryWithSpeaker = brain_dream_memory.buildConversationMemoryWithSpeaker;
    pub const selectConversationMemories = @import("memory_selection.zig").selectConversationMemories;

    pub const formatConversationSummaryForMemory = brain_dream_memory.formatConversationSummaryForMemory;
    pub const formatTurnSummaryForMemory = brain_dream_memory.formatTurnSummaryForMemory;

    pub const setFact = brain_dream_memory.setFact;

    pub const recallFacts = brain_dream_memory.recallFacts;

    pub const invalidateFact = brain_dream_memory.invalidateFact;

    pub const createMemoryRecord = brain_dream_memory.createMemoryRecord;

    pub const seedEntryMemory = brain_dream_memory.seedEntryMemory;

    pub const recordExperienceFromLog = brain_dream_memory.recordExperienceFromLog;

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

    pub const consolidateMemory = brain_psyche_memory.consolidateMemory;

    pub const recallMemories = brain_psyche_memory.recallMemories;

    pub const sweepShortTermMemories = brain_psyche_memory.sweepShortTermMemories;

    pub const logSimple = brain_psyche_memory.logSimple;
};

pub const remote_thinking_failure_message = "I'm unable to continue thinking due to a remote error.";

pub const wireLlmStatsRecorder = brain_logging_events.wireLlmStatsRecorder;
pub const recordLlmCompletion = brain_logging_events.recordLlmCompletion;
pub const llmStatsRecorder = brain_logging_events.llmStatsRecorder;
