const std = @import("std");

pub const SeedEntryKind = enum {
    core_value,
    operating_tendency,
    want,
    superego_principle,

    pub fn tag(self: SeedEntryKind) []const u8 {
        return switch (self) {
            .core_value => "core_value",
            .operating_tendency => "seed_operating_tendency",
            .want => "self_want",
            .superego_principle => "superego_principle",
        };
    }

    pub fn label(self: SeedEntryKind) []const u8 {
        return switch (self) {
            .core_value => "core value",
            .operating_tendency => "operating tendency",
            .want => "want",
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
};

const Section = enum {
    other,
    core_values,
    operating_tendencies,
    wants,
    superego_principles,
};

pub fn readSeedFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !SeedDocument {
    const bytes = try readFileAllocPath(io, path, allocator, .limited(128 * 1024));
    defer allocator.free(bytes);
    return parseSeedMarkdown(allocator, bytes);
}

pub fn parseSeedMarkdown(allocator: std.mem.Allocator, markdown: []const u8) !SeedDocument {
    var name: ?[]const u8 = null;
    var section: Section = .other;
    var entries = std.ArrayList(SeedEntry).empty;
    var core_count: usize = 0;
    var tendency_count: usize = 0;
    var want_count: usize = 0;
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
            else if (std.ascii.eqlIgnoreCase(heading, "Wants"))
                .wants
            else if (std.ascii.eqlIgnoreCase(heading, "Superego Principles") or std.ascii.eqlIgnoreCase(heading, "Principles"))
                .superego_principles
            else
                .other;
            continue;
        }

        switch (section) {
            .core_values, .operating_tendencies, .wants, .superego_principles => {
                if (!std.mem.startsWith(u8, line, "- ")) return error.InvalidSeedBullet;
                const text = std.mem.trim(u8, line[2..], " \r\t");
                if (text.len == 0) return error.EmptySeedBullet;
                const kind: SeedEntryKind = switch (section) {
                    .core_values => .core_value,
                    .operating_tendencies => .operating_tendency,
                    .wants => .want,
                    .superego_principles => .superego_principle,
                    .other => unreachable,
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
    };
}

fn readFileAllocPath(io: std.Io, path: []const u8, allocator: std.mem.Allocator, limit: std.Io.Limit) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
    }
    const dirname = std.fs.path.dirname(path) orelse return error.MissingParentDirectory;
    const basename = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, dirname, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, basename, allocator, limit);
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
