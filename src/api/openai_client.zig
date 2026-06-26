const std = @import("std");
const service_errors = @import("service_errors.zig");
const ai = @import("random_provider_client.zig");
const identity = @import("openai_identity_client.zig");
const openai_port = @import("../core/port_openai.zig");

pub const VISUAL_DESCRIPTION_POLICY = openai_port.VISUAL_DESCRIPTION_POLICY;

const visual_description_json_schema =
    \\{"type":"object","additionalProperties":false,"required":["description","change_summary","durable_notes","temporary_notes"],"properties":{"description":{"type":"string"},"change_summary":{"type":"string"},"durable_notes":{"type":"array","items":{"type":"string"}},"temporary_notes":{"type":"array","items":{"type":"string"}}}}
;

pub const VisualDescription = openai_port.VisualDescription;
pub const IdentityComparison = openai_port.IdentityComparison;
pub const IdentityComparisonService = openai_port.IdentityComparisonService;
pub const DescriptionService = openai_port.DescriptionService;
pub const TestDescriptionService = openai_port.TestDescriptionService;

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

test "random-provider visual description schema matches canonical shape" {
    try std.testing.expect(std.mem.indexOf(u8, visual_description_json_schema, "\"required\":[\"description\",\"change_summary\",\"durable_notes\",\"temporary_notes\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, visual_description_json_schema, "\"additionalProperties\":false") != null);
}

pub const TestIdentityComparisonService = identity.TestIdentityComparisonService;
pub const RandomProviderIdentityComparisonService = identity.RandomProviderIdentityComparisonService;
