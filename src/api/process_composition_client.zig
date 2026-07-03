const std = @import("std");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const chat = @import("chat_client.zig");
const port_chat = @import("../core/port_chat.zig");
const skills = @import("skills.zig");
const process_goal_port = @import("../core/port_process_goal.zig");
const llm_routing = @import("../core/llm_routing.zig");
const capability_registry = @import("../core/capability_registry.zig");
const llm_tester_scenario = @import("../harness/llm_tester/scenario.zig");
const action_pressure_json_schema = @import("action_pressure_json_schema.zig");
const service_errors = @import("service_errors.zig");

pub const ComposeMode = process_goal_port.ComposeMode;
pub const ProcessComposition = process_goal_port.ProcessComposition;
pub const ProcessComposer = process_goal_port.ProcessComposer;
pub const ComposeBatchItem = process_goal_port.ComposeBatchItem;
pub const ScriptedProcessComposer = process_goal_port.ScriptedProcessComposer;
pub const isForbiddenAutonomyAction = process_goal_port.isForbiddenAutonomyAction;

pub const RandomProviderProcessComposer = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?chat.ReasoningEffort,
    autonomy_mode: []const u8,

    pub fn init(
        io: std.Io,
        http: http_transport.Client,
        roster: llm_routing.LlmRoster,
        quality: ai.LlmQuality,
        reasoning_effort: ?chat.ReasoningEffort,
        autonomy_mode: []const u8,
    ) RandomProviderProcessComposer {
        return .{
            .provider_client = ai.RandomProviderClient.initWithRoster(io, http, roster, quality),
            .reasoning_effort = reasoning_effort,
            .autonomy_mode = autonomy_mode,
        };
    }

    pub fn composer(self: *RandomProviderProcessComposer) ProcessComposer {
        return .{ .ctx = self, .composeFn = compose, .composeBatchFn = composeBatch };
    }

    fn compose(ctx: *anyopaque, allocator: std.mem.Allocator, goal: []const u8, context: []const u8, mode: ComposeMode) !ProcessComposition {
        const self: *RandomProviderProcessComposer = @ptrCast(@alignCast(ctx));
        const system_prompt = try compositionSystemPrompt(allocator, mode, self.autonomy_mode);
        defer allocator.free(system_prompt);
        const user_prompt = try buildUserPrompt(allocator, goal, context, mode);
        defer allocator.free(user_prompt);
        const json_schema = try compositionJsonSchema(allocator, mode, self.autonomy_mode);
        defer allocator.free(json_schema);
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const content = try self.provider_client.completeText(allocator, .{
                .subsystem = "process_composition",
                .system_prompt = system_prompt,
                .user_prompt = user_prompt,
                .temperature = 0.2,
                .response_format = .json_object,
                .response_size = .medium,
                .reasoning_effort = self.reasoning_effort,
                .json_schema = json_schema,
                .response_validator = null,
                .bad_response_logger = reportCompositionParseError,
            });
            defer self.provider_client.freeHttpResponse(allocator, content);
            const composition = parseProcessComposition(allocator, content, mode, self.autonomy_mode) catch |err| {
                if (shouldRetryCompositionParse(err, attempt)) continue;
                return err;
            };
            validateProcessComposition(composition, mode, context) catch |err| {
                port_chat.freeActionProposals(allocator, composition.action_pressures);
                for (composition.step_kinds) |kind| {
                    if (kind) |value| allocator.free(value);
                }
                if (composition.step_kinds.len > 0) allocator.free(@constCast(composition.step_kinds));
                allocator.free(composition.reason);
                if (shouldRetryCompositionParse(err, attempt)) continue;
                return err;
            };
            return composition;
        }
    }

    fn composeBatch(ctx: *anyopaque, allocator: std.mem.Allocator, items: []const ComposeBatchItem) ![]ProcessComposition {
        const self: *RandomProviderProcessComposer = @ptrCast(@alignCast(ctx));
        if (items.len == 0) return &.{};

        var text_items = try allocator.alloc(ai.TextBatchItem, items.len);
        defer allocator.free(text_items);
        var owned_strings = std.ArrayList([]const u8).empty;
        defer {
            for (owned_strings.items) |owned| allocator.free(owned);
            owned_strings.deinit(allocator);
        }

        for (items, 0..) |item, index| {
            const system_prompt = try compositionSystemPrompt(allocator, item.mode, self.autonomy_mode);
            try owned_strings.append(allocator, system_prompt);
            const user_prompt = try buildUserPrompt(allocator, item.goal, item.context, item.mode);
            try owned_strings.append(allocator, user_prompt);
            const json_schema = try compositionJsonSchema(allocator, item.mode, self.autonomy_mode);
            try owned_strings.append(allocator, json_schema);
            text_items[index] = .{
                .request = .{
                    .subsystem = "process_composition",
                    .system_prompt = system_prompt,
                    .user_prompt = user_prompt,
                    .temperature = 0.2,
                    .response_format = .json_object,
                    .response_size = .medium,
                    .reasoning_effort = self.reasoning_effort,
                    .json_schema = json_schema,
                    .response_validator = null,
                    .bad_response_logger = reportCompositionParseError,
                },
            };
        }

        try self.provider_client.completeTextBatch(allocator, text_items);
        errdefer for (text_items) |*text_item| {
            if (text_item.content) |content| self.provider_client.freeHttpResponse(allocator, content);
        };

        const out = try allocator.alloc(ProcessComposition, items.len);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |composition| {
                port_chat.freeActionProposals(allocator, composition.action_pressures);
                for (composition.step_kinds) |kind| {
                    if (kind) |value| allocator.free(value);
                }
                if (composition.step_kinds.len > 0) allocator.free(@constCast(composition.step_kinds));
                allocator.free(composition.reason);
            }
            allocator.free(out);
        }

        for (text_items, items, 0..) |*text_item, item, index| {
            const content = text_item.content orelse return error.MissingBatchResponse;
            out[index] = try parseProcessComposition(allocator, content, item.mode, self.autonomy_mode);
            initialized = index + 1;
            self.provider_client.freeHttpResponse(allocator, content);
            text_item.content = null;
        }
        return out;
    }
};

