const std = @import("std");
const openai = @import("openai_client.zig");
const ai = @import("random_provider_client.zig");
const process = @import("../platform/common/process.zig");
const service_errors = @import("service_errors.zig");

pub const GreetingIntent = enum {
    known_person,
    unknown_person,
    uncertain_person,
    memory_permission_denied,
    forget_profile,

    fn description(self: GreetingIntent) []const u8 {
        return switch (self) {
            .known_person => "welcome back a recognized known person",
            .unknown_person => "open a curious first exchange with an unrecognized person",
            .uncertain_person => "ask for identity when recognition is uncertain",
            .memory_permission_denied => "acknowledge that no memory should be kept after this conversation",
            .forget_profile => "confirm that a profile will be forgotten",
        };
    }
};

pub const GreetingContext = struct {
    intent: GreetingIntent = .known_person,
    person_name: ?[]const u8 = null,
    elapsed_days: ?i64 = null,
    visual_description: []const u8,
    change_summary: []const u8,
    senses: []const u8,
    interior_state: []const u8,
    stable_notes: []const []const u8,
    recent_notes: []const []const u8,
};

pub const GreetingService = struct {
    ctx: *anyopaque,
    generateFn: *const fn (*anyopaque, std.mem.Allocator, GreetingContext) anyerror![]const u8,

    pub fn generate(self: GreetingService, allocator: std.mem.Allocator, context: GreetingContext) ![]const u8 {
        return self.generateFn(self.ctx, allocator, context);
    }
};

pub const TestGreetingService = struct {
    pub fn service(self: *TestGreetingService) GreetingService {
        return .{ .ctx = self, .generateFn = generate };
    }

    fn generate(_: *anyopaque, allocator: std.mem.Allocator, context: GreetingContext) ![]const u8 {
        if (context.intent != .known_person) {
            return std.fmt.allocPrint(allocator, "generated {s} greeting", .{@tagName(context.intent)});
        }
        const person_name = context.person_name orelse return error.MissingGreetingPersonName;
        if (context.change_summary.len > 0) {
            return std.fmt.allocPrint(allocator, "Welcome back, {s}. I notice {s}.", .{ person_name, context.change_summary });
        }
        if (context.elapsed_days) |days| {
            if (days >= 2 and days < 9999) return std.fmt.allocPrint(allocator, "Welcome back, {s}. It has been {d} days.", .{ person_name, days });
        }
        return std.fmt.allocPrint(allocator, "Welcome back, {s}.", .{person_name});
    }
};

