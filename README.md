# AffectiveCore

Prototype Zig implementation of an AI-enabled face-memory brain. This repo now contains the reusable core plus headless/API helpers:

- `affective-core-mcp`: stdio MCP server for memory, reminders, and inner-life tools.
- `affective-core-api-health`: live provider routing check for configured LLM APIs.
- `affective-core-api-e2e`: live contract check for LLM and image APIs.

Host applications live in sibling projects that depend on this core module:

- `../AffectiveWebview`: macOS/WebKit host with webcam, typed input, hold-to-speak, facial expression assets, and Apple UI bridge code.
- `../AffectiveRadxa`: Radxa Zero 3 / aarch64 Linux host using `rpicam-still`, GPIO, and command-based audio playback.

## Required deps

- [Zig](https://ziglang.org/download/) 0.16.0 or compatible to build and test the project.
- A POSIX shell for the fixture test scripts in `scripts/`.
- Real local face recognition uses the repo-local `tools/affective-face-recognizer` command. The recognizer is an OpenCV DNN pipeline with OpenCV Zoo YuNet and SFace int8 ONNX models at `models/face_detection_yunet_2023mar_int8.onnx` and `models/face_recognition_sface_2021dec_int8.onnx`.
- Descriptive identity recognition uses the random provider client for person descriptions and final identity comparison, plus the brain's local vector index for candidate filtering.

The macOS WebView host also needs:

- [ffmpeg](https://ffmpeg.org/download.html) for webcam capture and microphone recording.
- `say` and `afplay`, which are included with macOS, for Speak & Spell-style speech.
- The bundled [whisper.cpp](https://github.com/ggerganov/whisper.cpp) `tools/whisper.cpp-v1.9.1-bin/whisper-cli` plus a model at `models/ggml-base.en.bin` when using the macOS webview, which supports hold-to-speak.

The Radxa Zero 3 host also needs:

- [`rpicam-still`](https://www.raspberrypi.com/documentation/computers/camera_software.html#rpicam-apps) for camera capture.
- [`gpioget`](https://libgpiod.readthedocs.io/) from libgpiod for the hardware button.
- OpenCV with DNN/ONNX support for the `affective-face-recognizer` helper when running `--recognition command`.
- [ffmpeg](https://ffmpeg.org/download.html) with ALSA support for voice transcription.
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) `whisper-cli` plus a model at `models/ggml-base.en.bin` when using `--transcription voice`.
- An audio player such as `aplay` from [ALSA](https://www.alsa-project.org/wiki/Main_Page), or [mpg123](https://mpg123.de/) passed with `--speaker-command mpg123`.

Random-provider AI modes require [curl](https://curl.se/download.html) and at least one configured provider key: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `GEMINI_API_KEY`/`GOOGLE_API_KEY`. Nano Banana image generation uses the Gemini API and requires `GEMINI_API_KEY`, `GOOGLE_API_KEY`, or `GOOGLE_AI_API_KEY`.

Email delivery uses `curl` with SMTP. Enable the chat `send_email` skill by copying `data/email.example.json` to `data/email.json` and filling in `smtp_url`, `from`, and, when the SMTP server requires auth, `username` and `password`. The real `data/email.json` file is local-only because it may contain credentials. Missing SMTP settings in that file, invalid addresses, empty bodies, and nonzero `curl` exits are hard errors.

```sh
cp data/email.example.json data/email.json
zig build
```

## Run

```sh
zig build
zig build test
zig build lint-module-size
zig build reinit-brain
```

Build and run the host projects from their own directories:

```sh
cd ../AffectiveWebview && zig build run
cd ../AffectiveRadxa && zig build radxa
```

`zig build lint-module-size` checks Zig modules under `src/` against a 700-line default limit and prints the top 5 largest modules. Pass tool args after `--`, for example `zig build lint-module-size -- --max-lines 800 --top 10`.

## Adding a skill

Skills are declared in `src/api/skills.zig`. That registry is the canonical source of truth for a skill's public name, description, dependencies, autonomy policy, energy cost, and failure guidance. `src/api/chat_client.zig` re-exports the registry types so older call sites can keep using `ChatCommandType`, `Capability`, and `CapabilitySet`.

Checklist for a new skill:

- Add one `SkillId` enum value and one matching `SkillSpec` registry entry. The `name` must exactly match the enum tag.
- Use `requires_senses` for host/runtime resources the skill directly needs, such as camera, memory read/write, stored image, system senses, speech, reminder I/O, image generation, face picture updates, email delivery, or local process I/O.
- Use `requires_skills` when a skill is conceptually built on another skill. Dependency resolution is recursive, so a missing dependency hides the dependent skill too.
- Add the execution handler in `Brain.executeCommands` and tests for success, unavailable dependencies, and implementation failure.
- Choose an `autonomy_policy`: `allowed` requires an `energy_cost`, `forbidden` is reserved for skills autonomy must never choose, and `invalid` keeps a skill out of autonomous planning.
- Add an MCP mapping only when the skill should also be callable as an external MCP tool. MCP-only tools may stay separate, but shared descriptions should come from the skill registry when they map directly to brain skills.

The brain only advertises skills that are callable in the current host/runtime state. If a stale or unavailable skill is requested anyway, the observation is `skill_failed: <skill>: unavailable: <reason>` with the registry failure hint when available. If a callable skill's implementation fails, the failure is logged as `skill_failed` and the Zig error still propagates; there are no fallback implementations.

Press Enter to simulate a local activation. Type `quit` at the activation prompt to exit, or `forget me` when asked a name to exercise the terminal forget path.

On macOS, runtime brain state is brain-scoped outside the repo. A brain is a transferable container for a being's experiences. Persistent state lives under `~/Library/Application Support/AffectiveCore/brains/<brain>/`, including `memory/people.sqlite`, `memory/relationships.sqlite`, event logs, maintenance files, runtime options, embeddings, promoted captures, and generated images. Transient capture and audio scratch files live under `$TMPDIR/affective-core/brains/<brain>/`.

Webcam frames and dropped images start in scratch storage. The brain promotes a photo into the active brain only when it becomes important enough to keep, such as a retained sighting or the representative photo for a person.

Use `--brain <name>` to run separate beings on the same machine. Brain names may contain letters, numbers, `_`, and `-`. `--profile <name>` is still accepted as a legacy alias for `--brain <name>`.

Brains can be exported and imported only as local frontend-managed brain files. A brain file is one zlib-compressed container holding the brain root's databases, logs, maintenance files, captures, generated assets, and brain-specific config. Host capabilities and credentials, such as email delivery settings, stay with the host adapter and are not part of a transferable brain. Safe inspection reports only manifest metadata: brain id, format version, compression, component paths, byte sizes, and totals. It does not dump memory contents or embedded settings.

Config files under `data/` are documented in `data/README.md`.

Seed documents live in `data/seeds`. `data/seeds/default.md` is loaded at startup by default, and `data/seeds/TEMPLATE.md` is the starting point for authoring additional seed orientations. Use `## Core Values` for durable values, `## Operating Tendencies` for default behavior, and `## Wants` for long-term goals that should start as durable self-wants. Pass `--seed path/to/seed.md` to choose another seed.

Use `zig build reinit-brain` to clear persisted brain memory, relationship graph data, event logs, reminders, runtime preferences, captured images, generated images, and generated audio for the default brain. It preserves fixture images and generated fixture-test files under `data/test`; pass `--brain <name>` to clear a different brain, and pass `--include-test` to clear generated test JSON/log files too:

```sh
zig build reinit-brain -- --include-test
zig build reinit-brain -- --brain ada
```

## Fixed photo test

Use `scripts/test_fixed_photo.sh` to run one deterministic interaction against a single fixture image. It writes to `data/test` so normal memory is not touched.

```sh
sh scripts/test_fixed_photo.sh fixtures/visitors/unknown_01.jpg Zelda
```

Use the two-pass version to enroll `data/test/image.png` as Obi Wan Kenobi and immediately test recognition from the saved test memory:

```sh
sh scripts/test_fixed_photo_recognition.sh
```

Use the changed-photo version to enroll `data/test/image.png`, then recognize `data/test/image2.png` as the same person and include a scripted visual difference in the greeting:

```sh
sh scripts/test_fixed_photo_change.sh
```

## Targets

Host-specific targets moved out of this repo. Build macOS/WebView from `../AffectiveWebview` and Radxa from `../AffectiveRadxa`.

The app passes the active brain's memory and embedding paths to the recognizer. On macOS those default to `~/Library/Application Support/AffectiveCore/brains/<brain>/memory/people.sqlite` and `~/Library/Application Support/AffectiveCore/brains/<brain>/memory/face_embeddings`; for the headless MCP server, the checked-in defaults are under `data/brains/default/`. The recognizer command shape is:

```sh
tools/affective-face-recognizer identify \
  --image /path/to/capture.jpg \
  --memory /path/to/brain/memory/people.sqlite \
  --embeddings-dir /path/to/brain/memory/face_embeddings \
  --detector models/face_detection_yunet_2023mar_int8.onnx \
  --recognizer models/face_recognition_sface_2021dec_int8.onnx \
  --known-threshold 0.8500 \
  --uncertain-threshold 0.6000
```

It must print one JSON object with `person_present`, `match_status`, `confidence`, and `people_count`; `known` results must include `person_id`. Optional fields include `candidate_name` and recognizer-specific diagnostics.

To replace a stored face recognition picture for an existing person, use the same helper's `enroll` command. This validates that the new image contains exactly one face, replaces that person's cached `.npy` embeddings, and updates the person's `representative_image_path` in the active brain's `memory/people.sqlite`:

```sh
tools/affective-face-recognizer enroll \
  --image /path/to/new_reference.jpg \
  --memory /path/to/brain/memory/people.sqlite \
  --embeddings-dir /path/to/brain/memory/face_embeddings \
  --detector models/face_detection_yunet_2023mar_int8.onnx \
  --recognizer models/face_recognition_sface_2021dec_int8.onnx \
  --person-id person_1782236784
```

You can use `--name Zelda` instead of `--person-id` when the display name is unique. If you want to add the picture beside existing cached embeddings instead of replacing them, pass `--keep-existing`.

For a lighter-weight recognizer that does not run a face embedding model, use the descriptive recognizer. It captures a fresh image, asks the random-provider description service for non-sensitive visible person details, vector-searches stored profile and sighting descriptions, then asks the random-provider identity comparison service for a final same-person decision and confidence rating. Missing API keys, unsupported image types, malformed JSON, and invalid confidence scores are hard errors.

Host binaries can enable descriptive recognition with `--recognition descriptive --description random --identity-comparison random --identity-comparison-model gpt-4.1-nano`.

The hardware brain is activated by a single GPIO button. A tap pokes the brain through the face-memory and registration flow. A hold starts a speech conversation with one recognition attempt at the beginning, records until release, then the brain responds and stores a compact conversation summary:

The Radxa host exposes its GPIO, transcription, speech, and speaker flags from `../AffectiveRadxa`.

Conversation-provider rotation lives in `data/llm_providers.json`. Set `"mode": "random"` and list equivalent-strength provider/model pairs there; each speech-turn LLM call samples one available provider from that list. Providers without a matching API key are skipped, so a partial local setup still runs.

```json
{
  "mode": "random",
  "reasoning_effort": "auto",
  "models": [
    { "provider": "openai", "model": "gpt-4.1-nano" },
    { "provider": "anthropic", "model": "claude-haiku-4-5-20251001" },
    { "provider": "google", "model": "gemini-3.1-flash-lite" }
  ]
}
```

The random mode reads `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `GEMINI_API_KEY` or `GOOGLE_API_KEY`.

Run the provider route health check when changing provider models, API keys, or endpoint code:

```sh
zig build api-health
```

This loads `data/llm_providers.json` and sends a tiny text request to every configured conversation and psyche provider/model pair. Missing keys, rejected model names, wrong routes, non-JSON provider responses, and unexpected response shapes fail the command.

Run the heavier live API contract suite when changing request/response envelope code:

```sh
zig build api-e2e
```

This exercises every configured random-provider conversation model with both text JSON and vision JSON requests, runs the route health check above, and performs a Gemini image generation call. It requires `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `GEMINI_API_KEY` or `GOOGLE_API_KEY` for the configured providers, and it fails loudly on missing keys, rejected envelopes, malformed JSON, wrong forced-tool output, empty route responses, or missing generated image files.

Talk-only LLM turns use a small command envelope so behavior can emerge from the brain's available skills instead of from a long list of behavioral instructions. The brain is treated as a situated being with senses, memory, uncertainty, and continuity; the standing prompt only includes the bootstrap commands needed to speak or request introspection. When the brain chooses `introspect`, the runtime generates the current skill catalog from the command enum and returns it as an observation.

Hosts can send dropped uploads as uploaded media observations. PNG, JPEG, and WebP files use the configured visual description service and become the latest stored visual observation. Audio uploads are classified before they are treated as speech when the host provides an audio inspection service; there is no fallback music, ambient audio, animation, or video analyzer.

The brain can also choose `imagine_image` when it wants to create a new imagined image. That command sends the command `text` as a Nano Banana prompt through Gemini's `generateContent` API, using `--image-generation-model` (default `gemini-3.1-flash-image`) and writing the result under `--image-generation-output-dir` (default `generated/images` inside the active brain root). Missing API keys, empty prompts, curl failures, and unexpected image responses are returned as hard errors.

With reasoning-capable OpenAI conversation models, the brain can also choose how much reasoning effort to spend on the next model call. Set an initial value with `reasoning_effort` in `data/llm_providers.json`, or with `--conversation-reasoning-effort low|medium|high`; leave it as `auto` to omit the API knob until the model requests one. The chat envelope's top-level `reasoning_effort` is carried forward for later calls in the same conversation loop and subsequent turns. The runtime only sends `reasoning_effort` for models that look reasoning-capable, such as `o*` and `gpt-5*`, so existing `gpt-4.1-nano` setups keep their current API shape.

The envelope shape is:

```json
{
  "commands": [
    { "command": "say", "text": "I can do that." },
    { "command": "introspect" }
  ],
  "user_summary": "Tiny summary of what the user said.",
  "brain_summary": "Tiny summary of what the brain did or said.",
  "reasoning_effort": "medium"
}
```

If the model chooses an observation command such as `introspect`, `recognize`, `take_picture`, `describe_image`, `compare_images`, `get_time`, `get_power`, `get_storage`, `get_database_stats`, or `think_about`, the brain executes it, sends the observation back to the model, and waits for the next natural command. `recognize` is the brain's identity-recognition skill for seeing who it is talking to; it captures a fresh image and returns current speaker recognition status as an observation. `describe_image` captures a fresh image and returns a written description. `compare_images` compares the latest stored visual observation with a fresh capture; if there is no previous image, it returns a hard error. `get_time` returns the current date/time only. `get_power` reads platform power status, including battery percentage and whether external power is plugged in. `get_storage` reports mounted filesystem fullness. `get_database_stats` reports SQLite page, freelist, size, and table counts for the memory databases. `think_about` accepts `query` or `text` plus optional tags; it recalls relevant memory, appraises the topic, may use model judgment for hard-to-quantify questions, and saves a short-term reflection before the next model pass. `ask_human` is reserved for asking the nearby human for help, clarification, or permission.

`update_face_picture` updates an existing face profile's command-recognizer reference image. It accepts `person_id` or unique `name`, optional `image_path`, and optional `keep_existing`. If `image_path` is omitted, the brain uses the latest uploaded or observed image. The command delegates to `tools/affective-face-recognizer enroll`, so missing files, duplicate names, no face, multiple faces, and invalid embeddings fail loudly.

General memories are separate from face profiles. They are taggable and start as short-term reconstructive records with score `1`, confidence, valence, salience, original text, current interpretation, and revision history. Recalling a memory increments its access count, raises score by `2`, records a small reconstruction revision, and may promote a short-term memory to long-term after three accesses or score `5`. A `sweep_memory` command decays each short-term memory score by `1` and removes short-term memories whose score reaches `0`. The brain can define durable self-needs and self-wants with `define_need` and `define_want`; seed markdown can also define startup self-wants under `## Wants` and Superego constraints under `## Superego Principles`. Introspection lists their memory ids under `self_needs_and_wants`, and `edit_need` / `edit_want` revise a matching stored self-definition by `memory_id`.

Long-term memory is retrieved on demand rather than inserted wholesale into every prompt. The first-pass conversation context is a working-state index, not a full memory dump: self facts, relationship graph summary, active needs, memory counts, up to 32 available tags, and up to 8 recent conversation summaries. The model should call `recall_memory` with a task-specific `query`, `tags`, or both, and only the matching memory records are returned as observations. This keeps stale or off-topic memories from crowding the context window; oversized rendered chat prompts fail loudly with `ContextBudgetExceeded` instead of being silently truncated or compacted. Use the MCP `chat_dry_run_prompt` tool to inspect the exact system and user prompt that would be sent without mutating memory. Memory records include a persisted local vector, so recall ranks by cosine similarity plus small lexical, tag, salience, and durability boosts. Older memories without vectors are indexed lazily the next time they are saved or recalled.

The inner-life system also persists raw impressions, structured appraisals, and dream records. Appraisals track valence, arousal, confidence, uncertainty, social warmth, curiosity, stress, feeling label, action tendency, expression style, dynamics, and a freeform "how this lands" note, including ambivalence. The emotion model follows a component view: appraisal, bodily arousal, action tendency, expression, subjective feeling, and update dynamics are represented separately. Dreams always roll a random heat value from `0.0` to `1.0`; optional `heat_bias` only nudges the range toward grounded or surreal. Low heat dreams are grounded replay, medium heat dreams are associative synthesis, and high heat dreams are more surreal, lower-confidence, and provisional.

Autonomy uses an Id/Ego/Superego deliberation layer when `--psyche on` is active, which is the default for autonomy. The Id and Superego run as two separate cheap-model calls over the same compact state: ranked needs, recent impressions/appraisals, salient memories, energy, quiet-hour status, autonomy skills, and seeded Superego principles. They drink from the same firehose, but may assign different salience, causes, and meanings to the same stimulus. Id acts as the short-term planning and consequence simulator, prioritizing near-term needs, urges, friction, opportunities, risks, curiosity, discomfort, and associative thoughts. Superego acts as the long-term planning and consequence simulator, prioritizing values, restraint, identity continuity, promises, user dignity, memory honesty, quiet hours, power, safety boundaries, and uncertainty about how conditions may change. Seeded `Superego Principles` remain compatible as long-term and big-goal inputs rather than brittle commands. The existing autonomy planner is the Ego: it receives both voices, compares their interpretations and priorities, and chooses exactly one command. Runtime gates still hard-block forbidden actions such as proactive camera capture.

Configure the psyche models independently with `--psyche-models openai:gpt-4.1-nano,anthropic:claude-haiku-4-5-20251001,google:gemini-3.1-flash-lite --psyche-reasoning-effort low` on the host runtime.

`data/llm_providers.json` also supports `psyche_models` and `psyche_reasoning_effort`. Invalid provider specs, unavailable API keys for all configured psyche providers, malformed model JSON, and invalid psyche outputs are hard errors.

Maintenance and reminders live in a simple Markdown file under the active brain root. The headless MCP server defaults to `data/brains/default/maintenance.md`; host projects can choose their own brain roots. Supported lines include:

```md
- every 6 hours run sweep_memory
- every day at 03:00 run consolidate_memory
- every day at 03:15 run dream
- every day at 09:00 run say:Check the plants.
- at unix 1782255000 run say:Check the tea.
```

The brain can add reminders itself with `set_reminder`; this appends a `say:` task to the maintenance schedule. For wait timers, use relative schedules such as `in 10 seconds`, `in 5 minutes`, `after 2 hours`, or `in 1 day`; these are stored as one-shot `at unix ...` tasks. Due tasks are tracked in `data/maintenance_state.json` so recurring tasks run once per scheduled window and one-shot timers run once.

`introspect` returns a compact observation about the brain's available senses, skills, memory counts, scores, access totals, recent appraisals, impressions, and dream/consolidation activity. `dream` loosely connects stored memories with recent conversation summaries; if the model includes `text`, the brain stores that text as a short-term provisional dream/reflection memory.

## MCP server

The brain also includes a small stdio MCP server so other LLM clients can talk to its memory and reminder system:

```sh
zig build mcp
./zig-out/bin/affective-core-mcp
```

The MCP server defaults to `data/brains/default` for headless local state. It also accepts explicit brain and storage paths:

```sh
./zig-out/bin/affective-core-mcp \
  --brain default \
  --brain-root data/brains/default \
  --memory-path data/brains/default/memory/people.sqlite \
  --graph-path data/brains/default/memory/relationships.sqlite \
  --schedule-path data/brains/default/maintenance.md \
  --events-path data/brains/default/events.jsonl \
  --recognition-command tools/affective-face-recognizer \
  --face-detector-model models/face_detection_yunet_2023mar_int8.onnx \
  --face-recognition-model models/face_recognition_sface_2021dec_int8.onnx \
  --face-embeddings-dir data/brains/default/memory/face_embeddings
```

Example MCP client configuration:

```json
{
  "mcpServers": {
    "affective-core": {
      "command": "/Users/zelda/Documents/AffectiveCore/zig-out/bin/affective-core-mcp",
      "args": [
        "--memory-path",
        "data/brains/default/memory/people.sqlite",
        "--graph-path",
        "data/brains/default/memory/relationships.sqlite",
        "--schedule-path",
        "data/brains/default/maintenance.md"
      ]
    }
  }
}
```

Exposed MCP tools:

- `brain_inspect`
- `chat_dry_run_prompt`
- `memory_index`
- `recall_memory`
- `remember_memory`
- `forget_memory`
- `sweep_memory`
- `introspect`
- `inner_state`
- `appraise_event`
- `feel_about`
- `choose_attention`
- `ask_human`
- `consolidate_memory`
- `dream`
- `set_reminder`
- `list_reminders`
- `update_face_picture`
- `graph_type_create`
- `graph_node_create`
- `graph_edge_upsert`
- `graph_entity_context`
- `graph_summary`
- `graph_edge_forget`

## Recognition

The default recognizer is `auto`: hosts decide which platform preset to apply. Pass `--recognition command` to force the external local recognizer, or `--recognition descriptive --description random --identity-comparison random` to use the LLM description, vector candidate search, and LLM comparison recognizer. The selected recognizer is shared by the activation flow and the chat `recognize` skill.

The recommended command-recognizer model pair is:

- YuNet int8 detector: a tiny OpenCV Zoo face detector with 5 landmarks.
- SFace int8 recognizer: a MobileFaceNet-based OpenCV Zoo face recognizer.

The brain stores face profile metadata in the active brain's `memory/people.sqlite` and expects real embedding artifacts under that brain's `memory/face_embeddings` for the command recognizer. The external recognizer owns embedding extraction and comparison; the descriptive recognizer uses stored non-sensitive profile and sighting descriptions. Zig owns the identity state machine, enrollment prompts, sightings, and chat observations.

## Test fixtures

The fixture camera cycles through:

- `fixtures/empty/empty_room_01.jpg`
- `fixtures/visitors/unknown_01.jpg`
- `fixtures/visitors/known_01.jpg`
- `fixtures/visitors/known_changed_01.jpg`

Test recognition maps filenames to no-person, unknown, known, and uncertain results. Placeholder fixture files are text markers so local fixture testing does not require real images yet.

## Random Providers

`src/api/random_provider_client.zig` contains the shared random provider boundary for OpenAI, Anthropic, and Google/Gemini text and vision requests.

The visual policy avoids sensitive inferred attributes. Identity matching lives behind `IdentityRecognizer`.

## Adapter notes

- Camera: host-specific cameras live in sibling host projects; the shared camera contract lives in `platform/common/camera.zig`.
- Recognition: `api/recognition_client.zig` defines the test and command-backed recognition boundaries.
- Speech: `api/speech_client.zig` includes a Speak & Spell-style generator. Host playback adapters live in sibling host projects.
- Transcription: `api/transcription_client.zig` defines the boundary; `platform/common/voice_input.zig` records microphone audio and sends it to the configured `whisper-cli`.
- Uploaded audio inspection: `api/audio_client.zig` defines the classification boundary. The default macOS implementation is transcription-backed and only classifies audio as speech when transcription produces text.
- Storage: `storage/json_store.zig` implements the memory store interface using SQLite-backed cognitive memory; `storage/store.zig` defines the interface.
