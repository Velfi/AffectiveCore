# Affective MCP

`affective-mcp` is the TCP-backed MCP host for letting an LLM interact directly with an Affective brain.

It speaks two protocols at once:

- **MCP over stdio** to the LLM client.
- **Brain Session Protocol (BSP) over loopback TCP** to `affective-core-session`.

The MCP process does not embed the brain in-process. It connects to a running BSP session service, creates a brain session there, attaches itself as the active host, and forwards MCP tool calls into the embedded brain dispatch envelope.

## Build

```bash
zig build affective-mcp
zig build affective-mcp-stdio
zig build session
```

Binaries:

- `zig-out/bin/affective-mcp`
- `zig-out/bin/affective-mcp-stdio`
- `zig-out/bin/affective-core-session`

## Run

Start the TCP session service first:

```bash
zig-out/bin/affective-core-session --port 0
```

It prints the selected loopback port:

```text
AFFECTIVE_BSP_PORT=50834
```

Then start the MCP host with that port:

```bash
zig-out/bin/affective-mcp --port 50834
```

`affective-mcp` also accepts the port through `AFFECTIVE_BSP_PORT`. If neither `--port` nor `AFFECTIVE_BSP_PORT` is present, startup fails immediately with `MissingBspPort`.

## MCP Tools

| Tool | Purpose |
|------|---------|
| `connect` | Send a brain `connect` event and return brain introspection. |
| `host_attach` | Attach Affective MCP as a host binding. |
| `user_text` | Deliver typed user text directly into the brain. |
| `short_touch` | Send a short touch activation. |
| `sense_observation` | Resume the brain with a camera image observation. |
| `read_models_snapshot` | Read compact brain models. |
| `conversation_text` | Run a synchronous conversation turn and return the brain's spoken response. |
| `brain_step` | Run one embedded autonomy brain step. |
| `request_dream_time` | Ask the brain to enter dream-time processing. |
| `drain` | Drain queued brain and host events. |
| `shutdown` | Return a final MCP response, then cleanly exit `affective-mcp-stdio`. |

## Important Distinctions

There are three MCP-adjacent binaries in this repo:

| Binary | Transport | Brain ownership | Use when |
|--------|-----------|-----------------|----------|
| `affective-mcp` | MCP stdio + BSP TCP | Brain lives in `affective-core-session` | An LLM should talk to the TCP-based brain runtime. |
| `affective-mcp-stdio` | MCP stdio only | Embedded brain in-process | Codex should spawn one no-network bridge and own its local brain directly. |
| `mcp-host --mcp` | MCP stdio | Embedded brain in-process | You want the older embedded harness with mock/live host scenarios. |
| `affective-core-mcp` | MCP stdio | Headless brain in-process via `app_core` | You want the original headless tool server. |

For Codex, prefer `affective-mcp-stdio`. For app/runtime scenarios where a shared external BSP session is desired, use `affective-mcp` with `affective-core-session`.

## Host HTTP

The BSP server asks the host to perform provider calls by sending `host.http.begin` frames. `affective-mcp` handles those requests and replies with `host.http.complete`.

Current host routes are shared with the live MCP host harness:

- `affective-host://llm/complete`
- `affective-host://vision/complete`
- `affective-host://embed/compute`
- `affective-host://recognize/identify`
- `affective-host://recognize/enroll`
- `affective-host://system/power`
- `affective-host://system/storage`

LLM and vision calls use the env-backed provider client. Missing provider configuration should fail loudly; do not add silent fallbacks.

## Flags

| Flag | Default | Purpose |
|------|---------|---------|
| `--port` | none | BSP TCP port. Required unless `AFFECTIVE_BSP_PORT` is set. |
| `--brain-root` | `data/affective-mcp/default` | Brain storage root for the BSP session. |
| `--brain-id` | `affective-mcp` | Brain id. |
| `--manifest` | `fixtures/embedded_api/manifest_macos.json` | Host capability manifest sent in `session.create`. |
| `--models` | `openai:gpt-4.1-nano` | Conversation model spec for env-backed provider routing. |
| `--reasoning-effort` | empty | Conversation reasoning effort. |
| `--image-model` | empty | Image generation model. |

## MCP Client Configuration

Use a wrapper script or process manager that starts `affective-core-session`, captures its `AFFECTIVE_BSP_PORT`, then launches `affective-mcp` with that port.

Example command after a port is known:

```json
{
  "command": "/Users/zelda/Documents/AffectiveCore/zig-out/bin/affective-mcp",
  "args": ["--port", "50834"]
}
```

Do not point an MCP client directly at `affective-core-session`; it speaks BSP NDJSON over TCP, not MCP.

## Codex Stdio Configuration

Codex can launch the embedded bridge directly. This binary does not open loopback sockets and does not connect to `affective-core-session`; it creates the embedded brain in-process.

```json
{
  "command": "/Users/zelda/Documents/AffectiveCore/zig-out/bin/affective-mcp-stdio",
  "args": ["--brain-root", "/private/tmp/affective-codex-brain"]
}
```

`affective-mcp-stdio` accepts the same brain identity and model-facing flags used by the embedded host path: `--brain-root`, `--brain-id`, `--manifest`, `--models`, `--reasoning-effort`, `--image-model`, and `--image-output-dir`. TCP flags such as `--port` are intentionally unsupported.

For a persistent Codex session, keep the MCP process alive and manage it with tools:

- Use `conversation_text` when you need an immediate spoken reply.
- Use `user_text`, `short_touch`, and `sense_observation` when you want to feed stimuli into the attention queue.
- Use `brain_step` to let the embedded brain run one autonomy pass.
- Use `read_models_snapshot` and `drain` to inspect state and queued events.
- Use `shutdown` when the client wants the server to tear down the embedded brain and exit gracefully.

## Smoke Test

After starting `affective-core-session` and noting the port, send an MCP `tools/list` request to `affective-mcp`. A valid response includes `Affective MCP` tools and a `Content-Length` header.

The `affective-mcp` startup path also sends `connect` and `host_attach` through BSP before reading MCP requests, so the session service logs should show both dispatches before the first tool call.
