const std = @import("std");
const process = @import("../platform/common/process.zig");
const service_errors = @import("service_errors.zig");
const ai = @import("random_provider_client.zig");
const openai = @import("openai_client.zig");

const OpenAIClient = openai.OpenAIClient;
const IdentityComparison = openai.IdentityComparison;
const IdentityComparisonService = openai.IdentityComparisonService;
const jsonString = openai.jsonString;
const extractChatContent = openai.extractChatContent;

pub const TestIdentityComparisonService = struct {
    pub fn service(self: *TestIdentityComparisonService) IdentityComparisonService {
        return .{ .ctx = self, .compareFn = compare };
    }

    fn compare(_: *anyopaque, allocator: std.mem.Allocator, current_description: []const u8, stored_description: []const u8) !IdentityComparison {
        const current = try localDescriptionVector(allocator, current_description);
        defer allocator.free(current);
        const stored = try localDescriptionVector(allocator, stored_description);
        defer allocator.free(stored);
        const similarity = cosine(current, stored);
        return .{
            .same_person = similarity >= 0.60,
            .confidence = similarity,
            .reason = try std.fmt.allocPrint(allocator, "test description similarity {d:.3}", .{similarity}),
        };
    }
};

pub const OpenAIIdentityComparisonService = struct {
    io: std.Io,
    client: OpenAIClient,
    model: []const u8,

    pub fn init(io: std.Io, client: OpenAIClient, model: []const u8) OpenAIIdentityComparisonService {
        return .{ .io = io, .client = client, .model = model };
    }

    pub fn service(self: *OpenAIIdentityComparisonService) IdentityComparisonService {
        return .{ .ctx = self, .compareFn = compare };
    }

    fn compare(ctx: *anyopaque, allocator: std.mem.Allocator, current_description: []const u8, stored_description: []const u8) !IdentityComparison {
        const self: *OpenAIIdentityComparisonService = @ptrCast(@alignCast(ctx));
        const api_key = self.client.api_key orelse return error.MissingOpenAIAPIKey;
        const system_prompt =
            \\Compare two non-sensitive visual descriptions of people for household robot identity recognition.
            \\Use only visible non-sensitive appearance details such as clothing, accessories, carried items, hair/clothing changes, and posture.
            \\Do not infer or use race, ethnicity, gender identity, age, health, disability, attractiveness, emotion, or socioeconomic status.
            \\Return only JSON with keys: same_person, confidence, reason.
            \\confidence must be a number from 0 to 1.
        ;
        const user_prompt = try std.fmt.allocPrint(
            allocator,
            "Current description:\n{s}\n\nStored description:\n{s}",
            .{ current_description, stored_description },
        );
        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"model\":{s},\"temperature\":0,\"response_format\":{{\"type\":\"json_schema\",\"json_schema\":{{\"name\":\"identity_comparison\",\"strict\":true,\"schema\":{s}}}}},\"messages\":[{{\"role\":\"system\",\"content\":{s}}},{{\"role\":\"user\",\"content\":{s}}}]}}",
            .{
                try jsonString(allocator, self.model),
                identityComparisonJsonSchema(),
                try jsonString(allocator, system_prompt),
                try jsonString(allocator, user_prompt),
            },
        );
        const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
        const content = try callOpenAIChatContentWithRetry(allocator, self.io, self.model, auth, body);
        return parseIdentityComparison(allocator, content);
    }
};

pub const RandomProviderIdentityComparisonService = struct {
    client: *ai.RandomProviderClient,

    pub fn init(client: *ai.RandomProviderClient) RandomProviderIdentityComparisonService {
        return .{ .client = client };
    }

    pub fn service(self: *RandomProviderIdentityComparisonService) IdentityComparisonService {
        return .{ .ctx = self, .compareFn = compare };
    }

    fn compare(ctx: *anyopaque, allocator: std.mem.Allocator, current_description: []const u8, stored_description: []const u8) !IdentityComparison {
        const self: *RandomProviderIdentityComparisonService = @ptrCast(@alignCast(ctx));
        const system_prompt =
            \\Compare two non-sensitive visual descriptions of people for household robot identity recognition.
            \\Use only visible non-sensitive appearance details such as clothing, accessories, carried items, hair/clothing changes, and posture.
            \\Do not infer or use race, ethnicity, gender identity, age, health, disability, attractiveness, emotion, or socioeconomic status.
            \\Return only JSON with keys: same_person, confidence, reason.
            \\confidence must be a number from 0 to 1.
        ;
        const user_prompt = try std.fmt.allocPrint(
            allocator,
            "Current description:\n{s}\n\nStored description:\n{s}",
            .{ current_description, stored_description },
        );
        const content = try self.client.completeText(allocator, .{
            .subsystem = "identity_comparison",
            .system_prompt = system_prompt,
            .user_prompt = user_prompt,
            .temperature = 0,
            .response_format = .json_object,
            .response_size = .small,
            .json_schema = identityComparisonJsonSchema(),
            .response_validator = validateIdentityComparison,
            .bad_response_logger = reportIdentityComparisonParseError,
        });
        return parseIdentityComparison(allocator, content);
    }
};

