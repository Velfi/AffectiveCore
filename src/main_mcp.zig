const std = @import("std");
const app_brain = @import("app/brain.zig");
const brain_config = @import("core/config.zig");
const chat = @import("api/chat_client.zig");
const schema = @import("storage/schema.zig");
const json_store = @import("storage/json_store.zig");
const graph_store = @import("storage/graph_store.zig");
const store_mod = @import("storage/store.zig");
const vector_index = @import("core/vector_index.zig");
const emotion = @import("core/emotion.zig");
const time_mod = @import("core/time.zig");
const maintenance = @import("core/maintenance.zig");
const process = @import("platform/common/process.zig");
const mcp_tools = @import("main_mcp_tools.zig");
const mcp_utils = @import("main_mcp_utils.zig");
const main_http_transport = @import("main_http_transport.zig");

const Tool = mcp_tools.Tool;

const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};

const ToolResult = struct {
    content: []const TextContent,
};

const InitializeResult = struct {
    protocolVersion: []const u8 = "2024-11-05",
    capabilities: Capabilities = .{},
    serverInfo: ServerInfo = .{},

    const Capabilities = struct {
        tools: struct {} = .{},
    };

    const ServerInfo = struct {
        name: []const u8 = "affective-core",
        version: []const u8 = "0.1.0",
    };
};

const InitializeResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    result: InitializeResult = .{},
};

const ToolsResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    result: struct { tools: []const Tool },
};

const ToolResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    result: ToolResult,
};

const ErrorResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    @"error": RpcError,

    const RpcError = struct {
        code: i32,
        message: []const u8,
    };
};