pub const OpenAIGreetingService = struct {
    io: std.Io,
    client: openai.OpenAIClient,
    model: []const u8,

    pub fn init(io: std.Io, client: openai.OpenAIClient, model: []const u8) OpenAIGreetingService {
        return .{ .io = io, .client = client, .model = model };
    }

    pub fn service(self: *OpenAIGreetingService) GreetingService {
        return .{ .ctx = self, .generateFn = generate };
    }

    fn generate(ctx: *anyopaque, allocator: std.mem.Allocator, context: GreetingContext) ![]const u8 {
        const self: *OpenAIGreetingService = @ptrCast(@alignCast(ctx));
        const api_key = self.client.api_key orelse return error.MissingOpenAIAPIKey;
        const system_prompt =
            \\Choose one spoken greeting or confirmation from the provided context.
            \\Follow greeting_intent exactly.
            \\Use the person's name only when an actual person_name is provided.
            \\Ground the sentence in the supplied memories, needs, appraisals, senses, and recognition context.
            \\Keep it to one sentence, under 160 characters.
            \\Return only JSON with key: text.
        ;
        const user_prompt = try formatGreetingPrompt(allocator, context);
        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"model\":{s},\"temperature\":0.6,\"response_format\":{{\"type\":\"json_schema\",\"json_schema\":{{\"name\":\"greeting\",\"strict\":true,\"schema\":{s}}}}},\"messages\":[{{\"role\":\"system\",\"content\":{s}}},{{\"role\":\"user\",\"content\":{s}}}]}}",
            .{
                try jsonString(allocator, self.model),
                greetingJsonSchema(),
                try jsonString(allocator, system_prompt),
                try jsonString(allocator, user_prompt),
            },
        );
        const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
        var attempt: usize = 0;
        const content = while (true) : (attempt += 1) {
            const out = try process.runCapture(allocator, self.io, &.{
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
            break extractChatContent(allocator, out) catch |err| {
                if (service_errors.shouldRetry(err, attempt)) {
                    service_errors.logRemoteRetry("greeting", "openai", self.model, attempt);
                    continue;
                }
                return err;
            };
        };
        return parseGreeting(allocator, content);
    }
};

pub const RandomProviderGreetingService = struct {
    client: *ai.RandomProviderClient,

    pub fn init(client: *ai.RandomProviderClient) RandomProviderGreetingService {
        return .{ .client = client };
    }

    pub fn service(self: *RandomProviderGreetingService) GreetingService {
        return .{ .ctx = self, .generateFn = generate };
    }

    fn generate(ctx: *anyopaque, allocator: std.mem.Allocator, context: GreetingContext) ![]const u8 {
        const self: *RandomProviderGreetingService = @ptrCast(@alignCast(ctx));
        const system_prompt =
            \\Choose one spoken greeting or confirmation from the provided context.
            \\Follow greeting_intent exactly.
            \\Use the person's name only when an actual person_name is provided.
            \\Ground the sentence in the supplied memories, needs, appraisals, senses, and recognition context.
            \\Keep it to one sentence, under 160 characters.
            \\Return only JSON with key: text.
        ;
        const user_prompt = try formatGreetingPrompt(allocator, context);
        const content = try self.client.completeText(allocator, .{
            .subsystem = "greeting",
            .system_prompt = system_prompt,
            .user_prompt = user_prompt,
            .temperature = 0.6,
            .response_format = .json_object,
            .response_size = .small,
            .json_schema = greetingJsonSchema(),
            .response_validator = validateGreeting,
            .bad_response_logger = reportGreetingParseError,
        });
        return parseGreeting(allocator, content);
    }
};

fn formatGreetingPrompt(allocator: std.mem.Allocator, context: GreetingContext) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.print(allocator, "greeting_intent: {s}\n", .{context.intent.description()});
    try out.print(allocator, "person_name: {s}\n", .{context.person_name orelse "none"});
    if (context.elapsed_days) |days| try out.print(allocator, "elapsed_days_since_last_seen: {d}\n", .{days});
    try out.print(allocator, "visual_description: {s}\n", .{context.visual_description});
    try out.print(allocator, "change_summary: {s}\n", .{context.change_summary});
    try appendNotes(allocator, &out, "stable_notes", context.stable_notes);
    try appendNotes(allocator, &out, "recent_notes", context.recent_notes);
    try out.print(allocator, "interior_state:\n{s}\n", .{context.interior_state});
    try out.print(allocator, "senses:\n{s}", .{context.senses});
    return out.toOwnedSlice(allocator);
}

fn appendNotes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8, notes: []const []const u8) !void {
    try out.print(allocator, "{s}:\n", .{label});
    if (notes.len == 0) {
        try out.appendSlice(allocator, "- none\n");
        return;
    }
    for (notes) |note| try out.print(allocator, "- {s}\n", .{note});
}

fn parseGreeting(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const Wire = struct { text: []const u8 };
    const parsed = try std.json.parseFromSlice(Wire, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const trimmed = std.mem.trim(u8, parsed.value.text, " \r\n\t");
    if (trimmed.len == 0) return error.EmptyGreetingText;
    if (trimmed.len > 240) return error.GreetingTextTooLong;
    return try allocator.dupe(u8, trimmed);
}

fn validateGreeting(allocator: std.mem.Allocator, content: []const u8) !void {
    const text = try parseGreeting(allocator, content);
    allocator.free(text);
}

fn greetingJsonSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"text":{"type":"string"}},"required":["text"]}
    ;
}

fn reportGreetingParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nGREETING PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON with key text\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

fn extractChatContent(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
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

fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, text, .{});
}

test "parse greeting requires text" {
    const text = try parseGreeting(std.testing.allocator, "{\"text\":\"Welcome back, Zelda.\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Welcome back, Zelda.", text);
    try std.testing.expectError(error.EmptyGreetingText, parseGreeting(std.testing.allocator, "{\"text\":\"\"}"));
    try std.testing.expectError(error.MissingField, parseGreeting(std.testing.allocator, "{}"));
}

test "greeting json schema requires text" {
    const schema = greetingJsonSchema();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"text\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"additionalProperties\":false") != null);
}
