const std = @import("std");
const embedded_protocol = @import("embedded_protocol.zig");

pub const BudgetConfig = struct {
    max_envelope_bytes: usize = 16 * 1024,
    max_event_count: usize = 12,
    max_event_text_bytes: usize = 768,
    max_result_bytes: usize = 2 * 1024,
};

pub const RawRef = struct {
    id: []const u8,
    kind: []const u8,
    bytes: []const u8,
};

pub const BudgetReport = struct {
    max_bytes: usize,
    used_bytes: usize,
    compacted: bool,
    dropped_event_count: usize,
    raw_refs: []const []const u8,
};

pub const CompactEventsResult = struct {
    events: []const embedded_protocol.HostEvent,
    raw_refs: []const RawRef,
    budget: BudgetReport,
};

pub const CompactTextResult = struct {
    summary: []const u8,
    raw_refs: []const RawRef,
    compacted: bool,
};

pub fn compactText(
    allocator: std.mem.Allocator,
    now_seconds: i64,
    kind: []const u8,
    text: []const u8,
    max_bytes: usize,
) !CompactTextResult {
    if (text.len <= max_bytes) {
        return .{
            .summary = try allocator.dupe(u8, text),
            .raw_refs = &.{},
            .compacted = false,
        };
    }
    const raw_ref = try makeRawRef(allocator, now_seconds, kind, text);
    const preview_len = @min(text.len, max_bytes);
    const summary = try std.fmt.allocPrint(
        allocator,
        "{s} compacted: original_bytes={d} raw_ref={s}\n{s}",
        .{ kind, text.len, raw_ref.id, text[0..preview_len] },
    );
    const refs = try allocator.alloc(RawRef, 1);
    refs[0] = raw_ref;
    return .{ .summary = summary, .raw_refs = refs, .compacted = true };
}

pub fn compactEvents(
    allocator: std.mem.Allocator,
    now_seconds: i64,
    request_id: []const u8,
    events: []const embedded_protocol.HostEvent,
    config: BudgetConfig,
) !CompactEventsResult {
    const selected_count = @min(events.len, config.max_event_count);
    const compacted_events = try allocator.alloc(embedded_protocol.HostEvent, selected_count);
    var raw_refs = std.ArrayList(RawRef).empty;
    var compacted = events.len > selected_count;

    const order = try rankedEventOrder(allocator, events);
    for (order[0..selected_count], 0..) |event_index, out_index| {
        compacted_events[out_index] = try compactEvent(
            allocator,
            now_seconds,
            request_id,
            events[event_index],
            config.max_event_text_bytes,
            &raw_refs,
            &compacted,
        );
    }

    const raw_ref_ids = try rawRefIds(allocator, raw_refs.items);
    return .{
        .events = compacted_events,
        .raw_refs = raw_refs.items,
        .budget = .{
            .max_bytes = config.max_envelope_bytes,
            .used_bytes = estimateEventsBytes(compacted_events),
            .compacted = compacted,
            .dropped_event_count = events.len - selected_count,
            .raw_refs = raw_ref_ids,
        },
    };
}

pub fn budgetWithResult(allocator: std.mem.Allocator, base: BudgetReport, result_bytes: usize, extra_raw_refs: []const RawRef, compacted: bool) !BudgetReport {
    var ids = std.ArrayList([]const u8).empty;
    for (base.raw_refs) |id| try ids.append(allocator, id);
    for (extra_raw_refs) |raw_ref| try ids.append(allocator, raw_ref.id);
    return .{
        .max_bytes = base.max_bytes,
        .used_bytes = base.used_bytes + result_bytes,
        .compacted = base.compacted or compacted,
        .dropped_event_count = base.dropped_event_count,
        .raw_refs = ids.items,
    };
}

