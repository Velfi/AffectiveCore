const std = @import("std");
const chat = @import("chat_client.zig");
const skills = @import("skills.zig");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const autonomy_port = @import("../core/port_autonomy.zig");

pub const Salience = autonomy_port.Salience;
pub const AutonomyTurn = autonomy_port.AutonomyTurn;
pub const AutonomyPlanner = autonomy_port.AutonomyPlanner;
pub const ScriptedAutonomyPlanner = autonomy_port.ScriptedAutonomyPlanner;

pub const RandomProviderAutonomyPlanner = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?chat.ReasoningEffort,

    pub fn init(io: std.Io, http: http_transport.Client, models_spec: []const u8, reasoning_effort: ?chat.ReasoningEffort) RandomProviderAutonomyPlanner {
        return .{
            .provider_client = ai.RandomProviderClient.init(io, http, models_spec),
            .reasoning_effort = reasoning_effort,
        };
    }

    pub fn planner(self: *RandomProviderAutonomyPlanner) AutonomyPlanner {
        return .{ .ctx = self, .planFn = plan };
    }

    fn plan(ctx: *anyopaque, allocator: std.mem.Allocator, context: []const u8) !AutonomyTurn {
        const self: *RandomProviderAutonomyPlanner = @ptrCast(@alignCast(ctx));
        const system_prompt = try autonomySystemPrompt(allocator);
        const content = try self.provider_client.completeText(allocator, .{
            .subsystem = "autonomy",
            .system_prompt = system_prompt,
            .user_prompt = context,
            .temperature = 0.3,
            .response_format = .json_object,
            .response_size = .medium,
            .reasoning_effort = self.reasoning_effort,
            .json_schema = autonomyJsonSchema(),
            .response_validator = validateAutonomyTurn,
            .bad_response_logger = reportAutonomyProviderParseError,
        });
        return parseAutonomyTurn(allocator, content) catch |err| {
            reportAutonomyParseError(err, content);
            return err;
        };
    }
};

fn autonomySystemPrompt(allocator: std.mem.Allocator) ![]const u8 {
    const allowed = try skills.autonomySkillNames(allocator);
    return std.fmt.allocPrint(
        allocator,
        "You are the Ego of a stationary household robot.\n" ++
            "Reconcile Id short-term consequence simulation, Superego long-term consequence simulation, external reality, autonomy budget, and available commands.\n" ++
            "Both voices drink from the same shared state, but may assign different salience, causes, and meanings to the same stimulus; compare those disagreements before choosing.\n" ++
            "Autonomy budget is an internal daily action budget, not battery charge and not external power.\n" ++
            "Only use get_power or ask_human about shutdown when supplied power evidence shows a real low battery, missing external power, or a power-source change.\n" ++
            "Return exactly one JSON object with keys: command, text, query, memory_id, schedule, heat_bias, eyes, mouth, duration_ms, tags, salience, reason.\n" ++
            "Allowed commands: {s}.\n" ++
            "Never choose skills marked forbidden or invalid in the registry, including camera commands.\n" ++
            "When you choose ask_human, ask one concrete question and then expect autonomy to sleep until the human responds.\n" ++
            "Use say only for rare high-salience speech that respects the supplied gates.\n" ++
            "Prefer quiet self-work when Id and Superego disagree unless the shared state shows an urgent, actionable need.\n" ++
            "Use define_need or define_want when a stable self-definition should become part of memory. Use edit_need or edit_want only when introspection has provided a matching memory_id to revise.\n" ++
            "Use salience low, medium, or high.\n" ++
            "For facial_expression, choose eyes and mouth sprite names from the supplied skill description; duration_ms may not exceed 5000.\n" ++
            "For unused optional fields, use null. tags must always be an array. heat_bias may only be null, low, mixed, or high.\n" ++
            "Return only JSON.\n" ++
            "Do not wrap the JSON in Markdown or code fences.",
        .{allowed},
    );
}

fn autonomyJsonSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"command":{"type":"string"},"text":{"type":["string","null"]},"query":{"type":["string","null"]},"memory_id":{"type":["string","null"]},"schedule":{"type":["string","null"]},"heat_bias":{"type":["string","null"],"enum":["low","mixed","high",null]},"eyes":{"type":["string","null"]},"mouth":{"type":["string","null"]},"duration_ms":{"type":["integer","null"]},"tags":{"type":"array","items":{"type":"string"}},"salience":{"type":"string","enum":["low","medium","high"]},"reason":{"type":"string"}},"required":["command","text","query","memory_id","schedule","heat_bias","eyes","mouth","duration_ms","tags","salience","reason"]}
    ;
}

fn validateAutonomyTurn(allocator: std.mem.Allocator, content: []const u8) !void {
    _ = try parseAutonomyTurn(allocator, content);
}

