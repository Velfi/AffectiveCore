const std = @import("std");

pub const PowerSupply = struct {
    name: []const u8,
    kind: []const u8,
    capacity_percent: ?u8 = null,
    status: ?[]const u8 = null,
    online: ?bool = null,
};

pub const DateTime = struct {
    datetime: []const u8,
    unix_seconds: i64,
};

pub const PowerSnapshot = struct {
    supplies: []const PowerSupply,
};

pub fn hasCriticalBattery(snapshot: PowerSnapshot, critical_percent: u8) bool {
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
        return .{ .supplies = supplies };
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
    try out.appendSlice(allocator, "system_senses:\n");
    try appendDateTime(allocator, &out, snapshot.datetime);
    try appendPower(allocator, &out, snapshot.power);
    try appendStorage(allocator, &out, snapshot.storage);
    try appendDatabase(allocator, &out, snapshot.database);
    return out.toOwnedSlice(allocator);
}

pub fn formatDateTime(allocator: std.mem.Allocator, datetime: DateTime) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "time:\n");
    try appendDateTime(allocator, &out, datetime);
    return out.toOwnedSlice(allocator);
}

pub fn formatPower(allocator: std.mem.Allocator, power: PowerSnapshot) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "power:\n");
    try appendPower(allocator, &out, power);
    return out.toOwnedSlice(allocator);
}

pub fn formatStorage(allocator: std.mem.Allocator, storage: StorageSnapshot) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "storage:\n");
    try appendStorage(allocator, &out, storage);
    return out.toOwnedSlice(allocator);
}

pub fn formatDatabase(allocator: std.mem.Allocator, database: DatabaseSnapshot) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "database:\n");
    try appendDatabase(allocator, &out, database);
    return out.toOwnedSlice(allocator);
}

fn appendDateTime(allocator: std.mem.Allocator, out: *std.ArrayList(u8), datetime: DateTime) !void {
    try out.print(allocator, "- datetime: {s}\n", .{datetime.datetime});
    try out.print(allocator, "- unix_seconds: {d}\n", .{datetime.unix_seconds});
}

fn appendPower(allocator: std.mem.Allocator, out: *std.ArrayList(u8), power: PowerSnapshot) !void {
    try appendPowerSummary(allocator, out, power.supplies);
    try out.appendSlice(allocator, "- power_supplies:\n");
    if (power.supplies.len == 0) {
        try out.appendSlice(allocator, "  - none detected\n");
    } else {
        for (power.supplies) |supply| {
            try out.print(allocator, "  - {s}: kind={s}", .{ supply.name, supply.kind });
            if (supply.capacity_percent) |capacity| try out.print(allocator, " capacity_percent={d}", .{capacity});
            if (supply.status) |status| try out.print(allocator, " status={s}", .{status});
            if (supply.online) |online| try out.print(allocator, " online={any}", .{online});
            try out.appendSlice(allocator, "\n");
        }
    }
}

fn appendPowerSummary(allocator: std.mem.Allocator, out: *std.ArrayList(u8), supplies: []const PowerSupply) !void {
    var battery_count: usize = 0;
    var external_count: usize = 0;
    var external_online = false;
    for (supplies) |supply| {
        if (std.mem.eql(u8, supply.kind, "Battery")) {
            battery_count += 1;
        } else if (supply.online != null) {
            external_count += 1;
            external_online = external_online or supply.online.?;
        }
    }

    if (battery_count == 0) {
        try out.appendSlice(allocator, "- battery: none detected\n");
    } else {
        for (supplies) |supply| {
            if (!std.mem.eql(u8, supply.kind, "Battery")) continue;
            try out.print(allocator, "- battery_{s}: ", .{supply.name});
            if (supply.capacity_percent) |capacity| {
                try out.print(allocator, "{d}% ", .{capacity});
            }
            if (supply.status) |status| {
                try out.print(allocator, "{s}", .{status});
            } else {
                try out.appendSlice(allocator, "status_unknown");
            }
            try out.appendSlice(allocator, "\n");
        }
    }

    if (external_count == 0) {
        try out.appendSlice(allocator, "- external_power: none detected\n");
    } else {
        try out.print(allocator, "- external_power: {s}\n", .{if (external_online) "plugged_in" else "unplugged"});
    }
}

fn appendStorage(allocator: std.mem.Allocator, out: *std.ArrayList(u8), storage: StorageSnapshot) !void {
    try appendStorageSummary(allocator, out, storage.volumes);
    try out.appendSlice(allocator, "- storage_volumes:\n");
    if (storage.volumes.len == 0) {
        try out.appendSlice(allocator, "  - none detected\n");
    } else {
        for (storage.volumes) |volume| {
            try out.print(
                allocator,
                "  - {s}: mount_path={s} total_bytes={d} available_bytes={d} used_percent={d}\n",
                .{ volume.name, volume.mount_path, volume.total_bytes, volume.available_bytes, volume.used_percent },
            );
        }
    }
}

fn appendStorageSummary(allocator: std.mem.Allocator, out: *std.ArrayList(u8), volumes: []const StorageVolume) !void {
    if (volumes.len == 0) {
        try out.appendSlice(allocator, "- storage: none detected\n");
        return;
    }
    for (volumes) |volume| {
        try out.print(
            allocator,
            "- storage_{s}: {d}% used, available_bytes={d}, total_bytes={d}\n",
            .{ volume.mount_path, volume.used_percent, volume.available_bytes, volume.total_bytes },
        );
    }
}

fn appendDatabase(allocator: std.mem.Allocator, out: *std.ArrayList(u8), database: DatabaseSnapshot) !void {
    try appendDatabaseSummary(allocator, out, database.databases);
    try out.appendSlice(allocator, "- database_files:\n");
    if (database.databases.len == 0) {
        try out.appendSlice(allocator, "  - none detected\n");
    } else {
        for (database.databases) |db| {
            try out.print(
                allocator,
                "  - {s}: path={s} total_bytes={d} page_count={d} page_size={d} freelist_count={d} table_count={d}\n",
                .{ db.label, db.path, db.total_bytes, db.page_count, db.page_size, db.freelist_count, db.table_count },
            );
        }
    }
}

fn appendDatabaseSummary(allocator: std.mem.Allocator, out: *std.ArrayList(u8), databases: []const DatabaseFileStats) !void {
    if (databases.len == 0) {
        try out.appendSlice(allocator, "- database: none detected\n");
        return;
    }
    for (databases) |db| {
        try out.print(
            allocator,
            "- database_{s}: total_bytes={d}, pages={d}, freelist_pages={d}, tables={d}\n",
            .{ db.label, db.total_bytes, db.page_count, db.freelist_count, db.table_count },
        );
    }
}

test "formats battery and external power snapshot" {
    const supplies = [_]PowerSupply{
        .{ .name = "BAT0", .kind = "Battery", .capacity_percent = 42, .status = "Discharging" },
        .{ .name = "AC", .kind = "Mains", .online = false },
    };
    const text = try formatPower(std.testing.allocator, .{ .supplies = &supplies });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "battery_BAT0: 42% Discharging") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "external_power: unplugged") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, text, "storage_/: 75% used") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "available_bytes=250") != null);
}

test "formats database snapshot" {
    const databases = [_]DatabaseFileStats{
        .{ .label = "memory", .path = "data/memory/people.sqlite", .page_count = 10, .page_size = 4096, .freelist_count = 1, .total_bytes = 40960, .table_count = 1 },
    };
    const text = try formatDatabase(std.testing.allocator, .{ .databases = &databases });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "database_memory: total_bytes=40960") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "freelist_pages=1") != null);
}
