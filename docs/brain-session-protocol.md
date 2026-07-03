# Brain Session Protocol

Brain Session Protocol (BSP) is the host/core transport for AffectiveCore sessions. It replaces the in-process C callback hot path with a localhost TCP stream carrying newline-delimited JSON (NDJSON). The only remaining in-app C boundary is a two-function boot shim that starts and stops the session runtime.

## Transport

- Bind only to `127.0.0.1`.
- Use one TCP connection per brain session.
- Frame every message as one JSON object followed by `\n`.
- Payload fields that may contain raw newlines or binary data use base64 and end in `_b64`.
- Unknown message types, malformed JSON, missing required fields, invalid base64, and invalid enum strings are protocol errors.

## Concurrency Model

BSP separates socket I/O from brain execution:

- The brain thread owns the brain handle, dispatch mutex, stimulus queue, and host event queue.
- The socket thread owns TCP reads/writes and never touches brain state directly.
- Host HTTP calls use an in-process completion channel keyed by `request_id`.
- During dispatch, `host_bridge.postJson` enqueues `host.http.begin`, then waits for `host.http.complete`.
- Waits have explicit deadlines. Timeout is reported through the same host HTTP failure path as the embedded callback transport.
- `AFFECTIVE_BSP_DISPATCH_MODE` selects session dispatch routing. `serial` runs dispatch and drain calls through one BSP lane for hosts that require strict in-order execution. `concurrent` and `parallel` allow overlapping BSP dispatch threads; the embedded handle still serializes non-queueable core work, while queueable operations return immediate queued acknowledgements when the dispatch mutex is busy.

Android currently builds the embedded target with `single_threaded = true`; the BSP brain-thread model is therefore not enabled for Android until that build constraint is removed or an async `std.Io` server variant is implemented.

## Deadlock Stress

The abstract model checker proves the dispatch routing rules do not create an internal wait cycle across all supported routing modes:

```sh
zig build dispatch-deadlock-model -- --max-depth 18 --max-queue 4
```

The model is intentionally small: it treats host completion as an independent event, then exhaustively checks that `serial`, `concurrent`, and `parallel` dispatch routing never make host completion depend on a worker that is itself blocked behind the active dispatch. It also checks that concurrent and parallel pressure dispatches never remain behind a dispatch lane while the active dispatch is waiting on the host.

The embedded dispatch harness exercises the shared concurrency contract without requiring BSP sockets. It starts a blocking `user_text` dispatch, holds the fake host LLM call open, then applies randomized pressure from queueable and non-queueable dispatches against the same handle. Queueable requests must return immediate queued acknowledgements while non-queueable requests must fail fast with a busy error; no pressure request may wait behind the blocked host call.

Smoke run:

```sh
zig build dispatch-deadlock-stress -- --cycles 100 --pressure 24 --timeout-ms 5000 --seed 0xdead10cc
```

Overnight run:

```sh
zig build dispatch-deadlock-stress-build
./zig-out/bin/dispatch-deadlock-stress --cycles 50000 --pressure 32 --timeout-ms 10000 --seed 0xdead10cc
```

Any watchdog failure prints the seed, cycle, pressure index, and blocked label, then exits non-zero. Re-run that seed with `--verbose` and a smaller `--cycles` window around the reported cycle to reproduce the interleaving.

## Message Types

### Host to Core

| Type | Purpose |
| --- | --- |
| `session.create` | Create a brain session from embedded config fields and `host_manifest_json`. |
| `session.destroy` | Tear down the active session. |
| `dispatch` | Dispatch an existing embedded request JSON envelope. |
| `drain` | Drain queued/progressive host events. |
| `drain.try` | Non-blocking event drain. |
| `raw_ref.lookup` | Resolve a raw reference. |
| `brain.export` | Export a brain archive. |
| `brain.import` | Import a brain archive. |
| `host.http.complete` | Complete a host HTTP request previously sent by core. |

### Core to Host

| Type | Purpose |
| --- | --- |
| `session.ready` | A session was created and is ready to receive requests. |
| `host.http.begin` | Ask the host to POST JSON to a host-owned route. |
| `events.push` | Push host event batches outside of direct dispatch responses. |
| `dispatch.result` | Return the existing embedded dispatch envelope unchanged. |
| `dispatch.error` | Return a structured protocol/runtime error. |
| `drain.result` | Return the existing embedded drain envelope unchanged. |

## Required Fields

Every message has:

- `type`: BSP message type string.
- `request_id`: optional correlation id, required for request/response and host HTTP fulfillment messages.

`session.create` includes `config`, whose fields match `AffectiveCoreEmbeddedConfig` by name:

- `brain_id`
- `brain_root`
- `conversation_models`
- `conversation_reasoning_effort`
- `image_generation_model`
- `image_generation_output_dir`
- `memory_path`
- `graph_path`
- `schedule_path`
- `maintenance_state_path`
- `face_embeddings_dir`
- `host_manifest_json`

`dispatch` includes `request_json`, which is the existing embedded request envelope serialized as a JSON string.

`host.http.begin` includes:

- `request_id`
- `url`
- `headers_json`
- `body_b64`
- `timeout_ms`
- `max_response_bytes`

`host.http.complete` includes:

- `request_id`
- `status`: `complete` or `failed`
- `data_b64` when `status` is `complete`
- `error` when `status` is `failed`

## Contract Fixtures

Golden BSP frames live in `fixtures/embedded_api/bsp/`. They document line-framed messages, not private runtime internals. Fixture JSON is pretty-printed for review; the wire form is the same object serialized on one line with a trailing newline.

## Stability

The dispatch and drain response payloads intentionally reuse `src/app/embedded_protocol.zig` envelopes. BSP changes framing and concurrency, not the host-facing brain event schema.
