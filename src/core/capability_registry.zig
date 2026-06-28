const std = @import("std");
const ports = @import("ports.zig");
const skills_mod = ports.skills;
const chat_mod = ports.chat;
const capability_synonyms = @import("capability_synonyms.zig");

pub const SynonymGroup = capability_synonyms.SynonymGroup;
pub const synonym_groups = capability_synonyms.groups;

pub const CapabilityEntry = struct {
    capability_id: []const u8,
    action: ?chat_mod.ActionProposalType,
    description: []const u8,
};

pub fn entries() []const CapabilityEntry {
    return &capability_entries;
}

pub fn lookup(capability_id: []const u8) ?CapabilityEntry {
    const canonical = canonicalId(capability_id);
    for (capability_entries) |entry| {
        if (std.mem.eql(u8, entry.capability_id, canonical)) return entry;
    }
    return null;
}

pub fn canonicalId(capability_id: []const u8) []const u8 {
    return capability_synonyms.resolveCapabilityId(capability_id);
}

pub fn capabilityIdForAction(action: chat_mod.ActionProposalType) []const u8 {
    return @tagName(action);
}

pub fn actionForCapabilityId(capability_id: []const u8) ?chat_mod.ActionProposalType {
    return capability_synonyms.resolveAction(capability_id);
}

const capability_entries = blk: {
    @setEvalBranchQuota(5000);
    var out: [skills_mod.registry.len]CapabilityEntry = undefined;
    for (skills_mod.registry, 0..) |spec, i| {
        const action: ?chat_mod.ActionProposalType = blk2: {
            for (@typeInfo(chat_mod.ActionProposalType).@"enum".fields) |field| {
                if (std.mem.eql(u8, field.name, spec.name)) break :blk2 @field(chat_mod.ActionProposalType, field.name);
            }
            break :blk2 null;
        };
        out[i] = .{
            .capability_id = spec.name,
            .action = action,
            .description = spec.description,
        };
    }
    break :blk out;
};

test "capability registry resolves synonyms and actions" {
    try std.testing.expectEqualStrings("say", canonicalId("text_reply"));
    try std.testing.expectEqualStrings("say", canonicalId("speech"));
    try std.testing.expectEqualStrings("say", canonicalId("speak"));
    try std.testing.expectEqualStrings("say", canonicalId("Say"));
    try std.testing.expectEqualStrings("recognize", canonicalId("RecognizeSubject"));
    try std.testing.expectEqualStrings("recognize", canonicalId("identify"));
    try std.testing.expect(actionForCapabilityId("text_reply") != null);
    try std.testing.expect(actionForCapabilityId("say") != null);
    try std.testing.expect(lookup("say") != null);
    try std.testing.expect(lookup("speech") != null);
}
