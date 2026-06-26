const std = @import("std");

pub const TypeKind = enum { node, edge };

pub const GraphType = struct {
    type_id: i64,
    kind: TypeKind,
    name: []const u8,
    description: []const u8,
    created_by: []const u8,
    created_at: []const u8,
    confidence: f32,
    active: bool,
};

pub const Node = struct {
    node_id: []const u8,
    type_name: []const u8,
    label: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const Edge = struct {
    edge_id: []const u8,
    source_node_id: []const u8,
    target_node_id: []const u8,
    type_name: []const u8,
    strength: f32,
    confidence: f32,
    salience: f32,
    evidence: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    active: bool,
};

pub const GraphStore = struct {
    ctx: *anyopaque,
    ensureNodeTypeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, []const u8, f32) anyerror!GraphType,
    ensureEdgeTypeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, []const u8, f32) anyerror!GraphType,
    createNodeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, []const u8) anyerror!Node,
    upsertEdgeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, []const u8, f32, f32, f32, []const u8, []const u8) anyerror!Edge,
    findEdgesFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]Edge,
    forgetEdgeFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!bool,
    summaryFn: *const fn (*anyopaque, std.mem.Allocator, usize) anyerror![]const u8,

    pub fn ensureNodeType(self: GraphStore, allocator: std.mem.Allocator, name: []const u8, description: []const u8, created_by: []const u8, confidence: f32) !GraphType {
        return self.ensureNodeTypeFn(self.ctx, allocator, name, description, created_by, confidence);
    }

    pub fn ensureEdgeType(self: GraphStore, allocator: std.mem.Allocator, name: []const u8, description: []const u8, created_by: []const u8, confidence: f32) !GraphType {
        return self.ensureEdgeTypeFn(self.ctx, allocator, name, description, created_by, confidence);
    }

    pub fn createNode(self: GraphStore, allocator: std.mem.Allocator, type_name: []const u8, node_id: []const u8, label: []const u8) !Node {
        return self.createNodeFn(self.ctx, allocator, type_name, node_id, label);
    }

    pub fn upsertEdge(self: GraphStore, allocator: std.mem.Allocator, source_node_id: []const u8, target_node_id: []const u8, type_name: []const u8, strength: f32, confidence: f32, salience: f32, evidence: []const u8, created_by: []const u8) !Edge {
        return self.upsertEdgeFn(self.ctx, allocator, source_node_id, target_node_id, type_name, strength, confidence, salience, evidence, created_by);
    }

    pub fn findEdges(self: GraphStore, allocator: std.mem.Allocator, node_id: []const u8) ![]Edge {
        return self.findEdgesFn(self.ctx, allocator, node_id);
    }

    pub fn forgetEdge(self: GraphStore, edge_id: []const u8, created_by: []const u8) !bool {
        return self.forgetEdgeFn(self.ctx, edge_id, created_by);
    }

    pub fn summary(self: GraphStore, allocator: std.mem.Allocator, limit: usize) ![]const u8 {
        return self.summaryFn(self.ctx, allocator, limit);
    }
};

pub const TestGraphStore = struct {
    pub fn store(self: *TestGraphStore) GraphStore {
        return .{
            .ctx = self,
            .ensureNodeTypeFn = ensureNodeType,
            .ensureEdgeTypeFn = ensureEdgeType,
            .createNodeFn = createNode,
            .upsertEdgeFn = upsertEdge,
            .findEdgesFn = findEdges,
            .forgetEdgeFn = forgetEdge,
            .summaryFn = summary,
        };
    }

    fn ensureNodeType(_: *anyopaque, _: std.mem.Allocator, name: []const u8, description: []const u8, created_by: []const u8, confidence: f32) !GraphType {
        return .{ .type_id = 1, .kind = .node, .name = name, .description = description, .created_by = created_by, .created_at = "test://now", .confidence = confidence, .active = true };
    }

    fn ensureEdgeType(_: *anyopaque, _: std.mem.Allocator, name: []const u8, description: []const u8, created_by: []const u8, confidence: f32) !GraphType {
        return .{ .type_id = 2, .kind = .edge, .name = name, .description = description, .created_by = created_by, .created_at = "test://now", .confidence = confidence, .active = true };
    }

    fn createNode(_: *anyopaque, _: std.mem.Allocator, type_name: []const u8, node_id: []const u8, label: []const u8) !Node {
        return .{ .node_id = node_id, .type_name = type_name, .label = label, .created_at = "test://now", .updated_at = "test://now" };
    }

    fn upsertEdge(_: *anyopaque, _: std.mem.Allocator, source_node_id: []const u8, target_node_id: []const u8, type_name: []const u8, strength: f32, confidence: f32, salience: f32, evidence: []const u8, _: []const u8) !Edge {
        return .{
            .edge_id = "test_edge",
            .source_node_id = source_node_id,
            .target_node_id = target_node_id,
            .type_name = type_name,
            .strength = strength,
            .confidence = confidence,
            .salience = salience,
            .evidence = evidence,
            .created_at = "test://now",
            .updated_at = "test://now",
            .active = true,
        };
    }

    fn findEdges(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]Edge {
        return &.{};
    }

    fn forgetEdge(_: *anyopaque, _: []const u8, _: []const u8) !bool {
        return false;
    }

    fn summary(_: *anyopaque, allocator: std.mem.Allocator, _: usize) ![]const u8 {
        return allocator.dupe(u8, "creator_of attached_to");
    }
};
