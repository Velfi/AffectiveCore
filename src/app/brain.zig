const std = @import("std");

const brain_mod = @import("../core/brain.zig");
const brain_container = @import("brain_container.zig");
const embedded_protocol = @import("embedded_protocol.zig");
const config_mod = @import("../core/config.zig");
const time_mod = @import("../core/time.zig");
const chat = @import("../api/chat_client.zig");
const intent = @import("../api/intent_client.zig");
const recognition = @import("../api/recognition_client.zig");
const openai = @import("../api/openai_client.zig");
const ai_provider = @import("../api/random_provider_client.zig");
const greeting = @import("../api/greeting_client.zig");
const speech = @import("../api/speech_client.zig");
const image = @import("../api/image_client.zig");
const audio = @import("../api/audio_client.zig");
const autonomy = @import("../api/autonomy_client.zig");
const psyche = @import("../api/psyche_client.zig");
const want_achievement = @import("../api/want_achievement_client.zig");
const http_transport = @import("../api/http_transport.zig");
const camera_mod = @import("../platform/common/camera.zig");
const speaker_mod = @import("../platform/common/speaker.zig");
const input_mod = @import("../platform/common/input.zig");
const button_mod = @import("../platform/common/button.zig");
const command_log_mod = @import("../platform/common/command_log.zig");
const orientation_mod = @import("../platform/common/orientation.zig");
const system_senses = @import("../platform/common/system_senses.zig");
const interrupt_mod = @import("../core/interrupt.zig");
const maintenance = @import("../core/maintenance.zig");
const graph_store = @import("../storage/graph_store.zig");
const brain_storage = @import("../storage/brain_storage.zig");

pub const HostKind = enum {
    macos,
    radxa_linux,
    mcp_headless,
};

pub const FrontendKind = enum {
    terminal,
    mac_webview,
    mcp,
};

pub const CommandInfo = struct {
    command: chat.ChatCommandType,
    name: []const u8,
    description: []const u8,
    available: bool,
};

pub const CommandResult = struct {
    command: chat.ChatCommandType,
    observation: []const u8,
    spoken_text: ?[]const u8,
    ended_with_speech: bool,
    interrupted_by: ?interrupt_mod.Stimulus,
};

pub const ConversationTurnResult = struct {
    user_text: []const u8,
    spoken_text: []const u8,
    user_summary: []const u8,
    brain_summary: []const u8,
    interrupted_by: ?[]const u8 = null,
};

pub const BrainHandle = struct {
    brain_id: []const u8,
    runtime: *BrainRuntime,
};

pub const AppCore = struct {
    allocator: std.mem.Allocator,
    brains: std.ArrayList(BrainHandle) = .empty,

    pub fn init(allocator: std.mem.Allocator) AppCore {
        return .{ .allocator = allocator };
    }

    pub fn registerBrain(self: *AppCore, brain_id: []const u8, runtime: *BrainRuntime) !void {
        if (brain_id.len == 0) return error.EmptyBrainId;
        if (self.findBrain(brain_id) != null) return error.DuplicateBrainId;
        try self.brains.append(self.allocator, .{
            .brain_id = try self.allocator.dupe(u8, brain_id),
            .runtime = runtime,
        });
    }

    pub fn requireBrain(self: *AppCore, brain_id: []const u8) !*BrainRuntime {
        return self.findBrain(brain_id) orelse error.UnknownBrainId;
    }

    pub fn executeCommand(self: *AppCore, brain_id: []const u8, command: chat.ChatCommand) !CommandResult {
        var runtime = try self.requireBrain(brain_id);
        return runtime.executeCommand(command);
    }

    pub fn conversationTurn(self: *AppCore, brain_id: []const u8, text: []const u8) !ConversationTurnResult {
        var runtime = try self.requireBrain(brain_id);
        return runtime.conversationTurn(text);
    }

    pub fn configureBrain(self: *AppCore, brain_id: []const u8, settings: config_mod.BrainSettings) !void {
        var runtime = try self.requireBrain(brain_id);
        try runtime.configure(settings);
    }

    pub fn brainSettings(self: *AppCore, brain_id: []const u8) !config_mod.BrainSettings {
        const runtime = try self.requireBrain(brain_id);
        return runtime.brain.cfg.brainSettings();
    }

    pub fn inspectBrain(self: *AppCore, brain_id: []const u8, io: std.Io) !brain_container.BrainIntrospection {
        var runtime = try self.requireBrain(brain_id);
        return runtime.inspectBrain(io);
    }

    pub fn inspectBrainFile(self: *AppCore, io: std.Io, brain_file_path: []const u8) !brain_container.BrainManifest {
        return brain_container.inspectBrainFile(self.allocator, io, brain_file_path);
    }

    pub fn exportBrain(self: *AppCore, brain_id: []const u8, io: std.Io, brain_file_path: []const u8) !brain_container.BrainManifest {
        var runtime = try self.requireBrain(brain_id);
        return runtime.exportBrain(io, brain_file_path);
    }

    pub fn importBrain(self: *AppCore, io: std.Io, brain_file_path: []const u8, cfg: config_mod.Config) !brain_container.BrainManifest {
        if (self.findBrain(cfg.brain_id) != null) return error.DuplicateBrainId;
        return brain_container.importBrain(self.allocator, io, brain_file_path, cfg);
    }

    fn findBrain(self: *AppCore, brain_id: []const u8) ?*BrainRuntime {
        for (self.brains.items) |handle| {
            if (std.mem.eql(u8, handle.brain_id, brain_id)) return handle.runtime;
        }
        return null;
    }
};

