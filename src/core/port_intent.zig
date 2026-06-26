const std = @import("std");

pub const IntentContext = enum {
    provide_name,
    name_prompt,
    identity_confirmation,
    identity_claim,
};

pub const IntentAction = enum {
    provide_name,
    claim_identity,
    grant_memory_permission,
    deny_memory_permission,
    forget_me,
    sleep_autonomy,
    wake_autonomy,
    quit,
    unknown,
};

pub const IntentResult = struct {
    action: IntentAction,
    value: ?[]const u8 = null,
};

pub const IntentService = struct {
    ctx: *anyopaque,
    classifyFn: *const fn (*anyopaque, std.mem.Allocator, IntentContext, []const u8) anyerror!IntentResult,

    pub fn classify(self: IntentService, allocator: std.mem.Allocator, context: IntentContext, text: []const u8) !IntentResult {
        return self.classifyFn(self.ctx, allocator, context, text);
    }
};

pub const TestIntentService = struct {
    pub fn service(self: *TestIntentService) IntentService {
        return .{ .ctx = self, .classifyFn = classify };
    }

    fn classify(_: *anyopaque, allocator: std.mem.Allocator, context: IntentContext, text: []const u8) !IntentResult {
        return classifyHeuristic(allocator, context, text);
    }
};

pub fn classifyHeuristic(allocator: std.mem.Allocator, context: IntentContext, text: []const u8) !IntentResult {
    const trimmed = std.mem.trim(u8, text, " \r\n\t.!?");
    if (trimmed.len == 0) return .{ .action = .unknown };
    if (std.ascii.eqlIgnoreCase(trimmed, "quit") or std.ascii.eqlIgnoreCase(trimmed, "exit") or std.ascii.eqlIgnoreCase(trimmed, "stop")) return .{ .action = .quit };
    if (std.ascii.indexOfIgnoreCase(trimmed, "forget me") != null) return .{ .action = .forget_me };
    if (std.ascii.indexOfIgnoreCase(trimmed, "go to sleep") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "pause autonomy") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "stop self-directed") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "sleep autonomy") != null)
    {
        return .{ .action = .sleep_autonomy };
    }
    if (std.ascii.indexOfIgnoreCase(trimmed, "wake up") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "resume autonomy") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "restart autonomy") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "wake autonomy") != null)
    {
        return .{ .action = .wake_autonomy };
    }

    switch (context) {
        .identity_confirmation => {
            if (isAffirmative(trimmed)) return .{ .action = .grant_memory_permission };
            if (isNegative(trimmed)) return .{ .action = .deny_memory_permission };
        },
        .provide_name, .name_prompt, .identity_claim => {},
    }

    if (context == .identity_claim) {
        if (try extractIdentityClaimName(allocator, trimmed)) |name| return .{ .action = .claim_identity, .value = name };
        return .{ .action = .unknown };
    }

    if (try extractName(allocator, trimmed)) |name| return .{ .action = .provide_name, .value = name };
    if (context == .name_prompt and looksLikeBareName(trimmed)) return .{ .action = .provide_name, .value = try allocator.dupe(u8, trimmed) };
    return .{ .action = .unknown };
}

fn isAffirmative(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "y") or
        std.ascii.eqlIgnoreCase(text, "yep") or
        std.ascii.eqlIgnoreCase(text, "yeah") or
        std.ascii.eqlIgnoreCase(text, "yess") or
        std.ascii.eqlIgnoreCase(text, "sure") or
        std.ascii.eqlIgnoreCase(text, "please do") or
        std.ascii.indexOfIgnoreCase(text, "you can") != null;
}

fn isNegative(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "no") or
        std.ascii.eqlIgnoreCase(text, "n") or
        std.ascii.eqlIgnoreCase(text, "nope") or
        std.ascii.indexOfIgnoreCase(text, "do not") != null or
        std.ascii.indexOfIgnoreCase(text, "don't") != null;
}

fn extractName(allocator: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const markers = [_][]const u8{ "my name is ", "i am ", "i'm ", "im ", "call me " };
    for (markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(text, marker)) |idx| {
            const start = idx + marker.len;
            const name = std.mem.trim(u8, text[start..], " \r\n\t.!?");
            if (looksLikeBareName(name)) return try allocator.dupe(u8, name);
        }
    }
    return null;
}

fn looksLikeBareName(text: []const u8) bool {
    if (text.len == 0 or text.len > 80) return false;
    var saw_letter = false;
    var word_count: usize = 0;
    var in_word = false;
    for (text) |ch| {
        if (std.ascii.isAlphabetic(ch)) {
            saw_letter = true;
            if (!in_word) {
                word_count += 1;
                in_word = true;
                if (word_count > 4) return false;
            }
        } else if (ch == ' ' or ch == '\t' or ch == '-' or ch == '\'') {
            in_word = false;
        } else {
            return false;
        }
    }
    return saw_letter;
}

fn extractIdentityClaimName(allocator: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const markers = [_][]const u8{
        "it's me ",
        "it's me, ",
        "its me ",
        "its me, ",
        "it is me ",
        "it is me, ",
        "you know me i'm ",
        "you know me im ",
        "you know me, i'm ",
        "you know me, im ",
    };
    for (markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(text, marker)) |idx| {
            const start = idx + marker.len;
            const name = std.mem.trim(u8, text[start..], " \r\n\t.!?");
            if (name.len > 0) return try allocator.dupe(u8, name);
        }
    }
    return null;
}

test "provide name context does not treat arbitrary speech as a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try classifyHeuristic(arena.allocator(), .provide_name, "I'm someone you've met before");
    try std.testing.expectEqual(IntentAction.unknown, result.action);
}

test "name prompt accepts plausible bare and conversational names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bare = try classifyHeuristic(allocator, .name_prompt, "Zelda");
    try std.testing.expectEqual(IntentAction.provide_name, bare.action);
    try std.testing.expectEqualStrings("Zelda", bare.value.?);

    const conversational = try classifyHeuristic(allocator, .name_prompt, "Hello. I'm Zelda");
    try std.testing.expectEqual(IntentAction.provide_name, conversational.action);
    try std.testing.expectEqualStrings("Zelda", conversational.value.?);
}
