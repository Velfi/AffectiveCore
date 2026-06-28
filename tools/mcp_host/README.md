# McpHost

Developer harness for the **embedded** AffectiveCore brain. Talk to the same JSON dispatch envelope the Swift/macOS host uses, without launching the full app.

This is separate from `affective-core-mcp` (`src/main_mcp.zig`), which drives the headless full-brain MCP tools. McpHost targets `affective_core_embedded_dispatch_json` event types: `connect`, `host_attach`, `user_text`, `short_touch`, `sense_observation`, `read_models_snapshot`, and `drain`.

Zig sources live in `src/mcp_host/` (entry: `src/main_mcp_host.zig`). This directory holds docs and scripts.

## Build

From the repo root:

```bash
zig build mcp-host
```

Binary: `zig-out/bin/mcp-host`

## Architecture

- **Embedded runtime**: loads `affective_core_embedded` in-process (same path as Zig ABI tests).
- **Mock host HTTP** (default): implements `affective-host://llm/complete`, `vision/complete`, `recognize/identify`, and `recognize/enroll` so conversation, camera resume, and enrollment flows work offline.
- **Fail host** (`--scenario upstream_rejected`): returns upstream HTTP errors — use to reproduce `user_text` / think-path failures loudly.
- **Dual interface**: CLI for scripts/agents, `--mcp` stdio server for MCP clients (Cursor, Swift dashboard pattern).
- **Startup host binding**: `Session.setupHost()` sends one `connect` and one `host_attach` before the first CLI/MCP dispatch. The Swift dashboard (`apple/AffectiveCore`) calls the MCP `connect` tool again on its own connect path, and preview/dev flows may do the same — so logs often show two or three connect/host_attach pairs even though each process owns a single embedded brain session.

Real provider wiring (OpenAI/Anthropic/Gemini) is not bundled here. Point a real host at those routes or use `zig build api-e2e` for live API contract checks.

## CLI usage

```bash
# One-shot commands (default brain root: data/test/mcp_host/default)
zig-out/bin/mcp-host connect
zig-out/bin/mcp-host host_attach --host-id dev-agent
zig-out/bin/mcp-host user_text --text "hello"
zig-out/bin/mcp-host short_touch
zig-out/bin/mcp-host sense_observation --image fixtures/visitors/unknown_01.jpg
zig-out/bin/mcp-host read_models_snapshot
zig-out/bin/mcp-host drain

# Raw fixture dispatch
zig-out/bin/mcp-host dispatch --file fixtures/embedded_api/short_touch_request.json

# Reproduce host HTTP errors
zig-out/bin/mcp-host --scenario upstream_rejected user_text --text "hello"
```

Global flags may appear before or after the command:

```bash
zig-out/bin/mcp-host --brain-root data/test/mcp_host/demo --fresh run tools/mcp_host/flows/touch_camera_resume.json
```

### Example flows

```bash
# user_text → recognize pause → camera observation → resume
tools/mcp_host/scripts/touch_camera_resume.sh

# greet → unknown face → enroll name
tools/mcp_host/scripts/enroll_name_flow.sh
```

Or inline:

```bash
zig-out/bin/mcp-host --brain-root data/test/mcp_host/demo --fresh run tools/mcp_host/flows/touch_camera_resume.json
```

## MCP stdio server

```bash
zig-out/bin/mcp-host --mcp --brain-root data/test/mcp_host/mcp_session
```

Tools: `connect`, `host_attach`, `user_text`, `short_touch`, `sense_observation`, `read_models_snapshot`, `drain`.

Wire the binary like the Swift `MCPClient` does for `affective-core-mcp`, but use tool names above (embedded events, not headless brain ops).

## Flags

| Flag | Default | Purpose |
|------|---------|---------|
| `--brain-root` | `data/test/mcp_host/default` | Isolated brain storage |
| `--brain-id` | `mcp-host` | Brain id |
| `--scenario NAME` | `default` | Mock host behavior (see scenarios below) |
| `--manifest PATH` | `fixtures/embedded_api/manifest_macos.json` | Host capability manifest |

### Scenarios

| Scenario | Effect |
|----------|--------|
| `default` | Mock LLM: recognize on first turn, say on resume |
| `resume_invalid_llm` | Second conversation LLM returns `{}` → resume parse error |
| `enrollment_without_remember_person` | Unknown face, no `remember_person` action |
| `upstream_rejected` | All LLM calls fail (upstream rejection) |
| `scripted_recognize_resume` | In-process scripted chat + recognizer (no HTTP) |
| `unknown_want_achievement` | Seeds a want + scripted detector match |

## Fixtures

Shared contract examples live in `fixtures/embedded_api/`. See that directory's README for host route documentation.

## Follow-ups

- `think_about` / autonomy tick reproduction scripts
- `--host live` mode delegating to env-backed providers (like `main_api_e2e.zig`)
- Sense-request extraction helper (parse drain for `camera` pull after `short_touch`)
- Session snapshot/import helpers for bug bisect
