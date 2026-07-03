const std = @import("std");
const embedded = @import("affective_core_embedded.zig");

const c = @cImport({
    @cInclude("affective_core_embedded.h");
});

test "embedded C ABI layout matches public header" {
    try expectSameLayout(c.AffectiveCoreEmbeddedString, embedded.AffectiveCoreEmbeddedString, &.{
        "ptr",
        "len",
    });
    try expectSameLayout(c.AffectiveCoreEmbeddedConfig, embedded.AffectiveCoreEmbeddedConfig, &.{
        "brain_id",
        "brain_root",
        "conversation_models",
        "conversation_reasoning_effort",
        "image_generation_model",
        "image_generation_output_dir",
        "memory_path",
        "graph_path",
        "schedule_path",
        "maintenance_state_path",
        "face_embeddings_dir",
        "host_manifest_json",
    });
    try expectSameLayout(c.AffectiveCoreEmbeddedHostServices, embedded.AffectiveCoreEmbeddedHostServices, &.{
        "ctx",
        "http_post_json_begin",
        "http_post_json_poll",
        "free_string",
        "on_host_events",
    });
    try expectPackedStringSlots(embedded.AffectiveCoreEmbeddedConfig, &.{
        "brain_id",
        "brain_root",
        "conversation_models",
        "conversation_reasoning_effort",
        "image_generation_model",
        "image_generation_output_dir",
        "memory_path",
        "graph_path",
        "schedule_path",
        "maintenance_state_path",
        "face_embeddings_dir",
        "host_manifest_json",
    });
}

test "embedded C ABI status values match public header" {
    try std.testing.expectEqual(@as(c_int, @intFromEnum(embedded.AffectiveCoreEmbeddedStatus.ok)), c.AFFECTIVE_CORE_EMBEDDED_OK);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(embedded.AffectiveCoreEmbeddedStatus.invalid_argument)), c.AFFECTIVE_CORE_EMBEDDED_INVALID_ARGUMENT);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(embedded.AffectiveCoreEmbeddedStatus.initialization_failed)), c.AFFECTIVE_CORE_EMBEDDED_INITIALIZATION_FAILED);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(embedded.AffectiveCoreEmbeddedStatus.runtime_error)), c.AFFECTIVE_CORE_EMBEDDED_RUNTIME_ERROR);
}

fn expectSameLayout(comptime C: type, comptime Zig: type, comptime fields: []const []const u8) !void {
    try std.testing.expectEqual(@sizeOf(Zig), @sizeOf(C));
    try std.testing.expectEqual(@alignOf(Zig), @alignOf(C));
    inline for (fields) |field| {
        try std.testing.expectEqual(@offsetOf(Zig, field), @offsetOf(C, field));
    }
}

fn expectPackedStringSlots(comptime T: type, comptime fields: []const []const u8) !void {
    const slot_size = @sizeOf(embedded.AffectiveCoreEmbeddedString);
    try std.testing.expectEqual(fields.len * slot_size, @sizeOf(T));
    inline for (fields, 0..) |field, index| {
        try std.testing.expectEqual(index * slot_size, @offsetOf(T, field));
    }
}
