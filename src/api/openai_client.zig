const std = @import("std");
const files = @import("../platform/common/files.zig");
const process = @import("../platform/common/process.zig");
const service_errors = @import("service_errors.zig");
const ai = @import("random_provider_client.zig");
const identity = @import("openai_identity_client.zig");

pub const VISUAL_DESCRIPTION_POLICY =
    \\Describe visible, non-sensitive appearance details useful for the brain's memory.
    \\Do not infer identity, race, ethnicity, gender identity, age, health, disability, attractiveness, emotional state, or socioeconomic status.
    \\Focus on clothing, accessories, carried items, hair/clothing changes, and other non-sensitive visual details.
    \\Set change_summary to an empty string when there is no visible change from prior notes; do not describe the absence of change.
    \\Return only JSON matching the required schema.
;

const visual_description_response_format =
    \\,"response_format":{"type":"json_schema","json_schema":{"name":"visual_description","strict":true,"schema":{"type":"object","additionalProperties":false,"required":["description","change_summary","durable_notes","temporary_notes"],"properties":{"description":{"type":"string"},"change_summary":{"type":"string"},"durable_notes":{"type":"array","items":{"type":"string"}},"temporary_notes":{"type":"array","items":{"type":"string"}}}}}}
;

const visual_description_json_schema =
    \\{"type":"object","additionalProperties":false,"required":["description","change_summary","durable_notes","temporary_notes"],"properties":{"description":{"type":"string"},"change_summary":{"type":"string"},"durable_notes":{"type":"array","items":{"type":"string"}},"temporary_notes":{"type":"array","items":{"type":"string"}}}}
;

pub const VisualDescription = struct {
    description: []const u8,
    change_summary: []const u8,
    durable_notes: []const []const u8,
    temporary_notes: []const []const u8,
};

pub const IdentityComparison = struct {
    same_person: bool,
    confidence: f32,
    reason: []const u8,
};

pub const IdentityComparisonService = struct {
    ctx: *anyopaque,
    compareFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!IdentityComparison,

    pub fn compareDescriptions(self: IdentityComparisonService, allocator: std.mem.Allocator, current_description: []const u8, stored_description: []const u8) !IdentityComparison {
        return self.compareFn(self.ctx, allocator, current_description, stored_description);
    }
};

pub const DescriptionService = struct {
    ctx: *anyopaque,
    describeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!VisualDescription,
    describeImageFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror![]const u8,
    compareImagesFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, []const u8) anyerror![]const u8,

    pub fn describePerson(self: DescriptionService, allocator: std.mem.Allocator, image_path: []const u8, prior_notes: []const u8) !VisualDescription {
        return self.describeFn(self.ctx, allocator, image_path, prior_notes);
    }

    pub fn describeImage(self: DescriptionService, allocator: std.mem.Allocator, image_path: []const u8, prompt: []const u8) ![]const u8 {
        return self.describeImageFn(self.ctx, allocator, image_path, prompt);
    }

    pub fn compareImages(self: DescriptionService, allocator: std.mem.Allocator, before_image_path: []const u8, after_image_path: []const u8, prompt: []const u8) ![]const u8 {
        return self.compareImagesFn(self.ctx, allocator, before_image_path, after_image_path, prompt);
    }
};

pub const OpenAIClient = struct {
    api_key: ?[]const u8,
    vision_model: []const u8,
    text_model: []const u8,
    intent_model: []const u8,
    tts_model: []const u8,
    tts_voice: []const u8,

    pub fn fromEnv(env: *const std.process.Environ.Map) OpenAIClient {
        return .{
            .api_key = env.get("OPENAI_API_KEY"),
            .vision_model = env.get("OPENAI_VISION_MODEL") orelse "gpt-4.1-mini",
            .text_model = env.get("OPENAI_TEXT_MODEL") orelse "gpt-4.1-mini",
            .intent_model = env.get("OPENAI_INTENT_MODEL") orelse "gpt-4.1-nano",
            .tts_model = env.get("OPENAI_TTS_MODEL") orelse "gpt-4o-mini-tts",
            .tts_voice = env.get("OPENAI_TTS_VOICE") orelse "alloy",
        };
    }

    pub fn buildDescriptionPrompt(_: OpenAIClient, allocator: std.mem.Allocator, prior_notes: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}\nPrior non-sensitive notes:\n{s}", .{ VISUAL_DESCRIPTION_POLICY, prior_notes });
    }
};