pub const HostAdapter = struct {
    kind: HostKind,
    capabilities: chat.CapabilitySet,
    io: ?std.Io = null,
    camera: camera_mod.Camera,
    recognizer: @import("../core/identity.zig").IdentityRecognizer,
    description_service: openai.DescriptionService,
    greeting_service: greeting.GreetingService,
    intent_service: intent.IntentService,
    chat_service: chat.ChatService,
    email_service: ?@import("../api/email_client.zig").EmailService = null,
    image_generation_service: image.ImageGenerationService,
    audio_inspection_service: ?audio.AudioInspectionService = null,
    autonomy_planner: ?@import("../api/autonomy_client.zig").AutonomyPlanner = null,
    psyche_service: ?@import("../api/psyche_client.zig").PsycheService = null,
    want_achievement_detector: want_achievement.WantAchievementDetector,
    speech_service: speech.SpeechService,
    speaker: speaker_mod.Speaker,
    input: input_mod.UserInput,
    store: @import("../storage/store.zig").MemoryStore,
    graph: graph_store.GraphStore,
    command_log: ?command_log_mod.CommandLog = null,
    facial_expression_output: ?@import("../platform/common/facial_expression.zig").Output = null,
    orientation_query: ?orientation_mod.Query = null,
    system_senses: system_senses.SystemSenses,
    interrupt_source: ?interrupt_mod.Source = null,

    pub fn brainDeps(self: HostAdapter) brain_mod.BrainDeps {
        return .{
            .io = self.io,
            .capabilities = self.capabilities,
            .camera = self.camera,
            .recognizer = self.recognizer,
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
            .system_senses = self.system_senses,
            .interrupt_source = self.interrupt_source,
        };
    }
};

