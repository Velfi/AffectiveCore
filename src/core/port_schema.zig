pub const RelationshipStatus = enum { unknown, visitor, friend, creator, forgotten };
pub const GreetingStyle = enum { formal, warm, playful, quiet };
pub const EmbeddingSource = enum { enrollment, confirmed_sighting, manual_merge, local_reference };
pub const ConversationRole = enum { brain, person, system };
pub const ConversationIntent = enum { enrollment, greeting, confirmation, smalltalk, forget, @"error" };
pub const MemoryScope = enum { short_term, long_term };
pub const MemoryRecordStatus = enum { candidate, tentative, active, dormant, contradicted, corrected, retracted };
pub const ImpressionSource = enum { user_speech, visual_observation, reminder, dream, capability_failure, recalled_memory, self_reflection };
pub const MemoryExperienceSource = enum { human, brain, environment, model, maintenance, autonomy, memory };
pub const MemoryExperienceKind = enum { perception, utterance, action, capability_result, failure, memory_update, appraisal, dream, self_definition, reminder, summary };
pub const MemoryExperienceRetention = enum { raw_ephemeral, summarize, keep_episode, keep_fact, keep_disposition, discard };
pub const CognitiveStatus = enum { active, doubted, invalidated, pending_deletion };
pub const CognitiveArtifactKind = enum { image, audio, video, text, embedding, other };
pub const CognitiveRetention = enum { ephemeral, episode, durable, disposition, discard };

pub const CognitivePruneResult = struct {
    tombstoned: usize = 0,
    purged: usize = 0,
};

pub const ExperienceEventSource = enum { user, host, sense, subsystem, capability, memory, autonomy, dream_time, system };
pub const ExperienceEventRetention = enum { ephemeral, episode, durable, disposition, discard };
pub const ExperienceEventVisibility = enum { internal, host, developer, private };
pub const BrainMode = enum { waking, drowsy, dreaming, waking_up, unavailable };
pub const CapabilityPermission = enum { unknown, granted, denied, prompt_required, not_required };
pub const CapabilityAvailability = enum { available, degraded, unavailable, refused };
pub const CapabilityRequestState = enum { requested, started, completed, failed, unavailable, refused };
pub const MailboxItemKind = enum { DreamMail, WakingThought, MemoryQuestion, MaintenanceNotice, RelationshipNote, UnresolvedConcern };
pub const IdentityDecision = enum { unknown, familiar, suspected, soft_matched, recognized, misrecognized, corrected, confirmed, forgotten, conflict };

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
    source_event_ids: [][]const u8 = &.{},
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
    status: MemoryRecordStatus = .active,
    source_event_ids: [][]const u8 = &.{},
    entities: [][]const u8 = &.{},
    outcome: []const u8 = "",
    prediction_error: f32 = 0.0,
    reinforcement_value: f32 = 0.0,
    internal_synthesis: bool = false,
    scope: MemoryScope,
    text: []const u8,
    original_text: []const u8 = "",
    interpretation: []const u8 = "",
    context_snippet: []const u8 = "",
    fulfillment_criterion: []const u8 = "",
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
    pending_deletion_at: ?[]const u8 = null,
    pending_deletion_reason: ?[]const u8 = null,
    pending_deletion_source: ?[]const u8 = null,
    revisions: []MemoryRevision = &.{},
};

pub const Belief = struct {
    belief_id: []const u8,
    evidence_event_ids: [][]const u8 = &.{},
    counterevidence_event_ids: [][]const u8 = &.{},
    context: []const u8 = "",
    decay: f32 = 1.0,
    provenance: []const u8 = "",
    key: []const u8,
    proposition: []const u8,
    confidence: f32 = 0.70,
    salience: f32 = 0.40,
    valence: f32 = 0.0,
    tags: [][]const u8 = &.{},
    lifecycle: CognitiveLifecycle,
};

pub const Subject = struct {
    subject_id: []const u8,
    display_name: []const u8,
    relationship_status: RelationshipStatus = .unknown,
    greeting_style: GreetingStyle = .warm,
    source_event_ids: [][]const u8 = &.{},
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
    source_event_ids: [][]const u8 = &.{},
    lifecycle: CognitiveLifecycle,
};

pub const ExperienceEvent = struct {
    id: []const u8,
    brain_id: []const u8 = "default",
    host_id: []const u8 = "",
    timestamp_ms: i64,
    source: ExperienceEventSource,
    kind: []const u8,
    payload: []const u8 = "",
    salience: f32 = 0.40,
    confidence: f32 = 0.70,
    valence: f32 = 0.0,
    arousal: f32 = 0.0,
    uncertainty: f32 = 0.30,
    causal_parent_ids: [][]const u8 = &.{},
    retention: ExperienceEventRetention = .episode,
    visibility: ExperienceEventVisibility = .internal,
};

pub const HostBinding = struct {
    host_id: []const u8,
    platform: []const u8 = "",
    app_version: []const u8 = "",
    attached_at_ms: i64,
    permissions: [][]const u8 = &.{},
    capability_ids: [][]const u8 = &.{},
    provider_availability: []const u8 = "",
    sensor_quality: []const u8 = "",
    local_policy: []const u8 = "",
};

