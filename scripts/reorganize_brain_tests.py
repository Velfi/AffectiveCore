#!/usr/bin/env python3
"""Split numbered brain_tests_*.zig files into logically named test modules."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "src" / "core"

SOURCE_FILES = [
    CORE / "brain_tests_1.zig",
    CORE / "brain_tests_2.zig",
    CORE / "brain_tests_3.zig",
    CORE / "brain_tests_4.zig",
    CORE / "brain_tests_5.zig",
]

# Map destination filename -> ordered list of exact test names.
GROUPS: dict[str, list[str]] = {
    "brain_stimulus_tests.zig": [
        "touch records stimulus without forcing capture",
        "touch with fresh visual evidence does not force recognition",
        "touch during awaiting host records stimulus without superseding pause",
        "typed conversation includes recent touch in observations",
        "salient touch skips orchestration when chat prompt exceeds budget",
    ],
    "brain_recognition_tests.zig": [
        "recognize action identifies known person and clears awaited host request",
        "recognition observation warns when no face is detected",
        "recognition observation warns when face is present but unknown",
        "recognize skips re-identify when current frame is already in observations",
        "frontend camera pull observation completes the awaited recognition",
        "camera pull mid-conversation pauses for awaited sense without synthetic reply",
        "awaited camera observation resumes paused conversation with speech",
        "awaited camera resume stops after one say when recognize and say arrive together",
        "paused conversation resumes when visual observation arrives before next user turn",
        "stale visual observation does not resume paused conversation",
        "stale camera pause is superseded after timeout",
        "awaited visual resume reuses delivered frame when recognize is requested again",
        "awaited visual resume restores orchestration observations and framing",
        "known person gets warm greeting and sighting",
        "lower quality representative photo does not replace current best",
        "known person after long absence mentions duration",
        "weak match asks confirmation and updates existing person on yes",
        "existing name but weak match with no creates separate profile path",
        "conversation turn does not register unknown speaker",
        "conversation identity claim updates existing person after missed recognition",
        "conversation identity claim can create missing profile after confirmation",
        "remember person action creates profile from latest observed image",
        "recognition composite stores identity evidence confidence on hypothesis",
    ],
    "brain_activity_tests.zig": [
        "simple conversation turn opens and keeps activity across turns",
        "turn_complete closes and archives activity",
        "idle timeout pauses activity without archiving",
        "unrelated user message starts sibling activity and pauses prior",
        "timeline append grows across candidate action recording",
        "conversation turn awaiting host sense exposes activity id",
        "activity observation is included in orchestration prompts",
        "paused activity persists across restore",
        "conversation awaiting host sense accepts another user turn immediately",
    ],
    "brain_conversation_tests.zig": [
        "unknown conversation can register person through remember_person skill",
        "unknown person registration describes retained capture",
        "second remembered person does not replace existing creator",
        "unknown person non-name reply continues as conversation",
        "forget me action marks profile forgotten",
        "conversation turn stores summary without forcing speaker recognition",
        "conversation intent syntax error stops after appraisal",
        "plain conversation turns do not force repeated speaker recognition",
        "heard speech intake preserves full transcription provider data",
        "speech artifact sweep removes old audio and transcription json",
        "conversation continues after spoken prelude followed by memory recall",
        "conversation stops after a clarifying spoken question",
        "action batch services due reminder at interrupt point and continues",
        "action batch yields when touch stimulus arrives at interrupt point",
        "conversation idle timeout does not force speaker recognition",
        "due speech reminder reconsiders through chat loop",
        "conversation with large self facts stays within chat budget",
        "conversation skips chat when prompt exceeds budget",
        "chat action batch continues after speech",
        "conversation hard error asks for user aided recovery",
        "conversation runtime failure before chat turn completes turn",
        "empty speech recovery survives chat parse failure",
        "conversation expands process goals before executing skills",
        "conversation process goal composition records stats",
        "drowsy mode blocks conversation",
        "dreaming mode blocks conversation until host reinitialization",
        "dream request does not recover active dreaming mode",
        "dreaming mode blocks action proposal execution",
    ],
    "brain_memory_tests.zig": [
        "conversation memory avoids fixed bounded context presentation",
        "conversation memory caps available tags at thirty two",
        "conversation memory includes speaker context only when supplied",
        "dry run conversation prompt is sectioned and non mutating",
        "recalled short term memories track access and promote to long term",
        "recall ranks memories with vector similarity",
        "recall lazily indexes old vectorless memories",
        "recall with no query or tags does not access every memory",
        "recall respects explicit tag filters",
        "memory sweep decays and removes low scoring short term memories",
        "introspection summarizes memory and senses",
        "unavailable introspection records command result without forming brain memory",
        "sweep memory performs runtime event compaction as dreamtime work",
        "event readers log forget memory without making a tombstone memory",
        "memory formation reader stores eligible perception command results",
        "id monitor emits concern event to jsonl and developer log without memory by default",
        "id monitor eligible event forms memory only through memory formation reader",
        "startup seeds markdown document once as long term memories",
        "brain can revise recall and invalidate managed facts",
        "consolidation promotes salient memories and decays weak short term memories",
        "runtime memory consolidation emits consolidation chain",
        "runtime memory extraction fails loudly without extraction service",
    ],
    "brain_memory_selection_tests.zig": [
        "conversation memory selection adds relevant_memories and observation",
        "missing memory selection service fails loudly",
        "conversation memory selection skips llm ids outside candidate list",
    ],
    "brain_id_monitor_tests.zig": [
        "id monitor dedupe cooldown suppresses repeated identical concerns",
        "id monitor crash emits audit event and does not crash brain",
        "external id monitor crash emits audit event and cooldown prevents immediate retry",
        "ego and superego project warning events without forming memory",
    ],
    "brain_needs_wants_tests.zig": [
        "edit_need updates stored self need",
        "edit_want rejects need memory id",
        "want achievement reinforcement strengthens want and posts flexible identity box item",
        "want achievement reinforcement is proportional to want salience and score",
        "want achievement rejects unknown want id",
        "want achievement no match leaves memory and appraisals unchanged",
    ],
    "brain_skills_tests.zig": [
        "send email action uses configured email service",
        "skill implementation error is reported before failing loudly",
        "introspection separates available and unavailable skills",
        "affordance observation uses grouped skill library summary",
        "introspect drills into skill groups and individual skills",
        "unavailable action records reason without executing sense",
    ],
    "brain_media_upload_tests.zig": [
        "uploaded image marker is described and stored as visual observation",
        "uploaded media marker image is described and stored as visual observation",
        "frontend camera image is recorded as sensed image observation",
        "missing uploaded image reports missing file observation",
        "uploaded speech audio classification routes to transcription observation",
        "uploaded mixed audio preserves mixed classification while transcribing",
        "uploaded non speech audio suggests say instead of pretending to inspect music",
        "uploaded video reports unsupported media observation",
    ],
    "brain_image_tests.zig": [
        "uploaded image conversation does not capture or recognize speaker first",
        "describe image prefers uploaded visual observation over live camera",
        "describe image uses uploaded visual observation when live camera is unavailable",
        "missing remembered image is reported as not remembered",
        "compare image action requires stored visual observation",
        "imagine_image action calls image generation service",
        "image comparison uses previous visual observation as baseline",
    ],
    "brain_system_senses_tests.zig": [
        "get_time reports date time only",
        "get_power reports battery and plugged in state",
        "get_storage reports storage fullness only",
        "get_database_stats reports sqlite database stats only",
        "facial expression is unavailable without output",
        "facial expression shows valid sprites with default duration",
        "facial expression fails loudly for invalid sprites and long duration",
    ],
    "brain_autonomy_tests.zig": [
        "introspection reports autonomy control state",
        "autonomy first enabled poll arms interval",
        "waking autonomy starts interval without immediate planner spend",
        "autonomy tick spends control capacity for quiet action",
        "autonomy facial expression uses threshold gating without cooldown hard gate",
        "autonomy pauses while human input is active",
        "autonomy say logs chat question without forcing sleep",
        "quiet hours resolve from wall clock without process runner",
        "autonomy expands process goals before execution",
        "autonomy tick arms control state",
        "dream time request delivers mailbox item",
        "dream time persists causal belief self trust disposition and mailbox chain",
        "action pressures are proposed selected suppressed and visible in read models",
        "maintenance request_dream_time delivers mailbox through Dream Time manager",
        "unknown maintenance capability is a hard error",
        "dream time records source ids through canonical dream record",
        "registered subsystems arbitrate action pressures",
        "event backed subsystems emit concrete action pressures",
        "dream residue ignores capability failures outside waking period",
    ],
    "brain_psyche_tests.zig": [
        "appraisal allows ambivalence and structured affect",
        "feel_about can answer self-directed questions",
        "think_about reflects and saves a short term thought",
        "choose_attention prioritizes unresolved appraisal",
        "choose_attention prioritizes high intensity current stimulus",
        "choose_attention ignores stale current stimulus",
        "focus derives from a high-attention stimulus and leads the context",
        "a self-set focus overrides weaker derived attention until it decays",
        "a self-set focus decays past its TTL and re-derives",
        "unfocused mode shows the low-key line, not a focus block",
    ],
    "brain_capability_tests.zig": [
        "chat action execution records capability lifecycle",
        "host capability beliefs cite capability status events",
        "remote description service failure is a hard error",
        "exhausted remote action failure reports unable to continue thinking",
        "capability registry canonicalizes aliases and manifest statuses",
        "mailbox mark read persists read_at_ms",
        "capability result reconciles matching action outcome",
        "schema linkage round trips action outcomes and capability results",
    ],
    "brain_identity_tests.zig": [
        "identity mistake arc lowers self trust and proposes cautious disposition",
        "host change arc marks camera unavailable after detach",
        "dream arc delivers residue-derived mailbox and dream provenance belief",
        "self trust subsystem reads recognition faculty trust",
        "identity correction contradicts mistaken identity belief",
    ],
}

# Per-file import headers (after common prefix through helpers import).
HEADERS: dict[str, str] = {
    "brain_stimulus_tests.zig": """const files_mod = ports.files;
