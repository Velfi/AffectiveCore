# McpHost

CLI harness for driving the **embedded brain API** (same JSON envelope the macOS host uses) without the Swift app. Includes an in-process mock `affective-host://` HTTP provider for scripted flows and error reproduction.

## Build

```bash
zig build mcp-host
```

Binary: `zig-out/bin/mcp-host`

## Commands

```bash
# Connect + attach host + record manifest, print read_models snapshot
zig-out/bin/mcp-host setup --fresh

# One embedded operation (fixture or stdin)
zig-out/bin/mcp-host dispatch fixtures/embedded_api/user_text_request.json
echo '{"request_id":"x","event":{"type":"short_touch"}}' | zig-out/bin/mcp-host dispatch -

# Drain queued host/brain events (trace envelope)
zig-out/bin/mcp-host drain

# Run a multi-step flow
zig-out/bin/mcp-host run mcp_host/flows/basic_chat.json --fresh
```

Shared flags: `--brain-root`, `--brain-id`, `--manifest`, `--models`, `--scenario`, `--fresh`.

## Scenarios

| Scenario | Purpose |
|----------|---------|
| `default` | Mock LLM echoes user text via `say` |
| `resume_invalid_llm` | 2nd LLM response is `{}` → `LocalServiceResponseInvalid` on camera resume |
| `enrollment_without_remember_person` | Recognize then greet without `remember_person` |
| `upstream_rejected` | All host LLM calls fail |
| `scripted_recognize_resume` | Swaps in test chat/recognizer (no mock LLM) for camera pause/resume |
| `unknown_want_achievement` | `user_text: done` hits `UnknownWantAchievementMemoryId` |

## Example error flows

```bash
# LocalServiceResponseInvalid on resume (mock host returns {} on 2nd LLM call)
zig-out/bin/mcp-host run mcp_host/flows/local_service_invalid_on_resume.json \
  --fresh --scenario resume_invalid_llm

# UnknownWantAchievementMemoryId
zig-out/bin/mcp-host run mcp_host/flows/unknown_want_achievement.json \
  --fresh --scenario unknown_want_achievement

# Camera pause/resume with scripted deps (matches embedded test behavior)
zig-out/bin/mcp-host run mcp_host/flows/camera_pause_resume.json \
  --fresh --scenario scripted_recognize_resume

# Short touch stimulus
zig-out/bin/mcp-host dispatch fixtures/embedded_api/short_touch_request.json --fresh
```

Responses include `outcome`, activity fields, and error codes in the embedded envelope. Use `drain` after each turn to inspect experience-event traces.

## Architecture note

This is **CLI-first** over the embedded C API with a mock host HTTP callback. The existing `affective-core-mcp` stdio server remains for dashboard/tooling via `app_core` (no touch/sense/drain). Use McpHost when you need host-parity embedded operations and scripted `affective-host://` behavior.

To hit **real** LLM/vision/recognize providers, point env vars at live routes and replace the mock by wiring host services externally (follow-up: optional `--live-host` mode).
