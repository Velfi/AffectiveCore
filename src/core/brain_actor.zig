const std = @import("std");
const brain_event = @import("brain_event.zig");

pub const HandleContext = struct {
    allocator: std.mem.Allocator,
    phase_name: []const u8,
    tick_index: u64,
};

pub const BrainActor = struct {
    ctx: *anyopaque,
    idFn: *const fn (*anyopaque) []const u8,
    subscribesToFn: *const fn (*anyopaque, []const u8) bool,
    handleFn: *const fn (*anyopaque, brain_event.BrainEvent, HandleContext) anyerror![]const brain_event.BrainEvent,

    pub fn id(self: BrainActor) []const u8 {
        return self.idFn(self.ctx);
    }

    pub fn subscribesTo(self: BrainActor, event_type: []const u8) bool {
        return self.subscribesToFn(self.ctx, event_type);
    }

    pub fn handle(self: BrainActor, event: brain_event.BrainEvent, context: HandleContext) ![]const brain_event.BrainEvent {
        return self.handleFn(self.ctx, event, context);
    }
};

pub const EventSink = struct {
    ctx: *anyopaque,
    emitFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,

    pub fn emit(self: EventSink, event_kind: []const u8, payload_json: []const u8) !void {
        try self.emitFn(self.ctx, event_kind, payload_json);
    }

    pub fn emitStruct(self: EventSink, allocator: std.mem.Allocator, event_kind: []const u8, payload: anytype) !void {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try std.json.Stringify.value(payload, .{}, &out.writer);
        const payload_json = try allocator.dupe(u8, out.written());
        defer allocator.free(payload_json);
        try self.emit(event_kind, payload_json);
    }
};

pub const SleepPort = struct {
    ctx: *anyopaque,
    sleepMsFn: *const fn (*anyopaque, u32) anyerror!void,

    pub fn sleepMs(self: SleepPort, delay_ms: u32) !void {
        try self.sleepMsFn(self.ctx, delay_ms);
    }
};
