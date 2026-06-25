const std = @import("std");

pub const BrainState = enum {
    Idle,
    Capture,
    DetectPerson,
    Identify,
    KnownGreeting,
    UnknownGreeting,
    AskName,
    RegisterPerson,
    UncertainConfirmation,
    MergeOrConfirm,
    TransientConversation,
    ForgetPerson,
    ErrorRecovery,

    pub fn jsonName(self: BrainState) []const u8 {
        return switch (self) {
            .Idle => "idle",
            .Capture => "capture",
            .DetectPerson => "detect_person",
            .Identify => "identify",
            .KnownGreeting => "known_greeting",
            .UnknownGreeting => "unknown_greeting",
            .AskName => "ask_name",
            .RegisterPerson => "register_person",
            .UncertainConfirmation => "uncertain_confirmation",
            .MergeOrConfirm => "merge_or_confirm",
            .TransientConversation => "transient_conversation",
            .ForgetPerson => "forget_person",
            .ErrorRecovery => "error_recovery",
        };
    }
};

pub fn printState(state: BrainState) void {
    std.debug.print("\nBRAIN STATE: {s}\n", .{@tagName(state)});
}
