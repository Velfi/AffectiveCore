const std = @import("std");
const llm_voice = @import("llm_voice.zig");

pub const PowerSupply = struct {
    name: []const u8,
    kind: []const u8,
    capacity_percent: ?u8 = null,
    status: ?[]const u8 = null,
    online: ?bool = null,
};

pub const DateTime = struct {
    datetime: []const u8,
    datetime_format: []const u8,
    friendly_datetime: []const u8,
    friendly_datetime_format: []const u8,
    unix_seconds: i64,
};

pub const PowerSnapshot = struct {
    supplies: []const PowerSupply,
    available: bool = true,
};

pub const power_sense_dulled_message = llm_voice.power_sense_dulled;

pub fn unavailablePower() PowerSnapshot {
    return .{ .supplies = &.{}, .available = false };
}

pub fn hasCriticalBattery(snapshot: PowerSnapshot, critical_percent: u8) bool {
    if (!snapshot.available) return false;
    var external_online = false;
    var battery_critical = false;

    for (snapshot.supplies) |supply| {
        if (supply.online) |online| {
            external_online = external_online or online;
        }
        if (!std.mem.eql(u8, supply.kind, "Battery")) continue;
        const capacity = supply.capacity_percent orelse continue;
        battery_critical = battery_critical or capacity <= critical_percent;
    }

    return battery_critical and !external_online;
}

pub const StorageVolume = struct {
    name: []const u8,
    mount_path: []const u8,
    total_bytes: u64,
    available_bytes: u64,
    used_percent: u8,
};

pub const StorageSnapshot = struct {
    volumes: []const StorageVolume,
};

pub const DatabaseFileStats = struct {
    label: []const u8,
    path: []const u8,
    page_count: u64,
    page_size: u64,
    freelist_count: u64,
    total_bytes: u64,
    table_count: u64,
};

pub const DatabaseSnapshot = struct {
    databases: []const DatabaseFileStats,
};

pub const DatabaseSenses = struct {
    ctx: *anyopaque,
    snapshotFn: *const fn (*anyopaque, std.mem.Allocator) anyerror!DatabaseSnapshot,

    pub fn snapshot(self: DatabaseSenses, allocator: std.mem.Allocator) !DatabaseSnapshot {
        return self.snapshotFn(self.ctx, allocator);
    }
};

pub const Snapshot = struct {
    datetime: DateTime,
    power: PowerSnapshot,
    storage: StorageSnapshot,
    database: DatabaseSnapshot,
};

pub const SystemSenses = struct {
    ctx: *anyopaque,
    datetimeFn: *const fn (*anyopaque, std.mem.Allocator) anyerror!DateTime,
    powerFn: *const fn (*anyopaque, std.mem.Allocator) anyerror!PowerSnapshot,
    storageFn: *const fn (*anyopaque, std.mem.Allocator) anyerror!StorageSnapshot,
    databaseFn: *const fn (*anyopaque, std.mem.Allocator) anyerror!DatabaseSnapshot,

    pub fn datetime(self: SystemSenses, allocator: std.mem.Allocator) !DateTime {
        return self.datetimeFn(self.ctx, allocator);
    }

    pub fn power(self: SystemSenses, allocator: std.mem.Allocator) !PowerSnapshot {
        return self.powerFn(self.ctx, allocator);
    }

    pub fn loadPower(self: SystemSenses, allocator: std.mem.Allocator) PowerSnapshot {
        return self.power(allocator) catch unavailablePower();
    }

    pub fn storage(self: SystemSenses, allocator: std.mem.Allocator) !StorageSnapshot {
        return self.storageFn(self.ctx, allocator);
    }

    pub fn database(self: SystemSenses, allocator: std.mem.Allocator) !DatabaseSnapshot {
        return self.databaseFn(self.ctx, allocator);
    }
};

