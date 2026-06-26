const std = @import("std");

pub const GeneratedImage = struct {
    path: []const u8,
    mime_type: []const u8,
};

pub const ImageGenerationService = struct {
    ctx: *anyopaque,
    generateFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!GeneratedImage,

    pub fn generate(self: ImageGenerationService, allocator: std.mem.Allocator, prompt: []const u8) !GeneratedImage {
        return self.generateFn(self.ctx, allocator, prompt);
    }
};

pub const TestImageGenerationService = struct {
    path: []const u8 = "data/test/test_generated_image.png",
    mime_type: []const u8 = "image/png",
    last_prompt: ?[]const u8 = null,

    pub fn service(self: *TestImageGenerationService) ImageGenerationService {
        return .{ .ctx = self, .generateFn = generate };
    }

    fn generate(ctx: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8) !GeneratedImage {
        const self: *TestImageGenerationService = @ptrCast(@alignCast(ctx));
        if (prompt.len == 0) return error.EmptyImagePrompt;
        self.last_prompt = try allocator.dupe(u8, prompt);
        return .{
            .path = try allocator.dupe(u8, self.path),
            .mime_type = try allocator.dupe(u8, self.mime_type),
        };
    }
};
