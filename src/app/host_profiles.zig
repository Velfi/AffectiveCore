const std = @import("std");

const brain_mod = @import("../core/brain.zig");
const host_adapter = @import("host_adapter.zig");
const embedded_protocol = @import("embedded_protocol.zig");
const config_mod = @import("../core/config.zig");
const identity = @import("../core/identity.zig");
const chat = @import("../api/chat_client.zig");
const intent = @import("../api/intent_client.zig");
const recognition = @import("../api/recognition_client.zig");
const openai = @import("../api/openai_client.zig");
const ai_provider = @import("../api/random_provider_client.zig");
const greeting = @import("../api/greeting_client.zig");
const speech = @import("../api/speech_client.zig");
const image = @import("../api/image_client.zig");
const autonomy = @import("../api/autonomy_client.zig");
const psyche = @import("../api/psyche_client.zig");
const want_achievement = @import("../api/want_achievement_client.zig");
const http_transport = @import("../api/http_transport.zig");
const camera_mod = @import("../platform/common/camera.zig");
const speaker_mod = @import("../platform/common/speaker.zig");
const input_mod = @import("../platform/common/input.zig");
const orientation_mod = @import("../platform/common/orientation.zig");
const output_mod = @import("../platform/common/output.zig");
const system_senses = @import("../platform/common/system_senses.zig");
const clock_mod = @import("../platform/common/clock.zig");
const process_mod = @import("../platform/common/process.zig");
const files_mod = @import("../platform/common/files.zig");
const brain_storage = @import("../storage/brain_storage.zig");

pub const HeadlessMcpBrainHost = struct {
    brain: brain_mod.Brain,
    storage: brain_storage.BrainStorage,

    pub fn deinit(self: *HeadlessMcpBrainHost, allocator: std.mem.Allocator) void {
        self.storage.deinit(allocator);
    }
};

pub fn initHeadlessMcpBrainHost(allocator: std.mem.Allocator, io: std.Io, http: http_transport.Client, cfg: config_mod.Config) !HeadlessMcpBrainHost {
    var storage = try brain_storage.BrainStorage.init(allocator, io, cfg.memory_path, cfg.events_path, cfg.graph_path, cfg.captures_dir);
    errdefer storage.deinit(allocator);
    const host = try makeHeadlessHost(allocator, io, http, cfg, storage);
    const brain = brain_mod.Brain.init(allocator, cfg, host.brainDeps());
    return .{ .brain = brain, .storage = storage };
}

pub const EmbeddedMacosBrainHost = struct {
    brain: brain_mod.Brain,
    storage: brain_storage.BrainStorage,
    effects: *embedded_protocol.HostEffectCollector,

    pub fn deinit(self: *EmbeddedMacosBrainHost, allocator: std.mem.Allocator) void {
        self.storage.deinit(allocator);
    }
};

pub fn initEmbeddedMacosBrainHost(allocator: std.mem.Allocator, io: std.Io, http: http_transport.Client, cfg: config_mod.Config, host_capabilities: chat.CapabilitySet) !EmbeddedMacosBrainHost {
    var storage = try brain_storage.BrainStorage.init(allocator, io, cfg.memory_path, cfg.events_path, cfg.graph_path, cfg.captures_dir);
    errdefer storage.deinit(allocator);
    const bundle = try makeEmbeddedMacosHost(allocator, io, http, cfg, storage, host_capabilities);
    const brain = brain_mod.Brain.init(allocator, cfg, bundle.host.brainDeps());
    return .{ .brain = brain, .storage = storage, .effects = bundle.effects };
}

fn makeHeadlessHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    http: http_transport.Client,
    cfg: config_mod.Config,
    storage: brain_storage.BrainStorage,
) !host_adapter.HostAdapter {
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
    senses.* = .{ .io = io, .storage_backend = storage };
    const use_provider = cfg.conversation_models.len > 0;

    const random_ai = try allocator.create(ai_provider.RandomProviderClient);
    random_ai.* = ai_provider.RandomProviderClient.init(io, http, cfg.conversation_models);
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
    chat_service.* = chat.RandomProviderChatService.init(io, http, cfg.conversation_models, parseReasoningEffort(cfg.conversation_reasoning_effort));

    const autonomy_planner = try allocator.create(autonomy.RandomProviderAutonomyPlanner);
    autonomy_planner.* = autonomy.RandomProviderAutonomyPlanner.init(io, http, cfg.conversation_models, parseReasoningEffort(cfg.conversation_reasoning_effort));
    const psyche_service = try allocator.create(psyche.RandomProviderPsycheService);
    psyche_service.* = psyche.RandomProviderPsycheService.init(io, http, cfg.psyche_models, parseReasoningEffort(cfg.psyche_reasoning_effort));

    const image_service = try allocator.create(image.NanoBananaImageService);
    image_service.* = image.NanoBananaImageService.init(io, http, cfg.image_generation_model, cfg.image_generation_output_dir);
    const speech_service = try allocator.create(speech.TestSpeechService);
    speech_service.* = .{};
    const speaker = try allocator.create(speaker_mod.TestSpeaker);
    speaker.* = .{};

    const scripted_want_detector = try allocator.create(want_achievement.ScriptedWantAchievementDetector);
    scripted_want_detector.* = .{};
    const want_detector = try allocator.create(want_achievement.RandomProviderWantAchievementDetector);
    want_detector.* = want_achievement.RandomProviderWantAchievementDetector.init(io, http, cfg.conversation_models, parseReasoningEffort(cfg.conversation_reasoning_effort));


    return .{
        .io = io,
        .capabilities = mcpHeadlessCapabilities(),
        .camera = unsupported.camera(),
        .recognizer = unsupported.recognizer(),
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
        .output = local_output.output(),
        .system_senses = senses.senses(),
        .clock = local_clock.clock(),
        .filesystem = local_filesystem.filesystem(),
        .process_runner = local_process_runner.runner(),
    };
}