pub const BrainRuntime = struct {
    allocator: std.mem.Allocator,
    brain_id: []const u8,
    host_kind: HostKind,
    frontend_kind: FrontendKind,
    brain: brain_mod.Brain,
    owned_storage: ?brain_storage.BrainStorage = null,
    embedded_effects: ?*embedded_protocol.HostEffectCollector = null,

    pub fn init(allocator: std.mem.Allocator, cfg: config_mod.Config, host: HostAdapter, frontend: FrontendKind) !BrainRuntime {
        return .{
            .allocator = allocator,
            .brain_id = cfg.brain_id,
            .host_kind = host.kind,
            .frontend_kind = frontend,
            .brain = brain_mod.Brain.init(allocator, cfg, host.brainDeps()),
        };
    }

    pub fn initHeadlessMcp(allocator: std.mem.Allocator, io: std.Io, http: http_transport.Client, env: *const std.process.Environ.Map, cfg: config_mod.Config) !BrainRuntime {
        var storage = try brain_storage.BrainStorage.init(allocator, io, cfg.memory_path, cfg.events_path, cfg.graph_path, cfg.captures_dir);
        errdefer storage.deinit(allocator);
        const host = try makeHeadlessHost(allocator, io, http, env, cfg, storage);
        var runtime = try init(allocator, cfg, host, .mcp);
        runtime.owned_storage = storage;
        return runtime;
    }

    pub fn initEmbeddedMacos(allocator: std.mem.Allocator, io: std.Io, http: http_transport.Client, env: *const std.process.Environ.Map, cfg: config_mod.Config) !BrainRuntime {
        var storage = try brain_storage.BrainStorage.init(allocator, io, cfg.memory_path, cfg.events_path, cfg.graph_path, cfg.captures_dir);
        errdefer storage.deinit(allocator);
        const bundle = try makeEmbeddedMacosHost(allocator, io, http, env, cfg, storage);
        var runtime = try init(allocator, cfg, bundle.host, .mcp);
        runtime.owned_storage = storage;
        runtime.embedded_effects = bundle.effects;
        return runtime;
    }

    pub fn deinit(self: *BrainRuntime) void {
        if (self.owned_storage) |*storage| {
            storage.deinit(self.allocator);
            self.owned_storage = null;
        }
    }

    pub fn executeCommand(self: *BrainRuntime, command: chat.ChatCommand) !CommandResult {
        var commands = [_]chat.ChatCommand{command};
        return self.executeCommands(commands[0..]);
    }

    pub fn executeCommands(self: *BrainRuntime, commands: []chat.ChatCommand) !CommandResult {
        var observations = std.ArrayList(u8).empty;
        const result = try self.brain.executeCommands(commands, &observations);
        return .{
            .command = if (commands.len > 0) commands[commands.len - 1].command else .unknown,
            .observation = try observations.toOwnedSlice(self.allocator),
            .spoken_text = result.spoken_text,
            .ended_with_speech = result.ended_with_speech,
            .interrupted_by = result.interrupted_by,
        };
    }

    pub fn clearEmbeddedEffects(self: *BrainRuntime) void {
        if (self.embedded_effects) |effects| effects.clear();
    }

    pub fn embeddedEvents(self: *BrainRuntime) []const embedded_protocol.HostEvent {
        if (self.embedded_effects) |effects| return effects.items();
        return &[_]embedded_protocol.HostEvent{};
    }

    pub fn conversationTurn(self: *BrainRuntime, text: []const u8) !ConversationTurnResult {
        const heard = try input_mod.HeardSpeech.typed(self.allocator, text);
        const result = try self.brain.handleConversationText(heard);
        return .{
            .user_text = result.user_text,
            .spoken_text = result.spoken_text,
            .user_summary = result.user_summary,
            .brain_summary = result.brain_summary,
            .interrupted_by = if (result.interrupted_by) |stimulus| @tagName(stimulus.kind) else null,
        };
    }

    pub fn shortTouchActivation(self: *BrainRuntime) !CommandResult {
        var observations = std.ArrayList(u8).empty;
        self.brain.handleFaceMemoryActivation() catch |err| {
            if (try self.brain.handleTouchStimulusError(err)) {
                return .{
                    .command = .unknown,
                    .observation = try observations.toOwnedSlice(self.allocator),
                    .spoken_text = null,
                    .ended_with_speech = false,
                    .interrupted_by = null,
                };
            }
            return err;
        };
        return .{
            .command = .unknown,
            .observation = try observations.toOwnedSlice(self.allocator),
            .spoken_text = null,
            .ended_with_speech = false,
            .interrupted_by = null,
        };
    }

    pub fn longTouchActivation(self: *BrainRuntime) !CommandResult {
        try self.brain.handleLongTouchActivation();
        return .{
            .command = .unknown,
            .observation = try self.allocator.dupe(u8, ""),
            .spoken_text = null,
            .ended_with_speech = false,
            .interrupted_by = null,
        };
    }

    pub fn runStimulusAutonomy(self: *BrainRuntime) !void {
        const io = self.brain.deps.io orelse return error.LocalDateUnavailable;
        try self.brain.runStimulusAutonomy(io);
    }

    pub fn dryRunConversationPrompt(self: *BrainRuntime, user_text: []const u8) !chat.ChatPrompt {
        return self.brain.dryRunConversationPrompt(user_text);
    }

    pub fn availableCommands(self: *BrainRuntime) ![]CommandInfo {
        var out = std.ArrayList(CommandInfo).empty;
        inline for (@typeInfo(chat.ChatCommandType).@"enum".fields) |field| {
            const command: chat.ChatCommandType = @field(chat.ChatCommandType, field.name);
            if (chat.commandSpec(command)) |spec| {
                const available = try self.brain.commandIsCallable(command);
                try out.append(self.allocator, .{
                    .command = command,
                    .name = chat.skills.name(command),
                    .description = spec.description,
                    .available = available,
                });
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    pub fn configure(self: *BrainRuntime, settings: config_mod.BrainSettings) !void {
        if (settings.brain_id.len > 0 and !std.mem.eql(u8, settings.brain_id, self.brain_id)) return error.BrainSettingsIdMismatch;
        self.brain.cfg = self.brain.cfg.withBrainSettings(settings);
    }

    pub fn inspectBrain(self: *BrainRuntime, io: std.Io) !brain_container.BrainIntrospection {
        return brain_container.inspectBrain(self.allocator, io, self.brain.cfg);
    }

    pub fn exportBrain(self: *BrainRuntime, io: std.Io, brain_file_path: []const u8) !brain_container.BrainManifest {
        return brain_container.exportBrain(self.allocator, io, self.brain.cfg, brain_file_path);
    }

    pub fn runTerminalLoop(self: *BrainRuntime, io: std.Io, button: button_mod.ButtonControl, wait_when_idle_ms: u64) !void {
        while (true) {
            self.brain.syncClock(io);
            try self.brain.runMaintenance(io);
            try self.brain.runAutonomyTick(io);
            const wait_ms: u64 = if (std.mem.eql(u8, self.brain.cfg.autonomy_mode, "on"))
                @max(@as(u64, 250), @min(@as(u64, 5000), self.brain.cfg.autonomy_interval_seconds * 1000))
            else
                wait_when_idle_ms;
            const action = try button.waitForActionFor(self.allocator, wait_ms);
            if (action == null) continue;
            self.brain.syncClock(io);
            self.brain.handleButtonAction(action.?) catch |err| {
                if (err == error.UserQuit) break;
                if (try self.brain.handleTouchStimulusError(err)) continue;
                return err;
            };
        }
    }
};

fn makeHeadlessHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    http: http_transport.Client,
    env: *const std.process.Environ.Map,
    cfg: config_mod.Config,
    storage: brain_storage.BrainStorage,
) !HostAdapter {
    const unsupported = try allocator.create(UnsupportedHostServices);
    unsupported.* = .{};
    const senses = try allocator.create(HeadlessSystemSenses);
    senses.* = .{ .io = io, .storage_backend = storage };
    const use_provider = cfg.conversation_models.len > 0;

    const random_ai = try allocator.create(ai_provider.RandomProviderClient);
    random_ai.* = ai_provider.RandomProviderClient.init(io, http, env, cfg.conversation_models);
    const description_service = try allocator.create(openai.RandomProviderDescriptionService);
    description_service.* = openai.RandomProviderDescriptionService.init(random_ai);

    const test_intent_service = try allocator.create(intent.TestIntentService);
    test_intent_service.* = .{};

    const test_greeting_service = try allocator.create(greeting.TestGreetingService);
    test_greeting_service.* = .{};
    const greeting_service = try allocator.create(greeting.RandomProviderGreetingService);
    greeting_service.* = greeting.RandomProviderGreetingService.init(random_ai);

    const unconfigured_chat_service = try allocator.create(chat.UnconfiguredChatService);
    unconfigured_chat_service.* = .{};
    const chat_service = try allocator.create(chat.RandomProviderChatService);
    chat_service.* = chat.RandomProviderChatService.init(io, http, env, cfg.conversation_models, parseReasoningEffort(cfg.conversation_reasoning_effort));

    const autonomy_planner = try allocator.create(autonomy.RandomProviderAutonomyPlanner);
    autonomy_planner.* = autonomy.RandomProviderAutonomyPlanner.init(io, http, env, cfg.conversation_models, parseReasoningEffort(cfg.conversation_reasoning_effort));
    const psyche_service = try allocator.create(psyche.RandomProviderPsycheService);
    psyche_service.* = psyche.RandomProviderPsycheService.init(io, http, env, cfg.psyche_models, parseReasoningEffort(cfg.psyche_reasoning_effort));

    const image_service = try allocator.create(image.NanoBananaImageService);
    image_service.* = image.NanoBananaImageService.init(io, http, env, cfg.image_generation_model, cfg.image_generation_output_dir);
    const speech_service = try allocator.create(speech.TestSpeechService);
    speech_service.* = .{};
    const speaker = try allocator.create(speaker_mod.TestSpeaker);
    speaker.* = .{};

    const scripted_want_detector = try allocator.create(want_achievement.ScriptedWantAchievementDetector);
    scripted_want_detector.* = .{};
    const want_detector = try allocator.create(want_achievement.RandomProviderWantAchievementDetector);
    want_detector.* = want_achievement.RandomProviderWantAchievementDetector.init(io, http, env, cfg.conversation_models, parseReasoningEffort(cfg.conversation_reasoning_effort));
    const command_recognizer = try allocator.create(recognition.CommandRecognitionClient);
    command_recognizer.* = .{
        .io = io,
        .command = cfg.recognition_command,
        .command_memory_path = storage.commandMemoryPath(),
        .embeddings_dir = cfg.face_embeddings_dir,
        .detector_model = cfg.face_detector_model,
        .recognizer_model = cfg.face_recognition_model,
        .known_threshold = cfg.known_threshold,
        .uncertain_threshold = cfg.uncertain_threshold,
    };

    return .{
        .kind = .mcp_headless,
        .io = io,
        .capabilities = mcpHeadlessCapabilities(),
        .camera = unsupported.camera(),
        .recognizer = command_recognizer.recognizer(),
        .description_service = if (use_provider) description_service.service() else unsupported.descriptionService(),
        .greeting_service = if (use_provider) greeting_service.service() else test_greeting_service.service(),
        .intent_service = test_intent_service.service(),
        .chat_service = if (use_provider) chat_service.service() else unconfigured_chat_service.service(),
        .image_generation_service = image_service.service(),
        .autonomy_planner = if (use_provider) autonomy_planner.planner() else null,
        .psyche_service = if (use_provider) psyche_service.service() else null,
        .want_achievement_detector = if (use_provider) want_detector.detector() else scripted_want_detector.detector(),
        .speech_service = speech_service.service(),
        .speaker = speaker.speaker(),
        .input = unsupported.input(),
        .store = storage.memoryStore(),
        .graph = storage.graphStore(),
        .system_senses = senses.senses(),
    };
}

const EmbeddedMacosHostBundle = struct {
    host: HostAdapter,
    effects: *embedded_protocol.HostEffectCollector,
};

fn makeEmbeddedMacosHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    http: http_transport.Client,
    env: *const std.process.Environ.Map,
    cfg: config_mod.Config,
    storage: brain_storage.BrainStorage,
) !EmbeddedMacosHostBundle {
    const unsupported = try allocator.create(UnsupportedHostServices);
    unsupported.* = .{};
    const senses = try allocator.create(HeadlessSystemSenses);
    senses.* = .{ .io = io, .storage_backend = storage };
    const use_provider = cfg.conversation_models.len > 0;

    const effects = try allocator.create(embedded_protocol.HostEffectCollector);
    effects.* = embedded_protocol.HostEffectCollector.init(allocator);
    const frontend_camera = try allocator.create(FrontendCamera);
    frontend_camera.* = .{ .effects = effects };
    const frontend_orientation = try allocator.create(FrontendOrientation);
    frontend_orientation.* = .{ .effects = effects };

    const random_ai = try allocator.create(ai_provider.RandomProviderClient);
    random_ai.* = ai_provider.RandomProviderClient.init(io, http, env, cfg.conversation_models);
    const description_service = try allocator.create(openai.RandomProviderDescriptionService);
    description_service.* = openai.RandomProviderDescriptionService.init(random_ai);
    const selected_descriptions = if (use_provider)
        description_service.service()
    else
        unsupported.descriptionService();

    const random_comparison = try allocator.create(openai.RandomProviderIdentityComparisonService);
    random_comparison.* = openai.RandomProviderIdentityComparisonService.init(random_ai);

    const command_recognizer = try allocator.create(recognition.CommandRecognitionClient);
    command_recognizer.* = .{
        .io = io,
        .command = cfg.recognition_command,
        .command_memory_path = storage.commandMemoryPath(),
        .embeddings_dir = cfg.face_embeddings_dir,
        .detector_model = cfg.face_detector_model,
        .recognizer_model = cfg.face_recognition_model,
        .known_threshold = cfg.known_threshold,
        .uncertain_threshold = cfg.uncertain_threshold,
    };
    const descriptive_recognizer = try allocator.create(recognition.DescriptiveRecognitionClient);
    descriptive_recognizer.* = .{
        .store = storage.memoryStore(),
        .description_service = selected_descriptions,
        .comparison_service = random_comparison.service(),
        .known_threshold = cfg.known_threshold,
        .uncertain_threshold = cfg.uncertain_threshold,
    };
    const effective_recognition_mode = config_mod.effectiveRecognitionMode(cfg, .macos);
    const selected_recognizer = if (std.mem.eql(u8, effective_recognition_mode, "command"))
        command_recognizer.recognizer()
    else if (std.mem.eql(u8, effective_recognition_mode, "descriptive"))
        descriptive_recognizer.recognizer()
    else
        command_recognizer.recognizer();

    const test_intent_service = try allocator.create(intent.TestIntentService);
    test_intent_service.* = .{};
    const test_greeting_service = try allocator.create(greeting.TestGreetingService);
    test_greeting_service.* = .{};
    const greeting_service = try allocator.create(greeting.RandomProviderGreetingService);
    greeting_service.* = greeting.RandomProviderGreetingService.init(random_ai);

    const unconfigured_chat_service = try allocator.create(chat.UnconfiguredChatService);
    unconfigured_chat_service.* = .{};
    const chat_service = try allocator.create(chat.RandomProviderChatService);
    chat_service.* = chat.RandomProviderChatService.init(io, http, env, cfg.conversation_models, parseReasoningEffort(cfg.conversation_reasoning_effort));

    const autonomy_planner = try allocator.create(autonomy.RandomProviderAutonomyPlanner);
    autonomy_planner.* = autonomy.RandomProviderAutonomyPlanner.init(io, http, env, cfg.conversation_models, parseReasoningEffort(cfg.conversation_reasoning_effort));
    const psyche_service = try allocator.create(psyche.RandomProviderPsycheService);
    psyche_service.* = psyche.RandomProviderPsycheService.init(io, http, env, cfg.psyche_models, parseReasoningEffort(cfg.psyche_reasoning_effort));
    const image_service = try allocator.create(image.NanoBananaImageService);
    image_service.* = image.NanoBananaImageService.init(io, http, env, cfg.image_generation_model, cfg.image_generation_output_dir);
    const scripted_want_detector = try allocator.create(want_achievement.ScriptedWantAchievementDetector);
    scripted_want_detector.* = .{};
    const want_detector = try allocator.create(want_achievement.RandomProviderWantAchievementDetector);
    want_detector.* = want_achievement.RandomProviderWantAchievementDetector.init(io, http, env, cfg.conversation_models, parseReasoningEffort(cfg.conversation_reasoning_effort));

    return .{ .host = .{
        .kind = .macos,
        .io = io,
        .capabilities = embeddedMacosCapabilities(use_provider),
        .camera = frontend_camera.camera(),
        .recognizer = selected_recognizer,
        .description_service = selected_descriptions,
        .greeting_service = if (use_provider) greeting_service.service() else test_greeting_service.service(),
        .intent_service = test_intent_service.service(),
        .chat_service = if (use_provider) chat_service.service() else unconfigured_chat_service.service(),
        .image_generation_service = image_service.service(),
        .autonomy_planner = if (use_provider) autonomy_planner.planner() else null,
        .psyche_service = if (use_provider) psyche_service.service() else null,
        .want_achievement_detector = if (use_provider) want_detector.detector() else scripted_want_detector.detector(),
        .speech_service = effects.speechService(),
        .speaker = effects.speaker(),
        .input = unsupported.input(),
        .store = storage.memoryStore(),
        .graph = storage.graphStore(),
        .command_log = effects.commandLog(),
        .facial_expression_output = effects.facialExpressionOutput(),
        .orientation_query = frontend_orientation.query(),
        .system_senses = senses.senses(),
    }, .effects = effects };
}

fn parseReasoningEffort(text: []const u8) ?chat.ReasoningEffort {
    inline for (@typeInfo(chat.ReasoningEffort).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(chat.ReasoningEffort, field.name);
    }
    return null;
}

fn mcpHeadlessCapabilities() chat.CapabilitySet {
    return .{
        .stored_memory_read = true,
        .stored_memory_write = true,
        .introspection = true,
        .time_lookup = true,
        .power_status = true,
        .storage_fullness = true,
        .database_stats = true,
        .reminder_io = true,
        .speech_output = true,
        .face_picture_update = true,
        .image_generation = true,
        .local_process_io = true,
        .facial_expression_output = true,
    };
}

fn embeddedMacosCapabilities(use_provider: bool) chat.CapabilitySet {
    return .{
        .live_camera = use_provider,
        .visual_description = use_provider,
        .visual_comparison = use_provider,
        .identity_recognition = use_provider,
        .uploaded_media_read = true,
        .stored_image_read = true,
        .stored_memory_read = true,
        .stored_memory_write = true,
        .introspection = true,
        .time_lookup = true,
        .power_status = true,
        .storage_fullness = true,
        .database_stats = true,
        .reminder_io = true,
        .speech_output = true,
        .face_picture_update = true,
        .image_generation = true,
        .local_process_io = true,
        .button_activation = true,
        .button_hold_state = true,
        .facial_expression_output = true,
    };
}

const FrontendCamera = struct {
    effects: *embedded_protocol.HostEffectCollector,

    fn camera(self: *FrontendCamera) camera_mod.Camera {
        return .{ .ctx = self, .captureFn = capture };
    }

    fn capture(ctx: *anyopaque, _: std.mem.Allocator) !@import("../core/events.zig").ImageCapture {
        const self: *FrontendCamera = @ptrCast(@alignCast(ctx));
        try self.effects.appendCaptureRequested("webcam photo", "The frontend should capture a webcam photo and send it back as uploaded media.");
        return error.FrontendCaptureRequested;
    }
};

const FrontendOrientation = struct {
    effects: *embedded_protocol.HostEffectCollector,

    fn query(self: *FrontendOrientation) orientation_mod.Query {
        return .{ .ctx = self, .requestFn = request };
    }

    fn request(ctx: *anyopaque, title: []const u8, body: []const u8) !void {
        const self: *FrontendOrientation = @ptrCast(@alignCast(ctx));
        try self.effects.appendSenseRequested("orientation", title, body);
        return error.FrontendOrientationRequested;
    }
};

const UnsupportedHostServices = struct {
    fn camera(self: *UnsupportedHostServices) camera_mod.Camera {
        return .{ .ctx = self, .captureFn = capture };
    }

    fn capture(_: *anyopaque, _: std.mem.Allocator) !@import("../core/events.zig").ImageCapture {
        return error.UnsupportedHostCapability;
    }

    fn descriptionService(self: *UnsupportedHostServices) openai.DescriptionService {
        return .{ .ctx = self, .describeFn = describePerson, .describeImageFn = describeImage, .compareImagesFn = compareImages };
    }

    fn describePerson(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !openai.VisualDescription {
        return error.UnsupportedHostCapability;
    }

    fn describeImage(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) ![]const u8 {
        return error.UnsupportedHostCapability;
    }

    fn compareImages(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) ![]const u8 {
        return error.UnsupportedHostCapability;
    }

    fn speaker(self: *UnsupportedHostServices) speaker_mod.Speaker {
        return .{ .ctx = self, .playFileFn = playFile };
    }

    fn playFile(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !void {
        return error.UnsupportedHostCapability;
    }

    fn input(self: *UnsupportedHostServices) input_mod.UserInput {
        return .{ .ctx = self, .askFn = ask, .isActiveFn = isActive };
    }

    fn ask(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !input_mod.HeardSpeech {
        return error.UnsupportedHostCapability;
    }

    fn isActive(_: *anyopaque, _: std.mem.Allocator) !bool {
        return false;
    }
};

const HeadlessSystemSenses = struct {
    io: std.Io,
    storage_backend: brain_storage.BrainStorage,

    fn senses(self: *HeadlessSystemSenses) system_senses.SystemSenses {
        return .{ .ctx = self, .datetimeFn = datetime, .powerFn = power, .storageFn = storage, .databaseFn = database };
    }

    fn datetime(ctx: *anyopaque, allocator: std.mem.Allocator) !system_senses.DateTime {
        const self: *HeadlessSystemSenses = @ptrCast(@alignCast(ctx));
        return .{
            .datetime = try time_mod.nowTimestamp(allocator),
            .unix_seconds = @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), 1000),
        };
    }

    fn power(_: *anyopaque, _: std.mem.Allocator) !system_senses.PowerSnapshot {
        return .{ .supplies = &.{} };
    }

    fn storage(_: *anyopaque, _: std.mem.Allocator) !system_senses.StorageSnapshot {
        return .{ .volumes = &.{} };
    }

    fn database(ctx: *anyopaque, allocator: std.mem.Allocator) !system_senses.DatabaseSnapshot {
        const self: *HeadlessSystemSenses = @ptrCast(@alignCast(ctx));
        return self.storage_backend.databaseSnapshot(allocator);
    }
};
