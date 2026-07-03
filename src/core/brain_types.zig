const std = @import("std");
const chat_mod = ports.chat;
const openai = ports.openai;
const speech_mod = ports.speech;
const email_mod = ports.email;
const autonomy_mod = ports.autonomy;
const psyche_client = ports.psyche;
const want_achievement_mod = ports.want_achievement;
const persona_directive_mod = ports.persona_directive;
const process_goal_mod = ports.process_goal;
const image_mod = ports.image;
const audio_mod = ports.audio;
const camera_mod = ports.camera;
const speaker_mod = ports.speaker;
const input_mod = ports.input;
const event_log_mod = ports.event_log;
const facial_expression = ports.facial_expression;
const emote_mod = ports.emote;
const mise_en_scene_mod = ports.mise_en_scene;
const memory_extraction_mod = ports.memory_extraction;
const embedding_mod = ports.embedding;
const orientation_mod = ports.orientation;
const output_mod = ports.output;
const system_senses_mod = ports.system_senses;
const clock_mod = ports.clock;
const process_mod = ports.process;
const files_mod = ports.files;
const store_mod = ports.store;
const graph_store = ports.graph_store;
const interrupt_mod = @import("interrupt.zig");
const identity = @import("identity.zig");
const id_monitor = @import("id_monitor.zig");
const ports = @import("ports.zig");
const stimulus = @import("stimulus.zig");

pub const BrainDeps = struct {
    io: ?std.Io = null,
    capabilities: chat_mod.CapabilitySet,
    camera: camera_mod.Camera,
    recognizer: identity.IdentityRecognizer,
    face_picture_updater: ?identity.FacePictureUpdater = null,
    description_service: openai.DescriptionService,
    chat_service: chat_mod.ChatService,
    embedding_service: embedding_mod.EmbeddingService,
    memory_extraction_service: ?memory_extraction_mod.MemoryExtractionService = null,
    email_service: ?email_mod.EmailService = null,
    image_generation_service: image_mod.ImageGenerationService,
    audio_inspection_service: ?audio_mod.AudioInspectionService = null,
    autonomy_planner: ?autonomy_mod.AutonomyPlanner = null,
    psyche_service: ?psyche_client.PsycheService = null,
    want_achievement_detector: want_achievement_mod.WantAchievementDetector,
    persona_directive_synthesizer: persona_directive_mod.PersonaDirectiveSynthesizer,
    process_composer: ?process_goal_mod.ProcessComposer = null,
    speech_service: speech_mod.SpeechService,
    speaker: speaker_mod.Speaker,
    input: input_mod.UserInput,
    store: store_mod.MemoryStore,
    graph: graph_store.GraphStore,
    event_log: ?event_log_mod.EventLog = null,
    facial_expression_output: ?facial_expression.Output = null,
    emote_output: ?emote_mod.Output = null,
    mise_en_scene_output: ?mise_en_scene_mod.Output = null,
    orientation_query: ?orientation_mod.Query = null,
    output: ?output_mod.Output = null,
    system_senses: system_senses_mod.SystemSenses,
    clock: ?clock_mod.Clock = null,
    filesystem: ?files_mod.FileSystem = null,
    process_runner: ?process_mod.ProcessRunner = null,
    interrupt_source: ?interrupt_mod.Source = null,
    id_monitor_sources: []const id_monitor.Source = &.{},
    stimulus_poll: ?*const fn (?*anyopaque) anyerror!void = null,
    stimulus_poll_ctx: ?*anyopaque = null,
};

pub const ActionPressureBatchResult = struct {
    spoken_text: ?[]const u8 = null,
    ended_with_speech: bool = false,
    interrupted_by: ?interrupt_mod.Stimulus = null,
    selected_primary_action: ?chat_mod.ActionProposalType = null,
};

pub const ConversationTurnResult = struct {
    user_text: []const u8,
    spoken_text: []const u8,
    user_summary: []const u8,
    brain_summary: []const u8,
    /// Correlates logs and host responses for this dispatch; empty when unavailable.
    dispatch_id: []const u8 = "",
    interrupted_by: ?interrupt_mod.Stimulus = null,
    /// True when the turn paused mid-loop waiting for a host-delivered sense
    /// observation. The host should keep the turn open and expect a follow-up
    /// user_text or sense_observation once the awaited sense arrives.
    awaiting_host_sense: bool = false,
  /// Host pull sense name when awaiting_host_sense is true (e.g. "camera").
    awaited_host_sense: ?[]const u8 = null,
    /// Host pull purpose when awaiting_host_sense is true (e.g. "recognize").
    awaited_host_purpose: ?[]const u8 = null,
    /// Host pull timeout in milliseconds when awaiting_host_sense is true.
    awaited_host_timeout_ms: ?u32 = null,
    /// Stable ID for a multi-step activity the brain opened. Absent on single-step turns.
    activity_id: ?[]const u8 = null,
    activity_kind: ?[]const u8 = null,
    activity_kind_label: ?[]const u8 = null,
    activity_state: ?[]const u8 = null,
    activity_goal: ?[]const u8 = null,
    activity_awaiting: ?[]const u8 = null,
};

pub const PsycheHabituation = struct {
    const window_seconds: i64 = 60;
    const max_slots: usize = 16;

    const Slot = struct {
        key: [192]u8 = undefined,
        key_len: usize = 0,
        window_start: i64 = 0,
        count: u32 = 0,
    };

    slots: [max_slots]Slot = [_]Slot{.{}} ** max_slots,
    next_slot: usize = 0,

    pub fn observe(self: *PsycheHabituation, now_seconds: i64, key: []const u8) u32 {
        for (&self.slots) |*slot| {
            if (slot.key_len == 0) continue;
            if (now_seconds - slot.window_start >= window_seconds) {
                slot.key_len = 0;
                slot.count = 0;
                continue;
            }
            if (std.mem.eql(u8, slot.key[0..slot.key_len], key)) {
                slot.count += 1;
                return slot.count;
            }
        }
        const index = self.next_slot % max_slots;
        self.next_slot = (self.next_slot + 1) % max_slots;
        self.slots[index].key_len = @min(key.len, self.slots[index].key.len);
        @memcpy(self.slots[index].key[0..self.slots[index].key_len], key[0..self.slots[index].key_len]);
        self.slots[index].window_start = now_seconds;
        self.slots[index].count = 1;
        return 1;
    }
};

pub const SenseStimulusState = stimulus.DualProcessState;

pub const PendingHardError = struct {
    action_pressure: []const u8,
    error_name: []const u8,
    recovery_hint: []const u8,
};

pub const speech_artifact_ttl_seconds: i64 = 7 * 86_400;
pub const speech_artifact_prefix = "utterance_";
pub const speech_audio_suffix = ".wav";
pub const speech_transcription_json_suffix = ".wav.transcription.json";

pub const SpeechArtifactSweepResult = struct {
    audio_removed: usize = 0,
    transcription_json_removed: usize = 0,

    pub fn total(self: SpeechArtifactSweepResult) usize {
        return self.audio_removed + self.transcription_json_removed;
    }
};
