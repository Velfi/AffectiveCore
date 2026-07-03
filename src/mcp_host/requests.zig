const std = @import("std");

pub fn connect(request_id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"connect\"}}}}", .{
        try jsonString(request_id),
    });
}

pub fn hostAttach(request_id: []const u8, host_id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"host_update\",\"kind\":\"host_attach\",\"host_id\":{s},\"platform\":\"mcp_host\",\"app_version\":\"0.1.0\",\"capability_ids\":[\"text_input\",\"short_touch\",\"camera_capture\",\"identity_recognition\",\"event_drain\",\"dream_time_request\"]}}}}", .{
        try jsonString(request_id),
        try jsonString(host_id),
    });
}

pub fn userText(request_id: []const u8, text: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"stimulus_ingest\",\"kind\":\"speech\",\"text\":{s}}}}}", .{
        try jsonString(request_id),
        try jsonString(text),
    });
}

pub fn shortTouch(request_id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"stimulus_ingest\",\"kind\":\"touch\",\"gesture\":\"short_touch\",\"summary\":\"Short touch observed.\"}}}}", .{
        try jsonString(request_id),
    });
}

pub fn senseObservationCamera(request_id: []const u8, image_path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"stimulus_ingest\",\"kind\":\"camera\",\"path\":{s},\"mime_type\":\"image/jpeg\",\"source\":\"affective_requested_capture\"}}}}", .{
        try jsonString(request_id),
        try jsonString(image_path),
    });
}

pub fn readModelsSnapshot(request_id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"brain_read\",\"query\":\"models_snapshot\"}}}}", .{
        try jsonString(request_id),
    });
}

pub fn exportBrain(request_id: []const u8, brain_file_path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"brain_archive\",\"action\":\"export\",\"brain_file_path\":{s}}}}}", .{
        try jsonString(request_id),
        try jsonString(brain_file_path),
    });
}

pub fn requestDreamTime(request_id: []const u8, text: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"mailbox_update\",\"action\":\"request_dream_time\",\"prompt\":{s}}}}}", .{
        try jsonString(request_id),
        try jsonString(text),
    });
}

pub fn brainStep(request_id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"brain_step\",\"kind\":\"autonomy\"}}}}", .{
        try jsonString(request_id),
    });
}

pub fn autonomyTick(request_id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"autonomy_tick\"}}}}", .{
        try jsonString(request_id),
    });
}

pub fn sendExperienceEvent(
    request_id: []const u8,
    kind: []const u8,
    payload: []const u8,
    salience: f32,
    confidence: f32,
    valence: f32,
    arousal: f32,
    uncertainty: f32,
    retention: []const u8,
    visibility: []const u8,
) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator,
        "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"send_experience_event\",\"host_id\":\"brain-quality-e2e\",\"source\":\"host\",\"kind\":{s},\"payload\":{s},\"salience\":{d},\"confidence\":{d},\"valence\":{d},\"arousal\":{d},\"uncertainty\":{d},\"causal_parent_ids\":[],\"retention\":{s},\"visibility\":{s}}}}}",
        .{
            try jsonString(request_id),
            try jsonString(kind),
            try jsonString(payload),
            salience,
            confidence,
            valence,
            arousal,
            uncertainty,
            try jsonString(retention),
            try jsonString(visibility),
        },
    );
}

fn jsonString(text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(std.heap.page_allocator, text, .{});
}