pub const SystemSensesWithDatabase = struct {
    base: SystemSenses,
    database_senses: DatabaseSenses,

    pub fn senses(self: *SystemSensesWithDatabase) SystemSenses {
        return .{ .ctx = self, .datetimeFn = datetime, .powerFn = power, .storageFn = storage, .databaseFn = database };
    }

    fn datetime(ctx: *anyopaque, allocator: std.mem.Allocator) !DateTime {
        const self: *SystemSensesWithDatabase = @ptrCast(@alignCast(ctx));
        return self.base.datetime(allocator);
    }

    fn power(ctx: *anyopaque, allocator: std.mem.Allocator) !PowerSnapshot {
        const self: *SystemSensesWithDatabase = @ptrCast(@alignCast(ctx));
        return self.base.power(allocator);
    }

    fn storage(ctx: *anyopaque, allocator: std.mem.Allocator) !StorageSnapshot {
        const self: *SystemSensesWithDatabase = @ptrCast(@alignCast(ctx));
        return self.base.storage(allocator);
    }

    fn database(ctx: *anyopaque, allocator: std.mem.Allocator) !DatabaseSnapshot {
        const self: *SystemSensesWithDatabase = @ptrCast(@alignCast(ctx));
        return self.database_senses.snapshot(allocator);
    }
};

pub const StaticSystemSenses = struct {
    snapshot_value: Snapshot,

    pub fn senses(self: *StaticSystemSenses) SystemSenses {
        return .{ .ctx = self, .datetimeFn = datetime, .powerFn = power, .storageFn = storage, .databaseFn = database };
    }

    fn datetime(ctx: *anyopaque, allocator: std.mem.Allocator) !DateTime {
        const self: *StaticSystemSenses = @ptrCast(@alignCast(ctx));
        return .{
            .datetime = try allocator.dupe(u8, self.snapshot_value.datetime.datetime),
            .datetime_format = try allocator.dupe(u8, self.snapshot_value.datetime.datetime_format),
            .friendly_datetime = try allocator.dupe(u8, self.snapshot_value.datetime.friendly_datetime),
            .friendly_datetime_format = try allocator.dupe(u8, self.snapshot_value.datetime.friendly_datetime_format),
            .unix_seconds = self.snapshot_value.datetime.unix_seconds,
        };
    }

    fn power(ctx: *anyopaque, allocator: std.mem.Allocator) !PowerSnapshot {
        const self: *StaticSystemSenses = @ptrCast(@alignCast(ctx));
        var supplies = try allocator.alloc(PowerSupply, self.snapshot_value.power.supplies.len);
        for (self.snapshot_value.power.supplies, 0..) |supply, i| {
            supplies[i] = .{
                .name = try allocator.dupe(u8, supply.name),
                .kind = try allocator.dupe(u8, supply.kind),
                .capacity_percent = supply.capacity_percent,
                .status = if (supply.status) |status| try allocator.dupe(u8, status) else null,
                .online = supply.online,
            };
        }
        return .{ .supplies = supplies, .available = self.snapshot_value.power.available };
    }

    fn storage(ctx: *anyopaque, allocator: std.mem.Allocator) !StorageSnapshot {
        const self: *StaticSystemSenses = @ptrCast(@alignCast(ctx));
        var volumes = try allocator.alloc(StorageVolume, self.snapshot_value.storage.volumes.len);
        for (self.snapshot_value.storage.volumes, 0..) |volume, i| {
            volumes[i] = .{
                .name = try allocator.dupe(u8, volume.name),
                .mount_path = try allocator.dupe(u8, volume.mount_path),
                .total_bytes = volume.total_bytes,
                .available_bytes = volume.available_bytes,
                .used_percent = volume.used_percent,
            };
        }
        return .{ .volumes = volumes };
    }

    fn database(ctx: *anyopaque, allocator: std.mem.Allocator) !DatabaseSnapshot {
        const self: *StaticSystemSenses = @ptrCast(@alignCast(ctx));
        var databases = try allocator.alloc(DatabaseFileStats, self.snapshot_value.database.databases.len);
        for (self.snapshot_value.database.databases, 0..) |db, i| {
            databases[i] = .{
                .label = try allocator.dupe(u8, db.label),
                .path = try allocator.dupe(u8, db.path),
                .page_count = db.page_count,
                .page_size = db.page_size,
                .freelist_count = db.freelist_count,
                .total_bytes = db.total_bytes,
                .table_count = db.table_count,
            };
        }
        return .{ .databases = databases };
    }
};

pub fn formatSnapshot(allocator: std.mem.Allocator, snapshot: Snapshot) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "what_my_host_senses:\n");
    try appendDateTime(allocator, &out, snapshot.datetime);
    try appendPower(allocator, &out, snapshot.power);
    try appendStorage(allocator, &out, snapshot.storage);
    try appendDatabase(allocator, &out, snapshot.database);
    return out.toOwnedSlice(allocator);
}

