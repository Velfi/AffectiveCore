const std = @import("std");

pub const MemoryCandidate = struct {
    memory_id: []const u8,
    interpretation: []const u8,
    tags: []const []const u8,
    salience: f32,
    score: i32,
    scope: []const u8,
};
