const std = @import("std");

const brain_mod = @import("../core/brain.zig");
const host_adapter = @import("host_adapter.zig");
const embedded_protocol = @import("embedded_protocol.zig");
const config_mod = @import("../core/config.zig");
const llm_routing = @import("../core/llm_routing.zig");
const identity = @import("../core/identity.zig");
const chat = @import("../api/chat_client.zig");
const extraction = @import("../api/extraction_client.zig");
const embedding_client = @import("../api/embedding_client.zig");
const embedding_port = @import("../core/port_embedding.zig");
const recognition = @import("../api/recognition_client.zig");
const openai = @import("../api/openai_client.zig");
const ai_provider = @import("../api/random_provider_client.zig");
const speech = @import("../api/speech_client.zig");
const image = @import("../api/image_client.zig");
const autonomy = @import("../api/autonomy_client.zig");
const psyche = @import("../api/psyche_client.zig");
const want_achievement = @import("../api/want_achievement_client.zig");
const persona_directive = @import("../api/persona_directive_client.zig");
const process_composition = @import("../api/process_composition_client.zig");
const http_transport = @import("../api/http_transport.zig");
const camera_mod = @import("../platform/common/camera.zig");
const speaker_mod = @import("../platform/common/speaker.zig");
const input_mod = @import("../platform/common/input.zig");
const orientation_mod = @import("../platform/common/orientation.zig");
const output_mod = @import("../platform/common/output.zig");
const system_senses = @import("../platform/common/system_senses.zig");
const macos_power = @import("../platform/common/macos_power.zig");
const df_storage = @import("../platform/common/df_storage.zig");
const host_system_senses = @import("../platform/common/host_system_senses.zig");
const clock_mod = @import("../platform/common/clock.zig");
const process_mod = @import("../platform/common/process.zig");
const files_mod = @import("../platform/common/files.zig");
const brain_storage = @import("../storage/brain_storage.zig");

pub const HeadlessMcpBrainHost = struct {
    brain: brain_mod.Brain,
    storage: brain_storage.BrainStorage,
    llm_provider_clients: []*ai_provider.RandomProviderClient,

    pub fn deinit(self: *HeadlessMcpBrainHost, allocator: std.mem.Allocator) void {
        self.storage.deinit(allocator);
    }
};

pub fn initHeadlessMcpBrainHost(allocator: std.mem.Allocator, io: std.Io, http: http_transport.Client, cfg: config_mod.Config) !HeadlessMcpBrainHost {
    var storage = try brain_storage.BrainStorage.init(allocator, io, cfg.memory_path, cfg.graph_path, cfg.captures_dir);
    errdefer storage.deinit(allocator);
    const bundle = try makeHeadlessHost(allocator, io, http, cfg, storage);
    var host = HeadlessMcpBrainHost{
        .brain = brain_mod.Brain.init(allocator, cfg, bundle.host.brainDeps()),
        .storage = storage,
        .llm_provider_clients = bundle.llm_provider_clients,
    };
    try host.brain.applyNewBrainDefaults();
    try host.brain.restorePersistedActivity();
    try host.brain.refreshPersonaDirectiveFromStore();
    return host;
}

pub const EmbeddedMacosBrainHost = struct {
    brain: brain_mod.Brain,
    storage: brain_storage.BrainStorage,
    effects: *embedded_protocol.HostEffectCollector,
    llm_provider_clients: []*ai_provider.RandomProviderClient,
    chat_service: *chat.RandomProviderChatService,
    autonomy_planner: *autonomy.RandomProviderAutonomyPlanner,

    pub fn deinit(self: *EmbeddedMacosBrainHost, allocator: std.mem.Allocator) void {
        self.storage.deinit(allocator);
    }
};

pub fn initEmbeddedMacosBrainHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    http: http_transport.Client,
    cfg: config_mod.Config,
    host_capabilities: chat.CapabilitySet,
    host_system_senses_http: ?http_transport.Client,
    host_http_available: bool,
) !EmbeddedMacosBrainHost {
    var storage = try brain_storage.BrainStorage.init(allocator, io, cfg.memory_path, cfg.graph_path, cfg.captures_dir);
    errdefer storage.deinit(allocator);
    const bundle = try makeEmbeddedMacosHost(allocator, io, http, cfg, storage, host_capabilities, host_system_senses_http, host_http_available);
    var host = EmbeddedMacosBrainHost{
        .brain = brain_mod.Brain.init(allocator, cfg, bundle.host.brainDeps()),
        .storage = storage,
        .effects = bundle.effects,
        .llm_provider_clients = bundle.llm_provider_clients,
        .chat_service = bundle.chat_service,
        .autonomy_planner = bundle.autonomy_planner,
    };
    host.chat_service.parse_failure_brain = &host.brain;
    host.autonomy_planner.parse_failure_brain = &host.brain;
    try host.brain.applyNewBrainDefaults();
    try host.brain.restorePersistedActivity();
    try host.brain.refreshPersonaDirectiveFromStore();
    return host;
}

fn makeHeadlessHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    http: http_transport.Client,
    cfg: config_mod.Config,
    storage: brain_storage.BrainStorage,
) !HeadlessHostBundle {
    const unsupported = try allocator.create(UnsupportedHostServices);
    unsupported.* = .{};
    const local_process_runner = try allocator.create(process_mod.LocalProcessRunner);
    local_process_runner.* = .{};
    const local_filesystem = try allocator.create(files_mod.LocalFileSystem);
    local_filesystem.* = .{};
    const local_clock = try allocator.create(clock_mod.LocalClock);
    local_clock.* = .{};
    const local_output = try allocator.create(output_mod.LocalOutput);
    local_output.* = .{};
    const senses = try allocator.create(HeadlessSystemSenses);
    senses.* = .{ .io = io, .storage_backend = storage, .source = .headless_local };
    try requireConversationModels(cfg);

    const llm_quality = parseLlmQuality(cfg.llm_quality);

    const random_ai = try allocator.create(ai_provider.RandomProviderClient);
    random_ai.* = ai_provider.RandomProviderClient.initWithRoster(io, http, cfg.conversation_roster, llm_quality);
    const description_service = try allocator.create(openai.RandomProviderDescriptionService);
    description_service.* = openai.RandomProviderDescriptionService.init(random_ai);

    const chat_service = try allocator.create(chat.RandomProviderChatService);
    chat_service.* = chat.RandomProviderChatService.init(io, http, cfg.conversation_roster, llm_quality, parseReasoningEffort(cfg.conversation_reasoning_effort));
    const extraction_service = try allocator.create(extraction.RandomProviderMemoryExtractionService);
    extraction_service.* = extraction.RandomProviderMemoryExtractionService.init(io, http, cfg.conversation_roster, llm_quality, parseReasoningEffort(cfg.conversation_reasoning_effort));
    const test_embedding = try allocator.create(embedding_port.TestEmbeddingService);
    test_embedding.* = .{};

    const autonomy_planner = try allocator.create(autonomy.RandomProviderAutonomyPlanner);
    autonomy_planner.* = autonomy.RandomProviderAutonomyPlanner.init(io, http, cfg.conversation_roster, llm_quality, parseReasoningEffort(cfg.conversation_reasoning_effort), cfg.autonomy_mode);
    const psyche_service = try allocator.create(psyche.RandomProviderPsycheService);
    psyche_service.* = psyche.RandomProviderPsycheService.init(io, http, cfg.psyche_roster, llm_quality, parseReasoningEffort(cfg.psyche_reasoning_effort));

    const image_service = try allocator.create(image.NanoBananaImageService);
    image_service.* = image.NanoBananaImageService.init(io, http, cfg.image_generation_model, cfg.image_generation_output_dir);
    const speech_service = try allocator.create(speech.TestSpeechService);
    speech_service.* = .{};
    const speaker = try allocator.create(speaker_mod.TestSpeaker);
    speaker.* = .{};

    const want_detector = try allocator.create(want_achievement.RandomProviderWantAchievementDetector);
    want_detector.* = want_achievement.RandomProviderWantAchievementDetector.init(io, http, cfg.conversation_roster, llm_quality, parseReasoningEffort(cfg.conversation_reasoning_effort));

    const persona_synthesizer = try allocator.create(persona_directive.RandomProviderPersonaDirectiveSynthesizer);
    persona_synthesizer.* = persona_directive.RandomProviderPersonaDirectiveSynthesizer.init(io, http, cfg.conversation_roster, llm_quality, parseReasoningEffort(cfg.conversation_reasoning_effort));

    const process_composer = try allocator.create(process_composition.RandomProviderProcessComposer);
    process_composer.* = process_composition.RandomProviderProcessComposer.init(io, http, cfg.conversation_roster, llm_quality, parseReasoningEffort(cfg.conversation_reasoning_effort), cfg.autonomy_mode);

    const llm_provider_clients = try allocator.alloc(*ai_provider.RandomProviderClient, 8);
    llm_provider_clients[0] = random_ai;
    llm_provider_clients[1] = &chat_service.provider_client;
    llm_provider_clients[2] = &extraction_service.provider_client;
    llm_provider_clients[3] = &autonomy_planner.provider_client;
    llm_provider_clients[4] = &psyche_service.provider_client;
    llm_provider_clients[5] = &want_detector.provider_client;
    llm_provider_clients[6] = &process_composer.provider_client;
    llm_provider_clients[7] = &persona_synthesizer.provider_client;

    return .{
        .host = .{
            .io = io,
            .capabilities = mcpHeadlessCapabilities(),
            .camera = unsupported.camera(),
            .recognizer = unsupported.recognizer(),
            .description_service = description_service.service(),
            .chat_service = chat_service.service(),
            .embedding_service = test_embedding.service(),
            .memory_extraction_service = extraction_service.service(),
            .image_generation_service = image_service.service(),
            .autonomy_planner = autonomy_planner.planner(),
            .psyche_service = psyche_service.service(),
            .want_achievement_detector = want_detector.detector(),
            .persona_directive_synthesizer = persona_synthesizer.synthesizer(),
            .process_composer = process_composer.composer(),
            .speech_service = speech_service.service(),
            .speaker = speaker.speaker(),
            .input = unsupported.input(),
            .store = storage.memoryStore(),
            .graph = storage.graphStore(),
            .output = local_output.output(),
            .system_senses = senses.senses(),
            .clock = local_clock.clock(),
            .filesystem = local_filesystem.filesystem(),
            .process_runner = local_process_runner.runner(),
        },
        .llm_provider_clients = llm_provider_clients,
    };
}

