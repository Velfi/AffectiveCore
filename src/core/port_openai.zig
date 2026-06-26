const std = @import("std");

pub const VISUAL_DESCRIPTION_POLICY =
    \\Describe visible, non-sensitive appearance details useful for the brain's memory.
    \\Do not infer identity, race, ethnicity, gender identity, age, health, disability, attractiveness, emotional state, or socioeconomic status.
    \\Focus on clothing, accessories, carried items, hair/clothing changes, and other non-sensitive visual details.
    \\Set change_summary to an empty string when there is no visible change from prior notes; do not describe the absence of change.
    \\Return only JSON matching the required schema.
;

pub const VisualDescription = struct {
    description: []const u8,
    change_summary: []const u8,
    durable_notes: []const []const u8,
    temporary_notes: []const []const u8,
};

pub const IdentityComparison = struct {
    same_person: bool,
    confidence: f32,
    reason: []const u8,
};

pub const IdentityComparisonService = struct {
    ctx: *anyopaque,
    compareFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!IdentityComparison,

    pub fn compareDescriptions(self: IdentityComparisonService, allocator: std.mem.Allocator, current_description: []const u8, stored_description: []const u8) !IdentityComparison {
        return self.compareFn(self.ctx, allocator, current_description, stored_description);
    }
};

pub const DescriptionService = struct {
    ctx: *anyopaque,
    describeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!VisualDescription,
    describeImageFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror![]const u8,
    compareImagesFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, []const u8) anyerror![]const u8,

    pub fn describePerson(self: DescriptionService, allocator: std.mem.Allocator, image_path: []const u8, prior_notes: []const u8) !VisualDescription {
        return self.describeFn(self.ctx, allocator, image_path, prior_notes);
    }

    pub fn describeImage(self: DescriptionService, allocator: std.mem.Allocator, image_path: []const u8, prompt: []const u8) ![]const u8 {
        return self.describeImageFn(self.ctx, allocator, image_path, prompt);
    }

    pub fn compareImages(self: DescriptionService, allocator: std.mem.Allocator, before_image_path: []const u8, after_image_path: []const u8, prompt: []const u8) ![]const u8 {
        return self.compareImagesFn(self.ctx, allocator, before_image_path, after_image_path, prompt);
    }
};

pub const TestDescriptionService = struct {
    fail: bool = false,
    missing_image_path: ?[]const u8 = null,

    pub fn service(self: *TestDescriptionService) DescriptionService {
        return .{
            .ctx = self,
            .describeFn = describe,
            .describeImageFn = describeImage,
            .compareImagesFn = compareImages,
        };
    }

    fn describe(ctx: *anyopaque, _: std.mem.Allocator, image_path: []const u8, _: []const u8) !VisualDescription {
        const self: *TestDescriptionService = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.RemoteServiceFailed;
        if (self.missing_image_path) |path| {
            if (std.mem.eql(u8, image_path, path)) return error.FileNotFound;
        }
        if (std.mem.indexOf(u8, image_path, "changed") != null or std.mem.indexOf(u8, image_path, "image2") != null) {
            return .{
                .description = "Wearing a blue jacket and carrying a small bag.",
                .change_summary = "a blue jacket and small bag are visible",
                .durable_notes = &.{"often carries a small bag"},
                .temporary_notes = &.{"blue jacket"},
            };
        }
        return .{
            .description = "Visible clothing and accessories only; no sensitive traits inferred.",
            .change_summary = "",
            .durable_notes = &.{},
            .temporary_notes = &.{},
        };
    }

    fn describeImage(ctx: *anyopaque, allocator: std.mem.Allocator, image_path: []const u8, prompt: []const u8) ![]const u8 {
        const self: *TestDescriptionService = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.RemoteServiceFailed;
        if (self.missing_image_path) |path| {
            if (std.mem.eql(u8, image_path, path)) return error.FileNotFound;
        }
        return std.fmt.allocPrint(allocator, "Test image description for {s}. Focus: {s}", .{ image_path, prompt });
    }

    fn compareImages(ctx: *anyopaque, allocator: std.mem.Allocator, before_image_path: []const u8, after_image_path: []const u8, prompt: []const u8) ![]const u8 {
        const self: *TestDescriptionService = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.RemoteServiceFailed;
        if (self.missing_image_path) |path| {
            if (std.mem.eql(u8, before_image_path, path) or std.mem.eql(u8, after_image_path, path)) return error.FileNotFound;
        }
        return std.fmt.allocPrint(allocator, "Test image comparison between {s} and {s}. Focus: {s}", .{ before_image_path, after_image_path, prompt });
    }
};