pub const OpenAIDescriptionService = struct {
    io: std.Io,
    client: OpenAIClient,

    pub fn init(io: std.Io, client: OpenAIClient) OpenAIDescriptionService {
        return .{ .io = io, .client = client };
    }

    pub fn service(self: *OpenAIDescriptionService) DescriptionService {
        return .{
            .ctx = self,
            .describeFn = describePerson,
            .describeImageFn = describeImage,
            .compareImagesFn = compareImages,
        };
    }

    fn describePerson(ctx: *anyopaque, allocator: std.mem.Allocator, image_path: []const u8, prior_notes: []const u8) !VisualDescription {
        const self: *OpenAIDescriptionService = @ptrCast(@alignCast(ctx));
        const prompt = try self.client.buildDescriptionPrompt(allocator, prior_notes);
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const content = self.callVisionJson(allocator, prompt, &[_][]const u8{image_path}) catch |err| {
                if (service_errors.shouldRetry(err, attempt)) {
                    service_errors.logRemoteRetry("vision_description", "openai", self.client.vision_model, attempt);
                    continue;
                }
                return err;
            };
            return parseVisualDescription(allocator, content) catch |err| {
                if (service_errors.shouldRetry(err, attempt)) {
                    service_errors.logRemoteRetry("vision_description", "openai", self.client.vision_model, attempt);
                    continue;
                }
                return err;
            };
        }
    }

    fn describeImage(ctx: *anyopaque, allocator: std.mem.Allocator, image_path: []const u8, prompt: []const u8) ![]const u8 {
        const self: *OpenAIDescriptionService = @ptrCast(@alignCast(ctx));
        const trimmed = std.mem.trim(u8, prompt, " \r\n\t");
        const instruction = if (trimmed.len > 0)
            try std.fmt.allocPrint(allocator, "Write a clear, useful description of this image. Focus only on visible content. User focus: {s}", .{trimmed})
        else
            "Write a clear, useful description of this image. Focus only on visible content.";
        return self.callVisionWithRetry(allocator, instruction, &[_][]const u8{image_path});
    }

    fn compareImages(ctx: *anyopaque, allocator: std.mem.Allocator, before_image_path: []const u8, after_image_path: []const u8, prompt: []const u8) ![]const u8 {
        const self: *OpenAIDescriptionService = @ptrCast(@alignCast(ctx));
        const trimmed = std.mem.trim(u8, prompt, " \r\n\t");
        const instruction = if (trimmed.len > 0)
            try std.fmt.allocPrint(allocator, "Compare image 1 and image 2. Describe meaningful visible similarities and differences. User focus: {s}", .{trimmed})
        else
            "Compare image 1 and image 2. Describe meaningful visible similarities and differences.";
        return self.callVisionWithRetry(allocator, instruction, &[_][]const u8{ before_image_path, after_image_path });
    }

    fn callVisionWithRetry(self: *OpenAIDescriptionService, allocator: std.mem.Allocator, prompt: []const u8, image_paths: []const []const u8) ![]const u8 {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            return self.callVision(allocator, prompt, image_paths) catch |err| {
                if (service_errors.shouldRetry(err, attempt)) {
                    service_errors.logRemoteRetry("vision_description", "openai", self.client.vision_model, attempt);
                    continue;
                }
                return err;
            };
        }
    }

    fn callVision(self: *OpenAIDescriptionService, allocator: std.mem.Allocator, prompt: []const u8, image_paths: []const []const u8) ![]const u8 {
        return self.callVisionWithFormat(allocator, prompt, image_paths, false);
    }

    fn callVisionJson(self: *OpenAIDescriptionService, allocator: std.mem.Allocator, prompt: []const u8, image_paths: []const []const u8) ![]const u8 {
        return self.callVisionWithFormat(allocator, prompt, image_paths, true);
    }

    fn callVisionWithFormat(self: *OpenAIDescriptionService, allocator: std.mem.Allocator, prompt: []const u8, image_paths: []const []const u8, json_mode: bool) ![]const u8 {
        const api_key = self.client.api_key orelse return error.MissingOpenAIAPIKey;
        const body = try buildVisionChatBody(allocator, self.io, self.client.vision_model, prompt, image_paths, json_mode);
        const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
        const out = try process.runCaptureLarge(allocator, self.io, &.{
            "curl",
            "-sS",
            "https://api.openai.com/v1/chat/completions",
            "-H",
            auth,
            "-H",
            "Content-Type: application/json",
            "-d",
            body,
        });
        defer allocator.free(out);
        return extractChatContent(allocator, out);
    }
};

