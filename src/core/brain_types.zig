const std = @import("std");
const chat_mod = @import("../api/chat_client.zig");
const intent_mod = @import("../api/intent_client.zig");
const openai = @import("../api/openai_client.zig");
const greeting_client = @import("../api/greeting_client.zig");
const speech_mod = @import("../api/speech_client.zig");
const email_mod = @import("../api/email_client.zig");
const autonomy_mod = @import("../api/autonomy_client.zig");
const psyche_client = @import("../api/psyche_client.zig");
const want_achievement_mod = @import("../api/want_achievement_client.zig");
const image_mod = @import("../api/image_client.zig");
const audio_mod = @import("../api/audio_client.zig");
const camera_mod = @import("../platform/common/camera.zig");
const speaker_mod = @import("../platform/common/speaker.zig");
const input_mod = @import("../platform/common/input.zig");
const command_log_mod = @import("../platform/common/command_log.zig");
const facial_expression = @import("../platform/common/facial_expression.zig");
const orientation_mod = @import("../platform/common/orientation.zig");
const system_senses_mod = @import("../platform/common/system_senses.zig");
const store_mod = @import("../storage/store.zig");
const graph_store = @import("../storage/graph_store.zig");
const interrupt_mod = @import("interrupt.zig");
const identity = @import("identity.zig");
const id_monitor = @import("id_monitor.zig");
const stimulus = @import("stimulus.zig");

pub const BrainDeps = struct {
    io: ?std.Io = null,
    capabilities: chat_mod.CapabilitySet,
    camera: camera_mod.Camera,
    recognizer: identity.IdentityRecognizer,
    description_service: openai.DescriptionService,
    greeting_service: greeting_client.GreetingService,
    intent_service: intent_mod.IntentService,
    chat_service: chat_mod.ChatService,
    email_service: ?email_mod.EmailService = null,
    image_generation_service: image_mod.ImageGenerationService,
    audio_inspection_service: ?audio_mod.AudioInspectionService = null,
    autonomy_planner: ?autonomy_mod.AutonomyPlanner = null,
    psyche_service: ?psyche_client.PsycheService = null,
    want_achievement_detector: want_achievement_mod.WantAchievementDetector,
    speech_service: speech_mod.SpeechService,
    speaker: speaker_mod.Speaker,
    input: input_mod.UserInput,
    store: store_mod.MemoryStore,
    graph: graph_store.GraphStore,
    command_log: ?command_log_mod.CommandLog = null,
    facial_expression_output: ?facial_expression.Output = null,
    orientation_query: ?orientation_mod.Query = null,
    system_senses: system_senses_mod.SystemSenses,
    interrupt_source: ?interrupt_mod.Source = null,
    id_monitor_sources: []const id_monitor.Source = &.{},
};

pub const CommandBatchResult = struct {
    spoken_text: ?[]const u8 = null,
    ended_with_speech: bool = false,
    interrupted_by: ?interrupt_mod.Stimulus = null,
};

pub const ConversationTurnResult = struct {
    user_text: []const u8,
    spoken_text: []const u8,
    user_summary: []const u8,
    brain_summary: []const u8,
    interrupted_by: ?interrupt_mod.Stimulus = null,
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
    command: []const u8,
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
