const std = @import("std");
const brain_container = @import("app/brain_container.zig");
const app_core = @import("app/app_core.zig");
const host_profiles = @import("app/host_profiles.zig");
const brain_mod = @import("core/brain.zig");
const config_mod = @import("core/config.zig");
const cognitive_capacity = @import("core/cognitive_capacity.zig");
const llm_routing = @import("core/llm_routing.zig");
const schema = @import("storage/schema.zig");
const json_store = @import("storage/json_store.zig");
const brain_storage = @import("storage/brain_storage.zig");
const input_mod = @import("platform/common/input.zig");
const admin_tools = @import("mcp_host/admin_tools.zig");
const mcp_tools = @import("main_mcp_tools.zig");
const mcp_utils = @import("main_mcp_utils.zig");
const main_http_transport = @import("main_http_transport.zig");
const mcp_config = @import("main_mcp_config.zig");
const files_mod = @import("platform/common/files.zig");

const Tool = mcp_tools.Tool;
const Config = mcp_config.Config;

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
    brain: brain_mod.Brain,
    storage_backend: brain_storage.BrainStorage,
    http_transport: *main_http_transport.StdHttpTransport,
    face_embeddings_dir: []const u8,

    fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !Server {
        const http_transport = try allocator.create(main_http_transport.StdHttpTransport);
        http_transport.* = main_http_transport.StdHttpTransport.init(io);
        const local_filesystem = try allocator.create(files_mod.LocalFileSystem);
        local_filesystem.* = .{};
        defer allocator.destroy(local_filesystem);
        var brain_cfg = try config.toBrainConfig();
        brain_cfg = try brain_cfg.ensureBrainPaths(allocator);
        brain_cfg = try brain_cfg.loadForBrain(allocator, local_filesystem.filesystem(), io);
        var brain_host = try host_profiles.initHeadlessMcpBrainHost(allocator, io, http_transport.client(), brain_cfg);
        try brain_host.brain.recoverStuckBrainMode();
        var server = Server{
            .allocator = allocator,
            .io = io,
            .brain = brain_host.brain,
            .storage_backend = brain_host.storage,
            .http_transport = http_transport,
            .face_embeddings_dir = config.face_embeddings_dir,
        };
        brain_mod.wireLlmStatsRecorder(&server.brain, brain_host.llm_provider_clients);
        return server;
    }

    fn deinit(self: *Server) void {
        self.storage_backend.deinit(self.allocator);
    }

    fn dispatchOperation(self: *Server, operation: []const u8, args: std.json.Value) ![]const u8 {
        if (std.mem.eql(u8, operation, "connect")) return self.connect();
        if (std.mem.eql(u8, operation, "host_attach")) return self.hostAttach(args);
        if (std.mem.eql(u8, operation, "host_capability_manifest")) return self.hostCapabilityManifest(args);
        if (std.mem.eql(u8, operation, "refresh_facial_expression_catalog")) return self.refreshFacialExpressionCatalog();
        if (std.mem.eql(u8, operation, "send_experience_event")) return self.sendExperienceEvent(args);
        if (std.mem.eql(u8, operation, "user_text")) return self.userText(try mcp_utils.requireString(args, "text"), mcp_utils.getString(args, "request_id"));
        if (std.mem.eql(u8, operation, "emoji_reaction")) return self.emojiReaction(args);
        if (std.mem.eql(u8, operation, "request_dream_time")) return self.requestDreamTime(mcp_utils.getString(args, "text"));
        if (std.mem.eql(u8, operation, "brain_mode")) return self.brainMode();
        if (std.mem.eql(u8, operation, "read_models_snapshot")) return self.readModelsSnapshot();
        if (std.mem.eql(u8, operation, "memory_inspect_safe")) return self.memoryInspectSafe(args);
        if (std.mem.eql(u8, operation, "session_metadata_get")) return admin_tools.metadataGet(self.allocator, self.io, self.brain.cfg.brain_root);
        if (std.mem.eql(u8, operation, "session_metadata_set")) return admin_tools.metadataSet(self.allocator, self.io, self.brain.cfg.brain_root, args);
        if (std.mem.eql(u8, operation, "set_runtime_option")) return self.setRuntimeOption(args);
        if (std.mem.eql(u8, operation, "mailbox_list")) return self.mailboxList();
        if (std.mem.eql(u8, operation, "mailbox_mark_read")) return self.mailboxMarkRead(try mcp_utils.requireString(args, "mailbox_id"));
        if (std.mem.eql(u8, operation, "capability_status")) return self.capabilityStatus(args);
        if (std.mem.eql(u8, operation, "capability_status_batch")) return self.capabilityStatusBatch(args);
        if (std.mem.eql(u8, operation, "export_brain")) return self.exportBrain(try mcp_utils.requireString(args, "brain_file_path"));
        if (std.mem.eql(u8, operation, "import_brain")) return self.importBrain(args);
        return error.UnknownOperation;
    }

    fn connect(self: *Server) ![]const u8 {
        const info = try brain_container.inspectBrain(self.allocator, self.io, self.brain.cfg);
        _ = try self.brain.recordSimpleExperienceEvent("MCP.Connected", .host, "connect");
        try self.brain.refreshPersonaDirectiveFromStore();
        return std.json.Stringify.valueAlloc(self.allocator, struct { brain: brain_container.BrainIntrospection }{ .brain = info }, .{ .whitespace = .indent_2 });
    }

    fn hostAttach(self: *Server, args: std.json.Value) ![]const u8 {
        const host_id = try mcp_utils.requireString(args, "host_id");
        const binding: schema.HostBinding = .{
            .host_id = host_id,
            .platform = mcp_utils.getString(args, "platform") orelse "mcp",
            .app_version = mcp_utils.getString(args, "app_version") orelse "",
            .attached_at_ms = self.brain.now_seconds * 1000,
            .permissions = try mcp_utils.cloneConstStringSlice(self.allocator, try mcp_utils.getStringArray(self.allocator, args, "permissions")),
            .capability_ids = try mcp_utils.cloneConstStringSlice(self.allocator, try mcp_utils.getStringArray(self.allocator, args, "capability_ids")),
            .provider_availability = mcp_utils.getString(args, "provider_availability") orelse "",
            .sensor_quality = mcp_utils.getString(args, "sensor_quality") orelse "",
            .local_policy = mcp_utils.getString(args, "local_policy") orelse "",
        };
        try self.brain.deps.store.upsertHostBinding(binding);
        _ = try self.brain.recordSimpleExperienceEvent("Host.Attached", .host, host_id);
        return std.json.Stringify.valueAlloc(self.allocator, struct { host_binding: schema.HostBinding }{ .host_binding = binding }, .{ .whitespace = .indent_2 });
    }

    fn hostCapabilityManifest(self: *Server, args: std.json.Value) ![]const u8 {
        const host_id = mcp_utils.getString(args, "host_id") orelse "mcp";
        const ids = try mcp_utils.getStringArray(self.allocator, args, "capability_ids");
        _ = try self.brain.recordManifestStatuses(host_id, ids);
        return std.json.Stringify.valueAlloc(self.allocator, struct { capability_count: usize }{ .capability_count = ids.len }, .{ .whitespace = .indent_2 });
    }

    fn refreshFacialExpressionCatalog(self: *Server) ![]const u8 {
        const brain_facial_expression = @import("core/brain_facial_expression.zig");
        const catalog = try self.brain.refreshFacialExpressionCatalog();
        return std.json.Stringify.valueAlloc(self.allocator, struct { catalog: brain_facial_expression.FacialExpressionCatalogSnapshot }{ .catalog = catalog }, .{ .whitespace = .indent_2 });
    }

    fn sendExperienceEvent(self: *Server, args: std.json.Value) ![]const u8 {
        const kind = try mcp_utils.requireString(args, "kind");
        const payload = mcp_utils.getString(args, "payload") orelse "";
        const existing_events = self.brain.deps.store.loadExperienceEvents(self.allocator) catch &.{};
        const event: schema.ExperienceEvent = .{
            .id = mcp_utils.getString(args, "id") orelse try std.fmt.allocPrint(self.allocator, "mcp_evt_{d}_{d}_{s}", .{ self.brain.now_seconds * 1000, existing_events.len, kind }),
            .brain_id = self.brain.cfg.brain_id,
            .host_id = mcp_utils.getString(args, "host_id") orelse "mcp",
            .timestamp_ms = integerArg(args, "timestamp_ms") orelse self.brain.now_seconds * 1000,
            .source = experienceEventSourceFromString(mcp_utils.getString(args, "source") orelse "host"),
            .kind = kind,
            .payload = payload,
            .salience = f32Arg(args, "salience") orelse 0.40,
            .confidence = f32Arg(args, "confidence") orelse 0.70,
            .valence = f32Arg(args, "valence") orelse 0.0,
            .arousal = f32Arg(args, "arousal") orelse 0.0,
            .uncertainty = f32Arg(args, "uncertainty") orelse 0.30,
            .causal_parent_ids = try mcp_utils.cloneConstStringSlice(self.allocator, try mcp_utils.getStringArray(self.allocator, args, "causal_parent_ids")),
            .retention = retentionFromString(mcp_utils.getString(args, "retention") orelse "episode"),
            .visibility = visibilityFromString(mcp_utils.getString(args, "visibility") orelse "internal"),
        };
        try self.brain.recordExperienceEvent(event);
        return std.json.Stringify.valueAlloc(self.allocator, struct { event: schema.ExperienceEvent }{ .event = event }, .{ .whitespace = .indent_2 });
    }

    fn requestDreamTime(self: *Server, prompt: ?[]const u8) ![]const u8 {
        const item = try self.brain.requestDreamTime(prompt);
        return std.json.Stringify.valueAlloc(self.allocator, struct { mailbox_item: schema.MailboxItem }{ .mailbox_item = item }, .{ .whitespace = .indent_2 });
    }

    fn brainMode(self: *Server) ![]const u8 {
        const mode = try self.brain.deps.store.loadBrainMode();
        return std.json.Stringify.valueAlloc(self.allocator, struct { brain_mode: schema.BrainMode }{ .brain_mode = mode }, .{ .whitespace = .indent_2 });
    }

    fn readModelsSnapshot(self: *Server) ![]const u8 {
        const snapshot = try self.brain.readModelsSnapshot(self.allocator);
        return std.json.Stringify.valueAlloc(self.allocator, struct { read_models: @TypeOf(snapshot) }{ .read_models = snapshot }, .{ .whitespace = .indent_2 });
    }

    fn memoryInspectSafe(self: *Server, args: std.json.Value) ![]const u8 {
        const snapshot = try self.readModelsSnapshot();
        return try admin_tools.memoryInspectSafe(self.allocator, snapshot, args);
    }

    fn setRuntimeOption(self: *Server, args: std.json.Value) ![]const u8 {
        if (args != .object) return error.InvalidArguments;
        var touched_runtime = false;
        var touched_llm = false;
        if (mcp_utils.getString(args, "llm_quality")) |llm_quality| {
            _ = try llm_routing.LlmQuality.parse(llm_quality);
            self.brain.cfg.llm_quality = try self.allocator.dupe(u8, llm_quality);
            touched_runtime = true;
        }
        if (mcp_utils.getString(args, "reasoning_effort")) |effort| {
            self.brain.cfg.conversation_reasoning_effort = try self.allocator.dupe(u8, effort);
            touched_llm = true;
        }
        if (mcp_utils.getString(args, "psyche_reasoning_effort")) |effort| {
            self.brain.cfg.psyche_reasoning_effort = try self.allocator.dupe(u8, effort);
            touched_llm = true;
        }
        if (mcp_utils.getString(args, "ai_mode")) |mode| {
            self.brain.cfg.ai_mode = try self.allocator.dupe(u8, mode);
            touched_llm = true;
        }
        if (args.object.get("capacity")) |capacity_value| {
            const partial = try parseCapacityPartial(capacity_value);
            self.brain.cfg.capacity = cognitive_capacity.mergePartial(self.brain.cfg.capacity, partial);
            try cognitive_capacity.validate(self.brain.cfg.capacity);
            touched_runtime = true;
        }
        if (!touched_runtime and !touched_llm) return error.MissingRuntimeOptionField;
        var local_fs = files_mod.LocalFileSystem{};
        if (touched_runtime) try config_mod.saveRuntimeOptions(self.allocator, local_fs.filesystem(), self.io, self.brain.cfg);
        if (touched_llm) try config_mod.saveLlmProviders(self.allocator, local_fs.filesystem(), self.io, self.brain.cfg);
        return std.json.Stringify.valueAlloc(self.allocator, struct {
            llm_quality: []const u8,
            conversation_reasoning_effort: []const u8,
            psyche_reasoning_effort: []const u8,
            ai_mode: []const u8,
            capacity: config_mod.CapacityConfig,
        }{
            .llm_quality = self.brain.cfg.llm_quality,
            .conversation_reasoning_effort = self.brain.cfg.conversation_reasoning_effort,
            .psyche_reasoning_effort = self.brain.cfg.psyche_reasoning_effort,
            .ai_mode = self.brain.cfg.ai_mode,
            .capacity = self.brain.cfg.capacity,
        }, .{ .whitespace = .indent_2 });
    }

    fn mailboxList(self: *Server) ![]const u8 {
        const items = try self.brain.deps.store.loadMailboxItems(self.allocator);
        return std.json.Stringify.valueAlloc(self.allocator, struct { items: []const schema.MailboxItem }{ .items = items }, .{ .whitespace = .indent_2 });
    }

    fn mailboxMarkRead(self: *Server, mailbox_id: []const u8) ![]const u8 {
        const item = try self.brain.markMailboxRead(mailbox_id);
        return std.json.Stringify.valueAlloc(self.allocator, struct { mailbox_item: schema.MailboxItem }{ .mailbox_item = item }, .{ .whitespace = .indent_2 });
    }

    fn capabilityStatus(self: *Server, args: std.json.Value) ![]const u8 {
        const status: schema.CapabilityStatus = .{
            .capability_id = try mcp_utils.requireString(args, "capability_id"),
            .host_id = mcp_utils.getString(args, "host_id") orelse "mcp",
            .permission = permissionFromString(mcp_utils.getString(args, "permission") orelse "unknown"),
            .availability = availabilityFromString(mcp_utils.getString(args, "availability") orelse "unavailable"),
            .quality = f32Arg(args, "quality") orelse 0.0,
            .reliability = f32Arg(args, "reliability") orelse 0.0,
            .cost = f32Arg(args, "cost") orelse 0.0,
            .latency_ms = u32Arg(args, "latency_ms") orelse 0,
            .risk = f32Arg(args, "risk") orelse 0.0,
            .unavailable_reason = mcp_utils.getString(args, "unavailable_reason") orelse "",
            .updated_at_ms = self.brain.now_seconds * 1000,
        };
        try self.brain.recordCapabilityStatus(status);
        return std.json.Stringify.valueAlloc(self.allocator, struct { status: schema.CapabilityStatus }{ .status = status }, .{ .whitespace = .indent_2 });
    }

    fn capabilityStatusBatch(self: *Server, args: std.json.Value) ![]const u8 {
        const statuses_value = if (args == .object) args.object.get("statuses") orelse return error.MissingCapabilityStatuses else return error.MissingCapabilityStatuses;
        if (statuses_value != .array) return error.ExpectedCapabilityStatusArray;
        var persist = try self.brain.deps.store.deferredPersistGuard();
        const capability_count = capabilityStatusBatchInner(self, statuses_value.array.items) catch |err| {
            persist.cancel() catch return error.DeferredPersistEndFailed;
            return err;
        };
        try persist.commit();
        return std.json.Stringify.valueAlloc(self.allocator, struct { capability_count: usize }{ .capability_count = capability_count }, .{ .whitespace = .indent_2 });
    }

    fn capabilityStatusBatchInner(self: *Server, statuses: []std.json.Value) !usize {
        for (statuses) |item| {
            if (item != .object) return error.ExpectedCapabilityStatusObject;
            const object = item.object;
            const capability_id = object.get("capability_id") orelse return error.MissingRequiredString;
            if (capability_id != .string) return error.MissingRequiredString;
            const status: schema.CapabilityStatus = .{
                .capability_id = capability_id.string,
                .host_id = stringFromObject(object, "host_id") orelse "mcp",
                .permission = permissionFromString(stringFromObject(object, "permission") orelse "unknown"),
                .availability = availabilityFromString(stringFromObject(object, "availability") orelse "unavailable"),
                .quality = @floatCast(numberFromObject(object, "quality") orelse 0.0),
                .reliability = @floatCast(numberFromObject(object, "reliability") orelse 0.0),
                .cost = @floatCast(numberFromObject(object, "cost") orelse 0.0),
                .latency_ms = blk: {
                    const value = integerFromObject(object, "latency_ms") orelse break :blk 0;
                    if (value < 0) break :blk 0;
                    break :blk @intCast(value);
                },
                .risk = @floatCast(numberFromObject(object, "risk") orelse 0.0),
                .unavailable_reason = stringFromObject(object, "unavailable_reason") orelse "",
                .updated_at_ms = self.brain.now_seconds * 1000,
            };
            try self.brain.recordCapabilityStatus(status);
        }
        return statuses.len;
    }

    fn exportBrain(self: *Server, path: []const u8) ![]const u8 {
        const manifest = try brain_container.exportBrain(self.allocator, self.io, self.brain.cfg, path);
        _ = try self.brain.recordSimpleExperienceEvent("Brain.Exported", .system, path);
        return std.json.Stringify.valueAlloc(self.allocator, struct { manifest: brain_container.BrainManifest }{ .manifest = manifest }, .{ .whitespace = .indent_2 });
    }

    fn importBrain(self: *Server, args: std.json.Value) ![]const u8 {
        const path = try mcp_utils.requireString(args, "brain_file_path");
        const inspected = if (mcp_utils.getString(args, "brain_id") == null)
            try brain_container.inspectBrainFile(self.allocator, self.io, path)
        else
            null;
        const brain_id = mcp_utils.getString(args, "brain_id") orelse inspected.?.brain_id;
        const brain_root = try mcp_utils.requireString(args, "brain_root");
        const manifest = try brain_container.importBrain(self.allocator, self.io, path, .{
            .brain_id = brain_id,
            .brain_root = brain_root,
        });
        const host_id = mcp_utils.getString(args, "host_id") orelse self.brain.currentHostId();
        const payload = if (host_id.len > 0)
            try std.fmt.allocPrint(self.allocator, "brain_id={s}; brain_root={s}; host_id={s}", .{ manifest.brain_id, brain_root, host_id })
        else
            try std.fmt.allocPrint(self.allocator, "brain_id={s}; brain_root={s}", .{ manifest.brain_id, brain_root });
        _ = try self.brain.recordSimpleExperienceEvent("Brain.Imported", .system, payload);
        if (host_id.len > 0) _ = try self.brain.recordSimpleExperienceEvent("Host.BindingChangedAfterImport", .host, host_id);
        return std.json.Stringify.valueAlloc(self.allocator, struct { manifest: brain_container.BrainManifest }{ .manifest = manifest }, .{ .whitespace = .indent_2 });
    }

    fn userText(self: *Server, text: []const u8, request_id: ?[]const u8) ![]const u8 {
        const dispatch_id = if (request_id) |id|
            id
        else
            try std.fmt.allocPrint(self.allocator, "mcp_{d}_{d}", .{ self.brain.now_seconds, text.len });
        defer if (request_id == null) self.allocator.free(dispatch_id);
        const result = try app_core.handleUserText(
            &self.brain,
            try input_mod.HeardSpeech.typed(self.allocator, text),
            .{ .request_id = dispatch_id },
        );
        return std.json.Stringify.valueAlloc(self.allocator, result, .{ .whitespace = .indent_2 });
    }

    fn emojiReaction(self: *Server, args: std.json.Value) ![]const u8 {
        const emoji = try mcp_utils.requireString(args, "emoji");
        const utterance_text = try mcp_utils.requireString(args, "utterance_text");
        const result = app_core.userTextOutcome(try self.brain.handleEmojiReaction(.{
            .emoji = emoji,
            .utterance_text = utterance_text,
            .speaker_label = mcp_utils.getString(args, "speaker_label") orelse "",
            .utterance_event_id = mcp_utils.getString(args, "utterance_event_id") orelse "",
        }));
        return std.json.Stringify.valueAlloc(self.allocator, result, .{ .whitespace = .indent_2 });
    }

    fn chatDryRunPrompt(self: *Server, text: []const u8) ![]const u8 {
        const prompt = try self.brain.dryRunConversationPrompt(text);
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
        const info = try brain_container.inspectBrain(self.allocator, self.io, self.brain.cfg);
        return std.json.Stringify.valueAlloc(self.allocator, info, .{ .whitespace = .indent_2 });
    }
};