pub const RandomProviderDescriptionService = struct {
    client: *ai.RandomProviderClient,

    pub fn init(client: *ai.RandomProviderClient) RandomProviderDescriptionService {
        return .{ .client = client };
    }

    pub fn service(self: *RandomProviderDescriptionService) DescriptionService {
        return .{
            .ctx = self,
            .describeFn = describePerson,
            .describeImageFn = describeImage,
            .compareImagesFn = compareImages,
        };
    }

    fn describePerson(ctx: *anyopaque, allocator: std.mem.Allocator, image_path: []const u8, prior_notes: []const u8) !VisualDescription {
        const self: *RandomProviderDescriptionService = @ptrCast(@alignCast(ctx));
        const prompt = try std.fmt.allocPrint(allocator, "{s}\nPrior non-sensitive notes:\n{s}", .{ VISUAL_DESCRIPTION_POLICY, prior_notes });
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const content = self.client.completeVision(allocator, .{
                .subsystem = "vision_description",
                .prompt = prompt,
                .image_paths = &[_][]const u8{image_path},
                .temperature = 0.2,
                .response_format = .json_object,
                .response_size = .medium,
                .json_schema = visual_description_json_schema,
            }) catch |err| {
                if (service_errors.shouldRetry(err, attempt)) {
                    service_errors.logRemoteRetry("vision_description", "random", "selected", attempt);
                    continue;
                }
                return err;
            };
            return parseVisualDescription(allocator, content) catch |err| {
                if (service_errors.shouldRetry(err, attempt)) {
                    service_errors.logRemoteRetry("vision_description", "random", "selected", attempt);
                    continue;
                }
                return err;
            };
        }
    }

    fn describeImage(ctx: *anyopaque, allocator: std.mem.Allocator, image_path: []const u8, prompt: []const u8) ![]const u8 {
        const self: *RandomProviderDescriptionService = @ptrCast(@alignCast(ctx));
        const trimmed = std.mem.trim(u8, prompt, " \r\n\t");
        const instruction = if (trimmed.len > 0)
            try std.fmt.allocPrint(allocator, "Write a clear, useful description of this image. Focus only on visible content. User focus: {s}", .{trimmed})
        else
            "Write a clear, useful description of this image. Focus only on visible content.";
        return self.client.completeVision(allocator, .{
            .subsystem = "vision_description",
            .prompt = instruction,
            .image_paths = &[_][]const u8{image_path},
            .temperature = 0.2,
            .response_format = .text,
            .response_size = .medium,
        });
    }

    fn compareImages(ctx: *anyopaque, allocator: std.mem.Allocator, before_image_path: []const u8, after_image_path: []const u8, prompt: []const u8) ![]const u8 {
        const self: *RandomProviderDescriptionService = @ptrCast(@alignCast(ctx));
        const trimmed = std.mem.trim(u8, prompt, " \r\n\t");
        const instruction = if (trimmed.len > 0)
            try std.fmt.allocPrint(allocator, "Compare image 1 and image 2. Describe meaningful visible similarities and differences. User focus: {s}", .{trimmed})
        else
            "Compare image 1 and image 2. Describe meaningful visible similarities and differences.";
        return self.client.completeVision(allocator, .{
            .subsystem = "vision_description",
            .prompt = instruction,
            .image_paths = &[_][]const u8{ before_image_path, after_image_path },
            .temperature = 0.2,
            .response_format = .text,
            .response_size = .medium,
        });
    }
};

