const std = @import("std");
const openai = @import("openai_client.zig");
const ai = @import("random_provider_client.zig");
const process = @import("../platform/common/process.zig");
const service_errors = @import("service_errors.zig");

pub const IntentContext = enum {
    provide_name,
    name_prompt,
    identity_confirmation,
    identity_claim,
};

pub const IntentAction = enum {
    provide_name,
    claim_identity,
    grant_memory_permission,
    deny_memory_permission,
    forget_me,
    sleep_autonomy,
    wake_autonomy,
    quit,
    unknown,
};

pub const IntentResult = struct {
    action: IntentAction,
    value: ?[]const u8 = null,
};

pub const IntentService = struct {
    ctx: *anyopaque,
    classifyFn: *const fn (*anyopaque, std.mem.Allocator, IntentContext, []const u8) anyerror!IntentResult,

    pub fn classify(self: IntentService, allocator: std.mem.Allocator, context: IntentContext, text: []const u8) !IntentResult {
        return self.classifyFn(self.ctx, allocator, context, text);
    }
};

pub const TestIntentService = struct {
    pub fn service(self: *TestIntentService) IntentService {
        return .{ .ctx = self, .classifyFn = classify };
    }

    fn classify(_: *anyopaque, allocator: std.mem.Allocator, context: IntentContext, text: []const u8) !IntentResult {
        return classifyHeuristic(allocator, context, text);
    }
};

pub const OpenAIIntentService = struct {
    io: std.Io,
    client: openai.OpenAIClient,
    model: []const u8,

    pub fn init(io: std.Io, client: openai.OpenAIClient, model: []const u8) OpenAIIntentService {
        return .{ .io = io, .client = client, .model = model };
    }

    pub fn service(self: *OpenAIIntentService) IntentService {
        return .{ .ctx = self, .classifyFn = classify };
    }

    fn classify(ctx: *anyopaque, allocator: std.mem.Allocator, context: IntentContext, text: []const u8) !IntentResult {
        const self: *OpenAIIntentService = @ptrCast(@alignCast(ctx));
        const api_key = self.client.api_key orelse return error.MissingOpenAIAPIKey;

        const system_prompt =
            \\You map a household robot user's short utterance to one allowed action.
            \\Return only compact JSON with keys: action, value.
            \\Allowed actions: provide_name, claim_identity, grant_memory_permission, deny_memory_permission, forget_me, sleep_autonomy, wake_autonomy, quit, unknown.
            \\Use provide_name only when the user gives a name; put only the person's name in value.
            \\Use claim_identity only when the user says they are a specific remembered person, such as "it's me, Zelda"; put only the person's name in value.
            \\Use grant_memory_permission for yes/affirmative permission or confirmation.
            \\Use deny_memory_permission for no/refusal.
            \\Use forget_me when the user asks to be forgotten.
            \\Use sleep_autonomy when the user asks you to go to sleep, stop self-directed actions, or pause autonomy.
            \\Use wake_autonomy when the user asks you to wake up, resume, or restart self-directed actions.
            \\Use quit when the user wants to stop or exit.
            \\Use unknown when unclear.
        ;
        const user_prompt = try std.fmt.allocPrint(allocator, "Context: {s}\nUtterance: {s}", .{ @tagName(context), text });
        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"model\":{s},\"temperature\":0,\"response_format\":{{\"type\":\"json_schema\",\"json_schema\":{{\"name\":\"intent\",\"strict\":true,\"schema\":{s}}}}},\"messages\":[{{\"role\":\"system\",\"content\":{s}}},{{\"role\":\"user\",\"content\":{s}}}]}}",
            .{
                try jsonString(allocator, self.model),
                intentResponseSchema(),
                try jsonString(allocator, system_prompt),
                try jsonString(allocator, user_prompt),
            },
        );
        const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
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

            const content = extractChatContent(allocator, out) catch |err| {
                if (service_errors.shouldRetry(err, attempt)) {
                    service_errors.logRemoteRetry("intent", "openai", self.model, attempt);
                    continue;
                }
                return err;
            };
            return try parseIntentJson(allocator, content);
        }
    }
};

