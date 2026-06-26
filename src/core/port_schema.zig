pub const RelationshipStatus = enum { unknown, visitor, friend, creator, forgotten };
pub const GreetingStyle = enum { formal, warm, playful, quiet };
pub const EmbeddingSource = enum { enrollment, confirmed_sighting, manual_merge, local_reference };
pub const ConversationRole = enum { brain, person, system };
pub const ConversationIntent = enum { enrollment, greeting, confirmation, smalltalk, forget, @"error" };
pub const MemoryScope = enum { short_term, long_term };
pub const ImpressionSource = enum { user_speech, visual_observation, reminder, dream, command_failure, recalled_memory, self_reflection };
pub const ExperienceSource = enum { human, brain, environment, model, maintenance, autonomy, memory };
pub const ExperienceKind = enum { perception, utterance, action, command_result, failure, memory_update, appraisal, dream, self_definition, reminder, summary };
pub const ExperienceRetention = enum { raw_ephemeral, summarize, keep_episode, keep_fact, keep_disposition, discard };
pub const CognitiveTraceSource = enum { human, brain, environment, model, maintenance, autonomy, memory, visual, dream, command };
pub const CognitiveTraceKind = enum { perception, utterance, action, command_result, failure, memory_update, appraisal, dream, self_definition, reminder, summary, thought, belief_evidence };
pub const CognitiveTraceScope = enum { short_term, long_term };
pub const CognitiveStatus = enum { active, doubted, superseded, invalidated, pending_deletion };
pub const CognitiveArtifactKind = enum { image, audio, video, text, embedding, other };
pub const CognitiveRetention = enum { ephemeral, episode, durable, disposition, discard };

pub const VisualNote = struct {
    time: []const u8,
    text: []const u8,
};

pub const FaceEmbeddingRef = struct {
    embedding_id: []const u8,
    quality_score: f32,
    created_at: []const u8,
    source: EmbeddingSource,
};

pub const Person = struct {
    person_id: []const u8,
    display_name: []const u8,
    relationship_status: RelationshipStatus,
    created_at: []const u8,
    last_seen_at: ?[]const u8,
    sighting_count: u32,
    greeting_style: GreetingStyle,
    stable_notes: [][]const u8,
    recent_notes: []VisualNote,
    embeddings: []FaceEmbeddingRef,
    representative_sighting_id: ?[]const u8 = null,
    representative_image_path: ?[]const u8 = null,
    representative_quality_score: f32 = 0,
};

pub const Sighting = struct {
    sighting_id: []const u8,
    person_id: ?[]const u8,
    seen_at: []const u8,
    confidence: f32,
    image_path: ?[]const u8,
    description: ?[]const u8,
    change_summary: ?[]const u8,
    retained_until: ?[]const u8,
};

pub const ConversationEvent = struct {
    event_id: []const u8,
    person_id: ?[]const u8,
    time: []const u8,
    role: ConversationRole,
    text: []const u8,
    intent: ConversationIntent,
};

pub const ConversationSummary = struct {
    summary_id: []const u8,
    time: []const u8,
    user_summary: []const u8,
    brain_summary: []const u8,
};

pub const MemoryRecord = struct {
    memory_id: []const u8,
    scope: MemoryScope,
    text: []const u8,
    original_text: []const u8 = "",
    interpretation: []const u8 = "",
    vector: []f32 = &.{},
    confidence: f32 = 0.70,
    valence: f32 = 0.0,
    salience: f32 = 0.40,
    tags: [][]const u8,
    revisions: []MemoryRevision = &.{},
    created_at: []const u8,
    last_accessed_at: ?[]const u8,
    access_count: u32,
    score: i32 = 1,
};

pub const MemoryRevision = struct {
    time: []const u8,
    text: []const u8,
    confidence: f32,
};

pub const CognitiveLifecycle = struct {
    status: CognitiveStatus = .active,
    created_at: []const u8,
    updated_at: []const u8,
    invalidated_at: ?[]const u8 = null,
    superseded_by_id: ?[]const u8 = null,
    revisions: []MemoryRevision = &.{},
};

pub const Trace = struct {
    trace_id: []const u8,
    source: CognitiveTraceSource,
    kind: CognitiveTraceKind,
    scope: CognitiveTraceScope = .short_term,
    text: []const u8,
    interpretation: []const u8 = "",
    confidence: f32 = 0.70,
    salience: f32 = 0.40,
    valence: f32 = 0.0,
    arousal: f32 = 0.0,
    uncertainty: f32 = 0.30,
    decay: f32 = 1.0,
    access_count: u32 = 0,
    score: i32 = 1,
    vector: []f32 = &.{},
    tags: [][]const u8 = &.{},
    linked_trace_ids: [][]const u8 = &.{},
    linked_belief_ids: [][]const u8 = &.{},
    artifact_ids: [][]const u8 = &.{},
    lifecycle: CognitiveLifecycle,
};

pub const Belief = struct {
    belief_id: []const u8,
    key: []const u8,
    proposition: []const u8,
    confidence: f32 = 0.70,
    salience: f32 = 0.40,
    valence: f32 = 0.0,
    evidence_trace_ids: [][]const u8 = &.{},
    contradiction_trace_ids: [][]const u8 = &.{},
    tags: [][]const u8 = &.{},
    lifecycle: CognitiveLifecycle,
};

