# AffectiveCore Embedded API v1 Fixtures

These JSON files are the shared host contract examples for Affective, Zig tests, and future Android/JNI tests. They intentionally exercise the v1 envelope shape rather than private AffectiveCore or Affective implementation details.

- `manifest_macos.json`: Affective's default file-backed embedded manifest.
- `speech_transcript_request.json`: spoken transcript input event.
- `typed_text_request.json`: typed text input event.
- `short_touch_request.json`: short tap input event.
- `long_touch_request.json`: long hold input event.
- `poke_sequence_request.json`: structured nonverbal poke stimulus input event.
- `tool_call_request.json`: host tool-call input event.
- `success_response.json`: successful event-first response envelope.
- `error_response.json`: stable v1 error envelope.
- `drain_response.json`: queued/progressive event drain response with request correlation.
