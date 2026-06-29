const std = @import("std");
const context_composition = @import("context_composition.zig");
const context_tokens = @import("context_tokens.zig");
const chat = @import("port_chat.zig");

pub const top_section_limit: usize = context_composition.top_section_limit;

pub const SectionEntry = struct {
    name: []const u8,
    bytes: usize,
    count: ?usize = null,

    pub fn jsonStringify(self: SectionEntry, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("bytes");
        try jw.write(self.bytes);
        if (self.count) |count| {
            try jw.objectField("count");
            try jw.write(count);
        }
        try jw.endObject();
    }
};

pub const Report = struct {
    dispatch_id: []const u8 = "",
    operation: []const u8 = "",
    stimulus_kind: ?[]const u8 = null,
    compact_memory_bytes: usize = 0,
    observations_bytes: usize = 0,
    user_prompt_bytes: usize = 0,
    user_prompt_tokens: usize = 0,
    system_prompt_bytes: usize = 0,
    budget_max_tokens: usize = 0,
    budget_exceeded: bool = false,
    sections: []const SectionEntry = &.{},
    top_sections: []const SectionEntry = &.{},
    warnings: []const []const u8 = &.{},
    llm_call_count: usize = 0,

    pub fn jsonStringify(self: Report, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("dispatch_id");
        try jw.write(self.dispatch_id);
        try jw.objectField("operation");
        try jw.write(self.operation);
        if (self.stimulus_kind) |kind| {
            try jw.objectField("stimulus_kind");
            try jw.write(kind);
        }
        try jw.objectField("compact_memory_bytes");
        try jw.write(self.compact_memory_bytes);
        try jw.objectField("observations_bytes");
        try jw.write(self.observations_bytes);
        try jw.objectField("user_prompt_bytes");
        try jw.write(self.user_prompt_bytes);
        try jw.objectField("user_prompt_tokens");
        try jw.write(self.user_prompt_tokens);
        try jw.objectField("system_prompt_bytes");
        try jw.write(self.system_prompt_bytes);
        try jw.objectField("budget_max_tokens");
        try jw.write(self.budget_max_tokens);
        try jw.objectField("budget_exceeded");
        try jw.write(self.budget_exceeded);
        try jw.objectField("sections");
        try jw.write(self.sections);
        try jw.objectField("top_sections");
        try jw.write(self.top_sections);
        try jw.objectField("warnings");
        try jw.write(self.warnings);
        try jw.objectField("llm_call_count");
        try jw.write(self.llm_call_count);
        try jw.endObject();
    }
};

pub const OwnedReport = struct {
    dispatch_id: []const u8,
    operation: []const u8,
    stimulus_kind: ?[]const u8,
    compact_memory_bytes: usize,
    observations_bytes: usize,
    user_prompt_bytes: usize,
    user_prompt_tokens: usize,
    system_prompt_bytes: usize,
    budget_max_tokens: usize,
    budget_exceeded: bool,
    sections: []SectionEntry,
    top_sections: []SectionEntry,
    warnings: []const []const u8,
    llm_call_count: usize,

    pub fn deinit(self: *OwnedReport, allocator: std.mem.Allocator) void {
        allocator.free(self.dispatch_id);
        allocator.free(self.operation);
        if (self.stimulus_kind) |kind| allocator.free(kind);
        for (self.sections) |section| allocator.free(section.name);
        allocator.free(self.sections);
        for (self.top_sections) |section| allocator.free(section.name);
        allocator.free(self.top_sections);
        for (self.warnings) |warning| allocator.free(warning);
        allocator.free(self.warnings);
        self.* = .{
            .dispatch_id = "",
            .operation = "",
            .stimulus_kind = null,
            .compact_memory_bytes = 0,
            .observations_bytes = 0,
            .user_prompt_bytes = 0,
            .user_prompt_tokens = 0,
            .system_prompt_bytes = 0,
            .budget_max_tokens = 0,
            .budget_exceeded = false,
            .sections = &.{},
            .top_sections = &.{},
            .warnings = &.{},
            .llm_call_count = 0,
        };
    }

    pub fn view(self: *const OwnedReport) Report {
        return .{
            .dispatch_id = self.dispatch_id,
            .operation = self.operation,
            .stimulus_kind = self.stimulus_kind,
            .compact_memory_bytes = self.compact_memory_bytes,
            .observations_bytes = self.observations_bytes,
            .user_prompt_bytes = self.user_prompt_bytes,
            .user_prompt_tokens = self.user_prompt_tokens,
            .system_prompt_bytes = self.system_prompt_bytes,
            .budget_max_tokens = self.budget_max_tokens,
            .budget_exceeded = self.budget_exceeded,
            .sections = self.sections,
            .top_sections = self.top_sections,
            .warnings = self.warnings,
            .llm_call_count = self.llm_call_count,
        };
    }

    /// Slim view for dispatch envelopes: section breakdown without the full section list.
    pub fn envelopeView(self: *const OwnedReport) Report {
        var report = self.view();
        report.sections = &.{};
        return report;
    }
};

fn sectionBytes(sections: []const SectionEntry, name: []const u8) usize {
    for (sections) |section| {
        if (std.mem.eql(u8, section.name, name)) return section.bytes;
    }
    return 0;
}

fn appendWarning(allocator: std.mem.Allocator, warnings: *std.ArrayList([]const u8), text: []const u8) !void {
    try warnings.append(allocator, try allocator.dupe(u8, text));
}