pub const TestDescriptionService = struct {
    fail: bool = false,
    missing_image_path: ?[]const u8 = null,

    pub fn service(self: *TestDescriptionService) DescriptionService {
        return .{
            .ctx = self,
            .describeFn = describe,
            .describeImageFn = describeImage,
            .compareImagesFn = compareImages,
        };
    }

    fn describe(ctx: *anyopaque, _: std.mem.Allocator, image_path: []const u8, _: []const u8) !VisualDescription {
        const self: *TestDescriptionService = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.RemoteServiceFailed;
        if (self.missing_image_path) |path| {
            if (std.mem.eql(u8, image_path, path)) return error.FileNotFound;
        }
        if (std.mem.indexOf(u8, image_path, "changed") != null or std.mem.indexOf(u8, image_path, "image2") != null) {
            return .{
                .description = "Wearing a blue jacket and carrying a small bag.",
                .change_summary = "a blue jacket and small bag are visible",
                .durable_notes = &.{"often carries a small bag"},
                .temporary_notes = &.{"blue jacket"},
            };
        }
        return .{
            .description = "Visible clothing and accessories only; no sensitive traits inferred.",
            .change_summary = "",
            .durable_notes = &.{},
            .temporary_notes = &.{},
        };
    }

    fn describeImage(ctx: *anyopaque, allocator: std.mem.Allocator, image_path: []const u8, prompt: []const u8) ![]const u8 {
        const self: *TestDescriptionService = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.RemoteServiceFailed;
        if (self.missing_image_path) |path| {
            if (std.mem.eql(u8, image_path, path)) return error.FileNotFound;
        }
        return std.fmt.allocPrint(allocator, "Test image description for {s}. Focus: {s}", .{ image_path, prompt });
    }

    fn compareImages(ctx: *anyopaque, allocator: std.mem.Allocator, before_image_path: []const u8, after_image_path: []const u8, prompt: []const u8) ![]const u8 {
        const self: *TestDescriptionService = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.RemoteServiceFailed;
        if (self.missing_image_path) |path| {
            if (std.mem.eql(u8, before_image_path, path) or std.mem.eql(u8, after_image_path, path)) return error.FileNotFound;
        }
        return std.fmt.allocPrint(allocator, "Test image comparison between {s} and {s}. Focus: {s}", .{ before_image_path, after_image_path, prompt });
    }
};

fn buildVisionChatBody(allocator: std.mem.Allocator, io: std.Io, model: []const u8, prompt: []const u8, image_paths: []const []const u8, json_mode: bool) ![]const u8 {
    if (image_paths.len == 0) return error.NoImagesProvided;
    var content = std.ArrayList(u8).empty;
    try content.appendSlice(allocator, "[{\"type\":\"text\",\"text\":");
    try content.appendSlice(allocator, try jsonString(allocator, prompt));
    try content.appendSlice(allocator, "}");
    for (image_paths) |image_path| {
        const data_url = try imageDataUrl(allocator, io, image_path);
        try content.appendSlice(allocator, ",{\"type\":\"image_url\",\"image_url\":{\"url\":");
        try content.appendSlice(allocator, try jsonString(allocator, data_url));
        try content.appendSlice(allocator, "}}");
    }
    try content.appendSlice(allocator, "]");
    const response_format = if (json_mode) visual_description_response_format else "";
    return std.fmt.allocPrint(
        allocator,
        "{{\"model\":{s},\"temperature\":0.2{s},\"messages\":[{{\"role\":\"user\",\"content\":{s}}}]}}",
        .{ try jsonString(allocator, model), response_format, content.items },
    );
}

fn imageDataUrl(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) ![]const u8 {
    const bytes = try files.readFileAllocPath(io, image_path, allocator, .limited(20 * 1024 * 1024));
    const size = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, size);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ try mimeTypeForPath(image_path), encoded });
}

