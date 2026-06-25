const std = @import("std");

pub const Kind = enum {
    speech,
    touch,
    poke_sequence,
    visual,
    orientation,
    power,
    time,
    storage,
    database,
    interrupt,
    reminder,
};

pub const Input = struct {
    kind: Kind,
    source: []const u8,
    signature: []const u8,
    raw_magnitude: f32,
    threat: f32 = 0,
    curiosity: f32 = 0,
    safety_relevant: bool = false,
    metadata: []const u8 = "",
};

pub const Packet = struct {
    kind: Kind,
    source: []const u8,
    signature: []const u8,
    raw_magnitude: f32,
    novelty: f32,
    habituation_level: f32,
    sensitization_level: f32,
    recovery_level: f32,
    change_rate: f32,
    threat: f32,
    curiosity: f32,
    attention_intensity: f32,
    exposure_count: u32,
    safety_relevant: bool,
    reason: []const u8,
    metadata: []const u8,
};

pub const DualProcessState = struct {
    const max_slots: usize = 24;
    const recovery_seconds: i64 = 120;

    const Slot = struct {
        kind: Kind = .speech,
        signature: [192]u8 = undefined,
        signature_len: usize = 0,
        signature_hash: u64 = 0,
        last_seen_seconds: i64 = 0,
        exposure_count: u32 = 0,
        habituation_level: f32 = 0,
        sensitization_level: f32 = 0,
        recovery_level: f32 = 1,
        last_raw_magnitude: f32 = 0,
        last_attention_intensity: f32 = 0,
    };

    slots: [max_slots]Slot = [_]Slot{.{}} ** max_slots,
    next_slot: usize = 0,

    pub fn observe(self: *DualProcessState, allocator: std.mem.Allocator, now_seconds: i64, input: Input) !Packet {
        var slot = self.findOrCreateSlot(input.kind, input.signature);
        const elapsed = if (slot.exposure_count == 0) recovery_seconds else @max(0, now_seconds - slot.last_seen_seconds);
        const recovery = clamp01(@as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(recovery_seconds)));
        const previous_raw = slot.last_raw_magnitude;
        const repeated = slot.exposure_count > 0 and signatureEquals(slot.*, input.signature);
        const change_rate = if (slot.exposure_count == 0) input.raw_magnitude else input.raw_magnitude - previous_raw;
        const novelty: f32 = if (repeated) @max(0.08, recovery * 0.45 + @max(0, change_rate) * 0.6) else 1.0;

        slot.habituation_level = @max(0, slot.habituation_level * (1.0 - recovery * 0.75));
        slot.sensitization_level = @max(0, slot.sensitization_level * (1.0 - recovery * 0.45));

        if (repeated) {
            slot.exposure_count += 1;
            const safety_resistance: f32 = if (input.safety_relevant) 0.25 else 1.0;
            const harmlessness = 1.0 - clamp01(input.threat);
            slot.habituation_level = clamp01(slot.habituation_level + 0.18 * harmlessness * safety_resistance);
            const worsening = @max(0, change_rate);
            const safety_boost: f32 = if (input.safety_relevant and input.threat >= 0.35) 0.12 else 0;
            const sensitizing = input.threat * 0.20 + worsening * 0.45 + safety_boost;
            slot.sensitization_level = clamp01(slot.sensitization_level + sensitizing);
        } else {
            slot.exposure_count = 1;
            slot.habituation_level *= 0.35;
            slot.sensitization_level = clamp01(slot.sensitization_level + input.threat * 0.25 + @max(0, change_rate) * 0.25);
            copySignature(slot, input.signature);
        }

        const safety_habituation_scale: f32 = if (input.safety_relevant) 0.55 else 1.0;
        const habituation_damp = slot.habituation_level * (1.0 - input.threat * 0.80) * safety_habituation_scale;
        const base = input.raw_magnitude * 0.42 + novelty * 0.24 + input.curiosity * 0.14 + input.threat * 0.34 + @max(0, change_rate) * 0.18;
        var attention = clamp01(base + slot.sensitization_level * 0.36 - habituation_damp * 0.46);
        if (input.safety_relevant and input.threat >= 0.65) attention = @max(attention, 0.72);
        if (repeated and input.safety_relevant and input.threat >= 0.65) {
            attention = @max(attention, slot.last_attention_intensity);
            if (change_rate > 0) attention = @max(attention, clamp01(slot.last_attention_intensity + change_rate * 0.20));
        }

        slot.kind = input.kind;
        slot.last_seen_seconds = now_seconds;
        slot.recovery_level = recovery;
        slot.last_raw_magnitude = input.raw_magnitude;
        slot.last_attention_intensity = attention;

        return .{
            .kind = input.kind,
            .source = try allocator.dupe(u8, input.source),
            .signature = try allocator.dupe(u8, input.signature),
            .raw_magnitude = clamp01(input.raw_magnitude),
            .novelty = clamp01(novelty),
            .habituation_level = clamp01(slot.habituation_level),
            .sensitization_level = clamp01(slot.sensitization_level),
            .recovery_level = clamp01(recovery),
            .change_rate = change_rate,
            .threat = clamp01(input.threat),
            .curiosity = clamp01(input.curiosity),
            .attention_intensity = attention,
            .exposure_count = slot.exposure_count,
            .safety_relevant = input.safety_relevant,
            .reason = try reasonFor(allocator, repeated, input, novelty, slot.habituation_level, slot.sensitization_level, attention),
            .metadata = try allocator.dupe(u8, input.metadata),
        };
    }

    fn findOrCreateSlot(self: *DualProcessState, kind: Kind, signature: []const u8) *Slot {
        for (&self.slots) |*slot| {
            if (slot.exposure_count == 0) continue;
            if (slot.kind == kind and signatureEquals(slot.*, signature)) return slot;
        }
        const index = self.next_slot % max_slots;
        self.next_slot = (self.next_slot + 1) % max_slots;
        self.slots[index] = .{ .kind = kind };
        copySignature(&self.slots[index], signature);
        return &self.slots[index];
    }
};