fn compositionSystemPrompt(allocator: std.mem.Allocator, mode: ComposeMode, autonomy_mode: []const u8) ![]const u8 {
    const allowed = switch (mode) {
        .autonomy => try skills.autonomySkillNames(allocator, autonomy_mode),
        .interaction => try skills.interactionSkillNames(allocator),
    };
    defer allocator.free(allowed);
    const origin_rule = switch (mode) {
        .autonomy => "Set origin to autonomy for every step—never interaction.",
        .interaction => "Set origin to interaction for every step—never autonomy.",
    };
    const touch_interaction_example =
        \\Example (investigate_unusual_touch, no camera, interaction mode): {"action_pressures":[{"action":"feel_about","origin":"interaction","step_kind":"sync_capability","query":"short tap on head","scale":null,"text":null,"tags":[]},{"action":"emote","origin":"interaction","text":"*startles slightly*","tags":[]},{"action":"say","origin":"interaction","step_kind":"respond","scale":"tiny","text":"That surprised me.","tags":[]}],"reason":"Non-visual touch investigation with user-visible acknowledgment."}
    ;
    const touch_autonomy_example =
        \\Example (investigate_unusual_touch, no camera, attention loop): {"action_pressures":[{"action":"feel_about","origin":"autonomy","step_kind":"sync_capability","query":"short tap on head","tags":[]},{"action":"think_about","origin":"autonomy","step_kind":"sync_capability","query":"touch source without camera","tags":[]}],"reason":"Inner investigation without speech."}
    ;
    const touch_example = switch (mode) {
        .interaction => touch_interaction_example,
        .autonomy => touch_autonomy_example,
    };
    const step_kind_rule = switch (mode) {
        .interaction => "step_kind respond is only for say. feel_about and think_about use step_kind sync_capability with query set—never text, never scale.",
        .autonomy => "step_kind respond is only for say. feel_about and think_about use step_kind sync_capability with query set—never text, never scale.",
    };
    return std.fmt.allocPrint(
        allocator,
        "You expand a process goal into an ordered chain of registered capability actions.\n" ++
            "Return exactly one JSON object with keys action_pressures and reason.\n" ++
            "action_pressures must be an ordered array; prefer the shortest chain that satisfies the goal.\n" ++
            "Each action_pressure requires action; include step_kind when the runtime step type is not obvious from action alone.\n" ++
            "Allowed step_kind values: sync_capability, async_host_pull, wait_timer, wait_stimulus, respond.\n" ++
            "Examples: recognize with step_kind async_host_pull then say with step_kind respond; schedule_reminder with step_kind wait_timer.\n" ++
            "{s}\n" ++
            "Allowed capability actions: {s}.\n" ++
            "Use only listed actions. Never invent new action names.\n" ++
            "Process goals are inputs describing intent; do not put process goal names in action fields.\n" ++
            "If context mentions a prior failed recipe for this goal, revise the chain—do not repeat the same mistake.\n" ++
            "{s}\n" ++
            "Use delay_ms for sequencing when order matters.\n" ++
            "Respect context affordances: when context says no camera available, do not use recognize, take_picture, or describe_image.\n" ++
            "introspect query uses skill/<name> or skills/<group> paths—not free-form sentences; think_about query is the topic only, without repeating the skill name.\n" ++
            "feel_about sets query to the feeling topic—never text. think_about sets query to the topic—never text.\n" ++
            "Interaction touch investigation without camera: prefer say, emote, choose_attention, think_about, feel_about—not get_power or get_storage unless power or storage is the question.\n" ++
            "Autonomy investigation prefers think_about, feel_about, and introspect over say unless reporting to a present user.\n" ++
            "Include tags only when non-empty.\n" ++
            "Return only JSON.\n" ++
            "Do not wrap the JSON in Markdown or code fences.\n" ++
            "{s}",
        .{ step_kind_rule, allowed, origin_rule, touch_example },
    );
}

