const std = @import("std");

pub const ResponseFormat = enum {
    text,
    json_object,
    image_generation,

    pub fn wireName(self: ResponseFormat) []const u8 {
        return switch (self) {
            .text => "text",
            .json_object => "json_object",
            .image_generation => "image_generation",
        };
    }
};

pub const Scenario = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8,
    subsystem: []const u8,
    system_prompt: []const u8,
    user_prompt: []const u8,
    response_format: ResponseFormat = .json_object,
    json_schema: []const u8,
    max_tokens: u32 = 512,
    temperature: f32 = 0.2,

    pub fn deinit(self: Scenario, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.description);
        allocator.free(self.subsystem);
        allocator.free(self.system_prompt);
        allocator.free(self.user_prompt);
        if (self.json_schema.len > 0) allocator.free(self.json_schema);
    }

    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        label: []const u8,
        description: []const u8,
        subsystem: []const u8,
        system_prompt: []const u8,
        user_prompt: []const u8,
        response_format: ResponseFormat,
        json_schema: []const u8,
        max_tokens: u32,
        temperature: f32,
    ) !Scenario {
        return .{
            .id = try allocator.dupe(u8, id),
            .label = try allocator.dupe(u8, label),
            .description = try allocator.dupe(u8, description),
            .subsystem = try allocator.dupe(u8, subsystem),
            .system_prompt = try allocator.dupe(u8, system_prompt),
            .user_prompt = try allocator.dupe(u8, user_prompt),
            .response_format = response_format,
            .json_schema = try allocator.dupe(u8, json_schema),
            .max_tokens = max_tokens,
            .temperature = temperature,
        };
    }
};

pub fn freeScenarios(allocator: std.mem.Allocator, scenarios: []Scenario) void {
    for (scenarios) |scenario| scenario.deinit(allocator);
    allocator.free(scenarios);
}