fn callOpenAIChatContentWithRetry(allocator: std.mem.Allocator, io: std.Io, model: []const u8, auth: []const u8, body: []const u8) ![]const u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const out = try process.runCapture(allocator, io, &.{
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
        return extractChatContent(allocator, out) catch |err| {
            if (service_errors.shouldRetry(err, attempt)) {
                service_errors.logRemoteRetry("identity_comparison", "openai", model, attempt);
                continue;
            }
            return err;
        };
    }
}

const IdentityComparisonWire = struct {
    same_person: bool,
    confidence: f32,
    reason: []const u8 = "",
};

fn parseIdentityComparison(allocator: std.mem.Allocator, body: []const u8) !IdentityComparison {
    const parsed = try std.json.parseFromSlice(IdentityComparisonWire, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.confidence < 0 or parsed.value.confidence > 1) return error.InvalidIdentityConfidence;
    return .{
        .same_person = parsed.value.same_person,
        .confidence = parsed.value.confidence,
        .reason = try allocator.dupe(u8, parsed.value.reason),
    };
}

fn validateIdentityComparison(allocator: std.mem.Allocator, content: []const u8) !void {
    const comparison = try parseIdentityComparison(allocator, content);
    allocator.free(comparison.reason);
}

fn identityComparisonJsonSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"same_person":{"type":"boolean"},"confidence":{"type":"number"},"reason":{"type":"string"}},"required":["same_person","confidence","reason"]}
    ;
}

fn reportIdentityComparisonParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nIDENTITY COMPARISON PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON with same_person, confidence, reason\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

test "identity comparison schema requires comparison fields" {
    const schema = identityComparisonJsonSchema();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"same_person\",\"confidence\",\"reason\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"additionalProperties\":false") != null);
}

const local_description_dimensions: usize = 64;

fn localDescriptionVector(allocator: std.mem.Allocator, text: []const u8) ![]f32 {
    const vector = try allocator.alloc(f32, local_description_dimensions);
    @memset(vector, 0.0);
    var token_buf: [64]u8 = undefined;
    var token_len: usize = 0;
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (token_len < token_buf.len) {
                token_buf[token_len] = std.ascii.toLower(byte);
                token_len += 1;
            }
        } else {
            addLocalToken(vector, token_buf[0..token_len]);
            token_len = 0;
        }
    }
    addLocalToken(vector, token_buf[0..token_len]);
    normalize(vector);
    return vector;
}

fn addLocalToken(vector: []f32, token: []const u8) void {
    if (token.len < 2) return;
    vector[hashToken(token) % local_description_dimensions] += 1.0;
}

fn normalize(vector: []f32) void {
    var magnitude: f32 = 0;
    for (vector) |value| magnitude += value * value;
    if (magnitude == 0) return;
    const scale = @sqrt(magnitude);
    for (vector) |*value| value.* /= scale;
}

fn cosine(a: []const f32, b: []const f32) f32 {
    const count = @min(a.len, b.len);
    var dot: f32 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) dot += a[i] * b[i];
    return dot;
}

fn hashToken(token: []const u8) usize {
    var hash: u64 = 14695981039346656037;
    for (token) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return @as(usize, @truncate(hash));
}

test "test identity comparison rates overlapping descriptions higher" {
    var service_impl = TestIdentityComparisonService{};
    const service = service_impl.service();
    const comparison = try service.compareDescriptions(std.testing.allocator, "blue jacket small bag", "wearing a blue jacket and carrying a small bag");
    defer std.testing.allocator.free(comparison.reason);
    try std.testing.expect(comparison.same_person);
    try std.testing.expect(comparison.confidence >= 0.60);
}