pub fn formatPacket(allocator: std.mem.Allocator, packet: Packet) ![]const u8 {
    if (packet.metadata.len > 0) {
        return std.fmt.allocPrint(
            allocator,
            "sense_stimulus kind={s} source={s} signature={s} raw_magnitude={d:.3} novelty={d:.3} habituation_level={d:.3} sensitization_level={d:.3} recovery_level={d:.3} change_rate={d:.3} threat={d:.3} curiosity={d:.3} attention_intensity={d:.3} exposure_count={d} safety_relevant={any} reason={s} metadata=\"{s}\"",
            .{ @tagName(packet.kind), packet.source, packet.signature, packet.raw_magnitude, packet.novelty, packet.habituation_level, packet.sensitization_level, packet.recovery_level, packet.change_rate, packet.threat, packet.curiosity, packet.attention_intensity, packet.exposure_count, packet.safety_relevant, packet.reason, packet.metadata },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "sense_stimulus kind={s} source={s} signature={s} raw_magnitude={d:.3} novelty={d:.3} habituation_level={d:.3} sensitization_level={d:.3} recovery_level={d:.3} change_rate={d:.3} threat={d:.3} curiosity={d:.3} attention_intensity={d:.3} exposure_count={d} safety_relevant={any} reason={s}",
        .{ @tagName(packet.kind), packet.source, packet.signature, packet.raw_magnitude, packet.novelty, packet.habituation_level, packet.sensitization_level, packet.recovery_level, packet.change_rate, packet.threat, packet.curiosity, packet.attention_intensity, packet.exposure_count, packet.safety_relevant, packet.reason },
    );
}

fn reasonFor(allocator: std.mem.Allocator, repeated: bool, input: Input, novelty: f32, habituation: f32, sensitization: f32, attention: f32) ![]const u8 {
    if (input.safety_relevant and input.threat >= 0.65) return allocator.dupe(u8, "safety-relevant stimulus resists habituation");
    if (repeated and sensitization > habituation) return allocator.dupe(u8, "repetition is sensitizing because the signal is concerning or worsening");
    if (repeated and habituation >= 0.35 and attention < 0.55) return allocator.dupe(u8, "repeated low-risk signal is habituating");
    if (novelty >= 0.75) return allocator.dupe(u8, "novel or changed signal restores orienting");
    return allocator.dupe(u8, "balanced stimulus evidence");
}

fn signatureEquals(slot: DualProcessState.Slot, signature: []const u8) bool {
    const signature_len = @min(signature.len, slot.signature.len);
    return slot.signature_len == signature_len and
        slot.signature_hash == signatureHash(signature) and
        std.mem.eql(u8, slot.signature[0..slot.signature_len], signature[0..signature_len]);
}

fn copySignature(slot: *DualProcessState.Slot, signature: []const u8) void {
    slot.signature_len = @min(signature.len, slot.signature.len);
    slot.signature_hash = signatureHash(signature);
    @memcpy(slot.signature[0..slot.signature_len], signature[0..slot.signature_len]);
}

fn signatureHash(signature: []const u8) u64 {
    return std.hash.Wyhash.hash(0, signature);
}

fn clamp01(value: f32) f32 {
    return @min(1.0, @max(0.0, value));
}

test "dual-process habituates repeated harmless signals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = DualProcessState{};
    const allocator = arena.allocator();
    const first = try state.observe(allocator, 0, .{ .kind = .touch, .source = "test", .signature = "tap", .raw_magnitude = 0.45, .curiosity = 0.5 });
    const second = try state.observe(allocator, 5, .{ .kind = .touch, .source = "test", .signature = "tap", .raw_magnitude = 0.45, .curiosity = 0.5 });
    try std.testing.expect(second.attention_intensity < first.attention_intensity);
}