pub const RandomProviderIntentService = struct {
    client: *ai.RandomProviderClient,

    pub fn init(client: *ai.RandomProviderClient) RandomProviderIntentService {
        return .{ .client = client };
    }

    pub fn service(self: *RandomProviderIntentService) IntentService {
        return .{ .ctx = self, .classifyFn = classify };
    }

    fn classify(ctx: *anyopaque, allocator: std.mem.Allocator, context: IntentContext, text: []const u8) !IntentResult {
        const self: *RandomProviderIntentService = @ptrCast(@alignCast(ctx));
        const system_prompt =
            \\You map a household robot user's short utterance to one allowed action.
            \\Return only compact JSON with keys: action, value.
            \\Allowed actions: provide_name, claim_identity, grant_memory_permission, deny_memory_permission, forget_me, sleep_autonomy, wake_autonomy, quit, unknown.
            \\Use provide_name only when the user gives a name; put only the person's name in value.
            \\Use claim_identity only when the user says they are a specific remembered person, such as "it's me, Zelda"; put only the person's name in value.
            \\Use grant_memory_permission for yes/affirmative permission or confirmation.
            \\Use deny_memory_permission for no/refusal.
            \\Use forget_me when the user asks to be forgotten.
            \\Use sleep_autonomy when the user asks you to go to sleep, stop self-directed actions, or pause autonomy.
            \\Use wake_autonomy when the user asks you to wake up, resume, or restart self-directed actions.
            \\Use quit when the user wants to stop or exit.
            \\Use unknown when unclear.
        ;
        const user_prompt = try std.fmt.allocPrint(allocator, "Context: {s}\nUtterance: {s}", .{ @tagName(context), text });
        const content = try self.client.completeText(allocator, .{
            .subsystem = "intent",
            .system_prompt = system_prompt,
            .user_prompt = user_prompt,
            .temperature = 0,
            .response_format = .json_object,
            .response_size = .small,
            .json_schema = intentResponseSchema(),
        });
        return parseIntentJson(allocator, content);
    }
};

fn intentResponseSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"action":{"type":"string","enum":["provide_name","claim_identity","grant_memory_permission","deny_memory_permission","forget_me","sleep_autonomy","wake_autonomy","quit","unknown"]},"value":{"type":["string","null"]}},"required":["action","value"]}
    ;
}

fn classifyHeuristic(allocator: std.mem.Allocator, context: IntentContext, text: []const u8) !IntentResult {
    const trimmed = std.mem.trim(u8, text, " \r\n\t.!?");
    if (trimmed.len == 0) return .{ .action = .unknown };
    if (std.ascii.eqlIgnoreCase(trimmed, "quit") or std.ascii.eqlIgnoreCase(trimmed, "exit") or std.ascii.eqlIgnoreCase(trimmed, "stop")) return .{ .action = .quit };
    if (std.ascii.indexOfIgnoreCase(trimmed, "forget me") != null) return .{ .action = .forget_me };
    if (std.ascii.indexOfIgnoreCase(trimmed, "go to sleep") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "pause autonomy") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "stop self-directed") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "sleep autonomy") != null)
    {
        return .{ .action = .sleep_autonomy };
    }
    if (std.ascii.indexOfIgnoreCase(trimmed, "wake up") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "resume autonomy") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "restart autonomy") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "wake autonomy") != null)
    {
        return .{ .action = .wake_autonomy };
    }

    switch (context) {
        .identity_confirmation => {
            if (isAffirmative(trimmed)) return .{ .action = .grant_memory_permission };
            if (isNegative(trimmed)) return .{ .action = .deny_memory_permission };
        },
        .provide_name, .name_prompt, .identity_claim => {},
    }

    if (context == .identity_claim) {
        if (try extractIdentityClaimName(allocator, trimmed)) |name| return .{ .action = .claim_identity, .value = name };
        return .{ .action = .unknown };
    }

    if (try extractName(allocator, trimmed)) |name| return .{ .action = .provide_name, .value = name };
    if (context == .name_prompt and looksLikeBareName(trimmed)) return .{ .action = .provide_name, .value = try allocator.dupe(u8, trimmed) };
    return .{ .action = .unknown };
}

