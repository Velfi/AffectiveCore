const std = @import("std");

pub const remote_retry_attempts: usize = 3;

pub fn hasRemoteErrorEnvelope(allocator: std.mem.Allocator, body: []const u8) bool {
    const Envelope = struct {
        @"error": ?std.json.Value = null,
    };
    const parsed = std.json.parseFromSlice(Envelope, allocator, body, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    return parsed.value.@"error" != null;
}

pub fn responseShapeError(allocator: std.mem.Allocator, body: []const u8) anyerror {
    const Envelope = struct {
        @"error": ?std.json.Value = null,
    };
    const parsed = std.json.parseFromSlice(Envelope, allocator, body, .{ .ignore_unknown_fields = true }) catch {
        logFaultCode("local", "invalid_json", "provider response was not JSON");
        return error.LocalServiceResponseInvalid;
    };
    defer parsed.deinit();
    if (parsed.value.@"error") |remote_error| {
        if (errorValueIsRetryable(remote_error)) {
            logRemoteErrorFault("provider", remote_error);
            return error.RemoteServiceFailed;
        }
        logRemoteErrorFault("client", remote_error);
        return error.LocalServiceRequestRejected;
    }
    logFaultCode("local", "unexpected_shape", "provider response JSON did not match expected schema");
    return error.LocalServiceResponseInvalid;
}

pub fn remoteErrorIsRetryable(allocator: std.mem.Allocator, body: []const u8) bool {
    const Envelope = struct {
        @"error": ?std.json.Value = null,
    };
    const parsed = std.json.parseFromSlice(Envelope, allocator, body, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    const value = parsed.value.@"error" orelse return false;
    return errorValueIsRetryable(value);
}

pub fn shouldRetry(err: anyerror, attempt: usize) bool {
    return err == error.RemoteServiceFailed and attempt + 1 < remote_retry_attempts;
}

pub fn logRemoteRetry(subsystem: []const u8, provider: []const u8, model: []const u8, attempt: usize) void {
    std.debug.print(
        "{s} remote service failure from {s}/{s}; retrying attempt {d}/{d}\n",
        .{ subsystem, provider, model, attempt + 2, remote_retry_attempts },
    );
}

fn logRemoteErrorFault(owner: []const u8, value: std.json.Value) void {
    var code_buffer: [96]u8 = undefined;
    var detail_buffer: [160]u8 = undefined;
    const code = firstFieldCode(value, &code_buffer, &.{ "code", "type", "status", "status_code" }) orelse "unknown";
    const detail = firstFieldCode(value, &detail_buffer, &.{ "message", "error", "reason" }) orelse "no provider message";
    logFaultCode(owner, code, detail);
}

pub fn logFaultCode(owner: []const u8, code: []const u8, detail: []const u8) void {
    std.debug.print("REMOTE_FAULT owner={s} code={s} detail={s}\n", .{ owner, code, detail });
}

fn firstFieldCode(value: std.json.Value, buffer: []u8, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        if (findNamedField(value, name)) |field| return valueCode(field, buffer);
    }
    return null;
}

fn findNamedField(value: std.json.Value, name: []const u8) ?std.json.Value {
    switch (value) {
        .object => |object| {
            var iter = object.iterator();
            while (iter.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, name)) return entry.value_ptr.*;
                if (findNamedField(entry.value_ptr.*, name)) |nested| return nested;
            }
            return null;
        },
        .array => |array| {
            for (array.items) |item| {
                if (findNamedField(item, name)) |nested| return nested;
            }
            return null;
        },
        else => return null,
    }
}

fn valueCode(value: std.json.Value, buffer: []u8) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        .integer => |number| std.fmt.bufPrint(buffer, "{d}", .{number}) catch null,
        .float => |number| std.fmt.bufPrint(buffer, "{d}", .{number}) catch null,
        .bool => |flag| if (flag) "true" else "false",
        else => null,
    };
}

fn errorValueIsRetryable(value: std.json.Value) bool {
    if (errorTextContainsAny(value, &non_retryable_error_terms)) return false;
    return errorTextContainsAny(value, &retryable_error_terms);
}

const retryable_error_terms = [_][]const u8{
    "rate_limit",
    "rate limit",
    "overloaded",
    "unavailable",
    "temporarily",
    "timeout",
    "deadline",
    "internal",
    "server",
    "503",
    "502",
    "504",
    "500",
    "resource_exhausted",
};

const non_retryable_error_terms = [_][]const u8{
    "invalid_request",
    "authentication",
    "permission",
    "forbidden",
    "unauthorized",
    "not_found",
    "not found",
    "billing",
    "insufficient_quota",
    "quota exceeded",
};

fn errorTextContainsAny(value: std.json.Value, needles: []const []const u8) bool {
    switch (value) {
        .string => |text| return containsAny(text, needles),
        .object => |object| {
            var iter = object.iterator();
            while (iter.next()) |entry| {
                if (errorTextContainsAny(entry.value_ptr.*, needles)) return true;
            }
            return false;
        },
        .array => |array| {
            for (array.items) |item| {
                if (errorTextContainsAny(item, needles)) return true;
            }
            return false;
        },
        .integer => |number| {
            var buffer: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch return false;
            return containsAny(text, needles);
        },
        .float => |number| {
            var buffer: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch return false;
            return containsAny(text, needles);
        },
        else => return false,
    }
}

fn containsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(text, needle) != null) return true;
    }
    return false;
}

test "classifies provider error envelope as remote" {
    try std.testing.expectEqual(error.RemoteServiceFailed, responseShapeError(std.testing.allocator,
        \\{"error":{"message":"rate limited","type":"rate_limit_error"}}
    ));
}

test "classifies invalid provider request as local request rejection" {
    try std.testing.expectEqual(error.LocalServiceRequestRejected, responseShapeError(std.testing.allocator,
        \\{"error":{"message":"bad model","type":"invalid_request_error"}}
    ));
}

test "classifies malformed provider response as local shape failure" {
    try std.testing.expectEqual(error.LocalServiceResponseInvalid, responseShapeError(std.testing.allocator, "not json"));
}