fn mimeTypeForPath(path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    return error.UnsupportedImageType;
}

pub fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, text, .{});
}

pub fn extractChatContent(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const Response = struct {
        choices: []struct {
            message: struct {
                content: []const u8,
            },
        },
    };
    const parsed = std.json.parseFromSlice(Response, allocator, body, .{ .ignore_unknown_fields = true }) catch return service_errors.responseShapeError(allocator, body);
    defer parsed.deinit();
    if (parsed.value.choices.len == 0) return error.RemoteServiceFailed;
    return try allocator.dupe(u8, parsed.value.choices[0].message.content);
}

fn parseVisualDescription(allocator: std.mem.Allocator, body: []const u8) !VisualDescription {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| return invalidVisualDescriptionJson(err, body);
    defer parsed.deinit();
    const object = if (parsed.value == .object) parsed.value.object else null;
    return .{
        .description = visualDescriptionText(allocator, parsed.value) catch |err| return invalidVisualDescriptionJson(err, body),
        .change_summary = try allocator.dupe(u8, if (object) |fields| optionalVisualString(fields, "change_summary") orelse "" else ""),
        .durable_notes = if (object) |fields| try optionalVisualStringArray(allocator, fields, "durable_notes") else &.{},
        .temporary_notes = if (object) |fields| try optionalVisualStringArray(allocator, fields, "temporary_notes") else &.{},
    };
}

fn visualDescriptionText(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    if (value == .object) {
        const object = value.object;
        const has_only_canonical_fields = object.count() == 4 and
            object.get("description") != null and
            object.get("change_summary") != null and
            object.get("durable_notes") != null and
            object.get("temporary_notes") != null;
        if (has_only_canonical_fields) {
            if (optionalVisualString(object, "description")) |description| {
                const trimmed = std.mem.trim(u8, description, " \r\n\t");
                if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
            }
        }
    }
    var out = std.ArrayList(u8).empty;
    try appendVisualValue(allocator, &out, "", value);
    if (out.items.len == 0) return error.MissingField;
    return try out.toOwnedSlice(allocator);
}

fn appendVisualValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key_path: []const u8, value: std.json.Value) !void {
    switch (value) {
        .object => |object| {
            var iter = object.iterator();
            while (iter.next()) |entry| {
                const child_key = try visualChildKey(allocator, key_path, entry.key_ptr.*);
                try appendVisualValue(allocator, out, child_key, entry.value_ptr.*);
            }
        },
        .array => {
            try appendVisualLeaf(allocator, out, key_path, try std.json.Stringify.valueAlloc(allocator, value, .{}));
        },
        .string => |text| try appendVisualLeaf(allocator, out, key_path, text),
        .integer, .float, .number_string, .bool, .null => {
            try appendVisualLeaf(allocator, out, key_path, try std.json.Stringify.valueAlloc(allocator, value, .{}));
        },
    }
}

fn visualChildKey(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    const label = try visualDetailLabel(allocator, name);
    if (prefix.len == 0) return label;
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, label });
}

fn appendVisualLeaf(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key_path: []const u8, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \r\n\t");
    if (trimmed.len == 0) return;
    if (out.items.len > 0) try out.appendSlice(allocator, "; ");
    if (key_path.len == 0) {
        try out.appendSlice(allocator, trimmed);
    } else {
        try out.print(allocator, "{s}: {s}", .{ key_path, trimmed });
    }
}

fn visualDetailLabel(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const label = try allocator.dupe(u8, name);
    for (label) |*byte| {
        if (byte.* == '_') byte.* = ' ';
    }
    return label;
}

fn optionalVisualString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn optionalVisualStringArray(allocator: std.mem.Allocator, object: std.json.ObjectMap, name: []const u8) ![]const []const u8 {
    const value = object.get(name) orelse return &.{};
    const array = switch (value) {
        .array => |array| array,
        else => return &.{},
    };
    var out = try allocator.alloc([]const u8, array.items.len);
    for (array.items, 0..) |item, i| {
        out[i] = switch (item) {
            .string => |text| try allocator.dupe(u8, text),
            else => try std.json.Stringify.valueAlloc(allocator, item, .{}),
        };
    }
    return out;
}

