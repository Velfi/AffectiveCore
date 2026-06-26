const std = @import("std");

const brain_mod = @import("../core/brain.zig");
const brain_container = @import("brain_container.zig");
const brain_types = @import("brain_types.zig");
const config_mod = @import("../core/config.zig");
const chat = @import("../api/chat_client.zig");
const input_mod = @import("../platform/common/input.zig");

pub const CommandInfo = brain_types.CommandInfo;
pub const CommandResult = brain_types.CommandResult;
pub const ConversationTurnResult = brain_types.ConversationTurnResult;

pub const BrainHandle = struct {
    brain_id: []const u8,
    brain: *brain_mod.Brain,
};

pub const AppCore = struct {
    allocator: std.mem.Allocator,
    brains: std.ArrayList(BrainHandle) = .empty,

    pub fn init(allocator: std.mem.Allocator) AppCore {
        return .{ .allocator = allocator };
    }

    pub fn registerBrain(self: *AppCore, brain_id: []const u8, brain: *brain_mod.Brain) !void {
        if (brain_id.len == 0) return error.EmptyBrainId;
        if (self.findBrain(brain_id) != null) return error.DuplicateBrainId;
        try self.brains.append(self.allocator, .{
            .brain_id = try self.allocator.dupe(u8, brain_id),
            .brain = brain,
        });
    }

    pub fn requireBrain(self: *AppCore, brain_id: []const u8) !*brain_mod.Brain {
        return self.findBrain(brain_id) orelse error.UnknownBrainId;
    }

    pub fn executeCommand(self: *AppCore, brain_id: []const u8, command: chat.ChatCommand) !CommandResult {
        const brain = try self.requireBrain(brain_id);
        return executeBrainCommand(self.allocator, brain, command);
    }

    pub fn conversationTurn(self: *AppCore, brain_id: []const u8, text: []const u8) !ConversationTurnResult {
        const brain = try self.requireBrain(brain_id);
        return conversationBrainTurn(brain, try input_mod.HeardSpeech.typed(self.allocator, text));
    }

    pub fn availableCommands(self: *AppCore, brain_id: []const u8) ![]CommandInfo {
        const brain = try self.requireBrain(brain_id);
        return availableBrainCommands(self.allocator, brain);
    }

    pub fn configureBrain(self: *AppCore, brain_id: []const u8, settings: config_mod.BrainSettings) !void {
        const brain = try self.requireBrain(brain_id);
        if (settings.brain_id.len > 0 and !std.mem.eql(u8, settings.brain_id, brain.cfg.brain_id)) return error.BrainSettingsIdMismatch;
        brain.cfg = brain.cfg.withBrainSettings(settings);
    }

    pub fn brainSettings(self: *AppCore, brain_id: []const u8) !config_mod.BrainSettings {
        const brain = try self.requireBrain(brain_id);
        return brain.cfg.brainSettings();
    }

    pub fn inspectBrain(self: *AppCore, brain_id: []const u8, io: std.Io) !brain_container.BrainIntrospection {
        const brain = try self.requireBrain(brain_id);
        return brain_container.inspectBrain(self.allocator, io, brain.cfg);
    }

    pub fn inspectBrainFile(self: *AppCore, io: std.Io, brain_file_path: []const u8) !brain_container.BrainManifest {
        return brain_container.inspectBrainFile(self.allocator, io, brain_file_path);
    }

    pub fn exportBrain(self: *AppCore, brain_id: []const u8, io: std.Io, brain_file_path: []const u8) !brain_container.BrainManifest {
        const brain = try self.requireBrain(brain_id);
        return brain_container.exportBrain(self.allocator, io, brain.cfg, brain_file_path);
    }

    pub fn importBrain(self: *AppCore, io: std.Io, brain_file_path: []const u8, cfg: config_mod.Config) !brain_container.BrainManifest {
        if (self.findBrain(cfg.brain_id) != null) return error.DuplicateBrainId;
        return brain_container.importBrain(self.allocator, io, brain_file_path, cfg);
    }

    fn findBrain(self: *AppCore, brain_id: []const u8) ?*brain_mod.Brain {
        for (self.brains.items) |handle| {
            if (std.mem.eql(u8, handle.brain_id, brain_id)) return handle.brain;
        }
        return null;
    }
};

pub fn executeBrainCommand(
    allocator: std.mem.Allocator,
    brain: *brain_mod.Brain,
    command: chat.ChatCommand,
) !CommandResult {
    var commands = [_]chat.ChatCommand{command};
    return executeBrainCommands(allocator, brain, commands[0..]);
}

pub fn executeBrainCommands(
    allocator: std.mem.Allocator,
    brain: *brain_mod.Brain,
    commands: []chat.ChatCommand,
) !CommandResult {
    var observations = std.ArrayList(u8).empty;
    const result = try brain.executeCommands(commands, &observations);
    return .{
        .command = if (commands.len > 0) commands[commands.len - 1].command else .unknown,
        .observation = try observations.toOwnedSlice(allocator),
        .spoken_text = result.spoken_text,
        .ended_with_speech = result.ended_with_speech,
        .interrupted_by = result.interrupted_by,
    };
}

pub fn availableBrainCommands(
    allocator: std.mem.Allocator,
    brain: *brain_mod.Brain,
) ![]CommandInfo {
    var out = std.ArrayList(CommandInfo).empty;
    inline for (@typeInfo(chat.ChatCommandType).@"enum".fields) |field| {
        const command: chat.ChatCommandType = @field(chat.ChatCommandType, field.name);
        if (chat.commandSpec(command)) |spec| {
            const available = try brain.commandIsCallable(command);
            try out.append(allocator, .{
                .command = command,
                .name = chat.skills.name(command),
                .description = spec.description,
                .available = available,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn conversationBrainTurn(brain: *brain_mod.Brain, heard_speech: brain_mod.HeardSpeech) !ConversationTurnResult {
    return conversationResult(try brain.handleConversationText(heard_speech));
}

pub fn conversationResult(result: brain_mod.ConversationTurnResult) ConversationTurnResult {
    return .{
        .user_text = result.user_text,
        .spoken_text = result.spoken_text,
        .user_summary = result.user_summary,
        .brain_summary = result.brain_summary,
        .interrupted_by = if (result.interrupted_by) |stimulus| @tagName(stimulus.kind) else null,
    };
}
