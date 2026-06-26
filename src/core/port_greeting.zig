const std = @import("std");

pub const GreetingIntent = enum {
    known_person,
    unknown_person,
    uncertain_person,
    memory_permission_denied,
    forget_profile,

    pub fn description(self: GreetingIntent) []const u8 {
        return switch (self) {
            .known_person => "welcome back a recognized known person",
            .unknown_person => "open a curious first exchange with an unrecognized person",
            .uncertain_person => "ask for identity when recognition is uncertain",
            .memory_permission_denied => "acknowledge that no memory should be kept after this conversation",
            .forget_profile => "confirm that a profile will be forgotten",
        };
    }
};

pub const GreetingContext = struct {
    intent: GreetingIntent = .known_person,
    person_name: ?[]const u8 = null,
    elapsed_days: ?i64 = null,
    visual_description: []const u8,
    change_summary: []const u8,
    senses: []const u8,
    interior_state: []const u8,
    stable_notes: []const []const u8,
    recent_notes: []const []const u8,
};

pub const GreetingService = struct {
    ctx: *anyopaque,
    generateFn: *const fn (*anyopaque, std.mem.Allocator, GreetingContext) anyerror![]const u8,

    pub fn generate(self: GreetingService, allocator: std.mem.Allocator, context: GreetingContext) ![]const u8 {
        return self.generateFn(self.ctx, allocator, context);
    }
};

pub const TestGreetingService = struct {
    pub fn service(self: *TestGreetingService) GreetingService {
        return .{ .ctx = self, .generateFn = generate };
    }

    fn generate(_: *anyopaque, allocator: std.mem.Allocator, context: GreetingContext) ![]const u8 {
        if (context.intent != .known_person) {
            return std.fmt.allocPrint(allocator, "generated {s} greeting", .{@tagName(context.intent)});
        }
        const person_name = context.person_name orelse return error.MissingGreetingPersonName;
        if (context.change_summary.len > 0) {
            return std.fmt.allocPrint(allocator, "Welcome back, {s}. I notice {s}.", .{ person_name, context.change_summary });
        }
        if (context.elapsed_days) |days| {
            if (days >= 2 and days < 9999) return std.fmt.allocPrint(allocator, "Welcome back, {s}. It has been {d} days.", .{ person_name, days });
        }
        return std.fmt.allocPrint(allocator, "Welcome back, {s}.", .{person_name});
    }
};