fn buildUserPrompt(allocator: std.mem.Allocator, goal: []const u8, context: []const u8, mode: ComposeMode) ![]const u8 {
    const mode_block = switch (mode) {
        .interaction =>
        \\compose_mode: interaction
        \\required_origin: interaction (set on every step)
        \\affordances: no camera — do not use recognize, take_picture, describe_image, or compare_images
        \\skill_fields:
        \\- feel_about: query required (copy recent_touch from context); text null; step_kind sync_capability; scale null
        \\- think_about: query only (never text); step_kind sync_capability; scale null
        \\- say: text only; step_kind respond; scale tiny or full
        \\- emote: text only; scale null
        \\output_checklist:
        \\- step 1 feel_about: origin=interaction, query=short tap on head, text=null, scale=null, step_kind=sync_capability
        \\- step 2 emote: origin=interaction, text=*startles slightly*, query=null, scale=null, step_kind=null
        \\- step 3 say: origin=interaction, text=brief acknowledgment, query=null, step_kind=respond, scale=tiny
        ,
        .autonomy =>
        \\compose_mode: autonomy
        \\required_origin: autonomy (set on every step)
        \\affordances: no camera — do not use recognize, take_picture, describe_image, or compare_images
        \\skill_fields:
        \\- feel_about: query only (never text); step_kind sync_capability (never respond); scale null
        \\- think_about: query only (never text); step_kind sync_capability (never respond); scale null
        \\- say: avoid unless reporting to a present user
        \\output_checklist:
        \\- step 1 feel_about: origin=autonomy, query=short tap on head, text=null, step_kind=sync_capability
        \\- step 2 think_about: origin=autonomy, query=touch source without camera, text=null, step_kind=sync_capability
        ,
    };
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\nprocess_goal:\n{s}\n\ncontext:\n{s}",
        .{ mode_block, goal, context },
    );
}

pub fn llmTesterScenarios(allocator: std.mem.Allocator) ![]llm_tester_scenario.Scenario {
    const goal = "investigate_unusual_touch";
    const context =
        \\autonomy_mode: limited
        \\recent_touch: short tap on head
        \\senses: no camera available
        \\id: curious about touch source
    ;
    const modes = [_]ComposeMode{ .autonomy, .interaction };
    var out = try allocator.alloc(llm_tester_scenario.Scenario, modes.len);
    for (modes, 0..) |mode, i| {
        const system_prompt = try compositionSystemPrompt(allocator, mode, "limited");
        defer allocator.free(system_prompt);
        const user_prompt = try buildUserPrompt(allocator, goal, context, mode);
        const json_schema = try compositionJsonSchema(allocator, mode, "limited");
        const id = switch (mode) {
            .autonomy => "process_composition_autonomy",
            .interaction => "process_composition_interaction",
        };
        const label = switch (mode) {
            .autonomy => "Expand process goal into autonomy action chain",
            .interaction => "Expand process goal into interaction action chain",
        };
        const description = switch (mode) {
            .autonomy => "Expands a touch-investigation goal into an ordered autonomy action chain the being can execute without user interaction.",
            .interaction => "Expands the same goal into an interaction action chain that may involve speech or other user-visible steps.",
        };
        out[i] = try llm_tester_scenario.Scenario.init(
            allocator,
            id,
            label,
            description,
            "process_composition",
            system_prompt,
            user_prompt,
            .json_object,
            json_schema,
            512,
            0.2,
        );
    }
    return out;
}

