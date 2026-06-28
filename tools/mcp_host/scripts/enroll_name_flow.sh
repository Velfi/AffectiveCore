#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="${MCP_HOST_BIN:-$ROOT/zig-out/bin/mcp-host}"
BRAIN_ROOT="${MCP_HOST_BRAIN_ROOT:-$ROOT/data/test/mcp_host/enroll_name}"
FLOW="${MCP_HOST_FLOW:-$ROOT/tools/mcp_host/flows/enroll_name_flow.json}"

cd "$ROOT"
"$BIN" --brain-root "$BRAIN_ROOT" --fresh run "$FLOW"
