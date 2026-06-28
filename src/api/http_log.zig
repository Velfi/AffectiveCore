const std = @import("std");
const error_descriptions = @import("../core/error_descriptions.zig");

pub fn logStart(url: []const u8, payload_bytes: usize, response_limit: usize) void {
    std.debug.print("HTTP start method=POST url={s} payload_bytes={d} response_limit={d}\n", .{ url, payload_bytes, response_limit });
}

pub fn logDone(url: []const u8, response_bytes: usize) void {
    std.debug.print("HTTP done method=POST url={s} response_bytes={d}\n", .{ url, response_bytes });
}

pub fn logError(url: []const u8, err: anyerror) void {
    std.debug.print(
        "HTTP error method=POST url={s} error={s} detail=\"{s}\"\n",
        .{ url, error_descriptions.name(err), error_descriptions.detail(err) },
    );
}

pub fn logResponseTooLarge(url: []const u8, response_bytes: usize, response_limit: usize) void {
    std.debug.print(
        "HTTP response_too_large method=POST url={s} response_bytes={d} response_limit={d} detail=\"{s}\"\n",
        .{ url, response_bytes, response_limit, error_descriptions.detail(error.StreamTooLong) },
    );
}
