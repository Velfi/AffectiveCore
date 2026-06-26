const std = @import("std");
const identity = @import("../core/identity.zig");
const openai = @import("openai_client.zig");
const schema = @import("../storage/schema.zig");
const store_mod = @import("../storage/store.zig");
const vector_index = @import("../core/vector_index.zig");
const http_transport = @import("http_transport.zig");

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

pub const HostRecognitionClient = struct {
    http: http_transport.Client,
    memory_path: []const u8,
    embeddings_dir: []const u8,
    known_threshold: f32 = 0.85,
    uncertain_threshold: f32 = 0.60,

    pub fn recognizer(self: *HostRecognitionClient) identity.IdentityRecognizer {
        return .{ .ctx = self, .identifyFn = identify };
    }

    pub fn updater(self: *HostRecognitionClient) identity.FacePictureUpdater {
        return .{ .ctx = self, .updateFn = update };
    }

    fn identify(ctx: *anyopaque, allocator: std.mem.Allocator, image_path: []const u8) !identity.IdentityResult {
        const self: *HostRecognitionClient = @ptrCast(@alignCast(ctx));
        var body_writer: std.Io.Writer.Allocating = .init(allocator);
        defer body_writer.deinit();
        try std.json.Stringify.value(.{
            .image_path = image_path,
            .memory_path = self.memory_path,
            .embeddings_dir = self.embeddings_dir,
            .known_threshold = self.known_threshold,
            .uncertain_threshold = self.uncertain_threshold,
        }, .{}, &body_writer.writer);
        const body = body_writer.written();
        const out = try self.http.postJson(allocator, .{
            .url = "affective-host://recognize/identify",
            .body = body,
        });
        defer allocator.free(out);
        return parseHostIdentityResult(allocator, out);
    }

    fn update(ctx: *anyopaque, allocator: std.mem.Allocator, request: identity.FacePictureUpdateRequest) !identity.FacePictureUpdateResult {
        const self: *HostRecognitionClient = @ptrCast(@alignCast(ctx));
        var body_writer: std.Io.Writer.Allocating = .init(allocator);
        defer body_writer.deinit();
        try std.json.Stringify.value(.{
            .image_path = request.image_path,
            .memory_path = self.memory_path,
            .embeddings_dir = self.embeddings_dir,
            .person_id = request.person_id,
            .name = request.name,
            .keep_existing = request.keep_existing,
        }, .{}, &body_writer.writer);
        const body = body_writer.written();
        const out = try self.http.postJson(allocator, .{
            .url = "affective-host://recognize/enroll",
            .body = body,
        });
        defer allocator.free(out);
        return parseHostFacePictureUpdateResult(allocator, out);
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

const HostIdentityWire = struct {
    person_present: bool,
    match_status: []const u8,
    person_id: ?[]const u8 = null,
    confidence: f32 = 0,
    candidate_name: ?[]const u8 = null,
    people_count: u32 = 0,
};

const HostRecognitionError = error{
    InvalidRecognitionStatus,
    MissingKnownPersonId,
    InvalidRecognitionConfidence,
    InvalidPeopleCount,
};

fn parseHostIdentityResult(allocator: std.mem.Allocator, body: []const u8) !identity.IdentityResult {
    const parsed = try std.json.parseFromSlice(HostIdentityWire, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const status = try parseMatchStatus(parsed.value.match_status);
    if (parsed.value.confidence < 0 or parsed.value.confidence > 1) return HostRecognitionError.InvalidRecognitionConfidence;
    if (parsed.value.people_count == 0 and parsed.value.person_present) return HostRecognitionError.InvalidPeopleCount;
    if (status == .known and parsed.value.person_id == null) return HostRecognitionError.MissingKnownPersonId;

    return .{
        .person_present = parsed.value.person_present,
        .match_status = status,
        .person_id = if (parsed.value.person_id) |v| try allocator.dupe(u8, v) else null,
        .confidence = parsed.value.confidence,
        .candidate_name = if (parsed.value.candidate_name) |v| try allocator.dupe(u8, v) else null,
        .people_count = parsed.value.people_count,
    };
}


const HostFacePictureUpdateWire = struct {
    person_id: []const u8,
    display_name: ?[]const u8 = null,
    representative_image_path: []const u8,
    embedding_path: []const u8,
    quality_score: f32 = 0,
    removed_embeddings: u32 = 0,
    kept_existing: bool = false,
};

fn parseHostFacePictureUpdateResult(allocator: std.mem.Allocator, body: []const u8) !identity.FacePictureUpdateResult {
    const parsed = try std.json.parseFromSlice(HostFacePictureUpdateWire, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return .{
        .person_id = try allocator.dupe(u8, parsed.value.person_id),
        .display_name = if (parsed.value.display_name) |v| try allocator.dupe(u8, v) else null,
        .representative_image_path = try allocator.dupe(u8, parsed.value.representative_image_path),
        .embedding_path = try allocator.dupe(u8, parsed.value.embedding_path),
        .quality_score = parsed.value.quality_score,
        .removed_embeddings = parsed.value.removed_embeddings,
        .kept_existing = parsed.value.kept_existing,
    };
}

fn parseMatchStatus(text: []const u8) !identity.MatchStatus {
    if (std.mem.eql(u8, text, "none")) return .none;
    if (std.mem.eql(u8, text, "known")) return .known;
    if (std.mem.eql(u8, text, "unknown")) return .unknown;
    if (std.mem.eql(u8, text, "uncertain")) return .uncertain;
    if (std.mem.eql(u8, text, "multiple")) return .multiple;
    return HostRecognitionError.InvalidRecognitionStatus;
}

test "host recognition parser accepts strict identity result" {
    const result = try parseHostIdentityResult(std.testing.allocator,
        \\{"person_present":true,"match_status":"known","person_id":"person_1","confidence":0.91,"candidate_name":"Zelda","people_count":1}
    );
    defer std.testing.allocator.free(result.person_id.?);
    defer std.testing.allocator.free(result.candidate_name.?);

    try std.testing.expect(result.person_present);
    try std.testing.expectEqual(identity.MatchStatus.known, result.match_status);
    try std.testing.expectEqualStrings("person_1", result.person_id.?);
    try std.testing.expectEqual(@as(u32, 1), result.people_count);
}

test "host recognition parser rejects known result without person id" {
    try std.testing.expectError(
        HostRecognitionError.MissingKnownPersonId,
        parseHostIdentityResult(std.testing.allocator,
            \\{"person_present":true,"match_status":"known","confidence":0.91,"people_count":1}
        ),
    );
}