fn experienceEventSourceFromString(value: []const u8) schema.ExperienceEventSource {
    if (std.mem.eql(u8, value, "user")) return .user;
    if (std.mem.eql(u8, value, "sense")) return .sense;
    if (std.mem.eql(u8, value, "subsystem")) return .subsystem;
    if (std.mem.eql(u8, value, "capability")) return .capability;
    if (std.mem.eql(u8, value, "memory")) return .memory;
    if (std.mem.eql(u8, value, "autonomy")) return .autonomy;
    if (std.mem.eql(u8, value, "dream_time")) return .dream_time;
    if (std.mem.eql(u8, value, "system")) return .system;
    return .host;
}

fn retentionFromString(value: []const u8) schema.ExperienceEventRetention {
    if (std.mem.eql(u8, value, "ephemeral") or std.mem.eql(u8, value, "working")) return .ephemeral;
    if (std.mem.eql(u8, value, "durable") or std.mem.eql(u8, value, "long_term")) return .durable;
    if (std.mem.eql(u8, value, "disposition")) return .disposition;
    if (std.mem.eql(u8, value, "discard")) return .discard;
    return .episode;
}

fn visibilityFromString(value: []const u8) schema.ExperienceEventVisibility {
    if (std.mem.eql(u8, value, "host") or std.mem.eql(u8, value, "public")) return .host;
    if (std.mem.eql(u8, value, "developer") or std.mem.eql(u8, value, "diagnostic")) return .developer;
    if (std.mem.eql(u8, value, "private")) return .private;
    return .internal;
}

