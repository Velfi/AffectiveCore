const chat = @import("../api/chat_client.zig");
const interrupt_mod = @import("../core/interrupt.zig");

pub const CapabilityInfo = struct {
    capability: chat.ActionProposalType,
    name: []const u8,
    description: []const u8,
    available: bool,
};

pub const ActionExecutionResult = struct {
    action: chat.ActionProposalType,
    observation: []const u8,
    spoken_text: ?[]const u8,
    ended_with_speech: bool,
    interrupted_by: ?interrupt_mod.Stimulus,
};

pub const UserTextOutcome = struct {
    text: []const u8,
    spoken_text: []const u8,
    user_summary: []const u8,
    brain_summary: []const u8,
    /// Same id as TRACE `dispatch_id=` lines for this turn; use to spot duplicate dispatches.
    dispatch_id: []const u8 = "",
    interrupted_by: ?[]const u8 = null,
    awaiting_host_sense: bool = false,
    awaited_host_sense: ?[]const u8 = null,
    awaited_host_purpose: ?[]const u8 = null,
    awaited_host_timeout_ms: ?u32 = null,
    activity_id: ?[]const u8 = null,
    activity_kind: ?[]const u8 = null,
    activity_kind_label: ?[]const u8 = null,
    activity_state: ?[]const u8 = null,
    activity_goal: ?[]const u8 = null,
    activity_awaiting: ?[]const u8 = null,
};