pub const CapabilityStatus = struct {
    capability_id: []const u8,
    host_id: []const u8 = "",
    permission: CapabilityPermission = .unknown,
    availability: CapabilityAvailability = .unavailable,
    quality: f32 = 0.0,
    reliability: f32 = 0.0,
    cost: f32 = 0.0,
    latency_ms: u32 = 0,
    risk: f32 = 0.0,
    unavailable_reason: []const u8 = "",
    updated_at_ms: i64 = 0,
};

pub const CapabilityRequest = struct {
    request_id: []const u8,
    capability_id: []const u8,
    host_id: []const u8 = "",
    state: CapabilityRequestState = .requested,
    input: []const u8 = "",
    causal_parent_ids: [][]const u8 = &.{},
    created_at_ms: i64,
};

pub const CapabilityResult = struct {
    request_id: []const u8,
    capability_id: []const u8,
    host_id: []const u8 = "",
    state: CapabilityRequestState,
    output: []const u8 = "",
    error_message: []const u8 = "",
    outcome_event_id: []const u8 = "",
    pressure_id: []const u8 = "",
    outcome_id: []const u8 = "",
    completed_at_ms: i64,
};

pub const IdentityEvidence = struct {
    strategy_id: []const u8,
    candidate_person_id: []const u8 = "",
    score: f32 = 0.0,
    confidence: f32 = 0.0,
    supports_identity: bool = false,
    contradicts_identity: bool = false,
    explanation: []const u8 = "",
    source_event_ids: [][]const u8 = &.{},
};

pub const SelfTrustEntry = struct {
    self_trust_id: []const u8,
    faculty: []const u8,
    context_pattern: []const u8 = "",
    confidence: f32 = 0.50,
    evidence_event_ids: [][]const u8 = &.{},
    counterevidence_event_ids: [][]const u8 = &.{},
    updated_at_ms: i64,
};

pub const Disposition = struct {
    disposition_id: []const u8,
    context_pattern: []const u8,
    action_tendency: []const u8,
    strength: f32 = 0.50,
    source_event_ids: [][]const u8 = &.{},
    source_dream_ids: [][]const u8 = &.{},
    updated_at_ms: i64,
};

pub const ActionPressure = struct {
    pressure_id: []const u8,
    subsystem: []const u8,
    proposed_action: []const u8,
    capability_id: []const u8 = "",
    rationale: []const u8 = "",
    strength: f32 = 0.50,
    urgency: f32 = 0.50,
    valence: f32 = 0.0,
    risk: f32 = 0.0,
    causal_parent_ids: [][]const u8 = &.{},
    created_at_ms: i64,
    expires_at_ms: ?i64 = null,
};

pub const ActionOutcome = struct {
    outcome_id: []const u8,
    pressure_id: []const u8 = "",
    capability_request_id: []const u8 = "",
    capability_result_id: []const u8 = "",
    selected_action: []const u8 = "",
    suppressed: bool = false,
    executed: bool = false,
    result_event_id: []const u8 = "",
    source_event_ids: [][]const u8 = &.{},
    prediction_error: f32 = 0.0,
    reinforcement_value: f32 = 0.0,
    created_at_ms: i64,
};

pub const DreamImageSpec = struct {
    subject: []const u8 = "",
    setting: []const u8 = "",
    symbols: [][]const u8 = &.{},
    mood: []const u8 = "",
    visual_style: []const u8 = "",
    avoid: [][]const u8 = &.{},
};

pub const DreamTimeRecord = struct {
    dream_id: []const u8,
    source_event_ids: [][]const u8 = &.{},
    source_memory_ids: [][]const u8 = &.{},
    updated_belief_ids: [][]const u8 = &.{},
    self_trust_change_ids: [][]const u8 = &.{},
    disposition_change_ids: [][]const u8 = &.{},
    maintenance_counts_json: []const u8 = "{}",
    generated_artifact_id: ?[]const u8 = null,
    delivered_mailbox_id: ?[]const u8 = null,
    title: []const u8,
    text: []const u8,
    waking_thought: []const u8 = "",
    persona: []const u8 = "",
    short_term: []const u8 = "",
    long_term: []const u8 = "",
    image_spec: DreamImageSpec = .{},
    created_at_ms: i64,
};

pub const MailboxItem = struct {
    mailbox_id: []const u8,
    kind: MailboxItemKind,
    title: []const u8,
    text: []const u8,
    image_artifact_id: ?[]const u8 = null,
    image_spec_json: []const u8 = "",
    waking_thought: []const u8 = "",
    visible_lesson: []const u8 = "",
    debug_details: []const u8 = "",
    source_event_ids: [][]const u8 = &.{},
    source_dream_id: ?[]const u8 = null,
    created_at_ms: i64,
    read_at_ms: ?i64 = null,
};

pub const IdentityHypothesis = struct {
    hypothesis_id: []const u8,
    decision: IdentityDecision,
    candidates_json: []const u8 = "[]",
    evidence_event_ids: [][]const u8 = &.{},
    confidence: f32 = 0.0,
    contradictions: [][]const u8 = &.{},
    provenance: []const u8 = "",
    created_at_ms: i64,
};

