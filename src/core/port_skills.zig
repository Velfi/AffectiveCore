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
    forget_memory,
    forget_person,
    set_fact,
    recall_fact,
    invalidate_fact,
    sweep_memory,
    schedule_reminder,
    introspect,
    appraise_event,
    feel_about,
    think_about,
    define_need,
    define_want,
    define_goal,
    edit_need,
    edit_want,
    edit_goal,
    imagine_image,
    remember_person,
    update_face_picture,
    send_email,
    choose_attention,
    set_focus,
    clear_focus,
    begin_subtask,
    resume_parent,
    consolidate_memory,
    sleep_autonomy,
    wake_autonomy,
    emote,
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
    full_allowed,
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
    /// When set, autonomy-origin actions use this tier instead of energy_cost.
    autonomy_energy_cost: ?u8 = null,
    failure_hint: []const u8 = "",
    developer_title: ?[]const u8 = null,
    developer_symbol_name: ?[]const u8 = null,
    developer_mirror_to_chat: bool = false,
    developer_requires_camera: bool = false,
};

pub const ActionSpec = struct {
    action: SkillId,
    description: []const u8,
    requires: []const Sense,
};

pub const registry = [_]SkillSpec{
    .{ .id = .say, .name = "say", .description = "speak aloud. Include text—the words to say, not a promise to say them later.", .requires_senses = &.{.speech_output}, .autonomy_policy = .allowed, .energy_cost = 5, .autonomy_energy_cost = 3, .failure_hint = "Check speech output and speaker configuration." },
    .{ .id = .take_picture, .name = "take_picture", .description = "gather a fresh visual observation of the room.", .requires_senses = &.{ .live_camera, .visual_description }, .autonomy_policy = .full_allowed, .energy_cost = 3, .failure_hint = "Check camera and visual description configuration." },
    .{ .id = .describe_image, .name = "describe_image", .description = "describe visible content from a fresh camera image, or from the latest uploaded image when no live camera is available. Optional text/query narrows what to describe.", .requires_senses = &.{.visual_description}, .autonomy_policy = .full_allowed, .energy_cost = 3, .failure_hint = "Provide a live camera or upload an image, and configure visual description." },
    .{ .id = .compare_images, .name = "compare_images", .description = "compare the latest stored visual observation with a fresh image. Optional text/query narrows what differences to look for.", .requires_senses = &.{ .live_camera, .visual_comparison, .stored_image_read }, .autonomy_policy = .full_allowed, .energy_cost = 4, .failure_hint = "Capture or upload an image first, then ensure camera and visual comparison are configured." },
    .{ .id = .recognize, .name = "recognize", .description = "use your identity-recognition skill to see who you are talking to, returning match status, name, confidence, and people count.", .requires_senses = &.{ .live_camera, .identity_recognition, .stored_memory_read, .stored_memory_write }, .autonomy_policy = .full_allowed, .energy_cost = 4, .failure_hint = "Check camera, recognizer, and memory configuration.", .developer_title = "Recognize", .developer_symbol_name = "person.crop.square", .developer_mirror_to_chat = true, .developer_requires_camera = true },
    .{ .id = .get_time, .name = "get_time", .description = "observe the current date/time only.", .requires_senses = &.{.time_lookup}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check time lookup configuration." },
    .{ .id = .request_orientation, .name = "request_orientation", .description = "ask the Apple host for a one-shot device orientation observation.", .requires_senses = &.{.orientation_query}, .autonomy_policy = .full_allowed, .energy_cost = 2, .failure_hint = "Ask for host orientation only when the user has allowed orientation sensing." },
    .{ .id = .get_power, .name = "get_power", .description = "observe battery levels and whether external power is plugged in.", .requires_senses = &.{.power_status}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check power status sensing configuration." },
    .{ .id = .get_storage, .name = "get_storage", .description = "observe storage fullness for mounted local filesystems.", .requires_senses = &.{.storage_fullness}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check storage fullness sensing configuration." },
    .{ .id = .get_database_stats, .name = "get_database_stats", .description = "observe SQLite database size, page, freelist, and table counts for memory stores.", .requires_senses = &.{.database_stats}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check database statistics sensing configuration." },
    .{ .id = .forget_memory, .name = "forget_memory", .description = "release a memory by memory_id.", .requires_senses = &.{ .stored_memory_read, .stored_memory_write }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .forget_person, .name = "forget_person", .description = "mark a person's profile forgotten and clear their face embeddings. Include person_id or unique name; if omitted, use the current speaker when known.", .requires_senses = &.{ .stored_memory_read, .stored_memory_write }, .autonomy_policy = .invalid, .failure_hint = "Provide person_id or name, or establish who is speaking first." },
    .{ .id = .set_fact, .name = "set_fact", .description = "create or revise a durable self fact. Include name as the fact key, text as the value, and optional tags.", .requires_senses = &.{ .stored_memory_read, .stored_memory_write }, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .recall_fact, .name = "recall_fact", .description = "list durable self facts. Optional query matches fact key/value; optional tags narrow results.", .requires_senses = &.{.stored_memory_read}, .failure_hint = "Check memory read configuration." },
    .{ .id = .invalidate_fact, .name = "invalidate_fact", .description = "mark a durable self fact inactive by memory_id/fact_id, or by unique name/key.", .requires_senses = &.{ .stored_memory_read, .stored_memory_write }, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .sweep_memory, .name = "sweep_memory", .description = "let weak short-term memories fade.", .requires_senses = &.{ .stored_memory_read, .stored_memory_write }, .autonomy_policy = .allowed, .energy_cost = 2, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .schedule_reminder, .name = "schedule_reminder", .description = "add a future intention or wait timer to the Markdown maintenance schedule. Include schedule and text. For wait timers use schedules like `in 10 seconds`, `in 5 minutes`, `after 2 hours`, or `in 1 day`; recurring schedules like `every 6 hours` and `every day at 09:00` also work.", .requires_senses = &.{.reminder_io}, .autonomy_policy = .allowed, .energy_cost = 2, .failure_hint = "Check local reminder I/O and maintenance schedule path." },
    .{ .id = .introspect, .name = "introspect", .description = "observe internal state. Optional query drills down: overview (default), skills, skills/<group>, skill/<name>, memory, facts, needs, capabilities, senses, autonomy, focus, identity.", .requires_senses = &.{.introspection}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check introspection configuration." },
    .{ .id = .appraise_event, .name = "appraise_event", .description = "register how an event lands internally. Include text and optional tags.", .requires_senses = &.{.stored_memory_write}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory write configuration." },
    .{ .id = .feel_about, .name = "feel_about", .description = "form an appraisal of a topic, including self-directed questions. Include query and optional tags.", .requires_senses = &.{ .stored_memory_read, .stored_memory_write }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .think_about, .name = "think_about", .description = "reflect on a topic before answering. Include query or text and optional tags; this may recall relevant memory, use model judgment, and save a short-term thought.", .requires_senses = &.{ .stored_memory_read, .stored_memory_write }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .define_need, .name = "define_need", .description = "define one of your own ongoing needs. Include text. This stores a self_need memory and appraises it.", .requires_senses = &.{.stored_memory_write}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory write configuration." },
    .{ .id = .define_want, .name = "define_want", .description = "define one of your own ongoing wants. Include text. This stores a self_want memory and appraises it.", .requires_senses = &.{.stored_memory_write}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory write configuration." },
    .{ .id = .define_goal, .name = "define_goal", .description = "define one of your own ongoing goals. Include text. This stores a self_goal memory and appraises it.", .requires_senses = &.{.stored_memory_write}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory write configuration." },
    .{ .id = .edit_need, .name = "edit_need", .description = "edit one stored self_need memory. Include memory_id and replacement text.", .requires_senses = &.{ .stored_memory_read, .stored_memory_write }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .edit_want, .name = "edit_want", .description = "edit one stored self_want memory. Include memory_id and replacement text.", .requires_senses = &.{ .stored_memory_read, .stored_memory_write }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .edit_goal, .name = "edit_goal", .description = "edit one stored self_goal memory. Include memory_id and replacement text.", .requires_senses = &.{ .stored_memory_read, .stored_memory_write }, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory read/write configuration." },
    .{ .id = .imagine_image, .name = "imagine_image", .description = "create a new standalone imagined image with Nano Banana. Include text as the generation prompt. Do not use this when the user asks you to dream or enter dream time; use consolidate_memory instead.", .requires_senses = &.{.image_generation}, .autonomy_policy = .allowed, .energy_cost = 4, .failure_hint = "Check image generation service configuration." },
    .{ .id = .remember_person, .name = "remember_person", .description = "create or refresh a person's face memory from the latest observed image. Use this when an unrecognized person becomes salient and naturally offers a name or identity, or when updating an existing person. Include name, or person_id/name for an existing person.", .requires_senses = &.{ .face_picture_update, .stored_image_read, .stored_memory_read, .stored_memory_write }, .autonomy_policy = .invalid, .failure_hint = "Capture or upload an image first, then check face picture update and memory configuration." },
    .{ .id = .update_face_picture, .name = "update_face_picture", .description = "update an existing person's face recognition reference picture. Include person_id or unique name, and image_path; if image_path is omitted, the latest uploaded or observed image is used. Optional keep_existing keeps older cached embeddings.", .requires_senses = &.{ .face_picture_update, .stored_memory_read, .stored_memory_write }, .autonomy_policy = .invalid, .failure_hint = "Check host face picture update and memory configuration." },
    .{ .id = .send_email, .name = "send_email", .description = "send a plain-text email. Include to, subject, and text. Use only when the user clearly asks for email or explicitly consents to sending one.", .requires_senses = &.{.email_delivery}, .autonomy_policy = .invalid, .failure_hint = "Configure data/email.json and email delivery service." },
    .{ .id = .choose_attention, .name = "choose_attention", .description = "notice what currently seems worth attention.", .requires_senses = &.{.stored_memory_read}, .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Check memory read configuration.", .developer_title = "Attention", .developer_symbol_name = "scope", .developer_mirror_to_chat = true },
    .{ .id = .set_focus, .name = "set_focus", .description = "set a short plan as your current focus (working memory). Include text. Your focus leads your context while it stays fresh, then fades.", .autonomy_policy = .allowed, .energy_cost = 1, .failure_hint = "Provide non-empty focus text." },
    .{ .id = .clear_focus, .name = "clear_focus", .description = "drop your current focus and return to deriving attention from what is happening now.", .autonomy_policy = .allowed, .energy_cost = @as(u8, 0), .failure_hint = "Focus can be cleared without extra host capability." },
    .{ .id = .begin_subtask, .name = "begin_subtask", .description = "pause the current activity and open a child subtask without losing the main goal. Include text as the subtask goal. Run other skills after this in the same turn when needed; call resume_parent when the subtask is done.", .autonomy_policy = .allowed, .energy_cost = @as(u8, 0), .failure_hint = "Requires an active parent activity and non-empty subtask text." },
    .{ .id = .resume_parent, .name = "resume_parent", .description = "mark the current child subtask complete and resume the paused parent activity from the activity stack.", .autonomy_policy = .allowed, .energy_cost = @as(u8, 0), .failure_hint = "Requires an open child subtask with a paused parent on the activity stack." },
    .{ .id = .consolidate_memory, .name = "consolidate_memory", .description = "enter internal dream time to consolidate memory and integrate the day's traces. Use when the user asks to dream, nap internally, or enter dream time now.", .requires_senses = &.{ .stored_memory_read, .stored_memory_write }, .autonomy_policy = .allowed, .energy_cost = 2, .failure_hint = "Check memory read/write configuration.", .developer_title = "Consolidate", .developer_symbol_name = "square.stack.3d.up" },
    .{ .id = .sleep_autonomy, .name = "sleep_autonomy", .description = "pause self-directed autonomy actions until wake_autonomy is chosen. Optional text records why.", .autonomy_policy = .allowed, .energy_cost = @as(u8, 0), .failure_hint = "Autonomy sleep can be set without extra host capability." },
    .{ .id = .wake_autonomy, .name = "wake_autonomy", .description = "resume self-directed autonomy actions after sleep_autonomy. Optional text records why.", .autonomy_policy = .allowed, .energy_cost = @as(u8, 0), .failure_hint = "Autonomy wake can be set without extra host capability." },
    .{ .id = .emote, .name = "emote", .description = "silently show a brief third-person gesture in plain language; the host renders it as *text* in chat. Include text; optional duration_ms defaults to 3000 and may not exceed 5000. Use when facial_expression is unavailable or when a gesture fits text better than avatar sprites.", .autonomy_policy = .allowed, .energy_cost = @as(u8, 0), .failure_hint = "Provide non-empty emote text in plain language." },
    .{ .id = .facial_expression, .name = "facial_expression", .description = "silently show a facial expression on the avatar. Set eyes, mouth, or both from facial_expression_catalog; unspecified eyes or mouth default to neutral sprites. Or set text to a preset id from that catalog; optional duration_ms defaults to 3000 and may not exceed 5000. Use introspect query=skill/facial_expression for the sprite menu. When facial expression output or catalog is unavailable, use emote for visible affect instead.", .requires_senses = &.{.facial_expression_output}, .autonomy_policy = .allowed, .energy_cost = @as(u8, 1), .failure_hint = "Provide valid eyes and/or mouth sprite names from facial_expression_catalog, or set text to a preset id; unspecified aspects default to neutral; otherwise use emote." },
};

pub fn spec(id: SkillId) ?SkillSpec {
    for (registry) |entry| {
        if (entry.id == id) return entry;
    }
    return null;
}

pub fn actionSpec(id: SkillId) ?ActionSpec {
    const entry = spec(id) orelse return null;
    return .{ .action = entry.id, .description = entry.description, .requires = entry.requires_senses };
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

pub fn autonomyPolicyAllowed(policy: AutonomyPolicy, autonomy_mode: []const u8) bool {
    return switch (policy) {
        .allowed => true,
        .full_allowed => std.mem.eql(u8, autonomy_mode, "full"),
        .forbidden, .invalid => false,
    };
}

pub fn autonomyAllowed(id: SkillId, autonomy_mode: []const u8) bool {
    const entry = spec(id) orelse return false;
    return autonomyPolicyAllowed(entry.autonomy_policy, autonomy_mode);
}

pub fn autonomySkillNames(allocator: std.mem.Allocator, autonomy_mode: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var first = true;
    for (registry) |entry| {
        if (!autonomyPolicyAllowed(entry.autonomy_policy, autonomy_mode)) continue;
        if (!first) try out.appendSlice(allocator, ", ");
        first = false;
        try out.appendSlice(allocator, entry.name);
    }
    return out.toOwnedSlice(allocator);
}

pub fn autonomyActionEnumJson(allocator: std.mem.Allocator, autonomy_mode: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    var first = true;
    for (registry) |entry| {
        if (!autonomyPolicyAllowed(entry.autonomy_policy, autonomy_mode)) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, try std.json.Stringify.valueAlloc(allocator, entry.name, .{}));
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn interactionSkillNames(allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var first = true;
    for (registry) |entry| {
        if (entry.autonomy_policy == .invalid) continue;
        if (!first) try out.appendSlice(allocator, ", ");
        first = false;
        try out.appendSlice(allocator, entry.name);
    }
    return out.toOwnedSlice(allocator);
}

pub fn interactionActionEnumJson(allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    var first = true;
    for (registry) |entry| {
        if (entry.autonomy_policy == .invalid) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, try std.json.Stringify.valueAlloc(allocator, entry.name, .{}));
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn actionEnergyTier(id: SkillId) !u8 {
    const entry = spec(id) orelse return error.UnknownSkill;
    return entry.energy_cost orelse return error.MissingAutonomyEnergyCost;
}

pub fn actionAutonomyEnergyTier(id: SkillId) !u8 {
    const entry = spec(id) orelse return error.UnknownSkill;
    if (entry.autonomy_energy_cost) |tier| return tier;
    return entry.energy_cost orelse return error.MissingAutonomyEnergyCost;
}

pub fn actionPointCost(id: SkillId) !f32 {
    return autonomyPointCost(try actionEnergyTier(id));
}

pub fn actionAutonomyPointCost(id: SkillId) !f32 {
    return autonomyPointCost(try actionAutonomyEnergyTier(id));
}

pub fn autonomyPointCost(energy_tier: u8) f32 {
    if (energy_tier == 0) return 0;
    if (energy_tier == 1) return 1;
    return fibonacci(energy_tier + 1);
}

pub fn autonomyEnergyCost(id: SkillId, autonomy_mode: []const u8) !u8 {
    const entry = spec(id) orelse return error.UnknownSkill;
    if (!autonomyPolicyAllowed(entry.autonomy_policy, autonomy_mode)) return switch (entry.autonomy_policy) {
        .forbidden, .full_allowed => error.ProactiveCameraCaptureForbidden,
        .invalid => error.InvalidAutonomyAction,
        .allowed => unreachable,
    };
    return try actionAutonomyEnergyTier(id);
}

pub fn autonomyCostCatalog(allocator: std.mem.Allocator, autonomy_mode: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "planner=1");
    for (registry) |entry| {
        if (!autonomyPolicyAllowed(entry.autonomy_policy, autonomy_mode)) continue;
        const point_cost = try actionAutonomyPointCost(entry.id);
        try out.print(allocator, " {s}={d}", .{ entry.name, @as(u32, @intFromFloat(point_cost)) });
    }
    if (!std.mem.eql(u8, autonomy_mode, "full")) {
        try out.appendSlice(allocator, " host_sense_pulls=full_only");
    }
    return out.toOwnedSlice(allocator);
}

pub fn affordanceCatalog(allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (registry) |entry| {
        try out.print(allocator, "- {s}: {s}\n", .{ entry.name, entry.description });
    }
    return out.toOwnedSlice(allocator);
}

fn fibonacci(index: u8) f32 {
    var a: f32 = 1;
    var b: f32 = 1;
    var step: u8 = 2;
    while (step < index) : (step += 1) {
        const next = a + b;
        a = b;
        b = next;
    }
    return b;
}

test "autonomy point costs follow basic and fibonacci tiers" {
    try std.testing.expectEqual(@as(f32, 0), autonomyPointCost(0));
    try std.testing.expectEqual(@as(f32, 1), autonomyPointCost(1));
    try std.testing.expectEqual(@as(f32, 2), autonomyPointCost(2));
    try std.testing.expectEqual(@as(f32, 3), autonomyPointCost(3));
    try std.testing.expectEqual(@as(f32, 5), autonomyPointCost(4));
    try std.testing.expectEqual(@as(f32, 8), autonomyPointCost(5));
}

test "say costs less for autonomy than interaction" {
    try std.testing.expectEqual(@as(f32, 8), try actionPointCost(.say));
    try std.testing.expectEqual(@as(f32, 3), try actionAutonomyPointCost(.say));
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
        .{ .id = .say, .name = "say", .description = "one", .requires_skills = &.{.unknown} },
    };
    try std.testing.expectError(error.UnknownSkillDependency, validateSpecs(&entries));
}

test "skill registry rejects cyclic skill dependencies" {
    const entries = [_]SkillSpec{
        .{ .id = .say, .name = "say", .description = "one", .requires_skills = &.{.get_time} },
        .{ .id = .get_time, .name = "get_time", .description = "two", .requires_skills = &.{.say} },
    };
    try std.testing.expectError(error.CyclicSkillDependency, validateSpecs(&entries));
}

test "autonomy registry keeps host sense pulls full-only" {
    try std.testing.expect((spec(.take_picture) orelse return error.MissingSkillSpec).autonomy_policy == .full_allowed);
    try std.testing.expect((spec(.describe_image) orelse return error.MissingSkillSpec).autonomy_policy == .full_allowed);
    try std.testing.expect((spec(.compare_images) orelse return error.MissingSkillSpec).autonomy_policy == .full_allowed);
    try std.testing.expect((spec(.recognize) orelse return error.MissingSkillSpec).autonomy_policy == .full_allowed);
    try std.testing.expect((spec(.request_orientation) orelse return error.MissingSkillSpec).autonomy_policy == .full_allowed);
    try std.testing.expect(!autonomyAllowed(.take_picture, "limited"));
    try std.testing.expect(autonomyAllowed(.take_picture, "full"));
    try std.testing.expect(!autonomyAllowed(.recognize, "off"));
}