const maintenance = @import("maintenance.zig");
const interrupt_mod = @import("interrupt.zig");
const context_tokens = @import("context_tokens.zig");
const helpers = @import("brain_helpers.zig");
const activity_mod = @import("activity.zig");
""",
    "brain_recognition_tests.zig": """const files_mod = ports.files;
const maintenance = @import("maintenance.zig");
const interrupt_mod = @import("interrupt.zig");
const greeting = @import("greeting_policy.zig");
const helpers = @import("brain_helpers.zig");
const activity_mod = @import("activity.zig");
const brain_process = @import("brain_process.zig");
const read_models = @import("read_models.zig");
const recognition_composite = @import("recognition_composite.zig");
""",
    "brain_activity_tests.zig": """const maintenance = @import("maintenance.zig");
const interrupt_mod = @import("interrupt.zig");
const helpers = @import("brain_helpers.zig");
const activity_mod = @import("activity.zig");
const brain_process = @import("brain_process.zig");
const read_models = @import("read_models.zig");
""",
    "brain_conversation_tests.zig": """const files_mod = ports.files;
const maintenance = @import("maintenance.zig");
const interrupt_mod = @import("interrupt.zig");
const seed_mod = @import("seed.zig");
const facts = @import("facts.zig");
const context_tokens = @import("context_tokens.zig");
const helpers = @import("brain_helpers.zig");
const activity_mod = @import("activity.zig");
const brain_process = @import("brain_process.zig");
const process_goal_mod = ports.process_goal;
const process_goal_resolver = @import("process_goal_resolver.zig");
""",
    "brain_memory_tests.zig": """const maintenance = @import("maintenance.zig");