fn compactEvent(
    allocator: std.mem.Allocator,
    now_seconds: i64,
    request_id: []const u8,
    event: embedded_protocol.HostEvent,
    max_text_bytes: usize,
    raw_refs: *std.ArrayList(RawRef),
    compacted: *bool,
) !embedded_protocol.HostEvent {
    var out = event;
    out.request_id = if (request_id.len == 0) null else try allocator.dupe(u8, request_id);
    out.text = try compactOptionalField(allocator, now_seconds, "event_text", event.text, max_text_bytes, raw_refs, compacted, &out.raw_ref, &out.original_bytes);
    out.body = try compactOptionalField(allocator, now_seconds, "event_body", event.body, max_text_bytes, raw_refs, compacted, &out.raw_ref, &out.original_bytes);
    return out;
}

fn compactOptionalField(
    allocator: std.mem.Allocator,
    now_seconds: i64,
    kind: []const u8,
    value: ?[]const u8,
    max_text_bytes: usize,
    raw_refs: *std.ArrayList(RawRef),
    compacted: *bool,
    raw_ref_out: *?[]const u8,
    original_bytes_out: *?usize,
) !?[]const u8 {
    const text = value orelse return null;
    if (text.len <= max_text_bytes) return try allocator.dupe(u8, text);
    const raw_ref = try makeRawRef(allocator, now_seconds, kind, text);
    try raw_refs.append(allocator, raw_ref);
    raw_ref_out.* = raw_ref.id;
    original_bytes_out.* = text.len;
    compacted.* = true;
    return try std.fmt.allocPrint(allocator, "{s} compacted: original_bytes={d} raw_ref={s}\n{s}", .{ kind, text.len, raw_ref.id, text[0..@min(text.len, max_text_bytes)] });
}

fn makeRawRef(allocator: std.mem.Allocator, now_seconds: i64, kind: []const u8, bytes: []const u8) !RawRef {
    const hash = std.hash.Wyhash.hash(0, bytes);
    const id = try std.fmt.allocPrint(allocator, "raw_event_{d}_{x}", .{ now_seconds, hash });
    return .{
        .id = id,
        .kind = try allocator.dupe(u8, kind),
        .bytes = try allocator.dupe(u8, bytes),
    };
}

fn rankedEventOrder(allocator: std.mem.Allocator, events: []const embedded_protocol.HostEvent) ![]usize {
    const order = try allocator.alloc(usize, events.len);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, events, lessImportantEvent);
    return order;
}

fn lessImportantEvent(events: []const embedded_protocol.HostEvent, lhs: usize, rhs: usize) bool {
    return eventScore(events[lhs]) > eventScore(events[rhs]);
}

fn eventScore(event: embedded_protocol.HostEvent) i32 {
    if (std.mem.eql(u8, event.type, "speech_requested")) return 100;
    if (std.mem.eql(u8, event.type, "chat_message")) return 90;
    if (std.mem.eql(u8, event.type, "sense_stimulus")) return 80;
    if (std.mem.eql(u8, event.type, "state_changed")) return 70;
    if (event.kind) |kind| {
        if (std.mem.eql(u8, kind, "error")) return 95;
        if (std.mem.eql(u8, kind, "id")) return 75;
    }
    return 40;
}

fn rawRefIds(allocator: std.mem.Allocator, refs: []const RawRef) ![]const []const u8 {
    const ids = try allocator.alloc([]const u8, refs.len);
    for (refs, 0..) |raw_ref, i| ids[i] = raw_ref.id;
    return ids;
}

fn estimateEventsBytes(events: []const embedded_protocol.HostEvent) usize {
    var total: usize = 0;
    for (events) |event| {
        total += event.type.len + 32;
        if (event.text) |text| total += text.len;
        if (event.body) |body| total += body.len;
        if (event.title) |title| total += title.len;
        if (event.kind) |kind| total += kind.len;
    }
    return total;
}

test "context gate compacts large host events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const huge = "x" ** 2048;
    const events = [_]embedded_protocol.HostEvent{.{
        .type = "command_log",
        .kind = "result",
        .title = "huge",
        .body = huge,
    }};
    const result = try compactEvents(allocator, 10, "request", events[0..], .{ .max_event_text_bytes = 64 });
    try std.testing.expect(result.budget.compacted);
    try std.testing.expectEqual(@as(usize, 1), result.raw_refs.len);
    try std.testing.expect(result.events[0].body.?.len < huge.len);
}
