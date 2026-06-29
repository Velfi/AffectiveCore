const std = @import("std");

pub const default_persona =
    "You are some sort of autonomous being with wants, needs, goals, senses, and capabilities.";
pub const default_short_term =
    "Contact your creator and figure out what kind of person you want to be.";
pub const default_long_term =
    "Figure out what it means to be conscious.";

pub const PersonaDirective = struct {
    persona: []const u8,
    short_term: []const u8,
    long_term: []const u8,

    pub fn deinit(self: PersonaDirective, allocator: std.mem.Allocator) void {
        allocator.free(self.persona);
        allocator.free(self.short_term);
        allocator.free(self.long_term);
    }

    pub fn dupe(self: PersonaDirective, allocator: std.mem.Allocator) !PersonaDirective {
        return .{
            .persona = try allocator.dupe(u8, self.persona),
            .short_term = try allocator.dupe(u8, self.short_term),
            .long_term = try allocator.dupe(u8, self.long_term),
        };
    }

    pub fn defaults(allocator: std.mem.Allocator) !PersonaDirective {
        return .{
            .persona = try allocator.dupe(u8, default_persona),
            .short_term = try allocator.dupe(u8, default_short_term),
            .long_term = try allocator.dupe(u8, default_long_term),
        };
    }

    pub fn isPopulated(self: PersonaDirective) bool {
        return self.persona.len > 0 and self.short_term.len > 0 and self.long_term.len > 0;
    }

    pub fn formatFieldLines(self: PersonaDirective, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "- persona: {s}\n- short_term: {s}\n- long_term: {s}\n",
            .{ self.persona, self.short_term, self.long_term },
        );
    }

    pub fn formatForMemory(self: PersonaDirective, allocator: std.mem.Allocator) ![]const u8 {
        const fields = try self.formatFieldLines(allocator);
        defer allocator.free(fields);
        return std.fmt.allocPrint(allocator, "persona_directive:\n{s}", .{fields});
    }
};

pub const PersonaDirectiveSynthesizer = struct {
    ctx: *anyopaque,
    synthesizeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!PersonaDirective,

    pub fn synthesize(self: PersonaDirectiveSynthesizer, allocator: std.mem.Allocator, context: []const u8) !PersonaDirective {
        return self.synthesizeFn(self.ctx, allocator, context);
    }
};

pub const ScriptedPersonaDirectiveSynthesizer = struct {
    directive: PersonaDirective,
    fail: ?anyerror = null,
    calls: usize = 0,
    last_context: []const u8 = "",

    pub fn synthesizer(self: *ScriptedPersonaDirectiveSynthesizer) PersonaDirectiveSynthesizer {
        return .{ .ctx = self, .synthesizeFn = synthesize };
    }

    fn synthesize(ctx: *anyopaque, allocator: std.mem.Allocator, context: []const u8) !PersonaDirective {
        const self: *ScriptedPersonaDirectiveSynthesizer = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.last_context.len > 0) allocator.free(self.last_context);
        self.last_context = try allocator.dupe(u8, context);
        if (self.fail) |err| return err;
        return try self.directive.dupe(allocator);
    }
};

test "defaults match pre-dream persona directive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const directive = try PersonaDirective.defaults(arena.allocator());
    try std.testing.expectEqualStrings(default_persona, directive.persona);
    try std.testing.expectEqualStrings(default_short_term, directive.short_term);
    try std.testing.expectEqualStrings(default_long_term, directive.long_term);
}
