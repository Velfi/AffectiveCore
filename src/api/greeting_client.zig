const std = @import("std");
const ai = @import("random_provider_client.zig");
const greeting_port = @import("../core/port_greeting.zig");

pub const GreetingIntent = greeting_port.GreetingIntent;
pub const GreetingContext = greeting_port.GreetingContext;
pub const GreetingService = greeting_port.GreetingService;
pub const TestGreetingService = greeting_port.TestGreetingService;

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