pub fn formatDateTime(allocator: std.mem.Allocator, datetime: DateTime) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "what_i_feel_about_time:\n");
    try appendDateTime(allocator, &out, datetime);
    return out.toOwnedSlice(allocator);
}

pub fn formatPower(allocator: std.mem.Allocator, power: PowerSnapshot) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "what_i_feel_about_power:\n");
    try appendPower(allocator, &out, power);
    return out.toOwnedSlice(allocator);
}

pub fn formatStorage(allocator: std.mem.Allocator, storage: StorageSnapshot) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "what_i_feel_about_storage:\n");
    try appendStorage(allocator, &out, storage);
    return out.toOwnedSlice(allocator);
}

pub fn formatDatabase(allocator: std.mem.Allocator, database: DatabaseSnapshot) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "what_i_feel_about_memory_stores:\n");
    try appendDatabase(allocator, &out, database);
    return out.toOwnedSlice(allocator);
}

fn appendDateTime(allocator: std.mem.Allocator, out: *std.ArrayList(u8), datetime: DateTime) !void {
    try out.print(allocator, "- I feel it is {s} ({s})\n", .{ datetime.friendly_datetime, datetime.friendly_datetime_format });
    try out.print(allocator, "- internally I read the clock as {s} ({s})\n", .{ datetime.datetime, datetime.datetime_format });
}

fn formatHumanBytes(allocator: std.mem.Allocator, bytes: u64) ![]u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit_index: usize = 0;
    while (value >= 1024.0 and unit_index + 1 < units.len) : (unit_index += 1) {
        value /= 1024.0;
    }
    if (unit_index == 0) {
        return std.fmt.allocPrint(allocator, "{d} {s}", .{ bytes, units[0] });
    }
    return std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ value, units[unit_index] });
}

fn formatPowerFriendly(allocator: std.mem.Allocator, power: PowerSnapshot) ![]u8 {
    if (!power.available) return allocator.dupe(u8, llm_voice.power_sense_dulled);
    const supplies = power.supplies;
    var parts = std.ArrayList(u8).empty;
    var battery_count: usize = 0;
    for (supplies) |supply| {
        if (!std.mem.eql(u8, supply.kind, "Battery")) continue;
        battery_count += 1;
        if (battery_count > 1) try parts.appendSlice(allocator, "; ");
        if (supply.capacity_percent) |capacity| {
            if (supply.status) |status| {
                try parts.print(allocator, "I feel my charge at {d}% and I am {s}", .{ capacity, status });
            } else {
                try parts.print(allocator, "I feel my charge at {d}%", .{capacity});
            }
        } else if (supply.status) |status| {
            try parts.print(allocator, "I feel a battery that is {s}", .{status});
        } else {
            try parts.appendSlice(allocator, "I feel a battery but cannot read its level");
        }
    }
    if (battery_count == 0) {
        try parts.appendSlice(allocator, "I do not feel a battery on this host");
    }

    var external_count: usize = 0;
    var external_online = false;
    for (supplies) |supply| {
        if (supply.online == null) continue;
        external_count += 1;
        external_online = external_online or supply.online.?;
    }
    if (external_count == 0) {
        try parts.appendSlice(allocator, "; I cannot tell whether a cord is feeding me");
    } else if (external_online) {
        try parts.appendSlice(allocator, "; a cord is feeding me");
    } else {
        try parts.appendSlice(allocator, "; I feel unplugged");
    }
    return parts.toOwnedSlice(allocator);
}

fn appendPower(allocator: std.mem.Allocator, out: *std.ArrayList(u8), power: PowerSnapshot) !void {
    const friendly = try formatPowerFriendly(allocator, power);
    defer allocator.free(friendly);
    try out.print(allocator, "- {s}\n", .{friendly});
}

