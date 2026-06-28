const std = @import("std");
const brain_mod = @import("../brain.zig");
const schema = @import("../ports.zig").schema;
const learning = @import("../learning.zig");
const brain_actor = @import("brain_actor.zig");

const Brain = brain_mod.Brain;

pub const LearningActor = struct {
    allocator: std.mem.Allocator,
    sink: brain_actor.EventSink,

    pub fn init(allocator: std.mem.Allocator, sink: brain_actor.EventSink) LearningActor {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn recordCapability(
        self: *const LearningActor,
        brain: *Brain,
        result: schema.CapabilityResult,
        context: learning.CapabilityLearningContext,
    ) !void {
        const faculty = learning.facultyForCapability(result.capability_id);
        const context_pattern = try std.fmt.allocPrint(self.allocator, "capability:{s}", .{result.capability_id});
        defer self.allocator.free(context_pattern);
        const prior_confidence = try learning.selfTrustForFaculty(brain, faculty, context_pattern);
        try learning.recordCapabilityLearning(brain, result, context);
        const confidence = try learning.selfTrustForFaculty(brain, faculty, "");
        try self.sink.emitStruct(self.allocator, "learning.updated", .{
            .kind = "capability_result",
            .faculty = faculty,
            .capability_id = result.capability_id,
            .state = @tagName(result.state),
            .pressure_id = result.pressure_id,
            .outcome_id = result.outcome_id,
            .outcome_event_id = result.outcome_event_id,
            .prior_confidence = prior_confidence,
            .confidence = confidence,
        });
    }

    pub fn recordSocialCorrection(
        self: *const LearningActor,
        brain: *Brain,
        image_path: []const u8,
        person_id: []const u8,
        name: []const u8,
        confidence: f32,
        hypothesis_event_id: []const u8,
    ) !void {
        try learning.recordSocialCorrectionLearning(brain, image_path, person_id, name, confidence, hypothesis_event_id);
        const updated_confidence = try learning.selfTrustForFaculty(brain, "recognition", "recognition uncertainty or user correction");
        try self.sink.emitStruct(self.allocator, "learning.updated", .{
            .kind = "social_correction",
            .faculty = "recognition",
            .person_id = person_id,
            .hypothesis_event_id = hypothesis_event_id,
            .confidence = updated_confidence,
        });
    }
};

