const std = @import("std");

pub const SkillId = enum {
    say,
    take_picture,
    describe_image,
    compare_images,
    recognize,
    get_time,
    request_orientation,
    get_power,
    get_storage,
    get_database_stats,
    remember_memory,
    recall_memory,
    forget_memory,
    set_fact,
    recall_fact,
    invalidate_fact,
    sweep_memory,
    set_reminder,
    introspect,
    dream,
    appraise_event,
    feel_about,
    think_about,
    define_need,
    define_want,
    edit_need,
    edit_want,
    imagine_image,
    remember_person,
    update_face_picture,
    send_email,
    choose_attention,
    ask_human,
    consolidate_memory,
    facial_expression,
    unknown,
};

pub const Sense = enum {
    live_camera,
    button_activation,
    button_hold_state,
    visual_description,
    visual_comparison,
    identity_recognition,
    stored_memory_read,
    stored_memory_write,
    stored_image_read,
    introspection,
    time_lookup,
    orientation_query,
    power_status,
    storage_fullness,
    database_stats,
    speech_output,
    user_input,
    reminder_io,
    image_generation,
    face_picture_update,
    email_delivery,
    local_process_io,
    uploaded_media_read,
    audio_classification,
    audio_transcription,
    video_inspection,
    facial_expression_output,
};

pub const SenseSet = struct {
    live_camera: bool = false,
    button_activation: bool = false,
    button_hold_state: bool = false,
    visual_description: bool = false,
    visual_comparison: bool = false,
    identity_recognition: bool = false,
    stored_memory_read: bool = false,
    stored_memory_write: bool = false,
    stored_image_read: bool = false,
    introspection: bool = false,
    time_lookup: bool = false,
    orientation_query: bool = false,
    power_status: bool = false,
    storage_fullness: bool = false,
    database_stats: bool = false,
    speech_output: bool = false,
    user_input: bool = false,
    reminder_io: bool = false,
    image_generation: bool = false,
    face_picture_update: bool = false,
    email_delivery: bool = false,
    local_process_io: bool = false,
    uploaded_media_read: bool = false,
    audio_classification: bool = false,
    audio_transcription: bool = false,
    video_inspection: bool = false,
    facial_expression_output: bool = false,

    pub fn has(self: SenseSet, sense: Sense) bool {
        return switch (sense) {
            .live_camera => self.live_camera,
            .button_activation => self.button_activation,
            .button_hold_state => self.button_hold_state,
            .visual_description => self.visual_description,
            .visual_comparison => self.visual_comparison,
            .identity_recognition => self.identity_recognition,
            .stored_memory_read => self.stored_memory_read,
            .stored_memory_write => self.stored_memory_write,
            .stored_image_read => self.stored_image_read,
            .introspection => self.introspection,
            .time_lookup => self.time_lookup,
            .orientation_query => self.orientation_query,
            .power_status => self.power_status,
            .storage_fullness => self.storage_fullness,
            .database_stats => self.database_stats,
            .speech_output => self.speech_output,
            .user_input => self.user_input,
            .reminder_io => self.reminder_io,
            .image_generation => self.image_generation,
            .face_picture_update => self.face_picture_update,
            .email_delivery => self.email_delivery,
            .local_process_io => self.local_process_io,
            .uploaded_media_read => self.uploaded_media_read,
            .audio_classification => self.audio_classification,
            .audio_transcription => self.audio_transcription,
            .video_inspection => self.video_inspection,
            .facial_expression_output => self.facial_expression_output,
        };
    }

    pub fn all() SenseSet {
        return .{
            .live_camera = true,
            .button_activation = true,
            .button_hold_state = true,
            .visual_description = true,
            .visual_comparison = true,
            .identity_recognition = true,
            .stored_memory_read = true,
            .stored_memory_write = true,
            .stored_image_read = true,
            .introspection = true,
            .time_lookup = true,
            .orientation_query = true,
            .power_status = true,
            .storage_fullness = true,
            .database_stats = true,
            .speech_output = true,
            .user_input = true,
            .reminder_io = true,
            .image_generation = true,
            .face_picture_update = true,
            .email_delivery = true,
            .local_process_io = true,
            .uploaded_media_read = true,
            .audio_classification = true,
            .audio_transcription = true,
            .video_inspection = true,
            .facial_expression_output = true,
        };
    }
};

pub const AutonomyPolicy = enum {
    allowed,
    forbidden,
    invalid,
};

