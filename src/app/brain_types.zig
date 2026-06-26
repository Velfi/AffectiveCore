const chat = @import("../api/chat_client.zig");
const interrupt_mod = @import("../core/interrupt.zig");

pub const CommandInfo = struct {
    command: chat.ChatCommandType,
    name: []const u8,
    description: []const u8,
    available: bool,
};

pub const CommandResult = struct {
    command: chat.ChatCommandType,
    observation: []const u8,
    spoken_text: ?[]const u8,
    ended_with_speech: bool,
    interrupted_by: ?interrupt_mod.Stimulus,
};

pub const ConversationTurnResult = struct {
    user_text: []const u8,
    spoken_text: []const u8,
    user_summary: []const u8,
    brain_summary: []const u8,
    interrupted_by: ?[]const u8 = null,
};