const id_monitor = @import("id_monitor.zig");
const interrupt_mod = @import("interrupt.zig");
const seed_mod = @import("seed.zig");
const facts = @import("facts.zig");
const vector_index = @import("vector_index.zig");
const time_mod = @import("time.zig");
const helpers = @import("brain_helpers.zig");
""",
    "brain_memory_selection_tests.zig": """const memory_selection_mod = @import("memory_selection.zig");
const helpers = @import("brain_helpers.zig");
""",
    "brain_id_monitor_tests.zig": """const id_monitor = @import("id_monitor.zig");
const helpers = @import("brain_helpers.zig");
""",
    "brain_needs_wants_tests.zig": """const facts = @import("facts.zig");
const helpers = @import("brain_helpers.zig");
const wantReinforcementStrength = helpers.wantReinforcementStrength;
""",
    "brain_skills_tests.zig": """const email_mod = ports.email;
const helpers = @import("brain_helpers.zig");
""",
    "brain_media_upload_tests.zig": """const audio_mod = ports.audio;
const helpers = @import("brain_helpers.zig");
""",
    "brain_image_tests.zig": """const image_mod = ports.image;
const helpers = @import("brain_helpers.zig");
""",
    "brain_system_senses_tests.zig": """const facial_expression = ports.facial_expression;
const helpers = @import("brain_helpers.zig");
""",
    "brain_autonomy_tests.zig": """const autonomy_mod = ports.autonomy;
const process_goal_mod = ports.process_goal;
const maintenance = @import("maintenance.zig");
const time_mod = @import("time.zig");
const brain_autonomy = @import("brain_autonomy.zig");
const process_goal_resolver = @import("process_goal_resolver.zig");
const helpers = @import("brain_helpers.zig");
const read_models = @import("read_models.zig");
const subsystems = @import("subsystems.zig");
""",
    "brain_psyche_tests.zig": """const psyche_client = ports.psyche;
const helpers = @import("brain_helpers.zig");
""",
    "brain_capability_tests.zig": """const openai = ports.openai;
