const std = @import("std");

const brain_mod = @import("../core/brain.zig");
const brain_container = @import("brain_container.zig");
const brain_types = @import("brain_types.zig");
const config_mod = @import("../core/config.zig");
const chat = @import("../api/chat_client.zig");
const input_mod = @import("../platform/common/input.zig");

pub const CapabilityInfo = brain_types.CapabilityInfo;
pub const ActionExecutionResult = brain_types.ActionExecutionResult;
pub const UserTextOutcome = brain_types.UserTextOutcome;

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

    pub fn executeActionProposal(self: *AppCore, brain_id: []const u8, proposal: chat.ActionProposal) !ActionExecutionResult {
        const brain = try self.requireBrain(brain_id);
        return executeBrainActionProposal(self.allocator, brain, proposal);
    }

    pub fn userText(self: *AppCore, brain_id: []const u8, text: []const u8) !UserTextOutcome {
        const brain = try self.requireBrain(brain_id);
        return handleUserText(brain, try input_mod.HeardSpeech.typed(self.allocator, text), .{});
    }

    pub fn availableCapabilities(self: *AppCore, brain_id: []const u8) ![]CapabilityInfo {
        const brain = try self.requireBrain(brain_id);
        return availableBrainCapabilities(self.allocator, brain);
    }

    pub fn configureBrain(self: *AppCore, brain_id: []const u8, settings: config_mod.BrainSettings) !void {
        const brain = try self.requireBrain(brain_id);
        if (settings.brain_id.len > 0 and !std.mem.eql(u8, settings.brain_id, brain.cfg.brain_id)) return error.BrainSettingsIdMismatch;
        brain.cfg = try brain.cfg.withBrainSettings(settings);
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

pub fn executeBrainActionProposal(
    allocator: std.mem.Allocator,
    brain: *brain_mod.Brain,
    proposal: chat.ActionProposal,
) !ActionExecutionResult {
    var proposals = [_]chat.ActionProposal{proposal};
    return executeBrainActionProposals(allocator, brain, proposals[0..]);
}

pub fn executeBrainActionProposals(
    allocator: std.mem.Allocator,
    brain: *brain_mod.Brain,
    proposals: []chat.ActionProposal,
) !ActionExecutionResult {
    var observations = std.ArrayList(u8).empty;
    const result = try brain.executeActionProposals(proposals, &observations);
    return .{
        .action = if (proposals.len > 0) proposals[proposals.len - 1].action else .unknown,
        .observation = try observations.toOwnedSlice(allocator),
        .spoken_text = result.spoken_text,
        .ended_with_speech = result.ended_with_speech,
        .interrupted_by = result.interrupted_by,
    };
}

pub fn availableBrainCapabilities(
    allocator: std.mem.Allocator,
    brain: *brain_mod.Brain,
) ![]CapabilityInfo {
    var out = std.ArrayList(CapabilityInfo).empty;
    inline for (@typeInfo(chat.ActionProposalType).@"enum".fields) |field| {
        const action: chat.ActionProposalType = @field(chat.ActionProposalType, field.name);
        if (chat.actionSpec(action)) |spec| {
            const available = try brain.actionIsCallable(action);
            try out.append(allocator, .{
                .capability = action,
                .name = chat.skills.name(action),
                .description = spec.description,
                .available = available,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn handleUserText(brain: *brain_mod.Brain, heard_speech: brain_mod.HeardSpeech, dispatch: brain_mod.StimulusDispatch) !UserTextOutcome {
    return userTextOutcome(try brain.handleConversationText(heard_speech, dispatch));
}

pub fn userTextOutcome(result: brain_mod.ConversationTurnResult) UserTextOutcome {
    return .{
        .text = result.user_text,
        .spoken_text = result.spoken_text,
        .user_summary = result.user_summary,
        .brain_summary = result.brain_summary,
        .dispatch_id = result.dispatch_id,
        .interrupted_by = if (result.interrupted_by) |stimulus| @tagName(stimulus.kind) else null,
        .awaiting_host_sense = result.awaiting_host_sense,
        .awaited_host_sense = result.awaited_host_sense,
        .awaited_host_purpose = result.awaited_host_purpose,
        .awaited_host_timeout_ms = result.awaited_host_timeout_ms,
        .activity_id = result.activity_id,
        .activity_kind = result.activity_kind,
        .activity_kind_label = result.activity_kind_label,
        .activity_state = result.activity_state,
        .activity_goal = result.activity_goal,
        .activity_awaiting = result.activity_awaiting,
    };
}
