const std = @import("std");

pub fn connect(request_id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"connect\"}}}}", .{
        try jsonString(request_id),
    });
}

pub fn hostAttach(request_id: []const u8, host_id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"host_attach\",\"host_id\":{s},\"platform\":\"mcp_host\",\"app_version\":\"0.1.0\",\"capability_ids\":[\"text_input\",\"short_touch\",\"camera_capture\",\"identity_recognition\",\"event_drain\"]}}}}", .{
        try jsonString(request_id),
        try jsonString(host_id),
    });
}

pub fn userText(request_id: []const u8, text: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"user_text\",\"text\":{s}}}}}", .{
        try jsonString(request_id),
        try jsonString(text),
    });
}

pub fn shortTouch(request_id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"short_touch\"}}}}", .{
        try jsonString(request_id),
    });
}

pub fn senseObservationCamera(request_id: []const u8, image_path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"sense_observation\",\"sense\":\"camera\",\"observation\":{{\"path\":{s},\"mime_type\":\"image/jpeg\",\"source\":\"affective_requested_capture\"}}}}}}", .{
        try jsonString(request_id),
        try jsonString(image_path),
    });
}

pub fn readModelsSnapshot(request_id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"read_models_snapshot\"}}}}", .{
        try jsonString(request_id),
    });
}

fn jsonString(text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(std.heap.page_allocator, text, .{});
}