fn permissionFromString(value: []const u8) schema.CapabilityPermission {
    if (std.mem.eql(u8, value, "granted")) return .granted;
    if (std.mem.eql(u8, value, "denied")) return .denied;
    if (std.mem.eql(u8, value, "prompt_required")) return .prompt_required;
    if (std.mem.eql(u8, value, "not_required")) return .not_required;
    return .unknown;
}

fn availabilityFromString(value: []const u8) schema.CapabilityAvailability {
    if (std.mem.eql(u8, value, "available")) return .available;
    if (std.mem.eql(u8, value, "degraded")) return .degraded;
    if (std.mem.eql(u8, value, "refused")) return .refused;
    return .unavailable;
}

fn integerArg(args: std.json.Value, key: []const u8) ?i64 {
    return switch (argValue(args, key) orelse return null) {
        .integer => |value| value,
        .float => |value| @intFromFloat(value),
        else => null,
    };
}

fn u32Arg(args: std.json.Value, key: []const u8) ?u32 {
    const value = integerArg(args, key) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

fn f32Arg(args: std.json.Value, key: []const u8) ?f32 {
    return @floatCast(mcp_utils.getNumber(args, key) orelse return null);
}

fn argValue(args: std.json.Value, key: []const u8) ?std.json.Value {
    if (args != .object) return null;
    return args.object.get(key);
}

fn stringFromObject(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn numberFromObject(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .float => value.float,
        .integer => @floatFromInt(value.integer),
        else => null,
    };
}

fn integerFromObject(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => value.integer,
        .float => @intFromFloat(value.float),
        else => null,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    const config = try mcp_config.parseArgs(&args_iter);
    var server = try Server.init(allocator, init.io, config);
    defer server.deinit();

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
        const result_json = server.dispatchOperation(name, args) catch |err| {
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

fn parseCapacityPartial(value: std.json.Value) !config_mod.CapacityConfigPartial {
    if (value != .object) return error.InvalidCapacityObject;
    const object = value.object;
    return .{
        .activity_stack_max = usizeField(object.get("activity_stack_max")),
        .focus_slots_max = usizeField(object.get("focus_slots_max")),
        .memory_selected_max = usizeField(object.get("memory_selected_max")),
        .memory_prefilter_max = usizeField(object.get("memory_prefilter_max")),
        .memory_snippet_max_bytes = usizeField(object.get("memory_snippet_max_bytes")),
        .memory_context_bytes_max = usizeField(object.get("memory_context_bytes_max")),
        .candidate_actions_max = usizeField(object.get("candidate_actions_max")),
        .open_loops_soft_max = usizeField(object.get("open_loops_soft_max")),
        .conversation_summaries_in_context_max = usizeField(object.get("conversation_summaries_in_context_max")),
        .chat_context_tokens_max = usizeField(object.get("chat_context_tokens_max")),
        .dispatch_envelope_bytes_max = usizeField(object.get("dispatch_envelope_bytes_max")),
        .dispatch_event_count_max = usizeField(object.get("dispatch_event_count_max")),
    };
}

fn usizeField(value: ?std.json.Value) ?usize {
    const resolved = value orelse return null;
    return switch (resolved) {
        .integer => |v| if (v < 0) null else @intCast(v),
        .float => |v| if (v < 0) null else @intFromFloat(v),
        else => null,
    };
}