fn invalidVisualDescriptionJson(err: anyerror, body: []const u8) error{RemoteServiceFailed} {
    var preview_buffer: [240]u8 = undefined;
    const preview = oneLinePreview(body, &preview_buffer);
    std.debug.print(
        "REMOTE_FAULT owner=provider code=invalid_visual_description_json parse_error={s} content_prefix={s}\n",
        .{ @errorName(err), preview },
    );
    return error.RemoteServiceFailed;
}

fn oneLinePreview(text: []const u8, buffer: []u8) []const u8 {
    const len = @min(text.len, buffer.len);
    for (text[0..len], 0..) |byte, i| {
        buffer[i] = switch (byte) {
            '\r', '\n', '\t' => ' ',
            else => byte,
        };
    }
    return buffer[0..len];
}

test "parse visual description json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const description = try parseVisualDescription(arena.allocator(),
        \\{"description":"red scarf","change_summary":"scarf changed","durable_notes":["wears scarves"],"temporary_notes":["red scarf"]}
    );
    try std.testing.expectEqualStrings("red scarf", description.description);
    try std.testing.expectEqualStrings("scarf changed", description.change_summary);
    try std.testing.expectEqualStrings("wears scarves", description.durable_notes[0]);
}

test "parse visual description records provider detail keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const description = try parseVisualDescription(arena.allocator(),
        \\{"change_summary":"","appearance_details":{"clothing":"wearing a camouflage patterned shirt","accessories":"none visible","carried_items":"none visible","hair":"dark, curly hair","other":"beard and mustache"}}
    );
    try std.testing.expectEqualStrings("appearance details.clothing: wearing a camouflage patterned shirt; appearance details.accessories: none visible; appearance details.carried items: none visible; appearance details.hair: dark, curly hair; appearance details.other: beard and mustache", description.description);
    try std.testing.expectEqualStrings("", description.change_summary);
    try std.testing.expectEqual(@as(usize, 0), description.durable_notes.len);
    try std.testing.expectEqual(@as(usize, 0), description.temporary_notes.len);
}

test "parse visual description records arbitrary nested provider values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const description = try parseVisualDescription(arena.allocator(),
        \\{"appearance_details":{"clothing":{"text":"red scarf"}}}
    );
    try std.testing.expectEqualStrings("appearance details.clothing.text: red scarf", description.description);
}

test "vision chat body uses json mode only when requested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json_body = try buildVisionChatBody(allocator, std.testing.io, "gpt-4.1-mini", "Return JSON.", &.{"data/test/image.png"}, true);
    const text_body = try buildVisionChatBody(allocator, std.testing.io, "gpt-4.1-mini", "Describe image.", &.{"data/test/image.png"}, false);

    try std.testing.expect(std.mem.indexOf(u8, json_body, "\"response_format\":{\"type\":\"json_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_body, "\"required\":[\"description\",\"change_summary\",\"durable_notes\",\"temporary_notes\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_body, "\"response_format\"") == null);
}

test "random-provider visual description schema matches canonical shape" {
    try std.testing.expect(std.mem.indexOf(u8, visual_description_json_schema, "\"required\":[\"description\",\"change_summary\",\"durable_notes\",\"temporary_notes\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, visual_description_json_schema, "\"additionalProperties\":false") != null);
}

test "provider error envelope is remote service failure" {
    try std.testing.expectError(error.RemoteServiceFailed, extractChatContent(std.testing.allocator,
        \\{"error":{"message":"rate limited","type":"rate_limit_error"}}
    ));
}

test "malformed provider envelope is local service response failure" {
    try std.testing.expectError(error.LocalServiceResponseInvalid, extractChatContent(std.testing.allocator, "not json"));
}

pub const TestIdentityComparisonService = identity.TestIdentityComparisonService;
pub const OpenAIIdentityComparisonService = identity.OpenAIIdentityComparisonService;
pub const RandomProviderIdentityComparisonService = identity.RandomProviderIdentityComparisonService;
