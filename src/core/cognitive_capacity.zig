const std = @import("std");
const config = @import("config.zig");
const read_models = @import("read_models.zig");
const llm_voice = @import("llm_voice.zig");

pub fn validate(cfg: config.CapacityConfig) !void {
    if (cfg.activity_stack_max < 1) return error.InvalidActivityStackMax;
    if (cfg.focus_slots_max < 1) return error.InvalidFocusSlotsMax;
    if (cfg.memory_selected_max < 1) return error.InvalidMemorySelectedMax;
    if (cfg.memory_prefilter_max < 1) return error.InvalidMemoryPrefilterMax;
    if (cfg.memory_snippet_max_bytes < 1) return error.InvalidMemorySnippetMaxBytes;
    if (cfg.memory_context_bytes_max < 1) return error.InvalidMemoryContextBytesMax;
    if (cfg.candidate_actions_max < 1) return error.InvalidCandidateActionsMax;
    if (cfg.open_loops_soft_max < 1) return error.InvalidOpenLoopsSoftMax;
    if (cfg.conversation_summaries_in_context_max < 1) return error.InvalidConversationSummariesMax;
    if (cfg.chat_context_tokens_max < 1) return error.InvalidChatContextTokensMax;
    if (cfg.dispatch_envelope_bytes_max < 1) return error.InvalidDispatchEnvelopeBytesMax;
    if (cfg.dispatch_event_count_max < 1) return error.InvalidDispatchEventCountMax;
    if (cfg.stimulus_inbox_max < 1) return error.InvalidStimulusInboxMax;
    if (cfg.work_registry_max < 1) return error.InvalidWorkRegistryMax;
    if (cfg.memory_selected_max > cfg.memory_prefilter_max) return error.MemorySelectedExceedsPrefilter;
    if (cfg.open_loops_soft_max > cfg.activity_stack_max) return error.OpenLoopsSoftMaxExceedsStack;
}

pub fn mergePartial(base: config.CapacityConfig, partial: config.CapacityConfigPartial) config.CapacityConfig {
    var cfg = base;
    if (partial.activity_stack_max) |v| cfg.activity_stack_max = v;
    if (partial.focus_slots_max) |v| cfg.focus_slots_max = v;
    if (partial.memory_selected_max) |v| cfg.memory_selected_max = v;
    if (partial.memory_prefilter_max) |v| cfg.memory_prefilter_max = v;
    if (partial.memory_snippet_max_bytes) |v| cfg.memory_snippet_max_bytes = v;
    if (partial.memory_context_bytes_max) |v| cfg.memory_context_bytes_max = v;
    if (partial.candidate_actions_max) |v| cfg.candidate_actions_max = v;
    if (partial.open_loops_soft_max) |v| cfg.open_loops_soft_max = v;
    if (partial.conversation_summaries_in_context_max) |v| cfg.conversation_summaries_in_context_max = v;
    if (partial.chat_context_tokens_max) |v| cfg.chat_context_tokens_max = v;
    if (partial.dispatch_envelope_bytes_max) |v| cfg.dispatch_envelope_bytes_max = v;
    if (partial.dispatch_event_count_max) |v| cfg.dispatch_event_count_max = v;
    if (partial.stimulus_inbox_max) |v| cfg.stimulus_inbox_max = v;
    if (partial.work_registry_max) |v| cfg.work_registry_max = v;
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
    try out.appendSlice(allocator, "how_stretched_i_feel:\n");
    if (model.focus_in_use) {
        try out.print(allocator, "- My focus feels occupied ({d} of {d} slots).\n", .{ focus_used, focus_max });
    } else {
        try out.appendSlice(allocator, "- My focus feels open right now.\n");
    }
    if (model.activity_active) {
        try out.print(allocator, "- I am juggling an active goal with {d} nested steps (stack {d}/{d}).\n", .{ @intFromBool(model.activity_active), model.activity_stack_depth, cfg.activity_stack_max });
    }
    if (model.memory_total > 0) {
        try out.print(allocator, "- About {d} memories are surfacing; I can hold about {d} in working recall this turn.\n", .{ model.memory_total, cfg.memory_selected_max });
    }
    if (model.open_loop_count > 0) {
        try out.print(allocator, "- {d} unfinished threads are tugging at me (soft limit around {d}).\n", .{ model.open_loop_count, cfg.open_loops_soft_max });
    }
    if (model.budget_exceeded_count > 0) {
        try out.print(allocator, "- Context has felt tight lately ({d} recent budget failures; max around {d} tokens).\n", .{ model.budget_exceeded_count, cfg.chat_context_tokens_max });
    } else if (model.last_chat_tokens) |tokens| {
        try out.print(allocator, "- Recent context used about {d} tokens (max around {d}).\n", .{ tokens, cfg.chat_context_tokens_max });
    }
    if (model.under_pressure) {
        if (model.activity_stack_depth >= cfg.activity_stack_max -| 1) {
            try out.appendSlice(allocator, "- I feel stretched — too many nested goals; I should finish one before opening another.\n");
        } else if (model.open_loop_count >= cfg.open_loops_soft_max) {
            try out.appendSlice(allocator, "- I feel stretched — too many open loops; I should resolve or defer one.\n");
        } else if (model.budget_exceeded_count > 0) {
            try out.appendSlice(allocator, "- I feel stretched — context has been overflowing; I should shorten what I carry.\n");
        }
    } else if (!model.focus_in_use and !model.activity_active and model.open_loop_count == 0 and model.memory_total == 0) {
        try out.print(allocator, "- {s}\n", .{llm_voice.empty_inner_state});
    }
}
