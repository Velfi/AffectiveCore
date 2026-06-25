const std = @import("std");
const identity = @import("../core/identity.zig");
const openai = @import("openai_client.zig");
const schema = @import("../storage/schema.zig");
const store_mod = @import("../storage/store.zig");
const vector_index = @import("../core/vector_index.zig");
const process = @import("../platform/common/process.zig");

pub const TestRecognitionClient = struct {
    known_threshold: f32 = 0.85,
    uncertain_threshold: f32 = 0.60,

    pub fn recognizer(self: *TestRecognitionClient) identity.IdentityRecognizer {
        return .{ .ctx = self, .identifyFn = identify };
    }

    fn identify(ctx: *anyopaque, _: std.mem.Allocator, image_path: []const u8) !identity.IdentityResult {
        const self: *TestRecognitionClient = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOf(u8, image_path, "empty") != null) {
            return .{ .person_present = false, .match_status = .none, .confidence = 0, .people_count = 0 };
        }
        if (std.mem.indexOf(u8, image_path, "known_changed") != null) {
            const confidence: f32 = 0.72;
            return .{
                .person_present = true,
                .match_status = identity.statusFromConfidence(true, confidence, self.known_threshold, self.uncertain_threshold),
                .person_id = "person_001",
                .confidence = confidence,
                .candidate_name = "Mara",
                .people_count = 1,
            };
        }
        if (std.mem.indexOf(u8, image_path, "unknown") != null) {
            return .{ .person_present = true, .match_status = .unknown, .confidence = 0.40, .people_count = 1 };
        }
        if (std.mem.indexOf(u8, image_path, "known") != null) {
            const confidence: f32 = 0.91;
            return .{
                .person_present = true,
                .match_status = identity.statusFromConfidence(true, confidence, self.known_threshold, self.uncertain_threshold),
                .person_id = "person_001",
                .confidence = confidence,
                .candidate_name = "Mara",
                .people_count = 1,
            };
        }
        if (std.mem.indexOf(u8, image_path, "multiple") != null) {
            return .{ .person_present = true, .match_status = .multiple, .confidence = 0.66, .people_count = 2 };
        }
        return .{ .person_present = true, .match_status = .unknown, .confidence = 0.40, .people_count = 1 };
    }
};

pub const CommandRecognitionClient = struct {
    io: std.Io,
    command: []const u8,
    command_memory_path: []const u8,
    embeddings_dir: []const u8,
    detector_model: []const u8,
    recognizer_model: []const u8,
    known_threshold: f32 = 0.85,
    uncertain_threshold: f32 = 0.60,

    pub fn recognizer(self: *CommandRecognitionClient) identity.IdentityRecognizer {
        return .{ .ctx = self, .identifyFn = identify };
    }

    fn identify(ctx: *anyopaque, allocator: std.mem.Allocator, image_path: []const u8) !identity.IdentityResult {
        const self: *CommandRecognitionClient = @ptrCast(@alignCast(ctx));
        const known = try std.fmt.allocPrint(allocator, "{d:.4}", .{self.known_threshold});
        defer allocator.free(known);
        const uncertain = try std.fmt.allocPrint(allocator, "{d:.4}", .{self.uncertain_threshold});
        defer allocator.free(uncertain);
        const out = try process.runCapture(allocator, self.io, &.{
            self.command,
            "identify",
            "--image",
            image_path,
            "--memory",
            self.command_memory_path,
            "--embeddings-dir",
            self.embeddings_dir,
            "--detector",
            self.detector_model,
            "--recognizer",
            self.recognizer_model,
            "--known-threshold",
            known,
            "--uncertain-threshold",
            uncertain,
        });
        defer allocator.free(out);
        return parseCommandIdentityResult(allocator, out);
    }
};

