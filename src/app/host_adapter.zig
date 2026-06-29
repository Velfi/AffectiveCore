const std = @import("std");

const brain_mod = @import("../core/brain.zig");
const chat = @import("../api/chat_client.zig");
const openai = @import("../api/openai_client.zig");
const speech = @import("../api/speech_client.zig");
const image = @import("../api/image_client.zig");
const audio = @import("../api/audio_client.zig");
const autonomy = @import("../api/autonomy_client.zig");
const psyche = @import("../api/psyche_client.zig");
const want_achievement = @import("../api/want_achievement_client.zig");
const persona_directive = @import("../api/persona_directive_client.zig");
const process_composition = @import("../api/process_composition_client.zig");
const memory_extraction = @import("../api/extraction_client.zig");
const camera_mod = @import("../platform/common/camera.zig");
const speaker_mod = @import("../platform/common/speaker.zig");
const input_mod = @import("../platform/common/input.zig");
const event_log_mod = @import("../platform/common/event_log.zig");
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
    chat_service: chat.ChatService,
    embedding_service: @import("../core/port_embedding.zig").EmbeddingService,
    memory_extraction_service: ?memory_extraction.MemoryExtractionService = null,
    email_service: ?@import("../api/email_client.zig").EmailService = null,
    image_generation_service: image.ImageGenerationService,
    audio_inspection_service: ?audio.AudioInspectionService = null,
    autonomy_planner: ?autonomy.AutonomyPlanner = null,
    psyche_service: ?psyche.PsycheService = null,
    want_achievement_detector: want_achievement.WantAchievementDetector,
    persona_directive_synthesizer: persona_directive.PersonaDirectiveSynthesizer,
    process_composer: ?process_composition.ProcessComposer = null,
    speech_service: speech.SpeechService,
    speaker: speaker_mod.Speaker,
    input: input_mod.UserInput,
    store: @import("../storage/store.zig").MemoryStore,
    graph: graph_store.GraphStore,
    event_log: ?event_log_mod.EventLog = null,
    facial_expression_output: ?@import("../platform/common/facial_expression.zig").Output = null,
    emote_output: ?@import("../core/port_emote.zig").Output = null,
    mise_en_scene_output: ?@import("../core/port_mise_en_scene.zig").Output = null,
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
            .chat_service = self.chat_service,
            .embedding_service = self.embedding_service,
            .memory_extraction_service = self.memory_extraction_service,
            .email_service = self.email_service,
            .image_generation_service = self.image_generation_service,
            .audio_inspection_service = self.audio_inspection_service,
            .autonomy_planner = self.autonomy_planner,
            .psyche_service = self.psyche_service,
            .want_achievement_detector = self.want_achievement_detector,
            .persona_directive_synthesizer = self.persona_directive_synthesizer,
            .process_composer = self.process_composer,
            .speech_service = self.speech_service,
            .speaker = self.speaker,
            .input = self.input,
            .store = self.store,
            .graph = self.graph,
            .event_log = self.event_log,
            .facial_expression_output = self.facial_expression_output,
            .emote_output = self.emote_output,
            .mise_en_scene_output = self.mise_en_scene_output,
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
