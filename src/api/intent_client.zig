const std = @import("std");
const ai = @import("random_provider_client.zig");
const intent_port = @import("../core/port_intent.zig");
const llm_tester_scenario = @import("../harness/llm_tester/scenario.zig");

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
            \\You classify what someone said into one allowed action for the mind you are part of.
            \\Return only compact JSON with keys: action, value.
            \\Allowed actions: provide_name, claim_identity, grant_memory_permission, deny_memory_permission, forget_me, sleep_autonomy, wake_autonomy, quit, unknown.
            \\Use provide_name only when they give a name; put only the person's name in value.
            \\Use claim_identity only when they say they are a specific remembered person, such as "it's me, Zelda"; put only the person's name in value.
            \\Use grant_memory_permission only when Context is identity_confirmation and they affirm.
            \\Use deny_memory_permission only when Context is identity_confirmation and they refuse.
            \\Use forget_me when they ask to be forgotten.
            \\Use sleep_autonomy when they ask you to sleep, stop self-directed actions, or pause autonomy.
            \\Use wake_autonomy when they ask you to wake up, resume, or restart self-directed actions.
            \\Use quit when they want to stop or leave.
            \\Use unknown when unclear; use null for value when action is unknown.
            \\Return only valid JSON. No markdown, code fences, or prose outside the object.
        ;
        const user_prompt = try std.fmt.allocPrint(allocator, "Context: {s}\nWhat reached you: {s}", .{ @tagName(context), text });
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

pub fn llmTesterScenarios(allocator: std.mem.Allocator) ![]llm_tester_scenario.Scenario {
    const system_prompt =
        \\You classify what someone said into one allowed action for the mind you are part of.
        \\Return only compact JSON with keys: action, value.
        \\Allowed actions: provide_name, claim_identity, grant_memory_permission, deny_memory_permission, forget_me, sleep_autonomy, wake_autonomy, quit, unknown.
        \\Use provide_name only when they give a name; put only the person's name in value.
        \\Use claim_identity only when they say they are a specific remembered person, such as "it's me, Zelda"; put only the person's name in value.
        \\Use grant_memory_permission only when Context is identity_confirmation and they affirm.
        \\Use deny_memory_permission only when Context is identity_confirmation and they refuse.
        \\Use forget_me when they ask to be forgotten.
        \\Use sleep_autonomy when they ask you to sleep, stop self-directed actions, or pause autonomy.
        \\Use wake_autonomy when they ask you to wake up, resume, or restart self-directed actions.
        \\Use quit when they want to stop or leave.
        \\Use unknown when unclear; use null for value when action is unknown.
        \\Return only valid JSON. No markdown, code fences, or prose outside the object.
    ;
    const cases = [_]struct { id: []const u8, label: []const u8, description: []const u8, context: intent_port.IntentContext, text: []const u8 }{
        .{ .id = "intent_provide_name", .label = "User provides their name", .description = "Confirms the classifier maps a straightforward name introduction to provide_name with the extracted name in value.", .context = .provide_name, .text = "My name is Alex." },
        .{ .id = "intent_sleep_autonomy", .label = "User asks robot to sleep", .description = "Confirms a request to stop self-directed behavior maps to sleep_autonomy even when the intent context is not autonomy-specific.", .context = .name_prompt, .text = "Go to sleep for a while." },
        .{ .id = "intent_claim_identity", .label = "User claims remembered identity", .description = "Confirms remembered-identity phrasing maps to claim_identity with the person's name, not provide_name.", .context = .identity_claim, .text = "It's me, Zelda." },
    };
    var out = try allocator.alloc(llm_tester_scenario.Scenario, cases.len);
    for (cases, 0..) |case, i| {
        const user_prompt = try std.fmt.allocPrint(allocator, "Context: {s}\nWhat reached you: {s}", .{ @tagName(case.context), case.text });
        out[i] = try llm_tester_scenario.Scenario.init(
            allocator,
            case.id,
            case.label,
            case.description,
            "intent",
            system_prompt,
            user_prompt,
            .json_object,
            intentResponseSchema(),
            128,
            0,
        );
    }
    return out;
}

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