fn compositionJsonSchema(allocator: std.mem.Allocator, mode: ComposeMode, autonomy_mode: []const u8) ![]const u8 {
    const action_enum = switch (mode) {
        .autonomy => try skills.autonomyActionEnumJson(allocator, autonomy_mode),
        .interaction => try skills.interactionActionEnumJson(allocator),
    };
    defer allocator.free(action_enum);
    return action_pressure_json_schema.strictCompositionTurnSchema(allocator, action_enum);
}

fn shouldRetryCompositionParse(err: anyerror, attempt: usize) bool {
    if (attempt + 1 >= service_errors.remote_retry_attempts) return false;
    return switch (err) {
        error.InvalidProcessCompositionField,
        error.InvalidProcessCompositionAction,
        error.InvalidProcessCompositionJson,
        error.MissingProcessCompositionField,
        error.EmptyProcessComposition,
        error.InvalidProcessCompositionOrigin,
        error.InvalidProcessCompositionAffordance,
        error.InvalidProcessCompositionQuery,
        => true,
        else => false,
    };
}

fn contextDisallowsCamera(context: []const u8) bool {
    return std.mem.indexOf(u8, context, "no camera available") != null;
}

fn introspectQueryValid(query: []const u8) bool {
    return std.mem.startsWith(u8, query, "skill/") or std.mem.startsWith(u8, query, "skills/");
}

fn thinkAboutQueryValid(query: []const u8) bool {
    return !std.mem.startsWith(u8, query, "think_about");
}

pub fn validateProcessComposition(
    composition: ProcessComposition,
    mode: ComposeMode,
    context: []const u8,
) !void {
    const expected_origin: chat.ActionOrigin = switch (mode) {
        .autonomy => .autonomy,
        .interaction => .interaction,
    };
    const camera_blocked = contextDisallowsCamera(context);
    for (composition.action_pressures, composition.step_kinds) |pressure, step_kind| {
        if (pressure.origin != expected_origin) return error.InvalidProcessCompositionOrigin;
        if (camera_blocked) {
            switch (pressure.action) {
                .recognize, .take_picture, .describe_image, .compare_images => return error.InvalidProcessCompositionAffordance,
                else => {},
            }
        }
        if (pressure.action == .introspect) {
            if (pressure.query) |query| {
                if (!introspectQueryValid(query)) return error.InvalidProcessCompositionQuery;
            } else return error.InvalidProcessCompositionQuery;
        }
        if (pressure.action == .feel_about) {
            if (pressure.query == null or pressure.query.?.len == 0) return error.InvalidProcessCompositionQuery;
            if (pressure.text != null and pressure.text.?.len > 0) return error.InvalidProcessCompositionQuery;
            if (pressure.scale != .full) return error.InvalidProcessCompositionQuery;
            if (step_kind) |kind| {
                if (std.mem.eql(u8, kind, "respond")) return error.InvalidProcessCompositionQuery;
            }
        }
        if (pressure.action == .think_about) {
            const has_query = pressure.query != null and pressure.query.?.len > 0;
            const has_text = pressure.text != null and pressure.text.?.len > 0;
            if (!has_query and !has_text) return error.InvalidProcessCompositionQuery;
            if (pressure.scale != .full) return error.InvalidProcessCompositionQuery;
            if (step_kind) |kind| {
                if (std.mem.eql(u8, kind, "respond")) return error.InvalidProcessCompositionQuery;
            }
        }
    }
}

