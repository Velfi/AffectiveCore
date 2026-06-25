const std = @import("std");
const files = @import("../platform/common/files.zig");
const service_errors = @import("service_errors.zig");
const http_transport = @import("http_transport.zig");

pub const GeneratedImage = struct {
    path: []const u8,
    mime_type: []const u8,
};

pub const ImageGenerationService = struct {
    ctx: *anyopaque,
    generateFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!GeneratedImage,

    pub fn generate(self: ImageGenerationService, allocator: std.mem.Allocator, prompt: []const u8) !GeneratedImage {
        return self.generateFn(self.ctx, allocator, prompt);
    }
};

pub const NanoBananaImageService = struct {
    io: std.Io,
    http: http_transport.Client,
    api_key: ?[]const u8,
    model: []const u8,
    output_dir: []const u8,

    pub fn init(io: std.Io, http: http_transport.Client, env: *const std.process.Environ.Map, model: []const u8, output_dir: []const u8) NanoBananaImageService {
        return .{
            .io = io,
            .http = http,
            .api_key = env.get("GEMINI_API_KEY") orelse env.get("GOOGLE_API_KEY") orelse env.get("GOOGLE_AI_API_KEY"),
            .model = model,
            .output_dir = output_dir,
        };
    }

    pub fn service(self: *NanoBananaImageService) ImageGenerationService {
        return .{ .ctx = self, .generateFn = generate };
    }

    fn generate(ctx: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8) !GeneratedImage {
        const self: *NanoBananaImageService = @ptrCast(@alignCast(ctx));
        const api_key = self.api_key orelse return error.MissingGeminiApiKey;
        if (prompt.len == 0) return error.EmptyImagePrompt;

        const body = try buildGenerateContentRequestBody(allocator, prompt);
        const url = try std.fmt.allocPrint(allocator, "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent?key={s}", .{ self.model, api_key });
        var attempt: usize = 0;
        const image = while (true) : (attempt += 1) {
            const response = try self.http.postJson(allocator, .{
                .url = url,
                .body = body,
                .max_response_bytes = 1024 * 1024,
            });
            defer allocator.free(response);

            break extractGeneratedImage(allocator, response) catch |err| {
                if (err == error.ImageGenerationApiError) {
                    try printImageGenerationApiError(allocator, response);
                    if (service_errors.shouldRetry(error.RemoteServiceFailed, attempt)) {
                        service_errors.logRemoteRetry("image_generation", "google", self.model, attempt);
                        continue;
                    }
                    return error.RemoteServiceFailed;
                }
                return err;
            };
        };
        const ext = extensionForMime(image.mime_type);
        const path = try std.fmt.allocPrint(allocator, "{s}/image_{d}.{s}", .{ self.output_dir, std.Io.Clock.real.now(self.io).toMilliseconds(), ext });
        try writeBase64Image(allocator, self.io, path, image.data);
        return .{ .path = path, .mime_type = try allocator.dupe(u8, image.mime_type) };
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

const ExtractedImage = struct {
    data: []const u8,
    mime_type: []const u8,
};

fn buildGenerateContentRequestBody(allocator: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"contents\":[{{\"role\":\"user\",\"parts\":[{{\"text\":{s}}}]}}],\"generationConfig\":{{\"responseModalities\":[\"TEXT\",\"IMAGE\"]}}}}",
        .{try jsonString(allocator, prompt)},
    );
}

fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, text, .{});
}

