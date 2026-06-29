const std = @import("std");
const http_transport = @import("../../api/http_transport.zig");
const senses_mod = @import("system_senses.zig");

const host_power_url = "affective-host://system/power";
const host_storage_url = "affective-host://system/storage";

pub fn readPower(http: http_transport.Client, allocator: std.mem.Allocator) !senses_mod.PowerSnapshot {
    const bytes = try http.postJson(allocator, .{
        .url = host_power_url,
        .body = "{}",
    });
    defer allocator.free(bytes);
    return parsePowerJson(allocator, bytes);
}

pub fn readStorage(http: http_transport.Client, allocator: std.mem.Allocator) !senses_mod.StorageSnapshot {
    const bytes = try http.postJson(allocator, .{
        .url = host_storage_url,
        .body = "{}",
    });
    defer allocator.free(bytes);
    return parseStorageJson(allocator, bytes);
}

pub fn parsePowerJson(allocator: std.mem.Allocator, json: []const u8) !senses_mod.PowerSnapshot {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const supplies_value = parsed.value.object.get("supplies") orelse return error.MissingHostPowerSupplies;
    if (supplies_value != .array) return error.InvalidHostPowerSupplies;

    var supplies = try allocator.alloc(senses_mod.PowerSupply, supplies_value.array.items.len);
    for (supplies_value.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidHostPowerSupplies;
        const object = item.object;
        const name = object.get("name") orelse return error.MissingHostPowerSupplyName;
        if (name != .string) return error.MissingHostPowerSupplyName;
        const kind = object.get("kind") orelse return error.MissingHostPowerSupplyKind;
        if (kind != .string) return error.MissingHostPowerSupplyKind;
        const capacity = if (object.get("capacity_percent")) |value| switch (value) {
            .integer => |n| @as(?u8, @intCast(n)),
            else => return error.InvalidHostPowerSupplyCapacity,
        } else null;
        const status = if (object.get("status")) |value| switch (value) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.InvalidHostPowerSupplyStatus,
        } else null;
        const online = if (object.get("online")) |value| switch (value) {
            .bool => |b| b,
            else => return error.InvalidHostPowerSupplyOnline,
        } else null;
        supplies[index] = .{
            .name = try allocator.dupe(u8, name.string),
            .kind = try allocator.dupe(u8, kind.string),
            .capacity_percent = capacity,
            .status = status,
            .online = online,
        };
    }
    return .{ .supplies = supplies };
}

pub fn parseStorageJson(allocator: std.mem.Allocator, json: []const u8) !senses_mod.StorageSnapshot {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const volumes_value = parsed.value.object.get("volumes") orelse return error.MissingHostStorageVolumes;
    if (volumes_value != .array) return error.InvalidHostStorageVolumes;

    var volumes = try allocator.alloc(senses_mod.StorageVolume, volumes_value.array.items.len);
    for (volumes_value.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidHostStorageVolumes;
        const object = item.object;
        const name = object.get("name") orelse return error.MissingHostStorageVolumeName;
        if (name != .string) return error.MissingHostStorageVolumeName;
        const mount_path = object.get("mount_path") orelse return error.MissingHostStorageMountPath;
        if (mount_path != .string) return error.MissingHostStorageMountPath;
        const total_bytes = object.get("total_bytes") orelse return error.MissingHostStorageTotalBytes;
        if (total_bytes != .integer) return error.MissingHostStorageTotalBytes;
        const available_bytes = object.get("available_bytes") orelse return error.MissingHostStorageAvailableBytes;
        if (available_bytes != .integer) return error.MissingHostStorageAvailableBytes;
        const used_percent = object.get("used_percent") orelse return error.MissingHostStorageUsedPercent;
        if (used_percent != .integer) return error.MissingHostStorageUsedPercent;
        volumes[index] = .{
            .name = try allocator.dupe(u8, name.string),
            .mount_path = try allocator.dupe(u8, mount_path.string),
            .total_bytes = @intCast(total_bytes.integer),
            .available_bytes = @intCast(available_bytes.integer),
            .used_percent = @intCast(used_percent.integer),
        };
    }
    return .{ .volumes = volumes };
}