pub fn parseProcessComposition(allocator: std.mem.Allocator, body: []const u8, mode: ComposeMode, autonomy_mode: []const u8) !ProcessComposition {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidProcessCompositionJson;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidProcessCompositionJson,
    };
    const pressure_values = try requiredArrayField(object, "action_pressures");
    if (pressure_values.items.len == 0) return error.EmptyProcessComposition;
    const reason = try requiredStringField(object, "reason");
    var action_pressures = try allocator.alloc(chat.ActionProposal, pressure_values.items.len);
    var step_kinds = try allocator.alloc(?[]const u8, pressure_values.items.len);
    @memset(step_kinds, null);
    errdefer {
        for (step_kinds) |kind| if (kind) |value| allocator.free(value);
        allocator.free(step_kinds);
    }
    for (pressure_values.items, 0..) |value, i| {
        const pressure_object = switch (value) {
            .object => |child| child,
            else => return error.InvalidProcessCompositionField,
        };
        action_pressures[i] = try parseCompositionPressure(allocator, pressure_object, mode, autonomy_mode);
        step_kinds[i] = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "step_kind"));
    }
    return .{
        .action_pressures = action_pressures,
        .reason = try allocator.dupe(u8, reason),
        .step_kinds = step_kinds,
    };
}

fn parseCompositionPressure(allocator: std.mem.Allocator, pressure_object: std.json.ObjectMap, mode: ComposeMode, autonomy_mode: []const u8) !chat.ActionProposal {
    const action_text = try requiredStringField(pressure_object, "action");
    const action = capability_registry.actionForCapabilityId(action_text) orelse return error.InvalidProcessCompositionAction;
    if (action == .unknown) return error.InvalidProcessCompositionAction;
    if (mode == .autonomy and process_goal_port.isForbiddenAutonomyAction(action, autonomy_mode)) return error.InvalidProcessCompositionAction;
    const origin_text = optionalStringField(pressure_object, "origin") catch return error.InvalidProcessCompositionField;
    const scale_text = optionalStringField(pressure_object, "scale") catch return error.InvalidProcessCompositionField;
    const default_origin: []const u8 = switch (mode) {
        .autonomy => "autonomy",
        .interaction => "interaction",
    };
    return .{
        .action = action,
        .origin = parseOrigin(origin_text orelse default_origin) orelse return error.InvalidProcessCompositionField,
        .delay_ms = try optionalIntegerField(pressure_object, "delay_ms"),
        .scale = parseScale(scale_text orelse "full") orelse return error.InvalidProcessCompositionField,
        .text = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "text")),
        .query = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "query")),
        .memory_id = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "memory_id")),
        .schedule = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "schedule")),
        .heat_bias = try dupeOptionalString(allocator, try optionalHeatBiasField(pressure_object)),
        .eyes = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "eyes")),
        .mouth = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "mouth")),
        .duration_ms = try optionalIntegerField(pressure_object, "duration_ms"),
        .tags = try cloneTagsField(allocator, pressure_object),
    };
}

fn requiredArrayField(object: std.json.ObjectMap, name: []const u8) !std.json.Array {
    const value = object.get(name) orelse return error.MissingProcessCompositionField;
    return switch (value) {
        .array => |items| items,
        else => error.InvalidProcessCompositionField,
    };
}

fn requiredStringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.MissingProcessCompositionField;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidProcessCompositionField,
    };
}

fn optionalStringField(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidProcessCompositionField,
    };
}

fn optionalIntegerField(object: std.json.ObjectMap, name: []const u8) !?u32 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @intCast(number) else error.InvalidProcessCompositionField,
        else => error.InvalidProcessCompositionField,
    };
}

fn optionalHeatBiasField(object: std.json.ObjectMap) !?[]const u8 {
    const text = try optionalStringField(object, "heat_bias");
    if (text) |value| {
        if (std.mem.eql(u8, value, "low") or std.mem.eql(u8, value, "mixed") or std.mem.eql(u8, value, "high")) return value;
        return error.InvalidProcessCompositionField;
    }
    return null;
}

fn dupeOptionalString(allocator: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    return if (text) |value| try allocator.dupe(u8, value) else null;
}