pub const ActivityKind = enum {
    conversation,
    research,
    navigation,
    waiting,
    planning,
    maintenance,
    generic,
};

pub const ActivityStatus = enum {
    active,
    paused,
    blocked,
    complete,
    abandoned,
};

pub const ActivityTimelineEvent = struct {
    at_ms: i64,
    kind: []const u8,
    title: []const u8,
    body: []const u8,
    source_event_id: ?[]const u8 = null,
};

pub const ActivityCandidateAction = struct {
    action: []const u8,
    rationale: []const u8,
    strength: f32 = 0,
};

pub const ActivityCheckpoint = struct {
    anchor_text: []const u8,
    heard_speech_text: []const u8,
    heard_speech_source: []const u8,
    observations: []const u8,
    memory: []const u8,
    spoken_text: []const u8,
    paused_at_ms: i64,
};

pub const ActivityRecord = struct {
    id: []const u8,
    parent_id: ?[]const u8 = null,
    kind: ActivityKind,
    kind_label: []const u8,
    status: ActivityStatus,
    goal: []const u8,
    summary: []const u8,
    started_at_ms: i64,
    updated_at_ms: i64,
    paused_at_ms: ?i64 = null,
    completed_at_ms: ?i64 = null,
    originating_request_id: []const u8,
    interpretation: []const u8,
    focus_text: ?[]const u8 = null,
    stimulus_text: ?[]const u8 = null,
    last_spoken_text: ?[]const u8 = null,
    waiting_kind: ?[]const u8 = null,
    waiting_intent: ?[]const u8 = null,
    waiting_since_ms: ?i64 = null,
    awaiting: ?[]const u8 = null,
    timeline: []ActivityTimelineEvent = &.{},
    candidate_actions: []ActivityCandidateAction = &.{},
    checkpoint: ?ActivityCheckpoint = null,
    awaited_host_request_id: ?[]const u8 = null,
    awaited_host_sense: ?[]const u8 = null,
    awaited_host_purpose: ?[]const u8 = null,
    deferred_heard_speech_text: ?[]const u8 = null,
    close_reason: ?[]const u8 = null,
};

pub const CognitiveFile = struct {
    schema_version: u32 = 1,
    brain_id: []const u8 = "default",
    brain_mode: BrainMode = .waking,
    events: []ExperienceEvent = &.{},
    host_bindings: []HostBinding = &.{},
    capability_statuses: []CapabilityStatus = &.{},
    capability_requests: []CapabilityRequest = &.{},
    capability_results: []CapabilityResult = &.{},
    self_trust: []SelfTrustEntry = &.{},
    dispositions: []Disposition = &.{},
    action_pressures: []ActionPressure = &.{},
    action_outcomes: []ActionOutcome = &.{},
    dream_time_records: []DreamTimeRecord = &.{},
    mailbox_items: []MailboxItem = &.{},
    identity_hypotheses: []IdentityHypothesis = &.{},
    memories: []MemoryRecord = &.{},
    impressions: []Impression = &.{},
    appraisals: []Appraisal = &.{},
    conversation_summaries: []ConversationSummary = &.{},
    sightings: []Sighting = &.{},
    beliefs: []Belief = &.{},
    subjects: []Subject = &.{},
    artifacts: []Artifact = &.{},
    active_activity: ?ActivityRecord = null,
    activity_stack: []ActivityRecord = &.{},
    activity_history: []ActivityRecord = &.{},
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

pub const ExperienceLogKind = enum {
    capability_requested,
    capability_result,
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

pub const ExperienceLogSeverity = enum {
    debug,
    info,
    notice,
    concern,
    warning,
    critical,
};

pub const PsycheRole = enum {
    id,
    ego,
    superego,
};

pub const ExperienceLogEvent = struct {
    event_id: []const u8 = "",
    time: []const u8 = "",
    kind: ExperienceLogKind,
    source: []const u8 = "brain",
    title: []const u8 = "",
    body: []const u8 = "",
    action: ?[]const u8 = null,
    subject: []const u8 = "",
    raw: []const u8 = "",
    interpretation: []const u8 = "",
    developer_log_kind: ?[]const u8 = null,
    developer_log_title: ?[]const u8 = null,
    developer_log_body: ?[]const u8 = null,
    experience_source: ?MemoryExperienceSource = null,
    experience_kind: ?MemoryExperienceKind = null,
    experience_retention: ?MemoryExperienceRetention = null,
    derived_memory_ids: [][]const u8 = &.{},
    created_memory_id: ?[]const u8 = null,
    forgotten_memory_id: ?[]const u8 = null,
    created_fact_id: ?[]const u8 = null,
    invalidated_fact_id: ?[]const u8 = null,
    severity: ?ExperienceLogSeverity = null,
    psyche_role: ?PsycheRole = null,
    monitor_id: ?[]const u8 = null,
    pattern_id: ?[]const u8 = null,
    confidence: f32 = 0.0,
    dedupe_key: ?[]const u8 = null,
    attention_candidate: bool = false,
    tags: [][]const u8 = &.{},
};