test "dual-process sensitizes safety-relevant repeated signals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = DualProcessState{};
    const allocator = arena.allocator();
    const first = try state.observe(allocator, 0, .{ .kind = .power, .source = "test", .signature = "critical", .raw_magnitude = 0.8, .threat = 0.8, .safety_relevant = true });
    const second = try state.observe(allocator, 5, .{ .kind = .power, .source = "test", .signature = "critical", .raw_magnitude = 0.9, .threat = 0.9, .safety_relevant = true });
    try std.testing.expect(second.attention_intensity >= first.attention_intensity);
}

test "dual-process restores novelty after signature change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = DualProcessState{};
    const allocator = arena.allocator();
    _ = try state.observe(allocator, 0, .{ .kind = .touch, .source = "test", .signature = "tap", .raw_magnitude = 0.4 });
    _ = try state.observe(allocator, 5, .{ .kind = .touch, .source = "test", .signature = "tap", .raw_magnitude = 0.4 });
    const changed = try state.observe(allocator, 10, .{ .kind = .touch, .source = "test", .signature = "press", .raw_magnitude = 0.4 });
    try std.testing.expect(changed.novelty >= 0.9);
}

test "dual-process matches repeated long signatures by full-signature hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = DualProcessState{};
    const allocator = arena.allocator();
    const long_signature = "touch:" ++ ("abcdefghijklmnopqrstuvwxyz" ** 10);
    const first = try state.observe(allocator, 0, .{ .kind = .touch, .source = "test", .signature = long_signature, .raw_magnitude = 0.45, .curiosity = 0.5 });
    const second = try state.observe(allocator, 5, .{ .kind = .touch, .source = "test", .signature = long_signature, .raw_magnitude = 0.45, .curiosity = 0.5 });
    try std.testing.expectEqual(@as(u32, 1), first.exposure_count);
    try std.testing.expectEqual(@as(u32, 2), second.exposure_count);
}
