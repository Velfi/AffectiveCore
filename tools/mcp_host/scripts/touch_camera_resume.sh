#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="${MCP_HOST_BIN:-$ROOT/zig-out/bin/mcp-host}"
BRAIN_ROOT="${MCP_HOST_BRAIN_ROOT:-$ROOT/data/test/mcp_host/touch_camera_resume}"
FLOW="${MCP_HOST_FLOW:-$ROOT/tools/mcp_host/flows/touch_camera_resume.json}"

cd "$ROOT"
"$BIN" --brain-root "$BRAIN_ROOT" --fresh run "$FLOW"