const EmbeddedMacosHostBundle = struct {
    host: host_adapter.HostAdapter,
    effects: *embedded_protocol.HostEffectCollector,
};

fn makeEmbeddedMacosHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    http: http_transport.Client,
    cfg: config_mod.Config,
    storage: brain_storage.BrainStorage,
    host_capabilities: chat.CapabilitySet,
) !EmbeddedMacosHostBundle {
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
    senses.* = .{ .io = io, .storage_backend = storage };
    const use_provider = cfg.conversation_models.len > 0;

    const effects = try allocator.create(embedded_protocol.HostEffectCollector);
    effects.* = embedded_protocol.HostEffectCollector.init(allocator);
    const frontend_camera = try allocator.create(FrontendCamera);
    frontend_camera.* = .{ .effects = effects };
    const frontend_orientation = try allocator.create(FrontendOrientation);
    frontend_orientation.* = .{ .effects = effects };

    const random_ai = try allocator.create(ai_provider.RandomProviderClient);
    random_ai.* = ai_provider.RandomProviderClient.init(io, http, cfg.conversation_models);
    const description_service = try allocator.create(openai.RandomProviderDescriptionService);
    description_service.* = openai.RandomProviderDescriptionService.init(random_ai);
    const selected_descriptions = if (use_provider)
        description_service.service()
    else
        unsupported.descriptionService();

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

    const test_intent_service = try allocator.create(intent.TestIntentService);
    test_intent_service.* = .{};
    const test_greeting_service = try allocator.create(greeting.TestGreetingService);
    test_greeting_service.* = .{};
    const greeting_service = try allocator.create(greeting.RandomProviderGreetingService);
    greeting_service.* = greeting.RandomProviderGreetingService.init(random_ai);

    const unconfigured_chat_service = try allocator.create(chat.UnconfiguredChatService);
    unconfigured_chat_service.* = .{};
    const chat_service = try allocator.create(chat.RandomProviderChatService);
    chat_service.* = chat.RandomProviderChatService.init(io, http, cfg.conversation_models, parseReasoningEffort(cfg.conversation_reasoning_effort));

    const autonomy_planner = try allocator.create(autonomy.RandomProviderAutonomyPlanner);
    autonomy_planner.* = autonomy.RandomProviderAutonomyPlanner.init(io, http, cfg.conversation_models, parseReasoningEffort(cfg.conversation_reasoning_effort));
    const psyche_service = try allocator.create(psyche.RandomProviderPsycheService);
    psyche_service.* = psyche.RandomProviderPsycheService.init(io, http, cfg.psyche_models, parseReasoningEffort(cfg.psyche_reasoning_effort));
    const image_service = try allocator.create(image.NanoBananaImageService);
    image_service.* = image.NanoBananaImageService.init(io, http, cfg.image_generation_model, cfg.image_generation_output_dir);
    const scripted_want_detector = try allocator.create(want_achievement.ScriptedWantAchievementDetector);
    scripted_want_detector.* = .{};
    const want_detector = try allocator.create(want_achievement.RandomProviderWantAchievementDetector);
    want_detector.* = want_achievement.RandomProviderWantAchievementDetector.init(io, http, cfg.conversation_models, parseReasoningEffort(cfg.conversation_reasoning_effort));

    return .{ .host = .{
        .io = io,
        .capabilities = host_capabilities,
        .camera = frontend_camera.camera(),
        .recognizer = selected_recognizer,
        .face_picture_updater = selected_face_picture_updater,
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
        .output = local_output.output(),
        .system_senses = senses.senses(),
        .clock = local_clock.clock(),
        .filesystem = local_filesystem.filesystem(),
        .process_runner = local_process_runner.runner(),
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
            .datetime = try clock_mod.nowTimestamp(allocator, self.io),
            .unix_seconds = clock_mod.nowSeconds(self.io),
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