pub const Subject = struct {
    subject_id: []const u8,
    display_name: []const u8,
    relationship_status: RelationshipStatus = .unknown,
    greeting_style: GreetingStyle = .warm,
    trace_ids: [][]const u8 = &.{},
    belief_ids: [][]const u8 = &.{},
    artifact_ids: [][]const u8 = &.{},
    embeddings: []FaceEmbeddingRef = &.{},
    representative_artifact_id: ?[]const u8 = null,
    representative_image_path: ?[]const u8 = null,
    representative_quality_score: f32 = 0,
    lifecycle: CognitiveLifecycle,
};

pub const Artifact = struct {
    artifact_id: []const u8,
    kind: CognitiveArtifactKind,
    path: []const u8,
    mime_type: []const u8 = "",
    provenance: []const u8,
    retention: CognitiveRetention = .episode,
    linked_trace_ids: [][]const u8 = &.{},
    lifecycle: CognitiveLifecycle,
};

pub const Dream = struct {
    dream_id: []const u8,
    selected_trace_ids: [][]const u8,
    belief_change_ids: [][]const u8 = &.{},
    generated_artifact_id: ?[]const u8 = null,
    reflection: []const u8,
    heat: f32,
    promoted_count: u32 = 0,
    decayed_count: u32 = 0,
    removed_count: u32 = 0,
    revised_belief_count: u32 = 0,
    created_at: []const u8,
};

pub const CognitiveFile = struct {
    schema_version: u32 = 2,
    traces: []Trace = &.{},
    beliefs: []Belief = &.{},
    subjects: []Subject = &.{},
    artifacts: []Artifact = &.{},
    dreams: []Dream = &.{},
};

pub const FactRecord = struct {
    fact_id: []const u8,
    key: []const u8,
    value: []const u8,
    active: bool = true,
    confidence: f32 = 0.90,
    source: []const u8 = "brain",
    tags: [][]const u8 = &.{},
    revisions: []MemoryRevision = &.{},
    created_at: []const u8,
    updated_at: []const u8,
    invalidated_at: ?[]const u8 = null,
};

pub const Impression = struct {
    impression_id: []const u8,
    source: ImpressionSource,
    text: []const u8,
    tags: [][]const u8,
    created_at: []const u8,
    salience: f32 = 0.40,
};

pub const Appraisal = struct {
    appraisal_id: []const u8,
    impression_id: ?[]const u8,
    query: []const u8,
    valence: f32,
    arousal: f32,
    confidence: f32,
    uncertainty: f32,
    social_warmth: f32,
    curiosity: f32,
    stress: f32,
    feeling_label: []const u8,
    action_tendency: []const u8,
    expression: []const u8,
    dynamics: []const u8,
    freeform: []const u8,
    tags: [][]const u8,
    created_at: []const u8,
};

pub const DreamRecord = struct {
    dream_id: []const u8,
    heat: f32,
    confidence: f32,
    connection: []const u8,
    source_memory_ids: [][]const u8,
    saved_memory_id: ?[]const u8,
    created_at: []const u8,
};

pub const Experience = struct {
    experience_id: []const u8,
    time: []const u8,
    source: ExperienceSource,
    kind: ExperienceKind,
    subject: []const u8,
    raw: []const u8,
    interpretation: []const u8,
    confidence: f32 = 0.70,
    salience: f32 = 0.40,
    valence: f32 = 0.0,
    retention: ExperienceRetention = .raw_ephemeral,
    expires_at: ?[]const u8 = null,
    derived_memory_ids: [][]const u8 = &.{},
    related_experience_ids: [][]const u8 = &.{},
    tags: [][]const u8 = &.{},
};

pub const RuntimeEventKind = enum {
    command_sent,
    command_result,
    developer_log,
    user_utterance,
    brain_utterance,
    observation,
    state_change,
    memory_mutation,
    perception,
    reminder,
    @"error",
    system,
    autonomy,
    psyche,
};

pub const RuntimeEventSeverity = enum {
    debug,
    info,
    notice,
    concern,
    warning,
    critical,
};

pub const RuntimePsycheRole = enum {
    id,
    ego,
    superego,
};

pub const RuntimeEvent = struct {
    event_id: []const u8 = "",
    time: []const u8 = "",
    kind: RuntimeEventKind,
    source: []const u8 = "brain",
    title: []const u8 = "",
    body: []const u8 = "",
    command: ?[]const u8 = null,
    subject: []const u8 = "",
    raw: []const u8 = "",
    interpretation: []const u8 = "",
    developer_log_kind: ?[]const u8 = null,
    developer_log_title: ?[]const u8 = null,
    developer_log_body: ?[]const u8 = null,
    experience_source: ?ExperienceSource = null,
    experience_kind: ?ExperienceKind = null,
    experience_retention: ?ExperienceRetention = null,
    derived_memory_ids: [][]const u8 = &.{},
    created_memory_id: ?[]const u8 = null,
    forgotten_memory_id: ?[]const u8 = null,
    created_fact_id: ?[]const u8 = null,
    invalidated_fact_id: ?[]const u8 = null,
    severity: ?RuntimeEventSeverity = null,
    psyche_role: ?RuntimePsycheRole = null,
    monitor_id: ?[]const u8 = null,
    pattern_id: ?[]const u8 = null,
    confidence: f32 = 0.0,
    dedupe_key: ?[]const u8 = null,
    attention_candidate: bool = false,
    tags: [][]const u8 = &.{},
};
