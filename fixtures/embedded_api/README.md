# AffectiveCore Embedded API Fixtures

These JSON files are the shared host contract examples for Affective, Zig tests, and future Android/JNI tests. They exercise the typed Brain operation envelope rather than private AffectiveCore or Affective implementation details.

## Event envelope fixtures

- `manifest_macos.json`: Affective's default file-backed embedded manifest.
- `short_touch_request.json`: short tap input event.
- `long_touch_request.json`: long hold input event.
- `poke_sequence_request.json`: structured nonverbal poke stimulus input event.
- `sense_observation_camera_request.json`: camera frame delivered after a `sense_request`.
- `error_response.json`: stable typed error envelope.
- `drain_response.json`: queued/progressive experience-event response with request correlation.
- `user_text_request.json`: typed user text input event.

Text input uses the typed `user_text` operation. The legacy `conversation_turn` event type is rejected with `unknown_event_type`. The embedded event envelope does not accept direct text-message event types.

## Host HTTP route fixtures

The embedded brain calls the host through async `AffectiveCoreEmbeddedHostServices.http_post_json_begin` and `http_post_json_poll`. These JSON files document request/response bodies the host must implement.

- `recognize_identify_request.json`: POST `affective-host://recognize/identify`
- `recognize_identify_response_none.json`: identify result when no face is detected

Other required host routes (no fixture file yet):

- `affective-host://recognize/enroll` — face enrollment for `remember_person`
- `affective-host://llm/complete` — conversation and psyche text completion
- `affective-host://vision/complete` — image description (`describe_image`) and visual context for recognition

Wire parsing lives in [`src/api/recognition_client.zig`](../../src/api/recognition_client.zig) (`parseHostIdentityResult`) and [`src/api/chat_client.zig`](../../src/api/chat_client.zig) (`parseChatTurn`).

## Brain Session Protocol fixtures

`bsp/*.json` documents the new localhost TCP + NDJSON session frames. Fixture files are pretty-printed for review; the wire format is the same JSON object minified on a single line with a trailing newline.

- `bsp/session_create.json`: host creates a BSP brain session with embedded config fields.
- `bsp/dispatch.json`: host dispatches an existing embedded request envelope.
- `bsp/host_http_begin.json`: core asks the host to fulfill a provider HTTP request.
- `bsp/host_http_complete.json`: host completes that request.

## Host recognition debug checklist

When `recognize` returns `none` with `confidence=0.00` but vision still describes a person in the frame:

1. Log the exact `observation.path` in every `sense_observation` with `sense: "camera"`. Confirm the file exists and is non-empty before calling identify.
2. Confirm the host manifest declares `camera_capture`, `identity_recognition`, and `provider_vision_completion` so the brain reports accurate affordances.
3. Reproduce identify outside the app using the face recognizer CLI (paths must match what the host sends to identify):

```bash
tools/affective-face-recognizer identify \
  --image "<captured-path>" \
  --memory "<brain-root>/memory/people.sqlite" \
  --embeddings-dir "<brain-root>/memory/face_embeddings" \
  --detector "<opencv-models>/face_detector" \
  --recognizer "<opencv-models>/face_recognizer" \
  --known-threshold 0.85 \
  --uncertain-threshold 0.60
```

4. If CLI output has `people_count: 0`, the frame has no detectable face (blur, Fig capture failure, wrong path). Fix camera session lifecycle before chasing enrollment.
5. If CLI output has `match_status: "unknown"` with `people_count >= 1`, enroll through the selected recognition capability / `affective-host://recognize/enroll`.
6. Keep a single camera session per turn; repeated start/stop causes Fig `-12710` / `-17281` errors and blank frames.

## Automated test order

1. Run `testFaceRecognitionServiceFixtureMatrix` in AffectiveTests (fixture ONNX path; no camera hardware).
2. If the live app still logs `people_count=0`, run hardware e2e:
   `AFFECTIVE_RUN_CAMERA_HARDWARE_E2E=1 xcodebuild test -only-testing:AffectiveTests/testLiveCameraCaptureProducesDetectableFace`
3. On hardware failure, use the printed `image_path` with the CLI identify command above before changing brain conversation code.

## Manual device verification

After changing host or brain recognition code:

1. Send a user message that triggers `recognize`; confirm exactly one camera `sense_request` in the drain envelope.
2. Confirm logs show `HTTP start method=POST url=affective-host://recognize/identify`.
3. Run the CLI identify command on the captured path; result must match the brain log.
4. Enroll through the selected recognition capability, retry recognize under the same lighting.
5. When identify returns `people_count: 0`, the bot must not greet by a stored name from conversation memory alone.
