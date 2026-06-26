const std = @import("std");

pub const active_event_log_target_bytes: u64 = 1024 * 1024;
pub const active_event_log_read_limit: u64 = active_event_log_target_bytes * 4;
const active_event_log_recent_lines: usize = 512;
const active_event_log_line_limit: usize = 16 * 1024;

pub const RuntimeEventCompactionResult = struct {
    bytes: []const u8,
    dropped: usize,
};

pub fn eventLogNeedsLineBreak(file: std.Io.File, io: std.Io, size: u64) !bool {
    if (size == 0) return false;
    var byte: [1]u8 = undefined;
    const read_count = try file.readPositionalAll(io, &byte, size - 1);
    return read_count == 1 and byte[0] != '\n';
}

pub fn trimPartialFirstLine(bytes: []const u8) []const u8 {
    const newline = std.mem.indexOfScalar(u8, bytes, '\n') orelse return "";
    return bytes[newline + 1 ..];
}

pub fn compactRuntimeEventLines(allocator: std.mem.Allocator, bytes: []const u8) !RuntimeEventCompactionResult {
    var line_count: usize = 0;
    var iter_count = std.mem.splitScalar(u8, bytes, '\n');
    while (iter_count.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
    }

    var out = std.ArrayList(u8).empty;
    var line_index: usize = 0;
    var dropped: usize = 0;
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const recent = line_count - line_index <= active_event_log_recent_lines;
        const important = runtimeEventLineIsMemoryRelevant(line);
        if ((recent or important) and out.items.len < active_event_log_target_bytes) {
            try appendRuntimeEventLine(allocator, &out, line);
        } else {
            dropped += 1;
        }
        line_index += 1;
    }
    if (dropped > 0) {
        const summary = try std.fmt.allocPrint(allocator, "{{\"kind\":\"system\",\"title\":\"events_compacted\",\"body\":\"dropped={d}\",\"source\":\"storage\",\"tags\":[\"events\",\"compaction\"]}}\n", .{dropped});
        defer allocator.free(summary);
        if (summary.len + out.items.len <= active_event_log_target_bytes) {
            try out.insertSlice(allocator, 0, summary);
        }
    }
    return .{
        .bytes = try out.toOwnedSlice(allocator),
        .dropped = dropped,
    };
}

fn appendRuntimeEventLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    if (line.len <= active_event_log_line_limit) {
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
        return;
    }
    try out.print(
        allocator,
        "{{\"kind\":\"system\",\"title\":\"event_line_compacted\",\"body\":\"original_bytes={d}\",\"source\":\"storage\",\"tags\":[\"events\",\"compaction\"]}}\n",
        .{line.len},
    );
}

fn runtimeEventLineIsMemoryRelevant(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "\"severity\":\"warning\"") != null or
        std.mem.indexOf(u8, line, "\"severity\":\"critical\"") != null or
        std.mem.indexOf(u8, line, "\"severity\":\"concern\"") != null or
        std.mem.indexOf(u8, line, "\"kind\":\"error\"") != null or
        std.mem.indexOf(u8, line, "\"kind\":\"memory_mutation\"") != null or
        std.mem.indexOf(u8, line, "\"kind\":\"reminder\"") != null or
        std.mem.indexOf(u8, line, "\"psyche_role\":") != null or
        std.mem.indexOf(u8, line, "\"attention_candidate\":true") != null or
        std.mem.indexOf(u8, line, "\"experience_retention\":\"summarize\"") != null or
        std.mem.indexOf(u8, line, "\"experience_retention\":\"keep_episode\"") != null or
        std.mem.indexOf(u8, line, "\"experience_retention\":\"keep_fact\"") != null or
        std.mem.indexOf(u8, line, "\"experience_retention\":\"keep_disposition\"") != null or
        std.mem.indexOf(u8, line, "\"created_memory_id\":") != null or
        std.mem.indexOf(u8, line, "\"forgotten_memory_id\":") != null or
        std.mem.indexOf(u8, line, "\"created_fact_id\":") != null or
        std.mem.indexOf(u8, line, "\"invalidated_fact_id\":") != null;
}
