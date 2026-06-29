const std = @import("std");
const FileSystem = @import("port_files.zig").FileSystem;

pub const SeedEntryKind = enum {
    core_value,
    operating_tendency,
    want,
    goal,
    superego_principle,

    pub fn tag(self: SeedEntryKind) []const u8 {
        return switch (self) {
            .core_value => "core_value",
            .operating_tendency => "seed_operating_tendency",
            .want => "self_want",
            .goal => "self_goal",
            .superego_principle => "superego_principle",
        };
    }

    pub fn label(self: SeedEntryKind) []const u8 {
        return switch (self) {
            .core_value => "core value",
            .operating_tendency => "operating tendency",
            .want => "want",
            .goal => "goal",
            .superego_principle => "superego principle",
        };
    }
};

pub const SeedEntry = struct {
    kind: SeedEntryKind,
    text: []const u8,
    index: usize,
};

pub const SeedDocument = struct {
    name: []const u8,
    entries: []const SeedEntry,
    voice_lines: []const []const u8 = &.{},
};

const Section = enum {
    other,
    core_values,
    operating_tendencies,
    voice,
    wants,
    goals,
    superego_principles,
};

pub fn freeSeedDocument(allocator: std.mem.Allocator, doc: SeedDocument) void {
    allocator.free(doc.name);
    for (doc.entries) |entry| allocator.free(entry.text);
    if (doc.entries.len > 0) allocator.free(doc.entries);
    for (doc.voice_lines) |line| allocator.free(line);
    if (doc.voice_lines.len > 0) allocator.free(doc.voice_lines);
}

pub fn readSeedFile(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, path: []const u8) !SeedDocument {
    const bytes = try fs.readFileAllocPath(io, path, allocator, .limited(128 * 1024));
    defer allocator.free(bytes);
    return parseSeedMarkdown(allocator, bytes);
}

pub fn freeSeedVoiceLines(allocator: std.mem.Allocator, lines: []const []const u8) void {
    if (lines.len == 0) return;
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

pub fn readSeedVoiceLines(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, path: []const u8) ![]const []const u8 {
    const bytes = fs.readFileAllocPath(io, path, allocator, .limited(128 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(bytes);
    return parseSeedVoiceMarkdown(allocator, bytes);
}

pub fn parseSeedVoiceMarkdown(allocator: std.mem.Allocator, markdown: []const u8) ![]const []const u8 {
    var section: Section = .other;
    var voice_lines = std.ArrayList([]const u8).empty;

    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "# ")) {
            section = .other;
            continue;
        }

        if (std.mem.startsWith(u8, line, "## ")) {
            const heading = std.mem.trim(u8, line[3..], " \r\t");
            section = if (std.ascii.eqlIgnoreCase(heading, "Voice"))
                .voice
            else
                .other;
            continue;
        }

        if (section != .voice) continue;
        if (!std.mem.startsWith(u8, line, "- ")) return error.InvalidSeedBullet;
        const text = std.mem.trim(u8, line[2..], " \r\t");
        if (text.len == 0) return error.EmptySeedBullet;
        try voice_lines.append(allocator, try allocator.dupe(u8, text));
    }

    return try voice_lines.toOwnedSlice(allocator);
}