pub fn parseAutonomyTurn(allocator: std.mem.Allocator, body: []const u8) !AutonomyTurn {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidAutonomyJson;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidAutonomyJson,
    };
    const command_text = try requiredStringField(object, "command");
    const salience_text = try requiredStringField(object, "salience");
    const reason = try requiredStringField(object, "reason");
    const command = parseCommand(command_text) orelse return error.InvalidAutonomyCommand;
    if (command == .take_picture or command == .describe_image or command == .compare_images or command == .recognize or command == .unknown) return error.InvalidAutonomyCommand;
    return .{
        .command = .{
            .command = command,
            .text = try dupeOptionalString(allocator, try optionalStringField(object, "text")),
            .query = try dupeOptionalString(allocator, try optionalStringField(object, "query")),
            .memory_id = try dupeOptionalString(allocator, try optionalStringField(object, "memory_id")),
            .schedule = try dupeOptionalString(allocator, try optionalStringField(object, "schedule")),
            .heat_bias = try dupeOptionalString(allocator, try optionalHeatBiasField(object)),
            .eyes = try dupeOptionalString(allocator, try optionalStringField(object, "eyes")),
            .mouth = try dupeOptionalString(allocator, try optionalStringField(object, "mouth")),
            .duration_ms = try optionalIntegerField(object, "duration_ms"),
            .tags = try cloneTagsField(allocator, object),
        },
        .salience = parseSalience(salience_text) orelse return error.InvalidAutonomySalience,
        .reason = try allocator.dupe(u8, reason),
    };
}

fn requiredStringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.MissingAutonomyField;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidAutonomyField,
    };
}

fn optionalStringField(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return error.MissingAutonomyField;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidAutonomyField,
    };
}

fn optionalIntegerField(object: std.json.ObjectMap, name: []const u8) !?u32 {
    const value = object.get(name) orelse return error.MissingAutonomyField;
    return switch (value) {
        .null => null,
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @intCast(number) else error.InvalidAutonomyField,
        else => error.InvalidAutonomyField,
    };
}

fn optionalHeatBiasField(object: std.json.ObjectMap) !?[]const u8 {
    const text = try optionalStringField(object, "heat_bias");
    if (text) |value| {
        if (std.mem.eql(u8, value, "low") or std.mem.eql(u8, value, "mixed") or std.mem.eql(u8, value, "high")) return value;
        return error.InvalidAutonomyField;
    }
    return null;
}

fn dupeOptionalString(allocator: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    return if (text) |value| try allocator.dupe(u8, value) else null;
}

fn cloneTagsField(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]const []const u8 {
    const value = object.get("tags") orelse return error.MissingAutonomyField;
    return switch (value) {
        .array => |array| {
            const tags = try allocator.alloc([]const u8, array.items.len);
            for (array.items, 0..) |item, i| {
                tags[i] = switch (item) {
                    .string => |text| try allocator.dupe(u8, text),
                    else => return error.InvalidAutonomyField,
                };
            }
            return tags;
        },
        else => error.InvalidAutonomyField,
    };
}

fn reportAutonomyParseError(err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nAUTONOMY PARSE ERROR\nPROVIDER: random selected\nERROR: {s}\nEXPECTED: strict JSON object with command/text/query/memory_id/schedule/heat_bias/tags/salience/reason\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ @errorName(err), content },
    );
}

fn reportAutonomyProviderParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nAUTONOMY PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON object with command/text/query/memory_id/schedule/heat_bias/tags/salience/reason\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

fn parseCommand(text: []const u8) ?chat.ChatCommandType {
    inline for (@typeInfo(chat.ChatCommandType).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(chat.ChatCommandType, field.name);
    }
    return null;
}

fn parseSalience(text: []const u8) ?Salience {
    inline for (@typeInfo(Salience).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(Salience, field.name);
    }
    return null;
}

test "parseAutonomyTurn rejects proactive camera capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidAutonomyCommand, parseAutonomyTurn(allocator,
        \\{"command":"take_picture","salience":"high","reason":"curious"}
    ));
}

test "random-provider autonomy schema matches strict required envelope" {
    const schema = autonomyJsonSchema();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"command\",\"text\",\"query\",\"memory_id\",\"schedule\",\"heat_bias\",\"eyes\",\"mouth\",\"duration_ms\",\"tags\",\"salience\",\"reason\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"additionalProperties\":false") != null);
}

test "parseAutonomyTurn accepts a reflective command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseAutonomyTurn(allocator,
        \\{"command":"think_about","text":null,"query":"energy","memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":["self"],"salience":"medium","reason":"checking limits"}
    );
    try std.testing.expectEqual(chat.ChatCommandType.think_about, turn.command.command);
    try std.testing.expectEqual(Salience.medium, turn.salience);
}

test "parseAutonomyTurn rejects wrong optional field type clearly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidAutonomyField, parseAutonomyTurn(allocator,
        \\{"command":"dream","text":null,"query":null,"memory_id":null,"schedule":null,"heat_bias":0.5,"eyes":null,"mouth":null,"duration_ms":null,"tags":[],"salience":"low","reason":"resting"}
    ));
}

test "parseAutonomyTurn accepts facial expression fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseAutonomyTurn(allocator,
        \\{"command":"facial_expression","text":null,"query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":"neutral","mouth":"open","duration_ms":5000,"tags":["visible_affect"],"salience":"low","reason":"visible reaction"}
    );
    try std.testing.expectEqual(chat.ChatCommandType.facial_expression, turn.command.command);
    try std.testing.expectEqualStrings("neutral", turn.command.eyes.?);
    try std.testing.expectEqualStrings("open", turn.command.mouth.?);
    try std.testing.expectEqual(@as(?u32, 5000), turn.command.duration_ms);
}