const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: store_mod.MemoryStore,
    graph: graph_store.GraphStore,
    runtime: app_brain.BrainRuntime,
    http_transport: *main_http_transport.StdHttpTransport,
    memory_path: []const u8,
    schedule_path: []const u8,
    recognition_command: []const u8,
    face_detector_model: []const u8,
    face_recognition_model: []const u8,
    face_embeddings_dir: []const u8,

    fn init(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, config: Config) !Server {
        const http_transport = try allocator.create(main_http_transport.StdHttpTransport);
        http_transport.* = main_http_transport.StdHttpTransport.init(io);
        const runtime = try app_brain.BrainRuntime.initHeadlessMcp(allocator, io, http_transport.client(), env, try config.toBrainConfig());
        return .{
            .allocator = allocator,
            .io = io,
            .store = runtime.brain.deps.store,
            .graph = runtime.brain.deps.graph,
            .runtime = runtime,
            .http_transport = http_transport,
            .memory_path = config.memory_path,
            .schedule_path = config.schedule_path,
            .recognition_command = config.recognition_command,
            .face_detector_model = config.face_detector_model,
            .face_recognition_model = config.face_recognition_model,
            .face_embeddings_dir = config.face_embeddings_dir,
        };
    }

    fn callTool(self: *Server, name: []const u8, args: std.json.Value) ![]const u8 {
        if (std.mem.eql(u8, name, "brain_inspect")) return self.brainInspect();
        if (std.mem.eql(u8, name, "conversation_turn")) return self.conversationTurn(try mcp_utils.requireString(args, "text"));
        if (std.mem.eql(u8, name, "chat_dry_run_prompt")) return self.chatDryRunPrompt(try mcp_utils.requireString(args, "text"));
        if (std.mem.eql(u8, name, "memory_index")) return self.memoryIndex();
        if (std.mem.eql(u8, name, "recall_memory")) return self.callBrain(.{ .command = .recall_memory, .query = mcp_utils.getString(args, "query") orelse "", .tags = try mcp_utils.getStringArray(self.allocator, args, "tags") });
        if (std.mem.eql(u8, name, "remember_memory")) return self.callBrain(.{ .command = .remember_memory, .text = try mcp_utils.requireString(args, "text"), .tags = try mcp_utils.getStringArray(self.allocator, args, "tags") });
        if (std.mem.eql(u8, name, "forget_memory")) return self.callBrain(.{ .command = .forget_memory, .memory_id = try mcp_utils.requireString(args, "memory_id") });
        if (std.mem.eql(u8, name, "sweep_memory")) return self.callBrain(.{ .command = .sweep_memory });
        if (std.mem.eql(u8, name, "introspect")) return self.callBrain(.{ .command = .introspect });
        if (std.mem.eql(u8, name, "inner_state")) return self.callBrain(.{ .command = .introspect });
        if (std.mem.eql(u8, name, "appraise_event")) return self.callBrain(.{ .command = .appraise_event, .text = try mcp_utils.requireString(args, "text"), .tags = try mcp_utils.getStringArray(self.allocator, args, "tags") });
        if (std.mem.eql(u8, name, "feel_about")) return self.callBrain(.{ .command = .feel_about, .query = try mcp_utils.requireString(args, "query"), .tags = try mcp_utils.getStringArray(self.allocator, args, "tags") });
        if (std.mem.eql(u8, name, "choose_attention")) return self.callBrain(.{ .command = .choose_attention });
        if (std.mem.eql(u8, name, "ask_for_help")) return self.callBrain(.{ .command = .ask_human, .text = try mcp_utils.requireString(args, "text") });
        if (std.mem.eql(u8, name, "consolidate_memory")) return self.callBrain(.{ .command = .consolidate_memory });
        if (std.mem.eql(u8, name, "dream")) return self.callBrain(.{ .command = .dream, .text = mcp_utils.getString(args, "text"), .tags = try mcp_utils.getStringArray(self.allocator, args, "tags"), .heat_bias = mcp_utils.getString(args, "heat_bias") });
        if (std.mem.eql(u8, name, "set_reminder")) return self.callBrain(.{ .command = .set_reminder, .schedule = try mcp_utils.requireString(args, "schedule"), .text = try mcp_utils.requireString(args, "text") });
        if (std.mem.eql(u8, name, "list_reminders")) return self.listReminders();
        if (std.mem.eql(u8, name, "update_face_picture")) return self.callBrain(.{ .command = .update_face_picture, .person_id = mcp_utils.getString(args, "person_id"), .name = mcp_utils.getString(args, "name"), .image_path = try mcp_utils.requireString(args, "image_path"), .keep_existing = mcp_utils.getBool(args, "keep_existing") orelse false });
        if (std.mem.eql(u8, name, "graph_type_create")) return self.graphTypeCreate(try mcp_utils.requireString(args, "kind"), try mcp_utils.requireString(args, "name"), try mcp_utils.requireString(args, "description"), mcp_utils.getString(args, "created_by") orelse "mcp", @floatCast(mcp_utils.getNumber(args, "confidence") orelse 0.80));
        if (std.mem.eql(u8, name, "graph_node_create")) return self.graphNodeCreate(try mcp_utils.requireString(args, "type_name"), try mcp_utils.requireString(args, "node_id"), try mcp_utils.requireString(args, "label"));
        if (std.mem.eql(u8, name, "graph_edge_upsert")) return self.graphEdgeUpsert(try mcp_utils.requireString(args, "source_node_id"), try mcp_utils.requireString(args, "target_node_id"), try mcp_utils.requireString(args, "type_name"), @floatCast(mcp_utils.getNumber(args, "strength") orelse 0.70), @floatCast(mcp_utils.getNumber(args, "confidence") orelse 0.70), @floatCast(mcp_utils.getNumber(args, "salience") orelse 0.50), try mcp_utils.requireString(args, "evidence"), mcp_utils.getString(args, "created_by") orelse "mcp");
        if (std.mem.eql(u8, name, "graph_entity_context")) return self.graphEntityContext(try mcp_utils.requireString(args, "node_id"));
        if (std.mem.eql(u8, name, "graph_summary")) return self.graphSummary();
        if (std.mem.eql(u8, name, "graph_edge_forget")) return self.graphEdgeForget(try mcp_utils.requireString(args, "edge_id"), mcp_utils.getString(args, "created_by") orelse "mcp");
        return error.UnknownTool;
    }

    fn callBrain(self: *Server, command: chat.ChatCommand) ![]const u8 {
        const result = try self.runtime.executeCommand(command);
        return result.observation;
    }

    fn conversationTurn(self: *Server, text: []const u8) ![]const u8 {
        const result = try self.runtime.conversationTurn(text);
        return std.json.Stringify.valueAlloc(self.allocator, result, .{ .whitespace = .indent_2 });
    }

    fn chatDryRunPrompt(self: *Server, text: []const u8) ![]const u8 {
        const prompt = try self.runtime.dryRunConversationPrompt(text);
        return std.json.Stringify.valueAlloc(self.allocator, struct {
            dry_run: bool,
            system_prompt: []const u8,
            user_prompt: []const u8,
        }{
            .dry_run = true,
            .system_prompt = prompt.system_prompt,
            .user_prompt = prompt.user_prompt,
        }, .{ .whitespace = .indent_2 });
    }

    fn brainInspect(self: *Server) ![]const u8 {
        const info = try self.runtime.inspectBrain(self.io);
        return std.json.Stringify.valueAlloc(self.allocator, info, .{ .whitespace = .indent_2 });
    }

    fn memoryIndex(self: *Server) ![]const u8 {
        const memories = try self.store.loadMemoryRecords(self.allocator);
        const summaries = try self.store.loadConversationSummaries(self.allocator);
        var long_term: usize = 0;
        var short_term: usize = 0;
        var tags = std.ArrayList([]const u8).empty;
        for (memories) |memory| {
            switch (memory.scope) {
                .long_term => long_term += 1,
                .short_term => short_term += 1,
            }
            for (memory.tags) |tag| {
                if (tags.items.len >= 32) break;
                if (!mcp_utils.tagInSlice(tags.items, tag)) try tags.append(self.allocator, tag);
            }
        }
        const Result = struct {
            long_term: usize,
            short_term: usize,
            tags: []const []const u8,
            conversation_summaries: usize,
        };
        return std.json.Stringify.valueAlloc(self.allocator, Result{ .long_term = long_term, .short_term = short_term, .tags = tags.items, .conversation_summaries = summaries.len }, .{ .whitespace = .indent_2 });
    }

    fn recallMemory(self: *Server, query: []const u8, tags: []const []const u8) ![]const u8 {
        const memories = try self.store.loadMemoryRecords(self.allocator);
        const results = try vector_index.search(self.allocator, memories, query, tags, 8);
        var matches = std.ArrayList(RecallMatch).empty;
        const now = try mcp_utils.nowTimestamp(self.allocator);
        for (results) |result| {
            var memory = memories[result.memory_index];
            if (memory.vector.len != vector_index.dimensions) memory.vector = try vector_index.embedMemory(self.allocator, memory);
            memory.access_count += 1;
            memory.score += 2;
            memory.last_accessed_at = now;
            memory.confidence = @min(1.0, memory.confidence + 0.03);
            memory.revisions = try mcp_utils.appendRevision(self.allocator, memory.revisions, .{
                .time = now,
                .text = try std.fmt.allocPrint(self.allocator, "recalled with query '{s}'", .{query}),
                .confidence = memory.confidence,
            });
            if (memory.scope == .short_term and (memory.score >= 5 or memory.access_count >= 3)) memory.scope = .long_term;
            try self.store.saveMemoryRecord(memory);
            const impression = try self.makeImpression(.recalled_memory, mcp_utils.memoryInterpretation(memory), memory.tags);
            try self.store.addImpression(impression);
            try matches.append(self.allocator, .{
                .memory_id = memory.memory_id,
                .scope = @tagName(memory.scope),
                .text = memory.text,
                .interpretation = mcp_utils.memoryInterpretation(memory),
                .confidence = memory.confidence,
                .valence = memory.valence,
                .salience = memory.salience,
                .tags = memory.tags,
                .created_at = memory.created_at,
                .last_accessed_at = memory.last_accessed_at,
                .access_count = memory.access_count,
                .score = memory.score,
                .vector_score = result.score,
                .similarity = result.similarity,
            });
        }
        return std.json.Stringify.valueAlloc(self.allocator, struct { matches: []const RecallMatch }{ .matches = matches.items }, .{ .whitespace = .indent_2 });
    }

    fn rememberMemory(self: *Server, text: []const u8, tags: []const []const u8) ![]const u8 {
        const memory = try self.makeMemory(text, tags);
        try self.store.saveMemoryRecord(memory);
        return std.json.Stringify.valueAlloc(self.allocator, memory, .{ .whitespace = .indent_2 });
    }

    fn forgetMemory(self: *Server, memory_id: []const u8) ![]const u8 {
        const forgotten = try self.store.forgetMemoryRecord(memory_id);
        return std.json.Stringify.valueAlloc(self.allocator, struct { memory_id: []const u8, forgotten: bool }{ .memory_id = memory_id, .forgotten = forgotten }, .{ .whitespace = .indent_2 });
    }

    fn sweepMemory(self: *Server) ![]const u8 {
        const memories = try self.store.loadMemoryRecords(self.allocator);
        var decayed: usize = 0;
        var removed: usize = 0;
        for (memories) |memory| {
            if (memory.scope != .short_term) continue;
            var updated = memory;
            updated.score -= 1;
            decayed += 1;
            if (updated.score <= 0) {
                if (try self.store.forgetMemoryRecord(updated.memory_id)) removed += 1;
            } else {
                try self.store.saveMemoryRecord(updated);
            }
        }
        return std.json.Stringify.valueAlloc(self.allocator, struct { decayed: usize, removed: usize }{ .decayed = decayed, .removed = removed }, .{ .whitespace = .indent_2 });
    }

    fn introspect(self: *Server) ![]const u8 {
        const memories = try self.store.loadMemoryRecords(self.allocator);
        const impressions = try self.store.loadImpressions(self.allocator);
        const appraisals = try self.store.loadAppraisals(self.allocator);
        const dreams = try self.store.loadDreamRecords(self.allocator);
        var score_total: i32 = 0;
        var access_total: u32 = 0;
        for (memories) |memory| {
            score_total += memory.score;
            access_total += memory.access_count;
        }
        const index_json = try self.memoryIndex();
        const index = try std.json.parseFromSliceLeaky(std.json.Value, self.allocator, index_json, .{});
        const Result = struct {
            senses: []const []const u8,
            memory: std.json.Value,
            impressions: usize,
            appraisals: usize,
            dreams: usize,
            memory_score_total: i32,
            memory_access_total: u32,
            recent_appraisal: ?schema.Appraisal,
            tools: []const []const u8,
            schedule_path: []const u8,
        };
        return std.json.Stringify.valueAlloc(self.allocator, Result{
            .senses = &.{ "camera", "microphone transcription", "speech output", "time lookup" },
            .memory = index,
            .impressions = impressions.len,
            .appraisals = appraisals.len,
            .dreams = dreams.len,
            .memory_score_total = score_total,
            .memory_access_total = access_total,
            .recent_appraisal = if (appraisals.len > 0) appraisals[appraisals.len - 1] else null,
            .tools = mcp_tools.toolNames(),
            .schedule_path = self.schedule_path,
        }, .{ .whitespace = .indent_2 });
    }

    fn appraiseEvent(self: *Server, text: []const u8, tags: []const []const u8) ![]const u8 {
        const impression = try self.makeImpression(.self_reflection, text, tags);
        const appraisal = try self.makeAppraisal(text, impression.impression_id, tags);
        try self.store.addImpression(impression);
        try self.store.addAppraisal(appraisal);
        return std.json.Stringify.valueAlloc(self.allocator, struct { impression: schema.Impression, appraisal: schema.Appraisal }{ .impression = impression, .appraisal = appraisal }, .{ .whitespace = .indent_2 });
    }

    fn feelAbout(self: *Server, query: []const u8, tags: []const []const u8) ![]const u8 {
        const appraisal = try self.makeAppraisal(query, null, tags);
        try self.store.addAppraisal(appraisal);
        return std.json.Stringify.valueAlloc(self.allocator, appraisal, .{ .whitespace = .indent_2 });
    }

    fn chooseAttention(self: *Server) ![]const u8 {
        const appraisals = try self.store.loadAppraisals(self.allocator);
        if (appraisals.len > 0) {
            const recent = appraisals[appraisals.len - 1];
            if (recent.stress > 0.55 or recent.uncertainty > 0.65) {
                return std.json.Stringify.valueAlloc(self.allocator, struct { priority: []const u8, target: []const u8, reason: schema.Appraisal }{ .priority = "unresolved_appraisal", .target = recent.query, .reason = recent }, .{ .whitespace = .indent_2 });
            }
        }
        const memories = try self.store.loadMemoryRecords(self.allocator);
        if (memories.len > 0) {
            var best = memories[0];
            for (memories[1..]) |memory| {
                if (memory.score > best.score or memory.salience > best.salience) best = memory;
            }
            return std.json.Stringify.valueAlloc(self.allocator, struct { priority: []const u8, target: []const u8, memory_id: []const u8 }{ .priority = "salient_memory", .target = mcp_utils.memoryInterpretation(best), .memory_id = best.memory_id }, .{ .whitespace = .indent_2 });
        }
        return self.allocator.dupe(u8, "{\n  \"priority\": \"curiosity\",\n  \"target\": \"wait for the next human-driven interaction\"\n}");
    }

    fn graphTypeCreate(self: *Server, kind: []const u8, name: []const u8, description: []const u8, created_by: []const u8, confidence: f32) ![]const u8 {
        const typ = if (std.mem.eql(u8, kind, "node"))
            try self.graph.ensureNodeType(self.allocator, name, description, created_by, confidence)
        else if (std.mem.eql(u8, kind, "edge"))
            try self.graph.ensureEdgeType(self.allocator, name, description, created_by, confidence)
        else
            return error.InvalidGraphTypeKind;
        return std.json.Stringify.valueAlloc(self.allocator, typ, .{ .whitespace = .indent_2 });
    }

    fn graphNodeCreate(self: *Server, type_name: []const u8, node_id: []const u8, label: []const u8) ![]const u8 {
        const node = try self.graph.createNode(self.allocator, type_name, node_id, label);
        return std.json.Stringify.valueAlloc(self.allocator, node, .{ .whitespace = .indent_2 });
    }

    fn graphEdgeUpsert(self: *Server, source_node_id: []const u8, target_node_id: []const u8, type_name: []const u8, strength: f32, confidence: f32, salience: f32, evidence: []const u8, created_by: []const u8) ![]const u8 {
        const edge = try self.graph.upsertEdge(self.allocator, source_node_id, target_node_id, type_name, strength, confidence, salience, evidence, created_by);
        return std.json.Stringify.valueAlloc(self.allocator, edge, .{ .whitespace = .indent_2 });
    }

    fn graphEntityContext(self: *Server, node_id: []const u8) ![]const u8 {
        const edges = try self.graph.findEdges(self.allocator, node_id);
        return std.json.Stringify.valueAlloc(self.allocator, struct { node_id: []const u8, edges: []const graph_store.Edge }{ .node_id = node_id, .edges = edges }, .{ .whitespace = .indent_2 });
    }

    fn graphSummary(self: *Server) ![]const u8 {
        const text = try self.graph.summary(self.allocator, 16);
        return std.json.Stringify.valueAlloc(self.allocator, struct { summary: []const u8 }{ .summary = text }, .{ .whitespace = .indent_2 });
    }

    fn graphEdgeForget(self: *Server, edge_id: []const u8, created_by: []const u8) ![]const u8 {
        const forgotten = try self.graph.forgetEdge(edge_id, created_by);
        return std.json.Stringify.valueAlloc(self.allocator, struct { edge_id: []const u8, forgotten: bool }{ .edge_id = edge_id, .forgotten = forgotten }, .{ .whitespace = .indent_2 });
    }

    fn askForHelp(self: *Server, text: []const u8) ![]const u8 {
        const impression = try self.makeImpression(.self_reflection, text, &.{ "help", "unresolved" });
        try self.store.addImpression(impression);
        return std.json.Stringify.valueAlloc(self.allocator, struct { help_request: []const u8, impression_id: []const u8 }{ .help_request = text, .impression_id = impression.impression_id }, .{ .whitespace = .indent_2 });
    }

    fn consolidateMemory(self: *Server) ![]const u8 {
        const memories = try self.store.loadMemoryRecords(self.allocator);
        const now = try mcp_utils.nowTimestamp(self.allocator);
        var promoted: usize = 0;
        var decayed: usize = 0;
        var revised: usize = 0;
        var removed: usize = 0;
        for (memories) |memory| {
            var updated = memory;
            if (updated.scope == .short_term) {
                if (updated.score >= 5 or updated.salience >= 0.75 or updated.access_count >= 3) {
                    updated.scope = .long_term;
                    promoted += 1;
                } else {
                    updated.score -= 1;
                    updated.salience *= 0.92;
                    decayed += 1;
                }
            }
            if (updated.access_count > 0 and updated.revisions.len == 0) {
                updated.revisions = try mcp_utils.appendRevision(self.allocator, updated.revisions, .{
                    .time = now,
                    .text = try std.fmt.allocPrint(self.allocator, "recalled and stabilized: {s}", .{mcp_utils.memoryInterpretation(updated)}),
                    .confidence = updated.confidence,
                });
                revised += 1;
            }
            if (updated.scope == .short_term and updated.score <= 0 and updated.salience < 0.30) {
                if (try self.store.forgetMemoryRecord(updated.memory_id)) removed += 1;
            } else {
                try self.store.saveMemoryRecord(updated);
            }
        }
        return std.json.Stringify.valueAlloc(self.allocator, struct { promoted: usize, decayed: usize, revised: usize, removed: usize }{ .promoted = promoted, .decayed = decayed, .revised = revised, .removed = removed }, .{ .whitespace = .indent_2 });
    }

    fn dream(self: *Server, text: ?[]const u8, tags: []const []const u8, heat_bias: ?[]const u8) ![]const u8 {
        _ = try self.store.sweepUnreferencedCaptures();
        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(time_mod.nowSeconds())));
        const heat = mcp_utils.rollDreamHeat(prng.random(), heat_bias);
        const confidence = @max(0.20, 0.85 - heat * 0.55);
        const memories = try self.store.loadMemoryRecords(self.allocator);
        const summaries = try self.store.loadConversationSummaries(self.allocator);
        const source = if (memories.len > 0) memories[0] else null;
        const left = if (source) |memory| mcp_utils.memoryInterpretation(memory) else "no stored memory yet";
        const right = if (summaries.len > 0) summaries[summaries.len - 1].user_summary else "no recent conversation summary yet";
        var saved_memory_id: ?[]const u8 = null;
        if (text) |dream_text| {
            var memory = try self.makeMemory(dream_text, if (tags.len > 0) tags else &.{ "dream", "reflection" });
            memory.confidence = confidence;
            memory.salience = 0.25 + heat * 0.25;
            memory.interpretation = try std.fmt.allocPrint(self.allocator, "provisional dream: {s}", .{dream_text});
            try self.store.saveMemoryRecord(memory);
            saved_memory_id = memory.memory_id;
        }
        const source_ids: []const []const u8 = if (source) |memory| &.{memory.memory_id} else &.{};
        const dream_record: schema.DreamRecord = .{
            .dream_id = try std.fmt.allocPrint(self.allocator, "dream_{d}", .{time_mod.nowSeconds()}),
            .heat = heat,
            .confidence = confidence,
            .connection = try std.fmt.allocPrint(self.allocator, "{s} <-> {s}", .{ left, right }),
            .source_memory_ids = try mcp_utils.cloneConstStringSlice(self.allocator, source_ids),
            .saved_memory_id = saved_memory_id,
            .created_at = try mcp_utils.nowTimestamp(self.allocator),
        };
        try self.store.addDreamRecord(dream_record);
        return std.json.Stringify.valueAlloc(self.allocator, struct { heat: f32, style: []const u8, confidence: f32, connection: []const u8, source_memory_ids: []const []const u8, saved_memory_id: ?[]const u8 }{
            .heat = heat,
            .style = mcp_utils.dreamStyle(heat),
            .confidence = confidence,
            .connection = dream_record.connection,
            .source_memory_ids = dream_record.source_memory_ids,
            .saved_memory_id = saved_memory_id,
        }, .{ .whitespace = .indent_2 });
    }

    fn setReminder(self: *Server, schedule: []const u8, text: []const u8) ![]const u8 {
        const now_seconds = @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), 1000);
        const normalized_schedule = try maintenance.addReminder(self.allocator, self.io, self.schedule_path, schedule, text, now_seconds);
        const added = try std.fmt.allocPrint(self.allocator, "- {s} run say:{s}", .{ normalized_schedule, text });
        return std.json.Stringify.valueAlloc(self.allocator, struct { added: []const u8, schedule_path: []const u8 }{ .added = added, .schedule_path = self.schedule_path }, .{ .whitespace = .indent_2 });
    }

    fn listReminders(self: *Server) ![]const u8 {
        const markdown = try mcp_utils.readFileAllocPath(self.io, self.schedule_path, self.allocator, .limited(1024 * 1024));
        return std.json.Stringify.valueAlloc(self.allocator, struct { markdown: []const u8 }{ .markdown = markdown }, .{ .whitespace = .indent_2 });
    }

    fn updateFacePicture(self: *Server, person_id: ?[]const u8, name: ?[]const u8, image_path: []const u8, keep_existing: bool) ![]const u8 {
        var argv = std.ArrayList([]const u8).empty;
        try argv.append(self.allocator, self.recognition_command);
        try argv.append(self.allocator, "enroll");
        try argv.append(self.allocator, "--image");
        try argv.append(self.allocator, image_path);
        try argv.append(self.allocator, "--memory");
        try argv.append(self.allocator, self.memory_path);
        try argv.append(self.allocator, "--embeddings-dir");
        try argv.append(self.allocator, self.face_embeddings_dir);
        try argv.append(self.allocator, "--detector");
        try argv.append(self.allocator, self.face_detector_model);
        try argv.append(self.allocator, "--recognizer");
        try argv.append(self.allocator, self.face_recognition_model);
        if (person_id) |id| {
            try argv.append(self.allocator, "--person-id");
            try argv.append(self.allocator, id);
        } else if (name) |display_name| {
            try argv.append(self.allocator, "--name");
            try argv.append(self.allocator, display_name);
        } else {
            return error.MissingFacePicturePerson;
        }
        if (keep_existing) try argv.append(self.allocator, "--keep-existing");

        const out = try process.runCapture(self.allocator, self.io, argv.items);
        defer self.allocator.free(out);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, self.allocator, out, .{});
        return std.json.Stringify.valueAlloc(self.allocator, struct { updated: std.json.Value }{ .updated = parsed }, .{ .whitespace = .indent_2 });
    }

    fn makeMemory(self: *Server, text: []const u8, tags: []const []const u8) !schema.MemoryRecord {
        const now = try mcp_utils.nowTimestamp(self.allocator);
        return .{
            .memory_id = try std.fmt.allocPrint(self.allocator, "memory_{d}_{d}", .{ time_mod.nowSeconds(), text.len }),
            .scope = .short_term,
            .text = try self.allocator.dupe(u8, text),
            .original_text = try self.allocator.dupe(u8, text),
            .interpretation = try self.allocator.dupe(u8, text),
            .vector = try vector_index.embedQuery(self.allocator, text, tags),
            .confidence = 0.70,
            .valence = emotion.estimateValence(text),
            .salience = emotion.estimateSalience(text, tags),
            .tags = try mcp_utils.cloneConstStringSlice(self.allocator, tags),
            .revisions = &.{},
            .created_at = now,
            .last_accessed_at = null,
            .access_count = 0,
            .score = 1,
        };
    }

    fn makeImpression(self: *Server, source: schema.ImpressionSource, text: []const u8, tags: []const []const u8) !schema.Impression {
        const now = try mcp_utils.nowTimestamp(self.allocator);
        return .{
            .impression_id = try std.fmt.allocPrint(self.allocator, "impression_{d}_{s}", .{ time_mod.nowSeconds(), @tagName(source) }),
            .source = source,
            .text = try self.allocator.dupe(u8, text),
            .tags = try mcp_utils.cloneConstStringSlice(self.allocator, tags),
            .created_at = now,
            .salience = emotion.estimateSalience(text, tags),
        };
    }

    fn makeAppraisal(self: *Server, query: []const u8, impression_id: ?[]const u8, tags: []const []const u8) !schema.Appraisal {
        const now = try mcp_utils.nowTimestamp(self.allocator);
        const signals = emotion.appraise(query);
        return .{
            .appraisal_id = try std.fmt.allocPrint(self.allocator, "appraisal_{d}_{d}", .{ time_mod.nowSeconds(), query.len }),
            .impression_id = if (impression_id) |id| try self.allocator.dupe(u8, id) else null,
            .query = try self.allocator.dupe(u8, query),
            .valence = signals.valence,
            .arousal = signals.arousal,
            .confidence = signals.confidence,
            .uncertainty = signals.uncertainty,
            .social_warmth = signals.social_warmth,
            .curiosity = signals.curiosity,
            .stress = signals.stress,
            .feeling_label = signals.feeling_label,
            .action_tendency = signals.action_tendency,
            .expression = signals.expression,
            .dynamics = signals.dynamics,
            .freeform = try emotion.describe(self.allocator, query, signals),
            .tags = try mcp_utils.cloneConstStringSlice(self.allocator, tags),
            .created_at = now,
        };
    }
};