const HeadlessHostBundle = struct {
    host: host_adapter.HostAdapter,
    llm_provider_clients: []*ai_provider.RandomProviderClient,
};

const EmbeddedMacosHostBundle = struct {
    host: host_adapter.HostAdapter,
    effects: *embedded_protocol.HostEffectCollector,
    llm_provider_clients: []*ai_provider.RandomProviderClient,
    chat_service: *chat.RandomProviderChatService,
    autonomy_planner: *autonomy.RandomProviderAutonomyPlanner,
};

fn makeEmbeddedMacosHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    http: http_transport.Client,
    cfg: config_mod.Config,
    storage: brain_storage.BrainStorage,
    host_capabilities: chat.CapabilitySet,
    host_system_senses_http: ?http_transport.Client,
    host_http_available: bool,
) !EmbeddedMacosHostBundle {
    // Used for all Apple embedded targets (macOS and iOS), not macOS-only.
    const unsupported = try allocator.create(UnsupportedHostServices);
    unsupported.* = .{};
    const local_process_runner = try allocator.create(process_mod.LocalProcessRunner);
    local_process_runner.* = .{};
    const local_filesystem = try allocator.create(files_mod.LocalFileSystem);
    local_filesystem.* = .{};
    const local_clock = try allocator.create(clock_mod.LocalClock);
    local_clock.* = .{};
    const local_output = try allocator.create(output_mod.LocalOutput);
    local_output.* = .{};
    const senses = try allocator.create(HeadlessSystemSenses);
    senses.* = .{
        .io = io,
        .storage_backend = storage,
        .source = .host_app,
        .host_http = host_system_senses_http,
    };
    try requireConversationModels(cfg);
    try requirePsycheModels(cfg);

    const effects = try allocator.create(embedded_protocol.HostEffectCollector);
    effects.* = embedded_protocol.HostEffectCollector.init(allocator);
    const frontend_camera = try allocator.create(FrontendCamera);
    frontend_camera.* = .{ .effects = effects };
    const frontend_orientation = try allocator.create(FrontendOrientation);
    frontend_orientation.* = .{ .effects = effects };

    const llm_quality = parseLlmQuality(cfg.llm_quality);

    const random_ai = try allocator.create(ai_provider.RandomProviderClient);
    random_ai.* = ai_provider.RandomProviderClient.initWithRoster(io, http, cfg.conversation_roster, llm_quality);
    const description_service = try allocator.create(openai.RandomProviderDescriptionService);
    description_service.* = openai.RandomProviderDescriptionService.init(random_ai);
    const selected_descriptions = description_service.service();

    const random_comparison = try allocator.create(openai.RandomProviderIdentityComparisonService);
    random_comparison.* = openai.RandomProviderIdentityComparisonService.init(random_ai);

    const host_recognizer = try allocator.create(recognition.HostRecognitionClient);
    host_recognizer.* = .{
        .http = http,
        .memory_path = cfg.memory_path,
        .embeddings_dir = cfg.face_embeddings_dir,
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
    const selected_recognizer = if (host_capabilities.identity_recognition)
        host_recognizer.recognizer()
    else
        descriptive_recognizer.recognizer();
    const selected_face_picture_updater: ?identity.FacePictureUpdater = if (host_capabilities.face_picture_update)
        host_recognizer.updater()
    else
        null;

    const chat_service = try allocator.create(chat.RandomProviderChatService);
    chat_service.* = chat.RandomProviderChatService.init(io, http, cfg.conversation_roster, llm_quality, parseReasoningEffort(cfg.conversation_reasoning_effort));
    const extraction_service = try allocator.create(extraction.RandomProviderMemoryExtractionService);
    extraction_service.* = extraction.RandomProviderMemoryExtractionService.init(io, http, cfg.conversation_roster, llm_quality, parseReasoningEffort(cfg.conversation_reasoning_effort));
    const test_embedding = try allocator.create(embedding_port.TestEmbeddingService);
    test_embedding.* = .{};
    const host_embedding = try allocator.create(embedding_client.HostEmbeddingClient);
    host_embedding.* = .{ .http = http };
    const selected_embedding = if (host_http_available) host_embedding.service() else test_embedding.service();

    const autonomy_planner = try allocator.create(autonomy.RandomProviderAutonomyPlanner);
    autonomy_planner.* = autonomy.RandomProviderAutonomyPlanner.init(io, http, cfg.conversation_roster, llm_quality, parseReasoningEffort(cfg.conversation_reasoning_effort), cfg.autonomy_mode);
    const psyche_service = try allocator.create(psyche.RandomProviderPsycheService);
    psyche_service.* = psyche.RandomProviderPsycheService.init(io, http, cfg.psyche_roster, llm_quality, parseReasoningEffort(cfg.psyche_reasoning_effort));
    const image_service = try allocator.create(image.NanoBananaImageService);
    image_service.* = image.NanoBananaImageService.init(io, http, cfg.image_generation_model, cfg.image_generation_output_dir);
    const want_detector = try allocator.create(want_achievement.RandomProviderWantAchievementDetector);
    want_detector.* = want_achievement.RandomProviderWantAchievementDetector.init(io, http, cfg.conversation_roster, llm_quality, parseReasoningEffort(cfg.conversation_reasoning_effort));
    const persona_synthesizer = try allocator.create(persona_directive.RandomProviderPersonaDirectiveSynthesizer);
    persona_synthesizer.* = persona_directive.RandomProviderPersonaDirectiveSynthesizer.init(io, http, cfg.conversation_roster, llm_quality, parseReasoningEffort(cfg.conversation_reasoning_effort));
    const process_composer = try allocator.create(process_composition.RandomProviderProcessComposer);
    process_composer.* = process_composition.RandomProviderProcessComposer.init(io, http, cfg.conversation_roster, llm_quality, parseReasoningEffort(cfg.conversation_reasoning_effort), cfg.autonomy_mode);

    const llm_provider_clients = try allocator.alloc(*ai_provider.RandomProviderClient, 8);
    llm_provider_clients[0] = random_ai;
    llm_provider_clients[1] = &chat_service.provider_client;
    llm_provider_clients[2] = &extraction_service.provider_client;
    llm_provider_clients[3] = &autonomy_planner.provider_client;
    llm_provider_clients[4] = &psyche_service.provider_client;
    llm_provider_clients[5] = &want_detector.provider_client;
    llm_provider_clients[6] = &process_composer.provider_client;
    llm_provider_clients[7] = &persona_synthesizer.provider_client;

    return .{ .host = .{
        .io = io,
        .capabilities = host_capabilities,
        .camera = frontend_camera.camera(),
        .recognizer = selected_recognizer,
        .face_picture_updater = selected_face_picture_updater,
        .description_service = selected_descriptions,
        .chat_service = chat_service.service(),
        .embedding_service = selected_embedding,
        .memory_extraction_service = extraction_service.service(),
        .image_generation_service = image_service.service(),
        .autonomy_planner = autonomy_planner.planner(),
        .psyche_service = psyche_service.service(),
        .want_achievement_detector = want_detector.detector(),
        .persona_directive_synthesizer = persona_synthesizer.synthesizer(),
        .process_composer = process_composer.composer(),
        .speech_service = effects.speechService(),
        .speaker = effects.speaker(),
        .input = unsupported.input(),
        .store = storage.memoryStore(),
        .graph = storage.graphStore(),
        .event_log = effects.eventLog(),
        .facial_expression_output = effects.facialExpressionOutput(),
        .emote_output = effects.emoteOutput(),
        .mise_en_scene_output = effects.miseEnSceneOutput(),
        .orientation_query = frontend_orientation.query(),
        .output = local_output.output(),
        .system_senses = senses.senses(),
        .clock = local_clock.clock(),
        .filesystem = local_filesystem.filesystem(),
        .process_runner = local_process_runner.runner(),
    }, .effects = effects, .llm_provider_clients = llm_provider_clients, .chat_service = chat_service, .autonomy_planner = autonomy_planner };
}

fn parseLlmQuality(text: []const u8) llm_routing.LlmQuality {
    return llm_routing.LlmQuality.parse(text) catch .auto;
}

fn parseReasoningEffort(text: []const u8) ?chat.ReasoningEffort {
    inline for (@typeInfo(chat.ReasoningEffort).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(chat.ReasoningEffort, field.name);
    }
    return null;
}

fn requireConversationModels(cfg: config_mod.Config) !void {
    if (cfg.conversation_roster.entries.len == 0 and std.mem.trim(u8, cfg.conversation_models, " \r\n\t").len == 0) {
        return error.MissingConversationModels;
    }
}

fn requirePsycheModels(cfg: config_mod.Config) !void {
    if (!std.mem.eql(u8, cfg.psyche_mode, "on")) return;
    if (cfg.psyche_roster.entries.len == 0 and std.mem.trim(u8, cfg.psyche_models, " \r\n\t").len == 0) {
        return error.MissingPsycheModels;
    }
}

fn mcpHeadlessCapabilities() chat.CapabilitySet {
    return .{
        .stored_memory_read = true,
        .stored_memory_write = true,
        .time_lookup = true,
        .power_status = true,
        .storage_fullness = true,
        .database_stats = true,
        .reminder_io = true,
        .speech_output = true,
        .image_generation = true,
        .local_process_io = true,
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
    fn recognizer(self: *UnsupportedHostServices) identity.IdentityRecognizer {
        return .{ .ctx = self, .identifyFn = identify };
    }

    fn identify(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !identity.IdentityResult {
        return error.UnsupportedHostCapability;
    }

    fn facePictureUpdater(self: *UnsupportedHostServices) identity.FacePictureUpdater {
        return .{ .ctx = self, .updateFn = updateFacePicture };
    }

    fn updateFacePicture(_: *anyopaque, _: std.mem.Allocator, _: identity.FacePictureUpdateRequest) !identity.FacePictureUpdateResult {
        return error.UnsupportedHostCapability;
    }

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
        return .{ .ctx = self, .playFileFn = playFile, .playFileBackgroundFn = playFileBackground };
    }

    fn playFile(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !void {
        return error.UnsupportedHostCapability;
    }

    fn playFileBackground(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !void {
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

const SystemSenseSource = enum {
    /// MCP / dev host may probe local macOS power and disk usage.
    headless_local,
    /// Embedded Apple host owns system senses via affective-host://system/* HTTP.
    host_app,
};

const HeadlessSystemSenses = struct {
    io: std.Io,
    storage_backend: brain_storage.BrainStorage,
    source: SystemSenseSource = .headless_local,
    host_http: ?http_transport.Client = null,

    fn senses(self: *HeadlessSystemSenses) system_senses.SystemSenses {
        return .{ .ctx = self, .datetimeFn = datetime, .powerFn = power, .storageFn = storage, .databaseFn = database };
    }

    fn datetime(ctx: *anyopaque, allocator: std.mem.Allocator) !system_senses.DateTime {
        const self: *HeadlessSystemSenses = @ptrCast(@alignCast(ctx));
        const unix_seconds = clock_mod.nowSeconds(self.io);
        return .{
            .datetime = try clock_mod.localIso8601FromUnix(allocator, unix_seconds),
            .datetime_format = clock_mod.local_datetime_format,
            .friendly_datetime = try clock_mod.localFriendlyDateTimeFromUnix(allocator, unix_seconds),
            .friendly_datetime_format = clock_mod.local_friendly_datetime_format,
            .unix_seconds = unix_seconds,
        };
    }

    fn power(ctx: *anyopaque, allocator: std.mem.Allocator) !system_senses.PowerSnapshot {
        const self: *HeadlessSystemSenses = @ptrCast(@alignCast(ctx));
        if (self.host_http) |http| {
            return host_system_senses.readPower(http, allocator);
        }
        if (self.source == .headless_local and @import("builtin").target.os.tag == .macos) {
            return macos_power.readPowerSnapshot(allocator, self.io);
        }
        return .{ .supplies = &.{} };
    }

    fn storage(ctx: *anyopaque, allocator: std.mem.Allocator) !system_senses.StorageSnapshot {
        const self: *HeadlessSystemSenses = @ptrCast(@alignCast(ctx));
        if (self.host_http) |http| {
            return host_system_senses.readStorage(http, allocator);
        }
        if (self.source == .headless_local and @import("builtin").target.os.tag == .macos) {
            return df_storage.readMount(allocator, self.io, "/");
        }
        return .{ .volumes = &.{} };
    }

    fn database(ctx: *anyopaque, allocator: std.mem.Allocator) !system_senses.DatabaseSnapshot {
        const self: *HeadlessSystemSenses = @ptrCast(@alignCast(ctx));
        return self.storage_backend.databaseSnapshot(allocator);
    }
};
