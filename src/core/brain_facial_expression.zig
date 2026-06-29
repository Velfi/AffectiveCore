const std = @import("std");
const brain_mod = @import("brain.zig");
const facial_expression = @import("port_facial_expression.zig");
const action_pressure_json_schema = @import("../api/action_pressure_json_schema.zig");

const Brain = brain_mod.Brain;

pub fn facialExpressionAvailable(self: *Brain) bool {
    return self.deps.capabilities.facial_expression_output and self.deps.facial_expression_output != null;
}

pub fn facialExpressionCatalogReady(self: *Brain) bool {
    if (!facialExpressionAvailable(self)) return true;
    return facialExpressionCatalogView(self) != null;
}

pub const FacialExpressionCatalogSnapshot = struct {
    loaded: bool,
    eye_names: []const []const u8,
    mouth_names: []const []const u8,
};

pub fn snapshotFacialExpressionCatalog(self: *Brain) FacialExpressionCatalogSnapshot {
    if (self.facial_expression_catalog) |*catalog| {
        const view = catalog.view();
        return .{
            .loaded = true,
            .eye_names = view.eye_names,
            .mouth_names = view.mouth_names,
        };
    }
    return .{ .loaded = false, .eye_names = &.{}, .mouth_names = &.{} };
}

pub fn refreshFacialExpressionCatalog(self: *Brain) !FacialExpressionCatalogSnapshot {
    try reloadFacialExpressionCatalog(self);
    return snapshotFacialExpressionCatalog(self);
}

fn clearFacialExpressionCatalog(self: *Brain) void {
    if (self.facial_expression_catalog) |*catalog| {
        catalog.deinit(self.allocator);
        self.facial_expression_catalog = null;
    }
    invalidateCachedJsonSchemas(self);
}

pub fn reloadFacialExpressionCatalog(self: *Brain) !void {
    const io = self.deps.io orelse return error.MissingFacialExpressionCatalog;
    const fs = self.deps.filesystem orelse return error.MissingFacialExpressionCatalog;
    if (self.cfg.brain_root.len == 0) return error.MissingFacialExpressionCatalog;

    const path = try std.fs.path.join(self.allocator, &.{ self.cfg.brain_root, "avatar.json" });
    defer self.allocator.free(path);

    const bytes = fs.readFileAllocPath(io, path, self.allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            clearFacialExpressionCatalog(self);
            return;
        },
        else => |e| return e,
    };
    defer self.allocator.free(bytes);

    const next = facial_expression.parseCatalogFromAvatarJson(self.allocator, bytes) catch |err| {
        clearFacialExpressionCatalog(self);
        switch (err) {
            error.MissingFacialExpressionCatalog => return,
            else => |e| return e,
        }
    };
    if (self.facial_expression_catalog) |*catalog| catalog.deinit(self.allocator);
    invalidateCachedJsonSchemas(self);
    self.facial_expression_catalog = next;
}

fn invalidateCachedJsonSchemas(self: *Brain) void {
    if (self.cached_conversation_json_schema) |schema| {
        self.allocator.free(schema);
        self.cached_conversation_json_schema = null;
    }
    if (self.cached_autonomy_json_schema) |schema| {
        self.allocator.free(schema);
        self.cached_autonomy_json_schema = null;
    }
}

pub fn conversationJsonSchema(self: *Brain) ![]const u8 {
    if (self.cached_conversation_json_schema) |schema| return schema;
    if (!facialExpressionAvailable(self) or !facialExpressionCatalogReady(self))
        return action_pressure_json_schema.strictChatTurnSchema();
    const catalog = facialExpressionCatalogView(self).?;
    const schema = try action_pressure_json_schema.strictChatTurnSchemaAlloc(self.allocator, catalog);
    self.cached_conversation_json_schema = schema;
    return schema;
}

pub fn autonomyJsonSchema(self: *Brain) ![]const u8 {
    if (self.cached_autonomy_json_schema) |schema| return schema;
    if (!facialExpressionAvailable(self) or !facialExpressionCatalogReady(self))
        return action_pressure_json_schema.strictAutonomyTurnSchema();
    const catalog = facialExpressionCatalogView(self).?;
    const schema = try action_pressure_json_schema.strictAutonomyTurnSchemaAlloc(self.allocator, catalog);
    self.cached_autonomy_json_schema = schema;
    return schema;
}

pub fn facialExpressionCatalogView(self: *Brain) ?facial_expression.Catalog {
    if (self.facial_expression_catalog) |*catalog| return catalog.view();
    return null;
}

pub fn validateFacialExpression(self: *Brain, expression: facial_expression.Expression) !void {
    const catalog = facialExpressionCatalogView(self) orelse return error.MissingFacialExpressionCatalog;
    try facial_expression.validateWithCatalog(expression, catalog);
}

pub fn appendFacialExpressionCatalogObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    if (!facialExpressionAvailable(self) or !facialExpressionCatalogReady(self)) return;
    const catalog = facialExpressionCatalogView(self).?;
    try facial_expression.appendCatalogObservation(self.allocator, out, catalog);
}