test "parses host power json" {
    const json =
        \\{"supplies":[
        \\{"name":"InternalBattery-0","kind":"Battery","capacity_percent":86,"status":"discharging"},
        \\{"name":"AC","kind":"Mains","online":false}
        \\]}
    ;
    const snapshot = try parsePowerJson(std.testing.allocator, json);
    defer freePowerSnapshot(std.testing.allocator, snapshot);
    try std.testing.expectEqual(@as(usize, 2), snapshot.supplies.len);
    try std.testing.expectEqualStrings("InternalBattery-0", snapshot.supplies[0].name);
    try std.testing.expectEqual(@as(?u8, 86), snapshot.supplies[0].capacity_percent);
    try std.testing.expectEqual(@as(?bool, false), snapshot.supplies[1].online);
}

test "parses host storage json" {
    const json =
        \\{"volumes":[
        \\{"name":"/dev/disk3s1s1","mount_path":"/","total_bytes":994467184640,"available_bytes":185185443840,"used_percent":7}
        \\]}
    ;
    const snapshot = try parseStorageJson(std.testing.allocator, json);
    defer freeStorageSnapshot(std.testing.allocator, snapshot);
    try std.testing.expectEqual(@as(usize, 1), snapshot.volumes.len);
    try std.testing.expectEqualStrings("/", snapshot.volumes[0].mount_path);
    try std.testing.expectEqual(@as(u8, 7), snapshot.volumes[0].used_percent);
}

const FixtureHostHttpTransport = struct {
    power_json: []const u8,
    url: []const u8 = "",
    body: []const u8 = "",

    fn client(self: *FixtureHostHttpTransport) http_transport.Client {
        return .{ .ctx = self, .postJsonFn = FixtureHostHttpTransport.postJson };
    }

    fn postJson(ctx: *anyopaque, allocator: std.mem.Allocator, request: http_transport.JsonPostRequest) ![]u8 {
        const self: *FixtureHostHttpTransport = @ptrCast(@alignCast(ctx));
        self.url = request.url;
        self.body = try allocator.dupe(u8, request.body);
        if (!std.mem.eql(u8, request.url, host_power_url)) return error.UnexpectedHostUrl;
        return try allocator.dupe(u8, self.power_json);
    }
};

test "readPower routes through host HTTP transport" {
    const json =
        \\{"supplies":[
        \\{"name":"InternalBattery-0","kind":"Battery","capacity_percent":72,"status":"charging"},
        \\{"name":"AC","kind":"Mains","online":true}
        \\]}
    ;
    var transport = FixtureHostHttpTransport{ .power_json = json };
    const snapshot = try readPower(transport.client(), std.testing.allocator);
    defer freePowerSnapshot(std.testing.allocator, snapshot);
    defer std.testing.allocator.free(transport.body);
    try std.testing.expectEqualStrings(host_power_url, transport.url);
    try std.testing.expectEqualStrings("{}", transport.body);
    try std.testing.expectEqual(@as(usize, 2), snapshot.supplies.len);
    try std.testing.expectEqual(@as(?u8, 72), snapshot.supplies[0].capacity_percent);
    try std.testing.expectEqual(@as(?bool, true), snapshot.supplies[1].online);
}

fn freePowerSnapshot(allocator: std.mem.Allocator, snapshot: senses_mod.PowerSnapshot) void {
    for (snapshot.supplies) |supply| {
        allocator.free(supply.name);
        allocator.free(supply.kind);
        if (supply.status) |status| allocator.free(status);
    }
    allocator.free(snapshot.supplies);
}

fn freeStorageSnapshot(allocator: std.mem.Allocator, snapshot: senses_mod.StorageSnapshot) void {
    for (snapshot.volumes) |volume| {
        allocator.free(volume.name);
        allocator.free(volume.mount_path);
    }
    allocator.free(snapshot.volumes);
}
