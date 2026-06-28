const std = @import("std");
const ports = @import("ports.zig");
const skills_mod = ports.skills;
const chat_mod = ports.chat;

pub const SynonymGroup = struct {
    canonical: []const u8,
    synonyms: []const []const u8,
};

/// Alternate names hosts and models use for canonical capability ids.
pub const groups = [_]SynonymGroup{
    .{ .canonical = "say", .synonyms = &.{ "text_reply", "speech", "speak", "reply", "talk", "respond" } },
    .{ .canonical = "recognize", .synonyms = &.{ "RecognizeSubject", "identify", "recognise", "face_recognition", "Recognize" } },
    .{ .canonical = "take_picture", .synonyms = &.{ "camera_capture", "capture_photo", "photograph", "take_photo" } },
    .{ .canonical = "describe_image", .synonyms = &.{ "image_description", "describe_photo", "describe_picture" } },
    .{ .canonical = "compare_images", .synonyms = &.{ "image_comparison", "compare_photos" } },
    .{ .canonical = "recall_fact", .synonyms = &.{ "memory_read", "read_memory", "recall_memory" } },
    .{ .canonical = "set_fact", .synonyms = &.{ "memory_write", "write_memory", "remember_fact" } },
    .{ .canonical = "consolidate_memory", .synonyms = &.{ "request_dream_time", "dream_generation", "dream", "enter_dream", "enter_dream_time" } },
    .{ .canonical = "remember_person", .synonyms = &.{ "enroll_person", "register_person", "RememberPerson" } },
    .{ .canonical = "forget_person", .synonyms = &.{ "forget_profile", "ForgetPerson" } },
    .{ .canonical = "update_face_picture", .synonyms = &.{ "face_picture_update", "update_face" } },
    .{ .canonical = "imagine_image", .synonyms = &.{ "generate_image", "image_generation" } },
    .{ .canonical = "request_orientation", .synonyms = &.{ "orientation_query", "get_orientation" } },
};

comptime {
    @setEvalBranchQuota(3000);
    for (groups) |group| {
        var found = false;
        for (@typeInfo(skills_mod.SkillId).@"enum".fields) |field| {
            if (std.mem.eql(u8, field.name, group.canonical)) found = true;
        }
        if (!found) @compileError("capability synonym group references unknown canonical id: " ++ group.canonical);
    }
}

pub fn resolveCapabilityId(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return trimmed;

    inline for (@typeInfo(skills_mod.SkillId).@"enum".fields) |field| {
        if (!std.mem.eql(u8, field.name, "unknown") and eqlIgnoreCase(trimmed, field.name)) return field.name;
    }

    inline for (groups) |group| {
        for (group.synonyms) |synonym| {
            if (eqlIgnoreCase(trimmed, synonym)) return group.canonical;
        }
    }

    return trimmed;
}

pub fn resolveAction(text: []const u8) ?chat_mod.ActionProposalType {
    const canonical = resolveCapabilityId(text);
    inline for (@typeInfo(chat_mod.ActionProposalType).@"enum".fields) |field| {
        if (std.mem.eql(u8, canonical, field.name)) return @field(chat_mod.ActionProposalType, field.name);
    }
    return null;
}

pub fn isKnownCapabilityName(text: []const u8) bool {
    return resolveAction(text) != null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

test "resolveCapabilityId accepts canonical names case-insensitively" {
    try std.testing.expectEqualStrings("say", resolveCapabilityId("Say"));
    try std.testing.expectEqualStrings("recognize", resolveCapabilityId("RECOGNIZE"));
    try std.testing.expectEqualStrings("take_picture", resolveCapabilityId(" take_picture "));
}

test "resolveCapabilityId maps synonyms to canonical ids" {
    try std.testing.expectEqualStrings("say", resolveCapabilityId("speak"));
    try std.testing.expectEqualStrings("say", resolveCapabilityId("text_reply"));
    try std.testing.expectEqualStrings("recognize", resolveCapabilityId("RecognizeSubject"));
    try std.testing.expectEqualStrings("recognize", resolveCapabilityId("identify"));
    try std.testing.expectEqualStrings("take_picture", resolveCapabilityId("camera_capture"));
    try std.testing.expectEqualStrings("recall_fact", resolveCapabilityId("memory_read"));
    try std.testing.expectEqualStrings("consolidate_memory", resolveCapabilityId("dream_generation"));
}

test "resolveAction returns enum values for synonyms" {
    try std.testing.expectEqual(chat_mod.ActionProposalType.say, resolveAction("speak").?);
    try std.testing.expectEqual(chat_mod.ActionProposalType.recognize, resolveAction("identify").?);
    try std.testing.expectEqual(@as(?chat_mod.ActionProposalType, null), resolveAction("not_a_capability"));
}

test "isKnownCapabilityName rejects unknown labels" {
    try std.testing.expect(isKnownCapabilityName("speak"));
    try std.testing.expect(!isKnownCapabilityName("do_magic"));
}
