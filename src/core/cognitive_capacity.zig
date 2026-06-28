const std = @import("std");
const config = @import("config.zig");
const read_models = @import("read_models.zig");

pub fn validate(cfg: config.CapacityConfig) !void {
    if (cfg.activity_stack_max < 1) return error.InvalidActivityStackMax;
    if (cfg.focus_slots_max < 1) return error.InvalidFocusSlotsMax;
    if (cfg.memory_selected_max < 1) return error.InvalidMemorySelectedMax;
    if (cfg.memory_prefilter_max < 1) return error.InvalidMemoryPrefilterMax;
    if (cfg.candidate_actions_max < 1) return error.InvalidCandidateActionsMax;
    if (cfg.open_loops_soft_max < 1) return error.InvalidOpenLoopsSoftMax;
    if (cfg.conversation_summaries_in_context_max < 1) return error.InvalidConversationSummariesMax;
    if (cfg.chat_context_tokens_max < 1) return error.InvalidChatContextTokensMax;
    if (cfg.dispatch_envelope_bytes_max < 1) return error.InvalidDispatchEnvelopeBytesMax;
    if (cfg.dispatch_event_count_max < 1) return error.InvalidDispatchEventCountMax;
    if (cfg.memory_selected_max > cfg.memory_prefilter_max) return error.MemorySelectedExceedsPrefilter;
    if (cfg.open_loops_soft_max > cfg.activity_stack_max) return error.OpenLoopsSoftMaxExceedsStack;
}

pub fn mergePartial(base: config.CapacityConfig, partial: config.CapacityConfigPartial) config.CapacityConfig {
    var cfg = base;
    if (partial.activity_stack_max) |v| cfg.activity_stack_max = v;
    if (partial.focus_slots_max) |v| cfg.focus_slots_max = v;
    if (partial.memory_selected_max) |v| cfg.memory_selected_max = v;
    if (partial.memory_prefilter_max) |v| cfg.memory_prefilter_max = v;
    if (partial.candidate_actions_max) |v| cfg.candidate_actions_max = v;
    if (partial.open_loops_soft_max) |v| cfg.open_loops_soft_max = v;
    if (partial.conversation_summaries_in_context_max) |v| cfg.conversation_summaries_in_context_max = v;
    if (partial.chat_context_tokens_max) |v| cfg.chat_context_tokens_max = v;
    if (partial.dispatch_envelope_bytes_max) |v| cfg.dispatch_envelope_bytes_max = v;
    if (partial.dispatch_event_count_max) |v| cfg.dispatch_event_count_max = v;
    return cfg;
}

pub fn appendCapacityObservation(
    allocator: std.mem.Allocator,
    cfg: config.CapacityConfig,
    model: read_models.CapacityModel,
    out: *std.ArrayList(u8),
) !void {
    const focus_max = cfg.focus_slots_max;
    const focus_used: usize = if (model.focus_in_use) 1 else 0;
    try out.print(
        allocator,
        "attention_capacity:\n- focus: in_use={d}/{d}\n- activity: active={} stack={d}/{d}\n- memory: total={d} held_per_turn={d} (from {d} candidates)\n- open_loops: {d} (soft_max={d})\n- context: last_tokens={?d} max={d} budget_failures={d}\n",
        .{
            focus_used,
            focus_max,
            model.activity_active,
            model.activity_stack_depth,
            cfg.activity_stack_max,
            model.memory_total,
            cfg.memory_selected_max,
            cfg.memory_prefilter_max,
            model.open_loop_count,
            cfg.open_loops_soft_max,
            model.last_chat_tokens,
            cfg.chat_context_tokens_max,
            model.budget_exceeded_count,
        },
    );
    if (model.under_pressure) {
        if (model.activity_stack_depth >= cfg.activity_stack_max -| 1) {
            try out.appendSlice(allocator, "- pressure: activity stack near limit; finish or replace the current goal before opening another.\n");
        } else if (model.open_loop_count >= cfg.open_loops_soft_max) {
            try out.appendSlice(allocator, "- pressure: many open loops; resolve or defer one before adding more.\n");
        } else if (model.budget_exceeded_count > 0) {
            try out.appendSlice(allocator, "- pressure: recent context budget failures; shorten memory or observations.\n");
        }
    }
}