fn cloneTagsField(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]const []const u8 {
    const value = object.get("tags") orelse return &.{};
    return switch (value) {
        .array => |array| {
            const tags = try allocator.alloc([]const u8, array.items.len);
            for (array.items, 0..) |item, i| {
                tags[i] = switch (item) {
                    .string => |text| try allocator.dupe(u8, text),
                    else => return error.InvalidProcessCompositionField,
                };
            }
            return tags;
        },
        else => error.InvalidProcessCompositionField,
    };
}

fn parseOrigin(text: []const u8) ?chat.ActionOrigin {
    if (std.mem.eql(u8, text, "interaction")) return .interaction;
    if (std.mem.eql(u8, text, "autonomy")) return .autonomy;
    return null;
}

fn parseScale(text: []const u8) ?chat.ActionScale {
    if (std.mem.eql(u8, text, "full")) return .full;
    if (std.mem.eql(u8, text, "medium")) return .medium;
    if (std.mem.eql(u8, text, "tiny")) return .tiny;
    return null;
}

fn reportCompositionParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nPROCESS COMPOSITION PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON with action_pressures and reason\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

test "validateProcessComposition rejects wrong origin and blocked camera actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const context =
        \\senses: no camera available
    ;
    const bad_origin = try parseProcessComposition(allocator,
        \\{"action_pressures":[{"action":"think_about","origin":"autonomy","query":"touch","tags":[]}],"reason":"reflect"}
    , .interaction, "limited");
    defer port_chat.freeActionProposals(allocator, bad_origin.action_pressures);
    defer allocator.free(bad_origin.reason);
    defer if (bad_origin.step_kinds.len > 0) allocator.free(@constCast(bad_origin.step_kinds));
    try std.testing.expectError(error.InvalidProcessCompositionOrigin, validateProcessComposition(bad_origin, .interaction, context));

    const camera_pull = try parseProcessComposition(allocator,
        \\{"action_pressures":[{"action":"recognize","origin":"interaction","tags":[]}],"reason":"look"}
    , .interaction, "limited");
    defer port_chat.freeActionProposals(allocator, camera_pull.action_pressures);
    defer allocator.free(camera_pull.reason);
    defer if (camera_pull.step_kinds.len > 0) allocator.free(@constCast(camera_pull.step_kinds));
    try std.testing.expectError(error.InvalidProcessCompositionAffordance, validateProcessComposition(camera_pull, .interaction, context));

    const feel_text = try parseProcessComposition(allocator,
        \\{"action_pressures":[{"action":"feel_about","origin":"interaction","text":"surprised","tags":[]}],"reason":"feel"}
    , .interaction, "limited");
    defer port_chat.freeActionProposals(allocator, feel_text.action_pressures);
    defer allocator.free(feel_text.reason);
    defer if (feel_text.step_kinds.len > 0) allocator.free(@constCast(feel_text.step_kinds));
    try std.testing.expectError(error.InvalidProcessCompositionQuery, validateProcessComposition(feel_text, .interaction, context));
}

test "parseProcessComposition requires non-empty action pressures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.EmptyProcessComposition, parseProcessComposition(allocator,
        \\{"action_pressures":[],"reason":"nothing"}
    , .autonomy, "limited"));
    const result = try parseProcessComposition(allocator,
        \\{"action_pressures":[{"action":"think_about","origin":"autonomy","query":"touch","tags":["touch"]}],"reason":"reflect"}
    , .autonomy, "limited");
    try std.testing.expectEqual(@as(usize, 1), result.action_pressures.len);
    try std.testing.expectEqual(chat.ActionProposalType.think_about, result.action_pressures[0].action);
}

test "parseProcessComposition accepts host sense pulls without legacy full mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try parseProcessComposition(allocator,
        \\{"action_pressures":[{"action":"take_picture","origin":"autonomy","delay_ms":null,"scale":"full","text":null,"query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":[]}],"reason":"look"}
    , .autonomy, "limited");
    try std.testing.expectEqual(chat.ActionProposalType.take_picture, result.action_pressures[0].action);
}

test "parseProcessComposition accepts host sense pulls in compatibility full mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try parseProcessComposition(allocator,
        \\{"action_pressures":[{"action":"take_picture","origin":"autonomy","delay_ms":null,"scale":"full","text":null,"query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":[]}],"reason":"look"}
    , .autonomy, "full");
    try std.testing.expectEqual(chat.ActionProposalType.take_picture, result.action_pressures[0].action);
}