pub const SkillSpec = struct {
    id: SkillId,
    name: []const u8,
    description: []const u8,
    requires_senses: []const Sense = &.{},
    requires_skills: []const SkillId = &.{},
    autonomy_policy: AutonomyPolicy = .invalid,
    energy_cost: ?u8 = null,
    failure_hint: []const u8 = "",
};

pub const CommandSpec = struct {
    command: SkillId,
    description: []const u8,
    requires: []const Sense,
};

pub const registry = [_]SkillSpec{
    .{ .id = .say, .name = "say", .description = "speak in your own voice. Include text.", .requires_senses = &.{.speech_output}, .autonomy_policy = .allowed, .energy_cost = 5, .failure_hint = "Check speech output and speaker configuration." },
    .{ .id = .take_picture, .name = "take_picture", .description = "gather a fresh visual observation of the room.", .requires_senses = &.{ .live_camera, .visual_description }, .autonomy_policy = .forbidden, .failure_hint = "Check camera and visual description configuration." },
    .{ .id = .describe_image, .name = "describe_image", .description = "describe visible content from a fresh camera image, or from the latest uploaded image when no live camera is available. Optional text/query narrows what to describe.", .requires_senses = &.{.visual_description}, .autonomy_policy = .forbidden, .failure_hint = "Provide a live camera or upload an image, and configure visual description." },
    .{ .id = .compare_images, .name = "compare_images", .description = "compare the latest stored visual observation with a fresh image. Optional text/query narrows what differences to look for.", .requires_senses = &.{ .live_camera, .visual_comparison, .stored_image_read }, .autonomy_policy = .forbidden, .failure_hint = "Capture or upload an image first, then ensure camera and visual comparison are configured." },
    .{ .id = .recognize, .name = "recognize", .description = "use your identity-recognition skill to see who you are talking to, returning match status, name, confidence, and people count.", .requires_senses = &.{ .live_camera, .identity_recognition }, .requires_skills = &.{ .recall_memory, .remember_memory }, .autonomy_policy = .forbidden, .failure_hint = "Check camera, recognizer, and memory configuration." },
    .{ .id = .get_time, .name = "get_time", .description = "observe the current date/time only.", .requires_senses = &.{.time_lookup}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check time lookup configuration." },
    .{ .id = .request_orientation, .name = "request_orientation", .description = "ask the Apple host for a one-shot device orientation observation.", .requires_senses = &.{.orientation_query}, .autonomy_policy = .forbidden, .failure_hint = "Ask for host orientation only when the user has allowed orientation sensing." },
    .{ .id = .get_power, .name = "get_power", .description = "observe battery levels and whether external power is plugged in.", .requires_senses = &.{.power_status}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check power status sensing configuration." },
    .{ .id = .get_storage, .name = "get_storage", .description = "observe storage fullness for mounted local filesystems.", .requires_senses = &.{.storage_fullness}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check storage fullness sensing configuration." },
    .{ .id = .get_database_stats, .name = "get_database_stats", .description = "observe SQLite database size, page, freelist, and table counts for memory stores.", .requires_senses = &.{.database_stats}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check database statistics sensing configuration." },
    .{ .id = .remember_memory, .name = "remember_memory", .description = "keep a short-term memory. Include text and optional tags.", .requires_senses = &.{.stored_memory_write}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory write configuration." },
    .{ .id = .recall_memory, .name = "recall_memory", .description = "search remembered experience. Include query and/or tags when memory would matter.", .requires_senses = &.{.stored_memory_read}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory read configuration." },
    .{ .id = .forget_memory, .name = "forget_memory", .description = "release a memory by memory_id.", .requires_skills = &.{ .recall_memory, .remember_memory }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .set_fact, .name = "set_fact", .description = "create or revise a durable self fact. Include name as the fact key, text as the value, and optional tags.", .requires_skills = &.{ .recall_memory, .remember_memory }, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .recall_fact, .name = "recall_fact", .description = "list durable self facts. Optional query matches fact key/value; optional tags narrow results.", .requires_skills = &.{.recall_memory}, .failure_hint = "Check memory read configuration." },
    .{ .id = .invalidate_fact, .name = "invalidate_fact", .description = "mark a durable self fact inactive by memory_id/fact_id, or by unique name/key.", .requires_skills = &.{ .recall_memory, .remember_memory }, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .sweep_memory, .name = "sweep_memory", .description = "let weak short-term memories fade.", .requires_skills = &.{ .recall_memory, .remember_memory }, .autonomy_policy = .allowed, .energy_cost = 2, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .set_reminder, .name = "set_reminder", .description = "add a future intention or wait timer to the Markdown maintenance schedule. Include schedule and text. For wait timers use schedules like `in 10 seconds`, `in 5 minutes`, `after 2 hours`, or `in 1 day`; recurring schedules like `every 6 hours` and `every day at 09:00` also work.", .requires_senses = &.{.reminder_io}, .autonomy_policy = .allowed, .energy_cost = 2, .failure_hint = "Check local reminder I/O and maintenance schedule path." },
    .{ .id = .introspect, .name = "introspect", .description = "observe current senses, memory state, and available skills.", .requires_senses = &.{.introspection}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check introspection configuration." },
    .{ .id = .dream, .name = "dream", .description = "connect memories and recent conversation, then generate a picture of the dream. heat is always random; optional heat_bias can be low, mixed, or high. Optionally include text to save as a provisional dream memory.", .requires_skills = &.{ .recall_memory, .remember_memory, .imagine_image }, .autonomy_policy = .allowed, .energy_cost = 6, .failure_hint = "Check memory and image generation configuration." },
    .{ .id = .appraise_event, .name = "appraise_event", .description = "register how an event lands internally. Include text and optional tags.", .requires_skills = &.{.remember_memory}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory write configuration." },
    .{ .id = .feel_about, .name = "feel_about", .description = "form an appraisal of a topic, including self-directed questions. Include query and optional tags.", .requires_skills = &.{ .recall_memory, .remember_memory, .introspect }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory and introspection configuration." },
    .{ .id = .think_about, .name = "think_about", .description = "reflect on a topic before answering. Include query or text and optional tags; this may recall relevant memory, use model judgment, and save a short-term thought.", .requires_skills = &.{ .recall_memory, .remember_memory, .introspect }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory and introspection configuration." },
    .{ .id = .define_need, .name = "define_need", .description = "define one of your own ongoing needs. Include text. This stores a self_need memory and appraises it.", .requires_skills = &.{ .remember_memory, .introspect }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory write and introspection configuration." },
    .{ .id = .define_want, .name = "define_want", .description = "define one of your own ongoing wants. Include text. This stores a self_want memory and appraises it.", .requires_skills = &.{ .remember_memory, .introspect }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory write and introspection configuration." },
    .{ .id = .edit_need, .name = "edit_need", .description = "edit one stored self_need memory. Include memory_id and replacement text.", .requires_skills = &.{ .recall_memory, .remember_memory, .introspect }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory read/write and introspection configuration." },
    .{ .id = .edit_want, .name = "edit_want", .description = "edit one stored self_want memory. Include memory_id and replacement text.", .requires_skills = &.{ .recall_memory, .remember_memory, .introspect }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory read/write and introspection configuration." },
    .{ .id = .imagine_image, .name = "imagine_image", .description = "create a new imagined image with Nano Banana. Include text as the generation prompt.", .requires_senses = &.{.image_generation}, .autonomy_policy = .allowed, .energy_cost = 4, .failure_hint = "Check image generation service configuration." },
    .{ .id = .remember_person, .name = "remember_person", .description = "create or refresh a person's face memory from the latest observed image. Use this when an unrecognized person becomes salient and naturally offers a name or identity, or when updating an existing person. Include name, or person_id/name for an existing person.", .requires_senses = &.{ .face_picture_update, .stored_image_read }, .requires_skills = &.{ .recall_memory, .remember_memory }, .autonomy_policy = .invalid, .failure_hint = "Capture or upload an image first, then check face picture update and memory configuration." },
    .{ .id = .update_face_picture, .name = "update_face_picture", .description = "update an existing person's face recognition reference picture. Include person_id or unique name, and image_path; if image_path is omitted, the latest uploaded or observed image is used. Optional keep_existing keeps older cached embeddings.", .requires_senses = &.{ .face_picture_update, .local_process_io }, .requires_skills = &.{ .recall_memory, .remember_memory }, .autonomy_policy = .invalid, .failure_hint = "Check local process I/O, face picture update, and memory configuration." },
    .{ .id = .send_email, .name = "send_email", .description = "send a plain-text email. Include to, subject, and text. Use only when the user clearly asks for email or explicitly consents to sending one.", .requires_senses = &.{.email_delivery}, .autonomy_policy = .invalid, .failure_hint = "Configure data/email.json and email delivery service." },
    .{ .id = .choose_attention, .name = "choose_attention", .description = "notice what currently seems worth attention.", .requires_skills = &.{ .recall_memory, .introspect }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory read and introspection configuration." },
    .{ .id = .ask_human, .name = "ask_human", .description = "ask the human for help, clarification, or permission. Include text.", .requires_skills = &.{.remember_memory}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory write configuration." },
    .{ .id = .consolidate_memory, .name = "consolidate_memory", .description = "integrate memory offline.", .requires_skills = &.{ .recall_memory, .remember_memory }, .autonomy_policy = .allowed, .energy_cost = 2, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .facial_expression, .name = "facial_expression", .description = "silently show a WebView facial expression. Include eyes and mouth sprite names; optional duration_ms defaults to 3000 and may not exceed 5000. Eye sprites: neutral, stern, narrow, surprised, upward, concerned, unfocused, focused. Mouth sprites: smile_closed, smile_teeth, frown, kiss, grimace, open, disgust, smirk, uneasy_right, flat, parted, neutral_closed.", .requires_senses = &.{.facial_expression_output}, .autonomy_policy = .allowed, .energy_cost = 0, .failure_hint = "Use the macOS WebView activation mode and provide valid eyes and mouth sprite names." },
};

pub fn spec(id: SkillId) ?SkillSpec {
    for (registry) |entry| {
        if (entry.id == id) return entry;
    }
    return null;
}

pub fn commandSpec(id: SkillId) ?CommandSpec {
    const entry = spec(id) orelse return null;
    return .{ .command = entry.id, .description = entry.description, .requires = entry.requires_senses };
}

pub fn name(id: SkillId) []const u8 {
    if (spec(id)) |entry| return entry.name;
    return @tagName(id);
}

pub fn failureHint(id: SkillId) []const u8 {
    if (spec(id)) |entry| return entry.failure_hint;
    return "";
}

pub fn validateRegistry() !void {
    try validateSpecs(&registry);
}

pub fn validateSpecs(entries: []const SkillSpec) !void {
    var seen = [_]bool{false} ** @typeInfo(SkillId).@"enum".fields.len;
    for (entries) |entry| {
        if (entry.id == .unknown) return error.UnknownSkillRegistered;
        const index = @intFromEnum(entry.id);
        if (seen[index]) return error.DuplicateSkillSpec;
        seen[index] = true;
        if (!std.mem.eql(u8, entry.name, @tagName(entry.id))) return error.SkillNameMismatch;
        for (entry.requires_skills) |required| {
            if (required == .unknown) return error.UnknownSkillDependency;
            if (findSpec(entries, required) == null) return error.UnknownSkillDependency;
        }
        for (entry.requires_senses) |sense| {
            if (senseUnavailableReason(sense).len == 0) return error.MissingSenseFailureHint;
        }
        var visiting = [_]bool{false} ** @typeInfo(SkillId).@"enum".fields.len;
        var visited = [_]bool{false} ** @typeInfo(SkillId).@"enum".fields.len;
        try validateNoCycle(entries, entry.id, &visiting, &visited);
    }
    inline for (@typeInfo(SkillId).@"enum".fields) |field| {
        const id: SkillId = @field(SkillId, field.name);
        if (id != .unknown and !seen[@intFromEnum(id)]) return error.MissingSkillSpec;
    }
}

fn validateNoCycle(entries: []const SkillSpec, id: SkillId, visiting: *[@typeInfo(SkillId).@"enum".fields.len]bool, visited: *[@typeInfo(SkillId).@"enum".fields.len]bool) !void {
    const index = @intFromEnum(id);
    if (visiting[index]) return error.CyclicSkillDependency;
    if (visited[index]) return;
    visiting[index] = true;
    const entry = findSpec(entries, id) orelse return error.UnknownSkillDependency;
    for (entry.requires_skills) |required| {
        try validateNoCycle(entries, required, visiting, visited);
    }
    visiting[index] = false;
    visited[index] = true;
}

fn findSpec(entries: []const SkillSpec, id: SkillId) ?SkillSpec {
    for (entries) |entry| {
        if (entry.id == id) return entry;
    }
    return null;
}

pub fn senseUnavailableReason(sense: Sense) []const u8 {
    return switch (sense) {
        .live_camera => "no live camera is configured for this body",
        .button_activation => "button activation is not configured for this body",
        .button_hold_state => "button hold sensing is not configured for this body",
        .visual_description => "visual description is not configured",
        .visual_comparison => "visual comparison is not configured",
        .identity_recognition => "identity recognition is not configured",
        .stored_memory_read => "stored memory reading is not configured",
        .stored_memory_write => "stored memory writing is not configured",
        .stored_image_read => "stored image reading is not configured",
        .introspection => "introspection is not configured",
        .time_lookup => "time lookup is not configured",
        .orientation_query => "orientation query is not configured",
        .power_status => "power status sensing is not configured",
        .storage_fullness => "storage fullness sensing is not configured",
        .database_stats => "database statistics sensing is not configured",
        .speech_output => "speech output is not configured",
        .user_input => "user input is not configured",
        .reminder_io => "reminder storage is not configured",
        .image_generation => "image generation is not configured",
        .face_picture_update => "face recognition picture updates are not configured",
        .email_delivery => "email delivery is not configured",
        .local_process_io => "local process I/O is not configured",
        .uploaded_media_read => "uploaded media reading is not configured",
        .audio_classification => "audio classification is not configured",
        .audio_transcription => "audio transcription is not configured",
        .video_inspection => "video inspection is not configured",
        .facial_expression_output => "facial expression output is only available in the macOS WebView",
    };
}

pub fn autonomySkillNames(allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var first = true;
    for (registry) |entry| {
        if (entry.autonomy_policy != .allowed) continue;
        if (!first) try out.appendSlice(allocator, ", ");
        first = false;
        try out.appendSlice(allocator, entry.name);
    }
    return out.toOwnedSlice(allocator);
}

pub fn autonomyCommandEnumJson(allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    var first = true;
    for (registry) |entry| {
        if (entry.autonomy_policy != .allowed) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, try std.json.Stringify.valueAlloc(allocator, entry.name, .{}));
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn autonomyEnergyCost(id: SkillId) !u8 {
    const entry = spec(id) orelse return error.UnknownSkill;
    if (entry.autonomy_policy != .allowed) return switch (entry.autonomy_policy) {
        .forbidden => error.ProactiveCameraCaptureForbidden,
        .invalid => error.InvalidAutonomyCommand,
        .allowed => unreachable,
    };
    return entry.energy_cost orelse return error.MissingAutonomyEnergyCost;
}

pub fn autonomyCostCatalog(allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "planner=1");
    for (registry) |entry| {
        if (entry.autonomy_policy != .allowed) continue;
        try out.print(allocator, " {s}={d}", .{ entry.name, entry.energy_cost orelse return error.MissingAutonomyEnergyCost });
    }
    try out.appendSlice(allocator, " visual_camera=forbidden");
    return out.toOwnedSlice(allocator);
}

pub fn affordanceCatalog(allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (registry) |entry| {
        try out.print(allocator, "- {s}: {s}\n", .{ entry.name, entry.description });
    }
    return out.toOwnedSlice(allocator);
}

test "skill registry is complete and valid" {
    try validateRegistry();
}

test "skill registry rejects duplicate skill names" {
    const entries = [_]SkillSpec{
        .{ .id = .say, .name = "say", .description = "one" },
        .{ .id = .say, .name = "say", .description = "two" },
    };
    try std.testing.expectError(error.DuplicateSkillSpec, validateSpecs(&entries));
}

test "skill registry rejects unknown skill dependencies" {
    const entries = [_]SkillSpec{
        .{ .id = .say, .name = "say", .description = "one", .requires_skills = &.{.recall_memory} },
    };
    try std.testing.expectError(error.UnknownSkillDependency, validateSpecs(&entries));
}

test "skill registry rejects cyclic skill dependencies" {
    const entries = [_]SkillSpec{
        .{ .id = .say, .name = "say", .description = "one", .requires_skills = &.{.recall_memory} },
        .{ .id = .recall_memory, .name = "recall_memory", .description = "two", .requires_skills = &.{.say} },
    };
    try std.testing.expectError(error.CyclicSkillDependency, validateSpecs(&entries));
}

test "autonomy registry keeps camera skills forbidden" {
    try std.testing.expect((spec(.take_picture) orelse return error.MissingSkillSpec).autonomy_policy == .forbidden);
    try std.testing.expect((spec(.describe_image) orelse return error.MissingSkillSpec).autonomy_policy == .forbidden);
    try std.testing.expect((spec(.compare_images) orelse return error.MissingSkillSpec).autonomy_policy == .forbidden);
    try std.testing.expect((spec(.recognize) orelse return error.MissingSkillSpec).autonomy_policy == .forbidden);
}