pub const DescriptiveRecognitionClient = struct {
    store: store_mod.MemoryStore,
    description_service: openai.DescriptionService,
    comparison_service: openai.IdentityComparisonService,
    known_threshold: f32 = 0.85,
    uncertain_threshold: f32 = 0.60,
    vector_similarity_floor: f32 = 0.18,

    pub fn recognizer(self: *DescriptiveRecognitionClient) identity.IdentityRecognizer {
        return .{ .ctx = self, .identifyFn = identify };
    }

    fn identify(ctx: *anyopaque, allocator: std.mem.Allocator, image_path: []const u8) !identity.IdentityResult {
        const self: *DescriptiveRecognitionClient = @ptrCast(@alignCast(ctx));
        const current = try self.description_service.describePerson(allocator, image_path, "");
        const current_text = std.mem.trim(u8, current.description, " \r\n\t");
        if (current_text.len == 0) return .{ .person_present = false, .match_status = .none, .confidence = 0, .people_count = 0 };

        const people = try self.store.loadPeople(allocator);
        const traces = try self.store.loadTraces(allocator);
        const candidates = try buildDescriptionCandidates(allocator, people, try tracesToSightings(allocator, traces));
        if (candidates.len == 0) return .{ .person_present = true, .match_status = .unknown, .confidence = 0, .people_count = 1 };

        const best = try bestDescriptionCandidate(allocator, candidates, current_text);
        if (best == null or best.?.similarity < self.vector_similarity_floor) {
            return .{ .person_present = true, .match_status = .unknown, .confidence = bestCandidateConfidence(best), .people_count = 1 };
        }

        const candidate = candidates[best.?.index];
        const comparison = try self.comparison_service.compareDescriptions(allocator, current_text, candidate.description);
        if (!comparison.same_person) {
            return .{ .person_present = true, .match_status = .unknown, .confidence = comparison.confidence, .people_count = 1 };
        }

        const status = identity.statusFromConfidence(true, comparison.confidence, self.known_threshold, self.uncertain_threshold);
        return .{
            .person_present = true,
            .match_status = status,
            .person_id = if (status == .known or status == .uncertain) try allocator.dupe(u8, candidate.person.person_id) else null,
            .confidence = comparison.confidence,
            .candidate_name = if (status == .known or status == .uncertain) try allocator.dupe(u8, candidate.person.display_name) else null,
            .people_count = 1,
        };
    }
};

const DescriptionCandidate = struct {
    person: schema.Person,
    description: []const u8,
};

const CandidateMatch = struct {
    index: usize,
    similarity: f32,
};

fn buildDescriptionCandidates(allocator: std.mem.Allocator, people: []const schema.Person, sightings: []const schema.Sighting) ![]DescriptionCandidate {
    var out = std.ArrayList(DescriptionCandidate).empty;
    for (people) |person| {
        if (person.relationship_status == .forgotten) continue;
        const description = try profileDescription(allocator, person, sightings);
        if (std.mem.trim(u8, description, " \r\n\t").len == 0) continue;
        try out.append(allocator, .{ .person = person, .description = description });
    }
    return try out.toOwnedSlice(allocator);
}

fn profileDescription(allocator: std.mem.Allocator, person: schema.Person, sightings: []const schema.Sighting) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (person.stable_notes) |note| try appendDescriptionLine(allocator, &out, note);
    for (person.recent_notes) |note| try appendDescriptionLine(allocator, &out, note.text);
    for (sightings) |sighting| {
        if (sighting.person_id == null or !std.mem.eql(u8, sighting.person_id.?, person.person_id)) continue;
        if (sighting.description) |description| try appendDescriptionLine(allocator, &out, description);
        if (sighting.change_summary) |change| try appendDescriptionLine(allocator, &out, change);
    }
    return try out.toOwnedSlice(allocator);
}

fn appendDescriptionLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return;
    try out.appendSlice(allocator, trimmed);
    try out.append(allocator, '\n');
}

fn bestDescriptionCandidate(allocator: std.mem.Allocator, candidates: []const DescriptionCandidate, current_description: []const u8) !?CandidateMatch {
    const query = try vector_index.embedQuery(allocator, current_description, &[_][]const u8{"appearance"});
    defer allocator.free(query);
    var best: ?CandidateMatch = null;
    for (candidates, 0..) |candidate, i| {
        const vector = try vector_index.embedQuery(allocator, candidate.description, &[_][]const u8{"appearance"});
        defer allocator.free(vector);
        const similarity = vector_index.cosine(query, vector);
        if (best == null or similarity > best.?.similarity) best = .{ .index = i, .similarity = similarity };
    }
    return best;
}

