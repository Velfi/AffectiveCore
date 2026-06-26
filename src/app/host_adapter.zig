const std = @import("std");

const brain_mod = @import("../core/brain.zig");
const chat = @import("../api/chat_client.zig");
const intent = @import("../api/intent_client.zig");
const openai = @import("../api/openai_client.zig");
const greeting = @import("../api/greeting_client.zig");
const speech = @import("../api/speech_client.zig");
const image = @import("../api/image_client.zig");
const audio = @import("../api/audio_client.zig");
const autonomy = @import("../api/autonomy_client.zig");
const psyche = @import("../api/psyche_client.zig");
const want_achievement = @import("../api/want_achievement_client.zig");
const camera_mod = @import("../platform/common/camera.zig");
const speaker_mod = @import("../platform/common/speaker.zig");
const input_mod = @import("../platform/common/input.zig");
const command_log_mod = @import("../platform/common/command_log.zig");
const orientation_mod = @import("../platform/common/orientation.zig");
const output_mod = @import("../platform/common/output.zig");
const system_senses = @import("../platform/common/system_senses.zig");
const clock_mod = @import("../platform/common/clock.zig");
const process_mod = @import("../platform/common/process.zig");
const files_mod = @import("../platform/common/files.zig");
const interrupt_mod = @import("../core/interrupt.zig");
const graph_store = @import("../storage/graph_store.zig");

pub const HostAdapter = struct {
    capabilities: chat.CapabilitySet,
    io: ?std.Io = null,
    camera: camera_mod.Camera,
    recognizer: @import("../core/identity.zig").IdentityRecognizer,
    face_picture_updater: ?@import("../core/identity.zig").FacePictureUpdater = null,
    description_service: openai.DescriptionService,
    greeting_service: greeting.GreetingService,
    intent_service: intent.IntentService,
    chat_service: chat.ChatService,
    email_service: ?@import("../api/email_client.zig").EmailService = null,
    image_generation_service: image.ImageGenerationService,
    audio_inspection_service: ?audio.AudioInspectionService = null,
    autonomy_planner: ?autonomy.AutonomyPlanner = null,
    psyche_service: ?psyche.PsycheService = null,
    want_achievement_detector: want_achievement.WantAchievementDetector,
    speech_service: speech.SpeechService,
    speaker: speaker_mod.Speaker,
    input: input_mod.UserInput,
    store: @import("../storage/store.zig").MemoryStore,
    graph: graph_store.GraphStore,
    command_log: ?command_log_mod.CommandLog = null,
    facial_expression_output: ?@import("../platform/common/facial_expression.zig").Output = null,
    orientation_query: ?orientation_mod.Query = null,
    output: ?output_mod.Output = null,
    system_senses: system_senses.SystemSenses,
    clock: ?clock_mod.Clock = null,
    filesystem: ?files_mod.FileSystem = null,
    process_runner: ?process_mod.ProcessRunner = null,
    interrupt_source: ?interrupt_mod.Source = null,

    pub fn brainDeps(self: HostAdapter) brain_mod.BrainDeps {
        return .{
            .io = self.io,
            .capabilities = self.capabilities,
            .camera = self.camera,
            .recognizer = self.recognizer,
            .face_picture_updater = self.face_picture_updater,
            .description_service = self.description_service,
            .greeting_service = self.greeting_service,
            .intent_service = self.intent_service,
            .chat_service = self.chat_service,
            .email_service = self.email_service,
            .image_generation_service = self.image_generation_service,
            .audio_inspection_service = self.audio_inspection_service,
            .autonomy_planner = self.autonomy_planner,
            .psyche_service = self.psyche_service,
            .want_achievement_detector = self.want_achievement_detector,
            .speech_service = self.speech_service,
            .speaker = self.speaker,
            .input = self.input,
            .store = self.store,
            .graph = self.graph,
            .command_log = self.command_log,
            .facial_expression_output = self.facial_expression_output,
            .orientation_query = self.orientation_query,
            .output = self.output,
            .system_senses = self.system_senses,
            .clock = self.clock,
            .filesystem = self.filesystem,
            .process_runner = self.process_runner,
            .interrupt_source = self.interrupt_source,
        };
    }
};