const learning = @import("learning.zig");
const capability_registry = @import("capability_registry.zig");
const helpers = @import("brain_helpers.zig");
""",
    "brain_identity_tests.zig": """const maintenance = @import("maintenance.zig");
const learning = @import("learning.zig");
const belief_updates = @import("belief_updates.zig");
const subsystems = @import("subsystems.zig");
const identity = @import("identity.zig");
const helpers = @import("brain_helpers.zig");
""",
}

COMMON_PREFIX = """const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const input_mod = ports.input;

"""

COMMON_SUFFIX = """
const Brain = brain_mod.Brain;
const TestStore = store_support.TestStore;
const TestInput = support.TestInput;
const TestIdMonitor = support.TestIdMonitor;
const TestInterruptSource = support.TestInterruptSource;
const TestEventLog = support.TestEventLog;
const TestFacialExpressionOutput = support.TestFacialExpressionOutput;
const ScriptedRememberPersonChatService = support.ScriptedRememberPersonChatService;
const ScriptedIdentityClaimChatService = support.ScriptedIdentityClaimChatService;
const ScriptedForgetPersonChatService = support.ScriptedForgetPersonChatService;
const ScriptedRecallChatService = support.ScriptedRecallChatService;
const ScriptedClarificationChatService = support.ScriptedClarificationChatService;
const ScriptedHardErrorRecoveryChatService = support.ScriptedHardErrorRecoveryChatService;
const HeardSpeechObservationChatService = support.HeardSpeechObservationChatService;
const FailingIdentityClaimIntentService = support.FailingIdentityClaimIntentService;
const ScriptedContinuingChatService = support.ScriptedContinuingChatService;
const makeBrain = support.makeBrain;
const addMara = support.addMara;
const addZelda = support.addZelda;
const countOccurrences = support.countOccurrences;
const findMemoryById = helpers.findMemoryById;
const findMemoryWithTagForTest = helpers.findMemoryWithTagForTest;
const experienceEventsContain = helpers.experienceEventsContain;
const tagInSlice = helpers.tagInSlice;
const speech_artifact_ttl_seconds = brain_mod.speech_artifact_ttl_seconds;
const remote_thinking_failure_message = brain_mod.remote_thinking_failure_message;

"""

TEST_START = re.compile(r'^test "([^"]+)" \{$')


def extract_tests(source: str) -> dict[str, str]:
    lines = source.splitlines(keepends=True)
    header_end = 0
    for i, line in enumerate(lines):
        if TEST_START.match(line):
            header_end = i
            break

    tests: dict[str, str] = {}
    i = header_end
    while i < len(lines):
        match = TEST_START.match(lines[i])
        if not match:
            i += 1
            continue
        name = match.group(1)
        depth = 0
        start = i
        while i < len(lines):
            depth += lines[i].count("{") - lines[i].count("}")
            if depth == 0 and i > start:
                tests[name] = "".join(lines[start : i + 1])
                break
            i += 1
        i += 1
    return tests


def patch_source_references(body: str, dest_stem: str) -> str:
    return body.replace('"brain_tests_5"', f'"{dest_stem}"')


def main() -> int:
    all_tests: dict[str, str] = {}
    for path in SOURCE_FILES:
        content = path.read_text()
        for name, body in extract_tests(content).items():
            if name in all_tests:
                print(f"duplicate test name: {name}", file=sys.stderr)
                return 1
            all_tests[name] = body

    assigned: set[str] = set()
    for names in GROUPS.values():
        assigned.update(names)

    missing = sorted(set(all_tests) - assigned)
    extra = sorted(assigned - set(all_tests))
    if missing:
        print("unassigned tests:", file=sys.stderr)
        for name in missing:
            print(f"  - {name}", file=sys.stderr)
    if extra:
        print("unknown test names in groups:", file=sys.stderr)
        for name in extra:
            print(f"  - {name}", file=sys.stderr)
    if missing or extra:
        return 1

    for dest_name, test_names in GROUPS.items():
        dest_path = CORE / dest_name
        dest_stem = dest_path.stem
        parts = [COMMON_PREFIX, HEADERS[dest_name], COMMON_SUFFIX]
        for test_name in test_names:
            parts.append(patch_source_references(all_tests[test_name], dest_stem))
            parts.append("\n")
        dest_path.write_text("".join(parts))
        line_count = dest_path.read_text().count("\n") + 1
        print(f"wrote {dest_name}: {len(test_names)} tests, {line_count} lines")
        if line_count > 700:
            print(f"  WARNING: {dest_name} exceeds 700 lines", file=sys.stderr)

    for path in SOURCE_FILES:
        path.unlink()
        print(f"removed {path.name}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
