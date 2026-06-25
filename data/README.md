# Configuration

Runtime config files live in this directory. The brain still accepts hardware and test-target flags on the command line, but provider rosters and private delivery settings are file-backed.

## `llm_providers.json`

Controls model routing for conversation and psyche calls.

Fields:

- `mode`: conversation mode. Use `random`; provider-specific modes are no longer wired into the app entrypoints.
- `reasoning_effort`: initial conversation reasoning effort, or `auto`.
- `psyche_reasoning_effort`: reasoning effort for psyche calls.
- `models`: ordered provider/model roster for conversation.
- `psyche_models`: ordered provider/model roster for autonomy psyche calls.

Each model entry has:

```json
{
  "provider": "openai",
  "model": "gpt-4.1-nano"
}
```

Valid providers are `openai`, `anthropic`, and `google`/`gemini`. Empty provider or model entries are ignored. Invalid providers fail when the model roster is parsed for use.

## `email.json`

Enables the chat `send_email` affordance. This file is local-only because it may contain credentials. Start from the repo template:

```sh
cp data/email.example.json data/email.json
```

Fields:

- `smtp_url`: SMTP URL passed to `curl`, such as `smtps://smtp.example.com:465`.
- `from`: sender address used for the message header and SMTP envelope.
- `username`: optional SMTP username.
- `password`: optional SMTP password or app password.

If `data/email.json` is absent, email stays unavailable. If it exists, `smtp_url` and `from` must be non-empty. Auth must be configured as both `username` and `password`, or neither. Missing settings fail during startup config loading; invalid recipients, invalid headers, empty email bodies, and SMTP command failures fail during `send_email`.

## `runtime_options.json`

Runtime preferences changed from the macOS WebView Options tab are stored per brain outside the repo at `~/Library/Application Support/AffectiveCore/brains/<brain>/runtime_options.json`.

## Local State

These files are local configuration or test artifacts and are not meant to be shared as source:

- `data/email.json`
- `data/brains/`
- `data/memory/*.json`
- `data/memory/*.sqlite*`

macOS and Radxa runtime memory, logs, reminders, generated images, promoted captures, and WebView preferences are brain-scoped outside this directory. Persistent brain data lives in `~/Library/Application Support/AffectiveCore/brains/<brain>/`; transient capture and audio scratch data lives in `$TMPDIR/affective-core/brains/<brain>/`.

The headless MCP server defaults to `data/brains/default` for local development unless explicit storage paths are passed.
