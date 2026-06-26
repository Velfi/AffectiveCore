const std = @import("std");
const ai = @import("random_provider_client.zig");
const intent_port = @import("../core/port_intent.zig");

pub const IntentContext = intent_port.IntentContext;
pub const IntentAction = intent_port.IntentAction;
pub const IntentResult = intent_port.IntentResult;
pub const IntentService = intent_port.IntentService;
pub const TestIntentService = intent_port.TestIntentService;

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

test "malformed intent json fails loudly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.SyntaxError, parseIntentJson(arena.allocator(), "That's you. Remember?"));
}