fn isAffirmative(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "y") or
        std.ascii.eqlIgnoreCase(text, "yep") or
        std.ascii.eqlIgnoreCase(text, "yeah") or
        std.ascii.eqlIgnoreCase(text, "yess") or
        std.ascii.eqlIgnoreCase(text, "sure") or
        std.ascii.eqlIgnoreCase(text, "please do") or
        std.ascii.indexOfIgnoreCase(text, "you can") != null;
}

fn isNegative(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "no") or
        std.ascii.eqlIgnoreCase(text, "n") or
        std.ascii.eqlIgnoreCase(text, "nope") or
        std.ascii.indexOfIgnoreCase(text, "do not") != null or
        std.ascii.indexOfIgnoreCase(text, "don't") != null;
}

fn extractName(allocator: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const markers = [_][]const u8{ "my name is ", "i am ", "i'm ", "im ", "call me " };
    for (markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(text, marker)) |idx| {
            const start = idx + marker.len;
            const name = std.mem.trim(u8, text[start..], " \r\n\t.!?");
            if (looksLikeBareName(name)) return try allocator.dupe(u8, name);
        }
    }
    return null;
}

fn looksLikeBareName(text: []const u8) bool {
    if (text.len == 0 or text.len > 80) return false;
    var saw_letter = false;
    var word_count: usize = 0;
    var in_word = false;
    for (text) |ch| {
        if (std.ascii.isAlphabetic(ch)) {
            saw_letter = true;
            if (!in_word) {
                word_count += 1;
                in_word = true;
                if (word_count > 4) return false;
            }
        } else if (ch == ' ' or ch == '\t' or ch == '-' or ch == '\'') {
            in_word = false;
        } else {
            return false;
        }
    }
    return saw_letter;
}

fn extractIdentityClaimName(allocator: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const markers = [_][]const u8{
        "it's me ",
        "it's me, ",
        "its me ",
        "its me, ",
        "it is me ",
        "it is me, ",
        "you know me i'm ",
        "you know me im ",
        "you know me, i'm ",
        "you know me, im ",
    };
    for (markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(text, marker)) |idx| {
            const start = idx + marker.len;
            const name = std.mem.trim(u8, text[start..], " \r\n\t.!?");
            if (name.len > 0) return try allocator.dupe(u8, name);
        }
    }
    return null;
}

fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, text, .{});
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

fn parseIntentJson(allocator: std.mem.Allocator, body: []const u8) !IntentResult {
    const Wire = struct {
        action: []const u8,
        value: ?[]const u8 = null,
    };
    const parsed = try std.json.parseFromSlice(Wire, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return .{
        .action = parseAction(parsed.value.action),
        .value = if (parsed.value.value) |v| try allocator.dupe(u8, v) else null,
    };
}

fn parseAction(text: []const u8) IntentAction {
    inline for (@typeInfo(IntentAction).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(IntentAction, field.name);
    }
    return .unknown;
}

test "provide name context does not treat arbitrary speech as a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try classifyHeuristic(arena.allocator(), .provide_name, "I'm someone you've met before");
    try std.testing.expectEqual(IntentAction.unknown, result.action);
}

test "name prompt accepts plausible bare and conversational names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bare = try classifyHeuristic(allocator, .name_prompt, "Zelda");
    try std.testing.expectEqual(IntentAction.provide_name, bare.action);
    try std.testing.expectEqualStrings("Zelda", bare.value.?);

    const conversational = try classifyHeuristic(allocator, .name_prompt, "Hello. I'm Zelda");
    try std.testing.expectEqual(IntentAction.provide_name, conversational.action);
    try std.testing.expectEqualStrings("Zelda", conversational.value.?);
}

test "malformed intent json fails loudly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.SyntaxError, parseIntentJson(arena.allocator(), "That's you. Remember?"));
}