fn extractGeneratedImage(allocator: std.mem.Allocator, body: []const u8) !ExtractedImage {
    const Response = struct {
        const ApiError = struct {
            code: ?i64 = null,
            message: []const u8 = "",
            status: []const u8 = "",
        };
        const InlineDataCamel = struct {
            data: []const u8,
            mimeType: ?[]const u8 = null,
        };
        const InlineDataSnake = struct {
            data: []const u8,
            mime_type: ?[]const u8 = null,
        };

        @"error": ?ApiError = null,
        output_image: ?struct {
            data: []const u8,
            mime_type: ?[]const u8 = null,
        } = null,
        candidates: []struct {
            content: struct {
                parts: []struct {
                    inlineData: ?InlineDataCamel = null,
                    inline_data: ?InlineDataSnake = null,
                } = &.{},
            } = .{},
        } = &.{},
        steps: []struct {
            type: []const u8 = "",
            content: []struct {
                type: []const u8 = "",
                data: ?[]const u8 = null,
                mime_type: ?[]const u8 = null,
            } = &.{},
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(Response, allocator, body, .{ .ignore_unknown_fields = true }) catch return service_errors.responseShapeError(allocator, body);
    defer parsed.deinit();

    if (parsed.value.@"error") |api_error| {
        _ = api_error;
        return error.ImageGenerationApiError;
    }

    if (parsed.value.output_image) |image| {
        return normalizeExtractedImageData(allocator, image.data, image.mime_type orelse return error.ImageMimeTypeMissing);
    }

    for (parsed.value.candidates) |candidate| {
        for (candidate.content.parts) |part| {
            if (part.inlineData) |inline_data| {
                return normalizeExtractedImageData(allocator, inline_data.data, inline_data.mimeType orelse return error.ImageMimeTypeMissing);
            }
            if (part.inline_data) |inline_data| {
                return normalizeExtractedImageData(allocator, inline_data.data, inline_data.mime_type orelse return error.ImageMimeTypeMissing);
            }
        }
    }

    for (parsed.value.steps) |step| {
        if (!std.mem.eql(u8, step.type, "model_output")) continue;
        for (step.content) |block| {
            if (!std.mem.eql(u8, block.type, "image")) continue;
            const data = block.data orelse return error.ImageDataMissing;
            return normalizeExtractedImageData(allocator, data, block.mime_type orelse return error.ImageMimeTypeMissing);
        }
    }

    return error.NoGeneratedImage;
}

fn normalizeExtractedImageData(allocator: std.mem.Allocator, data: []const u8, mime_type: []const u8) !ExtractedImage {
    if (!std.mem.startsWith(u8, data, "data:")) {
        if (std.mem.trim(u8, mime_type, " \r\n\t").len == 0) return error.ImageMimeTypeMissing;
        return .{
            .data = try allocator.dupe(u8, data),
            .mime_type = try allocator.dupe(u8, mime_type),
        };
    }

    const comma = std.mem.indexOfScalar(u8, data, ',') orelse return error.InvalidImageDataUrl;
    const header = data["data:".len..comma];
    const marker = ";base64";
    const marker_index = std.mem.indexOf(u8, header, marker) orelse return error.InvalidImageDataUrl;
    const parsed_mime_type = header[0..marker_index];
    if (parsed_mime_type.len == 0) return error.InvalidImageDataUrl;
    const encoded = data[comma + 1 ..];
    if (encoded.len == 0) return error.ImageDataMissing;
    return .{
        .data = try allocator.dupe(u8, encoded),
        .mime_type = try allocator.dupe(u8, parsed_mime_type),
    };
}

fn printImageGenerationApiError(allocator: std.mem.Allocator, body: []const u8) !void {
    const ErrorBody = struct {
        @"error": ?struct {
            code: ?i64 = null,
            message: []const u8 = "",
            status: []const u8 = "",
        } = null,
    };
    const parsed = try std.json.parseFromSlice(ErrorBody, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const api_error = parsed.value.@"error" orelse return;
    std.debug.print("IMAGE GENERATION API ERROR: status={s} code={?d} message={s}\n", .{ api_error.status, api_error.code, api_error.message });
}

fn writeBase64Image(allocator: std.mem.Allocator, io: std.Io, path: []const u8, encoded: []const u8) !void {
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const bytes = try allocator.alloc(u8, size);
    try std.base64.standard.Decoder.decode(bytes, encoded);
    try files.writeFilePath(io, path, bytes);
}

fn extensionForMime(mime_type: []const u8) []const u8 {
    if (std.mem.eql(u8, mime_type, "image/jpeg")) return "jpg";
    if (std.mem.eql(u8, mime_type, "image/webp")) return "webp";
    if (std.mem.eql(u8, mime_type, "image/png")) return "png";
    return "img";
}

test "Gemini image request uses generateContent shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try buildGenerateContentRequestBody(arena.allocator(), "a brass automaton tending moonflowers");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"contents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"responseModalities\":[\"TEXT\",\"IMAGE\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"response_format\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\"") == null);
}

test "extractGeneratedImage reads output_image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const image = try extractGeneratedImage(arena.allocator(),
        \\{"output_image":{"data":"aGVsbG8=","mime_type":"image/png"}}
    );
    try std.testing.expectEqualStrings("aGVsbG8=", image.data);
    try std.testing.expectEqualStrings("image/png", image.mime_type);
}

test "extractGeneratedImage normalizes data url image payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const image = try extractGeneratedImage(arena.allocator(),
        \\{"output_image":{"data":"data:image/webp;base64,aGVsbG8=","mime_type":"image/png"}}
    );
    try std.testing.expectEqualStrings("aGVsbG8=", image.data);
    try std.testing.expectEqualStrings("image/webp", image.mime_type);
}

test "extractGeneratedImage rejects malformed data url image payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidImageDataUrl, extractGeneratedImage(arena.allocator(),
        \\{"output_image":{"data":"data:image/png,aGVsbG8=","mime_type":"image/png"}}
    ));
}

test "extractGeneratedImage reads model output step image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const image = try extractGeneratedImage(arena.allocator(),
        \\{"steps":[{"type":"model_output","content":[{"type":"image","data":"aGVsbG8=","mime_type":"image/jpeg"}]}]}
    );
    try std.testing.expectEqualStrings("aGVsbG8=", image.data);
    try std.testing.expectEqualStrings("image/jpeg", image.mime_type);
}

test "extractGeneratedImage reads Gemini candidate inlineData" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const image = try extractGeneratedImage(arena.allocator(),
        \\{"candidates":[{"content":{"parts":[{"text":"Here is the image."},{"inlineData":{"mimeType":"image/png","data":"aGVsbG8="}}]}}]}
    );
    try std.testing.expectEqualStrings("aGVsbG8=", image.data);
    try std.testing.expectEqualStrings("image/png", image.mime_type);
}

test "extractGeneratedImage reads Gemini candidate inline_data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const image = try extractGeneratedImage(arena.allocator(),
        \\{"candidates":[{"content":{"parts":[{"inline_data":{"mime_type":"image/webp","data":"aGVsbG8="}}]}}]}
    );
    try std.testing.expectEqualStrings("aGVsbG8=", image.data);
    try std.testing.expectEqualStrings("image/webp", image.mime_type);
}

test "extractGeneratedImage surfaces API error bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ImageGenerationApiError, extractGeneratedImage(arena.allocator(),
        \\{"error":{"code":400,"message":"bad image request","status":"INVALID_ARGUMENT"}}
    ));
}
