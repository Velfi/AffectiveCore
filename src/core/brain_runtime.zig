const std = @import("std");
const brain_event = @import("brain_event.zig");
const brain_actor = @import("brain_actor.zig");

pub const RuntimeError = error{
    MissingActorId,
    MissingEventType,
    MissingSourceActor,
    MissingTimestamp,
    InvalidTtl,
    TtlExpired,
    DepthExceeded,
    EventBudgetExceeded,
    CorrelationNotFound,
};

pub const Phase = enum {
    ingest,
    context,
    proposal,
    governance,
    execution,
    feedback,

    pub fn name(self: Phase) []const u8 {
        return switch (self) {
            .ingest => "ingest",
            .context => "context",
            .proposal => "proposal",
            .governance => "governance",
            .execution => "execution",
            .feedback => "feedback",
        };
    }
};

const phase_order = [_]Phase{
    .ingest,
    .context,
    .proposal,
    .governance,
    .execution,
    .feedback,
};

pub const Config = struct {
    max_depth: u16 = 6,
    per_tick_event_budget: usize = 128,
};

pub const TickReport = struct {
    processed: usize,
    remaining: usize,
};

const QueuedEvent = struct {
    phase: Phase,
    event: brain_event.BrainEvent,
};

pub const BrainRuntime = struct {
    allocator: std.mem.Allocator,
    config: Config,
    actors: std.ArrayList(brain_actor.BrainActor),
    queue: std.ArrayList(QueuedEvent),
    event_log: std.ArrayList(brain_event.BrainEvent),
    dispatch_trace: std.ArrayList([]const u8),
    owned_strings: std.ArrayList([]u8),
    next_event_id: u64 = 1,
    tick_index: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) BrainRuntime {
        return .{
            .allocator = allocator,
            .config = config,
            .actors = .empty,
            .queue = .empty,
            .event_log = .empty,
            .dispatch_trace = .empty,
            .owned_strings = .empty,
        };
    }

    pub fn deinit(self: *BrainRuntime) void {
        for (self.owned_strings.items) |owned| {
            self.allocator.free(owned);
        }
        self.owned_strings.deinit(self.allocator);
        self.dispatch_trace.deinit(self.allocator);
        self.event_log.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.actors.deinit(self.allocator);
    }

    /// Domain actors will be registered by parallel workers as they land.
    pub fn registerActor(self: *BrainRuntime, actor: brain_actor.BrainActor) !void {
        if (actor.id().len == 0) return RuntimeError.MissingActorId;
        try self.actors.append(self.allocator, actor);
    }

    pub fn publishedEventCount(self: *const BrainRuntime) usize {
        return self.event_log.items.len;
    }

    pub fn queuedEventCount(self: *const BrainRuntime) usize {
        return self.queue.items.len;
    }

    pub fn traceItems(self: *const BrainRuntime) []const []const u8 {
        return self.dispatch_trace.items;
    }

    pub fn events(self: *const BrainRuntime) []const brain_event.BrainEvent {
        return self.event_log.items;
    }

    pub fn publish(self: *BrainRuntime, phase: Phase, incoming: brain_event.BrainEvent) !brain_event.BrainEvent {
        var event = incoming;
        try self.normalizeRootEvent(&event);
        try self.enqueue(phase, event);
        return event;
    }

    pub fn publishAutoPhase(self: *BrainRuntime, incoming: brain_event.BrainEvent) !brain_event.BrainEvent {
        const phase = phaseForEventType(incoming.event_type);
        return self.publish(phase, incoming);
    }

    pub fn dispatchTick(self: *BrainRuntime) !TickReport {
        self.tick_index += 1;
        var processed: usize = 0;
        for (phase_order) |phase| {
            processed = try self.dispatchPhase(phase, processed);
            if (processed >= self.config.per_tick_event_budget and self.queue.items.len > 0) {
                return RuntimeError.EventBudgetExceeded;
            }
        }
        return .{
            .processed = processed,
            .remaining = self.queue.items.len,
        };
    }

    pub fn debugTraceForCorrelation(self: *const BrainRuntime, allocator: std.mem.Allocator, correlation_id: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var matched = false;
        for (self.event_log.items) |event| {
            if (!std.mem.eql(u8, event.correlation_id, correlation_id)) continue;
            matched = true;
            const line = try std.fmt.allocPrint(
                allocator,
                "{s} type={s} source={s} cause={s} depth={d} ttl={d}\n",
                .{
                    event.id,
                    event.event_type,
                    event.source_actor,
                    event.causation_id orelse "root",
                    event.depth,
                    event.ttl,
                },
            );
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        }
        if (!matched) return RuntimeError.CorrelationNotFound;
        return out.toOwnedSlice(allocator);
    }

    pub fn phaseForEventType(event_type: []const u8) Phase {
        if (std.mem.eql(u8, event_type, "interpretation.created")) return .context;
        if (std.mem.eql(u8, event_type, "proposal.ranked")) return .proposal;
        if (std.mem.eql(u8, event_type, "proposal.compressed")) return .proposal;
        if (std.mem.eql(u8, event_type, "proposal.annotated")) return .proposal;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.proposal_created)) return .proposal;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.memory_candidate)) return .context;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.memory_consolidate)) return .context;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.memory_consolidated)) return .context;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.memory_extract)) return .context;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.memory_retrieve)) return .context;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.memory_retrieved)) return .context;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.memory_audit_query)) return .context;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.memory_audit)) return .context;
        if (std.mem.eql(u8, event_type, "governance.policy")) return .governance;
        if (std.mem.eql(u8, event_type, "governance.autonomy")) return .governance;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.governance_decision)) return .governance;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.action_scheduled)) return .execution;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.action_executed)) return .execution;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.outcome_created)) return .feedback;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.memory_decay)) return .feedback;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.memory_decayed)) return .feedback;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.learning_capability_recorded)) return .feedback;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.learning_correction_recorded)) return .feedback;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.learning_updated)) return .feedback;
        if (std.mem.eql(u8, event_type, brain_event.EventTypes.activity_updated)) return .feedback;
        return .ingest;
    }

    fn normalizeRootEvent(self: *BrainRuntime, event: *brain_event.BrainEvent) !void {
        if (event.event_type.len == 0) return RuntimeError.MissingEventType;
        if (event.source_actor.len == 0) return RuntimeError.MissingSourceActor;
        if (event.timestamp == 0) return RuntimeError.MissingTimestamp;
        if (event.ttl == 0) return RuntimeError.InvalidTtl;
        if (event.depth > self.config.max_depth) return RuntimeError.DepthExceeded;
        if (event.id.len == 0) {
            event.id = try self.nextGeneratedEventId();
        }
        if (event.correlation_id.len == 0) {
            event.correlation_id = event.id;
        }
    }

    fn dispatchPhase(self: *BrainRuntime, phase: Phase, already_processed: usize) !usize {
        var processed = already_processed;
        while (true) {
            if (processed >= self.config.per_tick_event_budget) break;
            const queue_index = self.nextQueueIndexForPhase(phase) orelse break;
            const queued = self.queue.orderedRemove(queue_index);
            try self.traceDispatch(phase, queued.event);
            try self.dispatchToSubscribedActors(phase, queued.event);
            processed += 1;
        }
        return processed;
    }

    fn dispatchToSubscribedActors(self: *BrainRuntime, phase: Phase, event: brain_event.BrainEvent) !void {
        for (self.actors.items) |actor| {
            if (!actor.subscribesTo(event.event_type)) continue;
            const actor_id = actor.id();
            if (actor_id.len == 0) return RuntimeError.MissingActorId;
            const emitted = try actor.handle(event, .{
                .allocator = self.allocator,
                .phase_name = phase.name(),
                .tick_index = self.tick_index,
            });
            for (emitted) |outgoing| {
                var next_event = outgoing;
                try self.attachCausation(&next_event, event, actor_id);
                const next_phase = phaseForEventType(next_event.event_type);
                try self.enqueue(next_phase, next_event);
                try self.traceEmission(phase, event, next_event);
            }
        }
    }

    fn attachCausation(self: *BrainRuntime, event: *brain_event.BrainEvent, parent: brain_event.BrainEvent, actor_id: []const u8) !void {
        if (event.event_type.len == 0) return RuntimeError.MissingEventType;
        if (parent.ttl <= 1) return RuntimeError.TtlExpired;
        if (parent.depth >= self.config.max_depth) return RuntimeError.DepthExceeded;

        if (event.id.len == 0) event.id = try self.nextGeneratedEventId();
        if (event.timestamp == 0) event.timestamp = parent.timestamp;
        if (event.source_actor.len == 0) event.source_actor = actor_id;
        if (event.activity_id == null) event.activity_id = parent.activity_id;
        event.correlation_id = parent.correlation_id;
        event.causation_id = parent.id;
        event.depth = parent.depth + 1;
        event.ttl = parent.ttl - 1;

        if (event.depth > self.config.max_depth) return RuntimeError.DepthExceeded;
    }

    fn enqueue(self: *BrainRuntime, phase: Phase, event: brain_event.BrainEvent) !void {
        try self.event_log.append(self.allocator, event);
        try self.queue.append(self.allocator, .{
            .phase = phase,
            .event = event,
        });
    }

    fn nextQueueIndexForPhase(self: *const BrainRuntime, phase: Phase) ?usize {
        var selected: ?usize = null;
        var selected_rank: u8 = std.math.maxInt(u8);
        for (self.queue.items, 0..) |queued, index| {
            if (queued.phase != phase) continue;
            const rank = priorityRank(queued.event.priority);
            if (selected == null or rank < selected_rank) {
                selected = index;
                selected_rank = rank;
            }
        }
        return selected;
    }

    fn priorityRank(priority: brain_event.Priority) u8 {
        return switch (priority) {
            .high => 0,
            .normal => 1,
            .low => 2,
        };
    }

    fn nextGeneratedEventId(self: *BrainRuntime) ![]const u8 {
        defer self.next_event_id += 1;
        return self.ownFmt("evt-{d}", .{self.next_event_id});
    }

    fn ownFmt(self: *BrainRuntime, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const rendered = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.owned_strings.append(self.allocator, rendered);
        return rendered;
    }

    fn traceDispatch(self: *BrainRuntime, phase: Phase, event: brain_event.BrainEvent) !void {
        const line = try self.ownFmt(
            "dispatch phase={s} id={s} type={s} cause={s} corr={s}",
            .{
                phase.name(),
                event.id,
                event.event_type,
                event.causation_id orelse "root",
                event.correlation_id,
            },
        );
        try self.dispatch_trace.append(self.allocator, line);
    }

    fn traceEmission(self: *BrainRuntime, phase: Phase, parent: brain_event.BrainEvent, child: brain_event.BrainEvent) !void {
        const line = try self.ownFmt(
            "emit phase={s} parent={s} child={s} type={s}",
            .{
                phase.name(),
                parent.id,
                child.id,
                child.event_type,
            },
        );
        try self.dispatch_trace.append(self.allocator, line);
    }
};
