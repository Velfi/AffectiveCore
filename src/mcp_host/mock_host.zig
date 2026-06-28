const std = @import("std");
const embedded = @import("../affective_core_embedded.zig");
const embedded_config = @import("../affective_core_embedded_config.zig");

const AffectiveCoreEmbeddedString = embedded.AffectiveCoreEmbeddedString;

pub const Mode = enum {
    default,
    /// First LLM call proposes recognize; second returns `{}` to trigger LocalServiceResponseInvalid on resume.
    resume_invalid_llm,
    /// First LLM call proposes recognize; second says hello without remember_person after unknown face.
    enrollment_without_remember_person,
    /// Every LLM call fails like upstream provider rejection.
    upstream_rejected,
};

pub const MockHost = struct {
    mode: Mode,
    llm_calls: usize = 0,
    conversation_calls: usize = 0,
    vision_calls: usize = 0,
    identify_calls: usize = 0,
    enroll_calls: usize = 0,

    pub fn hostServices(self: *MockHost) embedded.AffectiveCoreEmbeddedHostServices {
        return .{
            .ctx = self,
            .http_post_json = httpPostJson,
            .free_string = freeHostString,
        };
    }

    fn httpPostJson(
        ctx: ?*anyopaque,
        url: AffectiveCoreEmbeddedString,
        _: AffectiveCoreEmbeddedString,
        body: AffectiveCoreEmbeddedString,
        out_data: ?*AffectiveCoreEmbeddedString,
        out_error: ?*AffectiveCoreEmbeddedString,
    ) callconv(.c) c_int {
        const self: *MockHost = @ptrCast(@alignCast(ctx orelse {
            return hostFailure(out_data, out_error, "missing mock host context");
        }));
        const url_slice = embedded_config.stringSlice(url) orelse "";
        const body_slice = embedded_config.stringSlice(body) orelse "";

        if (std.mem.endsWith(u8, url_slice, "/llm/complete")) {
            self.llm_calls += 1;
            if (self.mode == .upstream_rejected) {
                return hostFailure(out_data, out_error, "upstream provider rejected request");
            }
            return hostSuccess(out_data, out_error, self.llmResponse(body_slice));
        }
        if (std.mem.endsWith(u8, url_slice, "/vision/complete")) {
            self.vision_calls += 1;
            return hostSuccess(out_data, out_error, visionDescriptionResponse());
        }
        if (std.mem.endsWith(u8, url_slice, "/recognize/identify")) {
            self.identify_calls += 1;
            return hostSuccess(out_data, out_error, identifyResponse(body_slice));
        }
        if (std.mem.endsWith(u8, url_slice, "/recognize/enroll")) {
            self.enroll_calls += 1;
            return hostSuccess(out_data, out_error, enrollResponse());
        }
        return hostFailure(out_data, out_error, "unsupported mock host route");
    }

    fn llmResponse(self: *MockHost, request_body: []const u8) []const u8 {
        const Wire = struct { subsystem: ?[]const u8 = null };
        const parsed = std.json.parseFromSlice(Wire, std.heap.page_allocator, request_body, .{ .ignore_unknown_fields = true }) catch {
            return self.conversationResponse();
        };
        defer parsed.deinit();
        const subsystem = parsed.value.subsystem orelse "conversation";

        if (std.mem.eql(u8, subsystem, "want_achievement")) return "{\"matches\":[]}";
        if (std.mem.eql(u8, subsystem, "intent")) return "{\"action\":\"unknown\",\"value\":null}";
        if (std.mem.eql(u8, subsystem, "memory_extraction")) return "{\"candidates\":[]}";
        if (std.mem.eql(u8, subsystem, "greeting")) return "{\"text\":\"Hello there.\"}";
        if (std.mem.eql(u8, subsystem, "autonomy")) return "{\"action_pressures\":[],\"salience\":\"low\",\"reason\":\"mock autonomy\"}";
        if (std.mem.startsWith(u8, subsystem, "psyche") or std.mem.startsWith(u8, subsystem, "LanguageMind") or std.mem.eql(u8, subsystem, "language_mind")) {
            if (std.mem.eql(u8, subsystem, "psyche_superego")) {
                return "{\"concerns\":[],\"vetoes\":[],\"preferred_restraints\":[],\"values_to_preserve\":[],\"salience\":\"low\",\"reason\":\"mock superego\"}";
            }
            return "{\"top_need\":\"connection\",\"urges\":[],\"random_thoughts\":[],\"desired_action_bias\":\"say hello\",\"salience\":\"low\",\"reason\":\"mock psyche\"}";
        }
        if (!std.mem.eql(u8, subsystem, "conversation")) return "{\"ok\":true}";
        return self.conversationResponse();
    }

    fn conversationResponse(self: *MockHost) []const u8 {
        self.conversation_calls += 1;
        return switch (self.mode) {
            .upstream_rejected => "{}",
            .resume_invalid_llm => switch (self.conversation_calls) {
                1 => recognizeTurn(),
                else => "{}",
            },
            .enrollment_without_remember_person => switch (self.conversation_calls) {
                1 => recognizeTurn(),
                else => sayTurn("I see someone new here.", "Greeted without enrolling."),
            },
            .default => switch (self.conversation_calls) {
                1 => recognizeTurn(),
                else => sayTurn("Hi — I'm here.", "Responded after observation."),
            },
        };
    }
};

