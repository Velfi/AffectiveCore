const std = @import("std");
const service_errors = @import("service_errors.zig");
const http_transport = @import("http_transport.zig");
const image_port = @import("../core/port_image.zig");

pub const GeneratedImage = image_port.GeneratedImage;
pub const ImageGenerationService = image_port.ImageGenerationService;

pub const NanoBananaImageService = struct {
    io: std.Io,
    http: http_transport.Client,
    model: []const u8,
    output_dir: []const u8,

    pub fn init(io: std.Io, http: http_transport.Client, model: []const u8, output_dir: []const u8) NanoBananaImageService {
        return initHostManaged(io, http, model, output_dir);
    }

    pub fn initHostManaged(io: std.Io, http: http_transport.Client, model: []const u8, output_dir: []const u8) NanoBananaImageService {
        return .{
            .io = io,
            .http = http,
            .model = model,
            .output_dir = output_dir,
        };
    }

    pub fn service(self: *NanoBananaImageService) ImageGenerationService {
        return .{ .ctx = self, .generateFn = generate };
    }

    fn generate(ctx: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8) !GeneratedImage {
        const self: *NanoBananaImageService = @ptrCast(@alignCast(ctx));
        _ = self.io;
        _ = self.model;
        if (prompt.len == 0) return error.EmptyImagePrompt;
        const body = try buildHostImageGenerationBody(allocator, prompt, self.output_dir);
        const response = try self.http.postJson(allocator, .{
            .url = "affective-host://image/generate",
            .body = body,
            .max_response_bytes = 1024 * 1024,
        });
        defer allocator.free(response);

        const Response = struct {
            path: []const u8,
            mime_type: []const u8,
        };
        const parsed = std.json.parseFromSlice(Response, allocator, response, .{ .ignore_unknown_fields = true }) catch return service_errors.responseShapeError(allocator, response);
        defer parsed.deinit();
        if (parsed.value.path.len == 0) return error.NoGeneratedImage;
        if (parsed.value.mime_type.len == 0) return error.ImageMimeTypeMissing;
        return .{
            .path = try allocator.dupe(u8, parsed.value.path),
            .mime_type = try allocator.dupe(u8, parsed.value.mime_type),
        };
    }
};

pub const TestImageGenerationService = struct {
    path: []const u8 = "data/test/test_generated_image.png",
    mime_type: []const u8 = "image/png",
    last_prompt: ?[]const u8 = null,

    pub fn service(self: *TestImageGenerationService) ImageGenerationService {
        return .{ .ctx = self, .generateFn = generate };
    }

    fn generate(ctx: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8) !GeneratedImage {
        const self: *TestImageGenerationService = @ptrCast(@alignCast(ctx));
        if (prompt.len == 0) return error.EmptyImagePrompt;
        self.last_prompt = try allocator.dupe(u8, prompt);
        return .{
            .path = try allocator.dupe(u8, self.path),
            .mime_type = try allocator.dupe(u8, self.mime_type),
        };
    }
};

fn buildHostImageGenerationBody(allocator: std.mem.Allocator, prompt: []const u8, output_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"prompt\":{s},\"output_dir\":{s}}}",
        .{ try jsonString(allocator, prompt), try jsonString(allocator, output_dir) },
    );
}

fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, text, .{});
}

const CapturingImageHttpTransport = struct {
    url: []const u8 = "",
    body: []const u8 = "",

    fn client(self: *CapturingImageHttpTransport) http_transport.Client {
        return .{ .ctx = self, .postJsonFn = CapturingImageHttpTransport.postJson };
    }

    fn postJson(ctx: *anyopaque, allocator: std.mem.Allocator, request: http_transport.JsonPostRequest) ![]u8 {
        const self: *CapturingImageHttpTransport = @ptrCast(@alignCast(ctx));
        self.url = request.url;
        self.body = try allocator.dupe(u8, request.body);
        return try allocator.dupe(u8,
            \\{"path":"/tmp/affective/generated/image.png","mime_type":"image/png"}
        );
    }
};

test "default image generation construction routes through host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    var transport = CapturingImageHttpTransport{};
    var service = NanoBananaImageService.init(
        io_threaded.io(),
        transport.client(),
        "gemini-3.1-flash-image",
        "/tmp/affective/generated",
    );

    const image = try service.service().generate(allocator, "a watercolor lighthouse");

    try std.testing.expectEqualStrings("/tmp/affective/generated/image.png", image.path);
    try std.testing.expectEqualStrings("image/png", image.mime_type);
    try std.testing.expectEqualStrings("affective-host://image/generate", transport.url);
    try std.testing.expect(std.mem.indexOf(u8, transport.body, "\"prompt\":\"a watercolor lighthouse\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.body, "\"output_dir\":\"/tmp/affective/generated\"") != null);
}