const RecallMatch = struct {
    memory_id: []const u8,
    scope: []const u8,
    text: []const u8,
    interpretation: []const u8,
    confidence: f32,
    valence: f32,
    salience: f32,
    tags: []const []const u8,
    created_at: []const u8,
    last_accessed_at: ?[]const u8,
    access_count: u32,
    score: i32,
    vector_score: f32,
    similarity: f32,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    const config = try parseArgs(&args_iter);
    var server = try Server.init(allocator, init.io, init.environ_map, config);

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_file_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    while (try readMessage(allocator, stdin_reader)) |request_bytes| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_bytes, .{});
        defer parsed.deinit();
        if (try handleRequest(allocator, &server, parsed.value)) |response| {
            try sendMessage(init.io, response);
        }
    }
}

fn handleRequest(allocator: std.mem.Allocator, server: *Server, request: std.json.Value) !?[]u8 {
    const object = request.object;
    const method = object.get("method").?.string;
    const id = object.get("id") orelse .null;
    if (std.mem.eql(u8, method, "initialize")) {
        return try std.json.Stringify.valueAlloc(allocator, InitializeResponse{ .id = id }, .{});
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        return try std.json.Stringify.valueAlloc(allocator, ToolsResponse{ .id = id, .result = .{ .tools = try mcp_tools.tools(allocator) } }, .{});
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const params = object.get("params").?.object;
        const name = params.get("name").?.string;
        const args = params.get("arguments") orelse std.json.Value.null;
        const result_json = server.callTool(name, args) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
            return try std.json.Stringify.valueAlloc(allocator, ErrorResponse{ .id = id, .@"error" = .{ .code = -32000, .message = message } }, .{});
        };
        const content = [_]TextContent{.{ .text = result_json }};
        return try std.json.Stringify.valueAlloc(allocator, ToolResponse{ .id = id, .result = .{ .content = &content } }, .{});
    }
    if (object.get("id") == null) return null;
    return try std.json.Stringify.valueAlloc(allocator, ErrorResponse{ .id = id, .@"error" = .{ .code = -32601, .message = "unknown method" } }, .{});
}

fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var content_length: usize = 0;
    while (true) {
        const line = (try reader.takeDelimiter('\n')) orelse return null;
        const trimmed = std.mem.trim(u8, line, "\r");
        if (trimmed.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(trimmed, "Content-Length:")) {
            const value = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    if (content_length == 0) return null;
    const body = try allocator.alloc(u8, content_length);
    try reader.readSliceAll(body);
    return body;
}

fn sendMessage(io: std.Io, body: []const u8) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const writer = &stdout_file_writer.interface;
    try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    try writer.flush();
}

const Config = struct {
    brain_id: []const u8 = "default",
    brain_root: []const u8 = "data/brains/default",
    memory_path: []const u8 = "data/brains/default/memory/people.sqlite",
    graph_path: []const u8 = "data/brains/default/memory/relationships.sqlite",
    schedule_path: []const u8 = "data/brains/default/maintenance.md",
    events_path: []const u8 = "data/brains/default/events.jsonl",
    recognition_command: []const u8 = "tools/affective-face-recognizer",
    face_detector_model: []const u8 = "models/face_detection_yunet_2023mar_int8.onnx",
    face_recognition_model: []const u8 = "models/face_recognition_sface_2021dec_int8.onnx",
    face_embeddings_dir: []const u8 = "data/brains/default/memory/face_embeddings",

    fn toBrainConfig(self: Config) !brain_config.Config {
        return .{
            .brain_id = self.brain_id,
            .brain_root = self.brain_root,
            .memory_path = self.memory_path,
            .graph_path = self.graph_path,
            .events_path = self.events_path,
            .maintenance_schedule_path = self.schedule_path,
            .recognition_command = self.recognition_command,
            .face_detector_model = self.face_detector_model,
            .face_recognition_model = self.face_recognition_model,
            .face_embeddings_dir = self.face_embeddings_dir,
        };
    }
};