fn echoUserText(request_body: []const u8) []const u8 {
    const Wire = struct { user_prompt: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(Wire, std.heap.page_allocator, request_body, .{ .ignore_unknown_fields = true }) catch {
        return "I heard you.";
    };
    defer parsed.deinit();
    const prompt = parsed.value.user_prompt orelse return "I heard you.";
    const trimmed = std.mem.trim(u8, prompt, " \r\n\t");
    if (trimmed.len == 0) return "I heard you.";
    return std.fmt.allocPrint(std.heap.page_allocator, "You said: {s}", .{trimmed}) catch "I heard you.";
}

fn recognizeTurn() []const u8 {
    return
        \\{"action_pressures":[{"action":"recognize","origin":"interaction","delay_ms":null,"scale":"full","text":null,"query":null,"memory_id":null,"person_id":null,"name":null,"image_path":null,"schedule":null,"to":null,"subject":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"keep_existing":null,"tags":[]}],"user_summary":"User greeted the brain.","brain_summary":"Chose to look at who is here.","reasoning_effort":null,"turn_complete":false}
    ;
}

fn sayTurn(text: []const u8, brain_summary: []const u8) []const u8 {
    return std.fmt.allocPrint(
        std.heap.page_allocator,
        "{{\"action_pressures\":[{{\"action\":\"say\",\"origin\":\"interaction\",\"delay_ms\":null,\"scale\":\"full\",\"text\":{s},\"query\":null,\"memory_id\":null,\"person_id\":null,\"name\":null,\"image_path\":null,\"schedule\":null,\"to\":null,\"subject\":null,\"heat_bias\":null,\"eyes\":null,\"mouth\":null,\"duration_ms\":null,\"keep_existing\":null,\"tags\":[]}}],\"user_summary\":\"User spoke.\",\"brain_summary\":{s},\"reasoning_effort\":null,\"turn_complete\":true}}",
        .{ jsonString(text), jsonString(brain_summary) },
    ) catch "{}";
}

fn jsonString(text: []const u8) []const u8 {
    return std.json.Stringify.valueAlloc(std.heap.page_allocator, text, .{}) catch "\"\"";
}

fn visionDescriptionResponse() []const u8 {
    return "{\"description\":\"A person is visible in the frame.\",\"confidence\":0.82}";
}

fn identifyResponse(body: []const u8) []const u8 {
    const Wire = struct { image_path: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(Wire, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return noneIdentifyResponse();
    };
    defer parsed.deinit();
    const path = parsed.value.image_path orelse return noneIdentifyResponse();
    if (std.mem.indexOf(u8, path, "known") != null) {
        return
            \\{"person_present":true,"match_status":"known","person_id":"person_001","confidence":0.91,"candidate_name":"Mara","people_count":1}
        ;
    }
    if (std.mem.indexOf(u8, path, "empty") != null or std.mem.indexOf(u8, path, "none") != null) {
        return noneIdentifyResponse();
    }
    return
        \\{"person_present":true,"match_status":"unknown","confidence":0.40,"people_count":1}
    ;
}

fn noneIdentifyResponse() []const u8 {
    return
        \\{"person_present":false,"match_status":"none","confidence":0.0,"people_count":0}
    ;
}

fn enrollResponse() []const u8 {
    return
        \\{"person_id":"person_new","display_name":"Guest","representative_image_path":"/tmp/mcp-host-enroll.jpg","embedding_path":"/tmp/mcp-host-enroll.embedding","quality_score":0.82,"removed_embeddings":0,"kept_existing":false}
    ;
}

fn hostSuccess(out_data: ?*AffectiveCoreEmbeddedString, out_error: ?*AffectiveCoreEmbeddedString, body: []const u8) c_int {
    if (out_error) |err_out| err_out.* = .{};
    if (out_data) |data| {
        const owned = std.heap.page_allocator.dupe(u8, body) catch {
            data.* = .{};
            return 1;
        };
        data.* = .{ .ptr = owned.ptr, .len = owned.len };
    }
    return 0;
}

fn hostFailure(out_data: ?*AffectiveCoreEmbeddedString, out_error: ?*AffectiveCoreEmbeddedString, message: []const u8) c_int {
    if (out_data) |data| data.* = .{};
    if (out_error) |err_out| {
        const owned = std.heap.page_allocator.dupe(u8, message) catch {
            err_out.* = .{};
            return 1;
        };
        err_out.* = .{ .ptr = owned.ptr, .len = owned.len };
    }
    return 1;
}

fn freeHostString(_: ?*anyopaque, string: AffectiveCoreEmbeddedString) callconv(.c) void {
    const slice = embedded_config.stringSlice(string) orelse return;
    std.heap.page_allocator.free(slice);
}

test "mock host returns invalid json on resume for resume_invalid_llm mode" {
    var host: MockHost = .{ .mode = .resume_invalid_llm };
    host.conversation_calls = 1;
    const second = host.llmResponse("{\"subsystem\":\"conversation\"}");
    try std.testing.expectEqualStrings("{}", second);
}