fn formatStorageFriendly(allocator: std.mem.Allocator, volumes: []const StorageVolume) ![]u8 {
    if (volumes.len == 0) return allocator.dupe(u8, "I cannot feel any storage volumes on this host.");
    var parts = std.ArrayList(u8).empty;
    for (volumes, 0..) |volume, index| {
        const available = try formatHumanBytes(allocator, volume.available_bytes);
        defer allocator.free(available);
        const total = try formatHumanBytes(allocator, volume.total_bytes);
        defer allocator.free(total);
        if (index > 0) try parts.appendSlice(allocator, "; ");
        try parts.print(allocator, "I feel {s} is {d}% full with {s} breathing room of {s}", .{
            volume.mount_path,
            volume.used_percent,
            available,
            total,
        });
    }
    return parts.toOwnedSlice(allocator);
}

fn appendStorage(allocator: std.mem.Allocator, out: *std.ArrayList(u8), storage: StorageSnapshot) !void {
    const friendly = try formatStorageFriendly(allocator, storage.volumes);
    defer allocator.free(friendly);
    try out.print(allocator, "- {s}\n", .{friendly});
}

fn formatDatabaseFriendly(allocator: std.mem.Allocator, databases: []const DatabaseFileStats) ![]u8 {
    if (databases.len == 0) return allocator.dupe(u8, "I cannot feel any memory stores on this host.");
    var parts = std.ArrayList(u8).empty;
    for (databases, 0..) |db, index| {
        const total = try formatHumanBytes(allocator, db.total_bytes);
        defer allocator.free(total);
        if (index > 0) try parts.appendSlice(allocator, "; ");
        try parts.print(allocator, "I feel my {s} store holding {s} across {d} tables", .{ db.label, total, db.table_count });
    }
    return parts.toOwnedSlice(allocator);
}

fn appendDatabase(allocator: std.mem.Allocator, out: *std.ArrayList(u8), database: DatabaseSnapshot) !void {
    const friendly = try formatDatabaseFriendly(allocator, database.databases);
    defer allocator.free(friendly);
    try out.print(allocator, "- {s}\n", .{friendly});
}

test "formats dulled power sense when unavailable" {
    const text = try formatPower(std.testing.allocator, unavailablePower());
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, power_sense_dulled_message) != null);
}

test "formats battery and external power snapshot" {
    const supplies = [_]PowerSupply{
        .{ .name = "BAT0", .kind = "Battery", .capacity_percent = 42, .status = "Discharging" },
        .{ .name = "AC", .kind = "Mains", .online = false },
    };
    const text = try formatPower(std.testing.allocator, .{ .supplies = &supplies });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "I feel my charge at 42%") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "I feel unplugged") != null);
}

test "critical battery requires low battery without external power" {
    const unplugged_low = [_]PowerSupply{
        .{ .name = "AC", .kind = "Mains", .online = false },
        .{ .name = "BAT0", .kind = "Battery", .capacity_percent = 5, .status = "discharging" },
    };
    try std.testing.expect(hasCriticalBattery(.{ .supplies = &unplugged_low }, 5));

    const plugged_low = [_]PowerSupply{
        .{ .name = "AC", .kind = "Mains", .online = true },
        .{ .name = "BAT0", .kind = "Battery", .capacity_percent = 3, .status = "charging" },
    };
    try std.testing.expect(!hasCriticalBattery(.{ .supplies = &plugged_low }, 5));

    try std.testing.expect(!hasCriticalBattery(unavailablePower(), 5));

    const unplugged_ok = [_]PowerSupply{
        .{ .name = "AC", .kind = "Mains", .online = false },
        .{ .name = "BAT0", .kind = "Battery", .capacity_percent = 6, .status = "discharging" },
    };
    try std.testing.expect(!hasCriticalBattery(.{ .supplies = &unplugged_ok }, 5));
}

test "formats storage snapshot" {
    const volumes = [_]StorageVolume{
        .{ .name = "/dev/disk3s1", .mount_path = "/", .total_bytes = 1000, .available_bytes = 250, .used_percent = 75 },
    };
    const text = try formatStorage(std.testing.allocator, .{ .volumes = &volumes });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "I feel / is 75% full") != null);
}

test "formats database snapshot" {
    const databases = [_]DatabaseFileStats{
        .{ .label = "memory", .path = "data/memory/people.sqlite", .page_count = 10, .page_size = 4096, .freelist_count = 1, .total_bytes = 40960, .table_count = 1 },
    };
    const text = try formatDatabase(std.testing.allocator, .{ .databases = &databases });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "I feel my memory store holding") != null);
}