fn parseArgs(args: *std.process.Args.Iterator) !Config {
    var config = Config{};
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--brain")) {
            config.brain_id = args.next() orelse return error.MissingBrainId;
        } else if (std.mem.eql(u8, arg, "--brain-root")) {
            config.brain_root = args.next() orelse return error.MissingBrainRoot;
        } else if (std.mem.eql(u8, arg, "--memory-path")) {
            config.memory_path = args.next() orelse return error.MissingMemoryPath;
        } else if (std.mem.eql(u8, arg, "--graph-path")) {
            config.graph_path = args.next() orelse return error.MissingGraphPath;
        } else if (std.mem.eql(u8, arg, "--schedule-path")) {
            config.schedule_path = args.next() orelse return error.MissingSchedulePath;
        } else if (std.mem.eql(u8, arg, "--events-path")) {
            config.events_path = args.next() orelse return error.MissingEventsPath;
        } else if (std.mem.eql(u8, arg, "--recognition-command")) {
            config.recognition_command = args.next() orelse return error.MissingRecognitionCommand;
        } else if (std.mem.eql(u8, arg, "--face-detector-model")) {
            config.face_detector_model = args.next() orelse return error.MissingFaceDetectorModel;
        } else if (std.mem.eql(u8, arg, "--face-recognition-model")) {
            config.face_recognition_model = args.next() orelse return error.MissingFaceRecognitionModel;
        } else if (std.mem.eql(u8, arg, "--face-embeddings-dir")) {
            config.face_embeddings_dir = args.next() orelse return error.MissingFaceEmbeddingsDir;
        } else {
            return error.UnknownArgument;
        }
    }
    return config;
}
