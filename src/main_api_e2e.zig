const std = @import("std");
const config_mod = @import("core/config.zig");
const ai = @import("api/random_provider_client.zig");
const http_transport_mod = @import("api/http_transport.zig");
const image_api = @import("api/image_client.zig");
const main_http_transport = @import("main_http_transport.zig");

const Provider = enum {
    openai,
    anthropic,
    google,
};

const ProviderModel = struct {
    provider: Provider,
    model: []const u8,
};

const ok_schema =
    \\{"type":"object","additionalProperties":false,"required":["ok"],"properties":{"ok":{"type":"boolean"}}}
;

const vision_fixture_path = "data/test/image.png";

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.skip();
    var args_list: std.ArrayList([]const u8) = .empty;
    while (args_iter.next()) |arg| try args_list.append(allocator, arg);

    const args_cfg = try config_mod.Config.fromArgs(args_list.items);
    const cfg = try (try args_cfg.withLlmConfig(allocator, init.io)).withBrainPaths(allocator, init.environ_map);
    const models = try parseProviderModels(allocator, cfg.conversation_models);
    try requireProviderKeys(init.environ_map, models);
    var http_transport = main_http_transport.StdHttpTransport.init(init.io);
    const http = http_transport.client();

    const image_path = try requireVisionFixture(allocator, init.io);
    std.debug.print("API_E2E image_fixture path={s}\n", .{image_path});

    for (models) |model| {
        try runTextJsonContract(allocator, init.io, http, init.environ_map, model);
        try runVisionJsonContract(allocator, init.io, http, init.environ_map, model, image_path);
    }

    var health_client = ai.RandomProviderClient.init(init.io, http, init.environ_map, cfg.conversation_models);
    var health_total: usize = 0;
    health_total += try health_client.checkTextRoutes(allocator, "conversation", cfg.conversation_models);
    if (cfg.psyche_models.len > 0) {
        health_total += try health_client.checkTextRoutes(allocator, "psyche", cfg.psyche_models);
    }
    if (health_total == 0) return error.NoApiHealthRoutesChecked;

    try runImageGenerationContract(allocator, init.io, http, init.environ_map, cfg.image_generation_model, cfg.image_generation_output_dir);

    std.debug.print("API_E2E done providers={d} health_routes={d}\n", .{ models.len, health_total });
}

fn runTextJsonContract(allocator: std.mem.Allocator, io: std.Io, http: http_transport_mod.Client, env: *const std.process.Environ.Map, model: ProviderModel) !void {
    std.debug.print("API_E2E start kind=text-json provider={s} model={s}\n", .{ providerName(model.provider), model.model });
    const spec = try modelSpec(allocator, model);
    var client = ai.RandomProviderClient.init(io, http, env, spec);
    const content = try client.completeText(allocator, .{
        .subsystem = "api_e2e_text",
        .system_prompt = "You are a live API contract test. Return only the requested JSON object.",
        .user_prompt = "Return exactly this JSON object and nothing else: {\"ok\":true}",
        .temperature = 0,
        .response_format = .json_object,
        .response_size = .small,
        .json_schema = ok_schema,
    });
    try assertOkJson(allocator, content);
    std.debug.print("API_E2E ok kind=text-json provider={s} model={s}\n", .{ providerName(model.provider), model.model });
}

fn runVisionJsonContract(allocator: std.mem.Allocator, io: std.Io, http: http_transport_mod.Client, env: *const std.process.Environ.Map, model: ProviderModel, image_path: []const u8) !void {
    std.debug.print("API_E2E start kind=vision-json provider={s} model={s}\n", .{ providerName(model.provider), model.model });
    const spec = try modelSpec(allocator, model);
    var client = ai.RandomProviderClient.init(io, http, env, spec);
    const content = try client.completeVision(allocator, .{
        .subsystem = "api_e2e_vision",
        .prompt = "This is a live API contract test. Return exactly this JSON object and nothing else: {\"ok\":true}",
        .image_paths = &[_][]const u8{image_path},
        .temperature = 0,
        .response_format = .json_object,
        .response_size = .small,
        .json_schema = ok_schema,
    });
    try assertOkJson(allocator, content);
    std.debug.print("API_E2E ok kind=vision-json provider={s} model={s}\n", .{ providerName(model.provider), model.model });
}