pub fn collectWarnings(
    allocator: std.mem.Allocator,
    sections: []const SectionEntry,
    user_prompt_tokens: usize,
    budget_max_tokens: usize,
    budget_exceeded: bool,
) ![]const []const u8 {
    var warnings = std.ArrayList([]const u8).empty;
    errdefer {
        for (warnings.items) |warning| allocator.free(warning);
        warnings.deinit(allocator);
    }

    const memory_bytes = sectionBytes(sections, "compact_memory.relevant_memories");
    const selection_bytes = sectionBytes(sections, "observations.memory_selection");
    if (memory_bytes > 0 and selection_bytes > 0) {
        try appendWarning(allocator, &warnings, "memory_selection_duplicates_compact_memory");
    }

    for (sections) |section| {
        if (std.mem.startsWith(u8, section.name, "observations.checkpoint_resume") or std.mem.eql(u8, section.name, "checkpoint_resume")) {
            try appendWarning(allocator, &warnings, "checkpoint_resume_present");
            break;
        }
    }

    if (!budget_exceeded and budget_max_tokens > 0 and user_prompt_tokens * 10 >= budget_max_tokens * 9) {
        try appendWarning(allocator, &warnings, "context_near_budget_90pct");
    }

    return try warnings.toOwnedSlice(allocator);
}

fn cloneSections(allocator: std.mem.Allocator, sections: []const context_composition.SectionStat) ![]SectionEntry {
    var out = try allocator.alloc(SectionEntry, sections.len);
    for (sections, 0..) |section, index| {
        out[index] = .{
            .name = try allocator.dupe(u8, section.name),
            .bytes = section.bytes,
            .count = section.count,
        };
    }
    return out;
}

fn topSectionsFromOwned(allocator: std.mem.Allocator, sections: []const SectionEntry) ![]SectionEntry {
    if (sections.len == 0) return try allocator.alloc(SectionEntry, 0);
    const ranked = try allocator.alloc(SectionEntry, sections.len);
    @memcpy(ranked, sections);
    std.mem.sort(SectionEntry, ranked, {}, struct {
        fn lessThan(_: void, lhs: SectionEntry, rhs: SectionEntry) bool {
            if (lhs.bytes != rhs.bytes) return lhs.bytes > rhs.bytes;
            return std.mem.order(u8, lhs.name, rhs.name) == .lt;
        }
    }.lessThan);
    const take = @min(top_section_limit, ranked.len);
    var out = try allocator.alloc(SectionEntry, take);
    for (0..take) |index| {
        out[index] = .{
            .name = try allocator.dupe(u8, ranked[index].name),
            .bytes = ranked[index].bytes,
            .count = ranked[index].count,
        };
    }
    allocator.free(ranked);
    return out;
}

pub fn ownedFromComposition(
    allocator: std.mem.Allocator,
    dispatch_id: []const u8,
    stimulus_kind: ?chat.StimulusKind,
    budget_max_tokens: usize,
    budget_exceeded: bool,
    report: context_composition.ContextCompositionReport,
) !OwnedReport {
    const sections = try cloneSections(allocator, report.sections);
    errdefer {
        for (sections) |section| allocator.free(section.name);
        allocator.free(sections);
    }
    const user_prompt_tokens = if (report.user_prompt_tokens > 0)
        report.user_prompt_tokens
    else
        context_tokens.estimateTokensFromByteLength(report.user_prompt_bytes);

    const warnings = try collectWarnings(allocator, sections, user_prompt_tokens, budget_max_tokens, budget_exceeded);
    errdefer {
        for (warnings) |warning| allocator.free(warning);
        allocator.free(warnings);
    }

    const top_owned = try topSectionsFromOwned(allocator, sections);
    errdefer {
        for (top_owned) |section| allocator.free(section.name);
        allocator.free(top_owned);
    }

    const stimulus_text = if (stimulus_kind) |kind| try allocator.dupe(u8, @tagName(kind)) else null;

    return .{
        .dispatch_id = try allocator.dupe(u8, dispatch_id),
        .operation = try allocator.dupe(u8, report.operation),
        .stimulus_kind = stimulus_text,
        .compact_memory_bytes = report.compact_memory_bytes,
        .observations_bytes = report.observations_bytes,
        .user_prompt_bytes = report.user_prompt_bytes,
        .user_prompt_tokens = user_prompt_tokens,
        .system_prompt_bytes = report.system_prompt_bytes orelse 0,
        .budget_max_tokens = budget_max_tokens,
        .budget_exceeded = budget_exceeded,
        .sections = sections,
        .top_sections = top_owned,
        .warnings = warnings,
        .llm_call_count = 0,
    };
}

test "collectWarnings flags duplication and near budget" {
    const sections = [_]SectionEntry{
        .{ .name = "compact_memory.relevant_memories", .bytes = 100 },
        .{ .name = "observations.memory_selection", .bytes = 80 },
    };
    const warnings = try collectWarnings(std.testing.allocator, &sections, 9000, 10000, false);
    defer {
        for (warnings) |warning| std.testing.allocator.free(warning);
        std.testing.allocator.free(warnings);
    }
    try std.testing.expectEqual(@as(usize, 2), warnings.len);
    try std.testing.expect(std.mem.eql(u8, warnings[0], "memory_selection_duplicates_compact_memory"));
    try std.testing.expect(std.mem.eql(u8, warnings[1], "context_near_budget_90pct"));
}