fn bestCandidateConfidence(best: ?CandidateMatch) f32 {
    if (best) |match| return @max(@as(f32, 0), @min(@as(f32, 1), match.similarity));
    return 0;
}

fn tracesToSightings(allocator: std.mem.Allocator, traces: []const schema.Trace) ![]schema.Sighting {
    var out = std.ArrayList(schema.Sighting).empty;
    for (traces) |trace| {
        if (trace.source != .visual or trace.kind != .perception) continue;
        if (!hasTag(trace.tags, "sighting")) continue;
        try out.append(allocator, .{
            .sighting_id = try allocator.dupe(u8, trace.trace_id),
            .person_id = null,
            .seen_at = try allocator.dupe(u8, trace.lifecycle.created_at),
            .confidence = trace.confidence,
            .image_path = null,
            .description = try allocator.dupe(u8, trace.text),
            .change_summary = try allocator.dupe(u8, trace.interpretation),
            .retained_until = null,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn hasTag(tags: []const []const u8, wanted: []const u8) bool {
    for (tags) |tag| if (std.mem.eql(u8, tag, wanted)) return true;
    return false;
}

const CommandIdentityWire = struct {
    person_present: bool,
    match_status: []const u8,
    person_id: ?[]const u8 = null,
    confidence: f32 = 0,
    candidate_name: ?[]const u8 = null,
    people_count: u32 = 0,
};

const CommandRecognitionError = error{
    InvalidRecognitionStatus,
    MissingKnownPersonId,
    InvalidRecognitionConfidence,
    InvalidPeopleCount,
};

fn parseCommandIdentityResult(allocator: std.mem.Allocator, body: []const u8) !identity.IdentityResult {
    const parsed = try std.json.parseFromSlice(CommandIdentityWire, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const status = try parseMatchStatus(parsed.value.match_status);
    if (parsed.value.confidence < 0 or parsed.value.confidence > 1) return CommandRecognitionError.InvalidRecognitionConfidence;
    if (parsed.value.people_count == 0 and parsed.value.person_present) return CommandRecognitionError.InvalidPeopleCount;
    if (status == .known and parsed.value.person_id == null) return CommandRecognitionError.MissingKnownPersonId;

    return .{
        .person_present = parsed.value.person_present,
        .match_status = status,
        .person_id = if (parsed.value.person_id) |v| try allocator.dupe(u8, v) else null,
        .confidence = parsed.value.confidence,
        .candidate_name = if (parsed.value.candidate_name) |v| try allocator.dupe(u8, v) else null,
        .people_count = parsed.value.people_count,
    };
}

fn parseMatchStatus(text: []const u8) !identity.MatchStatus {
    if (std.mem.eql(u8, text, "none")) return .none;
    if (std.mem.eql(u8, text, "known")) return .known;
    if (std.mem.eql(u8, text, "unknown")) return .unknown;
    if (std.mem.eql(u8, text, "uncertain")) return .uncertain;
    if (std.mem.eql(u8, text, "multiple")) return .multiple;
    return CommandRecognitionError.InvalidRecognitionStatus;
}

test "command recognition parser accepts strict identity result" {
    const result = try parseCommandIdentityResult(std.testing.allocator,
        \\{"person_present":true,"match_status":"known","person_id":"person_1","confidence":0.91,"candidate_name":"Zelda","people_count":1}
    );
    defer std.testing.allocator.free(result.person_id.?);
    defer std.testing.allocator.free(result.candidate_name.?);

    try std.testing.expect(result.person_present);
    try std.testing.expectEqual(identity.MatchStatus.known, result.match_status);
    try std.testing.expectEqualStrings("person_1", result.person_id.?);
    try std.testing.expectEqual(@as(u32, 1), result.people_count);
}

test "command recognition parser rejects known result without person id" {
    try std.testing.expectError(
        CommandRecognitionError.MissingKnownPersonId,
        parseCommandIdentityResult(std.testing.allocator,
            \\{"person_present":true,"match_status":"known","confidence":0.91,"people_count":1}
        ),
    );
}