fn runImageGenerationContract(allocator: std.mem.Allocator, io: std.Io, http: http_transport_mod.Client, env: *const std.process.Environ.Map, model: []const u8, output_dir: []const u8) !void {
    std.debug.print("API_E2E start kind=image-generation provider=google model={s}\n", .{model});
    var service_impl = image_api.NanoBananaImageService.init(io, http, env, model, output_dir);
    const service = service_impl.service();
    const image = try service.generate(allocator, "Live API contract test: generate a single small plain blue square on a white background. No text.");
    if (!isKnownImageMime(image.mime_type)) return error.UnexpectedGeneratedImageMimeType;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, image.path, allocator, .limited(20 * 1024 * 1024));
    if (bytes.len == 0) return error.EmptyGeneratedImageFile;
    std.debug.print("API_E2E ok kind=image-generation provider=google model={s} path={s} mime={s} bytes={d}\n", .{ model, image.path, image.mime_type, bytes.len });
}

fn assertOkJson(allocator: std.mem.Allocator, body: []const u8) !void {
    const Wire = struct { ok: bool };
    const parsed = try std.json.parseFromSlice(Wire, allocator, body, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    if (!parsed.value.ok) return error.ApiE2ENotOk;
}

fn requireVisionFixture(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, vision_fixture_path, allocator, .limited(20 * 1024 * 1024));
    if (bytes.len == 0) return error.EmptyVisionFixture;
    return vision_fixture_path;
}

fn requireProviderKeys(env: *const std.process.Environ.Map, models: []const ProviderModel) !void {
    for (models) |model| {
        switch (model.provider) {
            .openai => if (env.get("OPENAI_API_KEY") == null) return error.MissingOpenAIAPIKey,
            .anthropic => if (env.get("ANTHROPIC_API_KEY") == null) return error.MissingAnthropicAPIKey,
            .google => if (googleApiKey(env) == null) return error.MissingGoogleAPIKey,
        }
    }
}

fn googleApiKey(env: *const std.process.Environ.Map) ?[]const u8 {
    return env.get("GEMINI_API_KEY") orelse env.get("GOOGLE_API_KEY") orelse env.get("GOOGLE_AI_API_KEY");
}

fn parseProviderModels(allocator: std.mem.Allocator, spec: []const u8) ![]ProviderModel {
    const text = std.mem.trim(u8, spec, " \r\n\t");
    if (text.len == 0) return error.NoRandomProviderModels;

    var out: std.ArrayList(ProviderModel) = .empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \r\n\t");
        if (part.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidRandomProviderModel;
        const provider_text = std.mem.trim(u8, part[0..sep], " \r\n\t");
        const model_text = std.mem.trim(u8, part[sep + 1 ..], " \r\n\t");
        if (provider_text.len == 0 or model_text.len == 0) return error.InvalidRandomProviderModel;
        try out.append(allocator, .{
            .provider = parseProvider(provider_text) orelse return error.InvalidRandomProvider,
            .model = model_text,
        });
    }
    if (out.items.len == 0) return error.NoRandomProviderModels;
    return try out.toOwnedSlice(allocator);
}

fn parseProvider(text: []const u8) ?Provider {
    if (std.ascii.eqlIgnoreCase(text, "openai")) return .openai;
    if (std.ascii.eqlIgnoreCase(text, "anthropic")) return .anthropic;
    if (std.ascii.eqlIgnoreCase(text, "google") or std.ascii.eqlIgnoreCase(text, "gemini")) return .google;
    return null;
}

fn modelSpec(allocator: std.mem.Allocator, model: ProviderModel) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ providerName(model.provider), model.model });
}

fn providerName(provider: Provider) []const u8 {
    return switch (provider) {
        .openai => "openai",
        .anthropic => "anthropic",
        .google => "google",
    };
}

fn isKnownImageMime(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "image/png") or
        std.mem.eql(u8, mime_type, "image/jpeg") or
        std.mem.eql(u8, mime_type, "image/webp");
}