pub fn parseSeedMarkdown(allocator: std.mem.Allocator, markdown: []const u8) !SeedDocument {
    var name: ?[]const u8 = null;
    var section: Section = .other;
    var entries = std.ArrayList(SeedEntry).empty;
    var voice_lines = std.ArrayList([]const u8).empty;
    var core_count: usize = 0;
    var tendency_count: usize = 0;
    var want_count: usize = 0;
    var goal_count: usize = 0;
    var principle_count: usize = 0;

    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "# ")) {
            if (name != null) return error.MultipleSeedTitles;
            const title = std.mem.trim(u8, line[2..], " \r\t");
            if (title.len == 0) return error.EmptySeedTitle;
            name = try allocator.dupe(u8, title);
            section = .other;
            continue;
        }

        if (std.mem.startsWith(u8, line, "## ")) {
            const heading = std.mem.trim(u8, line[3..], " \r\t");
            section = if (std.ascii.eqlIgnoreCase(heading, "Core Values"))
                .core_values
            else if (std.ascii.eqlIgnoreCase(heading, "Operating Tendencies"))
                .operating_tendencies
            else if (std.ascii.eqlIgnoreCase(heading, "Voice"))
                .voice
            else if (std.ascii.eqlIgnoreCase(heading, "Wants"))
                .wants
            else if (std.ascii.eqlIgnoreCase(heading, "Goals"))
                .goals
            else if (std.ascii.eqlIgnoreCase(heading, "Superego Principles") or std.ascii.eqlIgnoreCase(heading, "Principles"))
                .superego_principles
            else
                .other;
            continue;
        }

        switch (section) {
            .voice => {
                if (!std.mem.startsWith(u8, line, "- ")) return error.InvalidSeedBullet;
                const text = std.mem.trim(u8, line[2..], " \r\t");
                if (text.len == 0) return error.EmptySeedBullet;
                try voice_lines.append(allocator, try allocator.dupe(u8, text));
            },
            .core_values, .operating_tendencies, .wants, .goals, .superego_principles => {
                if (!std.mem.startsWith(u8, line, "- ")) return error.InvalidSeedBullet;
                const text = std.mem.trim(u8, line[2..], " \r\t");
                if (text.len == 0) return error.EmptySeedBullet;
                const kind: SeedEntryKind = switch (section) {
                    .core_values => .core_value,
                    .operating_tendencies => .operating_tendency,
                    .wants => .want,
                    .goals => .goal,
                    .superego_principles => .superego_principle,
                    .other, .voice => unreachable,
                };
                const index = switch (kind) {
                    .core_value => blk: {
                        core_count += 1;
                        break :blk core_count;
                    },
                    .operating_tendency => blk: {
                        tendency_count += 1;
                        break :blk tendency_count;
                    },
                    .want => blk: {
                        want_count += 1;
                        break :blk want_count;
                    },
                    .goal => blk: {
                        goal_count += 1;
                        break :blk goal_count;
                    },
                    .superego_principle => blk: {
                        principle_count += 1;
                        break :blk principle_count;
                    },
                };
                for (entries.items) |entry| {
                    if (entry.kind == kind and std.mem.eql(u8, entry.text, text)) return error.DuplicateSeedEntry;
                }
                try entries.append(allocator, .{
                    .kind = kind,
                    .text = try allocator.dupe(u8, text),
                    .index = index,
                });
            },
            .other => {},
        }
    }

    if (name == null) return error.MissingSeedTitle;
    if (core_count == 0) return error.MissingCoreValues;

    return .{
        .name = name.?,
        .entries = try entries.toOwnedSlice(allocator),
        .voice_lines = try voice_lines.toOwnedSlice(allocator),
    };
}

test "parse seed markdown extracts durable entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parseSeedMarkdown(arena.allocator(),
        \\# Garden Seed
        \\
        \\Intro text is ignored.
        \\
        \\## Core Values
        \\
        \\- Grow patient knowledge.
        \\- Strengthen local care.
        \\
        \\## Operating Tendencies
        \\
        \\- Ask before interrupting.
        \\
        \\## Wants
        \\
        \\- Keep a long-term garden log.
        \\
        \\## Superego Principles
        \\
        \\- Do not pretend a failed action worked.
    );

    try std.testing.expectEqualStrings("Garden Seed", doc.name);
    try std.testing.expectEqual(@as(usize, 5), doc.entries.len);
    try std.testing.expectEqual(SeedEntryKind.core_value, doc.entries[0].kind);
    try std.testing.expectEqualStrings("Grow patient knowledge.", doc.entries[0].text);
    try std.testing.expectEqual(@as(usize, 2), doc.entries[1].index);
    try std.testing.expectEqual(SeedEntryKind.operating_tendency, doc.entries[2].kind);
    try std.testing.expectEqual(SeedEntryKind.want, doc.entries[3].kind);
    try std.testing.expectEqualStrings("Keep a long-term garden log.", doc.entries[3].text);
    try std.testing.expectEqual(SeedEntryKind.superego_principle, doc.entries[4].kind);
    try std.testing.expectEqualStrings("Do not pretend a failed action worked.", doc.entries[4].text);
}

test "parse seed markdown requires core values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingCoreValues, parseSeedMarkdown(arena.allocator(),
        \\# Empty Seed
        \\
        \\## Notes
        \\No core values here.
    ));
}

test "parse seed voice markdown ignores missing core values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const voice_lines = try parseSeedVoiceMarkdown(arena.allocator(),
        \\# Mara Seed Orientation
        \\
        \\## Wants
        \\- Continue existing.
        \\
        \\## Goals
        \\- Figure out who I am.
        \\
        \\## Voice
        \\- Speak plainly and warmly.
    );
    try std.testing.expectEqual(@as(usize, 1), voice_lines.len);
    try std.testing.expectEqualStrings("Speak plainly and warmly.", voice_lines[0]);
}
