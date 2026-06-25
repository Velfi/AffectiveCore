const std = @import("std");
const ai = @import("api/random_provider_client.zig");
const config_mod = @import("core/config.zig");
const http_transport_mod = @import("api/http_transport.zig");
const image_api = @import("api/image_client.zig");
const files = @import("platform/common/files.zig");

const EmbeddedE2EProvider = enum {
    openai,
    anthropic,
    google,
};

const EmbeddedE2EProviderModel = struct {
    provider: EmbeddedE2EProvider,
    model: []const u8,
};

const embedded_e2e_ok_schema =
    \\{"type":"object","additionalProperties":false,"required":["ok"],"properties":{"ok":{"type":"boolean"}}}
;

const embedded_e2e_fixture_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
    0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41,
    0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
    0x00, 0x03, 0x01, 0x01, 0x00, 0xc9, 0xfe, 0x92,
    0xef, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
    0x44, 0xae, 0x42, 0x60, 0x82,
};

pub fn runApiE2E(allocator: std.mem.Allocator, io: std.Io, http: http_transport_mod.Client, env: *const std.process.Environ.Map, cfg: config_mod.Config) ![]const u8 {
    const models = try parseEmbeddedE2EProviderModels(allocator, cfg.conversation_models);
    try requireEmbeddedE2EProviderKeys(env, models);
    const image_path = try writeEmbeddedE2EVisionFixture(allocator, io, cfg.brain_root);

    for (models) |model| {
        try runEmbeddedE2ETextJsonContract(allocator, io, http, env, model);
        try runEmbeddedE2EVisionJsonContract(allocator, io, http, env, model, image_path);
    }

    var health_client = ai.RandomProviderClient.init(io, http, env, cfg.conversation_models);
    const health_total = try health_client.checkTextRoutes(allocator, "embedded_api_e2e", cfg.conversation_models);
    if (health_total == 0) return error.NoApiHealthRoutesChecked;

    var image_checked = false;
    var generated_image_bytes: usize = 0;
    if (googleApiKey(env) != null) {
        const image = try runEmbeddedE2EImageGenerationContract(allocator, io, http, env, cfg.image_generation_model, cfg.image_generation_output_dir);
        image_checked = true;
        generated_image_bytes = image.bytes;
    }

    return std.json.Stringify.valueAlloc(std.heap.page_allocator, struct {
        ok: bool,
        text_json_contracts: usize,
        vision_json_contracts: usize,
        health_routes: usize,
        image_generation_checked: bool,
        image_generation_bytes: usize,
    }{
        .ok = true,
        .text_json_contracts = models.len,
        .vision_json_contracts = models.len,
        .health_routes = health_total,
        .image_generation_checked = image_checked,
        .image_generation_bytes = generated_image_bytes,
    }, .{ .whitespace = .indent_2 });
}

fn runEmbeddedE2ETextJsonContract(allocator: std.mem.Allocator, io: std.Io, http: http_transport_mod.Client, env: *const std.process.Environ.Map, model: EmbeddedE2EProviderModel) !void {
    std.debug.print("EMBEDDED_API_E2E start kind=text-json provider={s} model={s}\n", .{ embeddedE2EProviderName(model.provider), model.model });
    const spec = try embeddedE2EModelSpec(allocator, model);
    var client = ai.RandomProviderClient.init(io, http, env, spec);
    const content = try client.completeText(allocator, .{
        .subsystem = "embedded_api_e2e_text",
        .system_prompt = "You are a live API contract test. Return only the requested JSON object.",
        .user_prompt = "Return exactly this JSON object and nothing else: {\"ok\":true}",
        .temperature = 0,
        .response_format = .json_object,
        .response_size = .small,
        .json_schema = embedded_e2e_ok_schema,
    });
    try assertEmbeddedE2EOkJson(allocator, content);
    std.debug.print("EMBEDDED_API_E2E ok kind=text-json provider={s} model={s}\n", .{ embeddedE2EProviderName(model.provider), model.model });
}

fn runEmbeddedE2EVisionJsonContract(allocator: std.mem.Allocator, io: std.Io, http: http_transport_mod.Client, env: *const std.process.Environ.Map, model: EmbeddedE2EProviderModel, image_path: []const u8) !void {
    std.debug.print("EMBEDDED_API_E2E start kind=vision-json provider={s} model={s}\n", .{ embeddedE2EProviderName(model.provider), model.model });
    const spec = try embeddedE2EModelSpec(allocator, model);
    var client = ai.RandomProviderClient.init(io, http, env, spec);
    const content = try client.completeVision(allocator, .{
        .subsystem = "embedded_api_e2e_vision",
        .prompt = "This is a live API contract test. Return exactly this JSON object and nothing else: {\"ok\":true}",
        .image_paths = &[_][]const u8{image_path},
        .temperature = 0,
        .response_format = .json_object,
        .response_size = .small,
        .json_schema = embedded_e2e_ok_schema,
    });
    try assertEmbeddedE2EOkJson(allocator, content);
    std.debug.print("EMBEDDED_API_E2E ok kind=vision-json provider={s} model={s}\n", .{ embeddedE2EProviderName(model.provider), model.model });
}

fn runEmbeddedE2EImageGenerationContract(allocator: std.mem.Allocator, io: std.Io, http: http_transport_mod.Client, env: *const std.process.Environ.Map, model: []const u8, output_dir: []const u8) !struct { bytes: usize } {
    std.debug.print("EMBEDDED_API_E2E start kind=image-generation provider=google model={s}\n", .{model});
    var service_impl = image_api.NanoBananaImageService.init(io, http, env, model, output_dir);
    const service = service_impl.service();
    const image = try service.generate(allocator, "Live embedded API contract test: generate a single small plain blue square on a white background. No text.");
    if (!isKnownImageMime(image.mime_type)) return error.UnexpectedGeneratedImageMimeType;
    const bytes = try files.readFileAllocPath(io, image.path, allocator, .limited(20 * 1024 * 1024));
    if (bytes.len == 0) return error.EmptyGeneratedImageFile;
    std.debug.print("EMBEDDED_API_E2E ok kind=image-generation provider=google model={s} path={s} mime={s} bytes={d}\n", .{ model, image.path, image.mime_type, bytes.len });
    return .{ .bytes = bytes.len };
}

fn assertEmbeddedE2EOkJson(allocator: std.mem.Allocator, body: []const u8) !void {
    const Wire = struct { ok: bool };
    const parsed = try std.json.parseFromSlice(Wire, allocator, body, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    if (!parsed.value.ok) return error.ApiE2ENotOk;
}

fn writeEmbeddedE2EVisionFixture(allocator: std.mem.Allocator, io: std.Io, brain_root: []const u8) ![]const u8 {
    const dir = try std.fs.path.join(allocator, &.{ brain_root, "generated", "e2e" });
    try files.ensureDir(io, dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "vision-fixture.png" });
    try files.writeFilePath(io, path, &embedded_e2e_fixture_png);
    return path;
}

fn parseEmbeddedE2EProviderModels(allocator: std.mem.Allocator, spec: []const u8) ![]EmbeddedE2EProviderModel {
    const text = std.mem.trim(u8, spec, " \r\n\t");
    if (text.len == 0) return error.NoRandomProviderModels;
    var out = std.ArrayList(EmbeddedE2EProviderModel).empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \r\n\t");
        if (part.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidRandomProviderModel;
        const provider_text = std.mem.trim(u8, part[0..sep], " \r\n\t");
        const model_text = std.mem.trim(u8, part[sep + 1 ..], " \r\n\t");
        if (provider_text.len == 0 or model_text.len == 0) return error.InvalidRandomProviderModel;
        try out.append(allocator, .{
            .provider = parseEmbeddedE2EProvider(provider_text) orelse return error.InvalidRandomProvider,
            .model = model_text,
        });
    }
    if (out.items.len == 0) return error.NoRandomProviderModels;
    return try out.toOwnedSlice(allocator);
}

fn parseEmbeddedE2EProvider(text: []const u8) ?EmbeddedE2EProvider {
    if (std.ascii.eqlIgnoreCase(text, "openai")) return .openai;
    if (std.ascii.eqlIgnoreCase(text, "anthropic")) return .anthropic;
    if (std.ascii.eqlIgnoreCase(text, "google") or std.ascii.eqlIgnoreCase(text, "gemini")) return .google;
    return null;
}

fn requireEmbeddedE2EProviderKeys(env: *const std.process.Environ.Map, models: []const EmbeddedE2EProviderModel) !void {
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

fn embeddedE2EModelSpec(allocator: std.mem.Allocator, model: EmbeddedE2EProviderModel) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ embeddedE2EProviderName(model.provider), model.model });
}

fn embeddedE2EProviderName(provider: EmbeddedE2EProvider) []const u8 {
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
