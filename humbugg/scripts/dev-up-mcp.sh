#!/usr/bin/env bash
# Start the MCP connector (humbugg/mcp) locally on :5002, against this machine's
# backend and signed in as a seeded person — the way to try the tools in Claude
# Code or the Inspector without OAuth. Needs the backend (dev-up-backend.sh).
#
#   ./humbugg/scripts/dev-up-mcp.sh                    # as HUMBUGG_DEV_USER_EMAIL (the organizer)
#   ./humbugg/scripts/dev-up-mcp.sh --as p1@humbugg.test
#   ./humbugg/scripts/dev-up-mcp.sh --stub             # against the in-memory stub API, no backend
#
# Builds the MCP Apps pages first when their source is newer than the build.
# Auth is OFF: humbugg_mcp.dev binds to 127.0.0.1 and refuses the production API.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dev-aws-common.sh
source "$SCRIPT_DIR/dev-aws-common.sh"

MCP_DIR="$HUMBUGG_DIR/mcp"
WIDGETS_DIR="$MCP_DIR/widgets"
UI_DIR="$MCP_DIR/humbugg_mcp/ui"
PORT=5002
module=humbugg_mcp.dev
as_email=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --as) [[ $# -ge 2 ]] || die "--as requires an email."; as_email="$2"; shift ;;
    --stub) module=humbugg_mcp.testing ;;
    --help|-h)
      printf 'Usage: %s [--as EMAIL] [--stub]\n' "$0"
      printf '  --as EMAIL  sign in as this seeded person (seeds/dev.json); default HUMBUGG_DEV_USER_EMAIL\n'
      printf '  --stub      serve against the in-memory stub API instead of the backend\n'
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

for command in uv npm curl; do require_command "$command"; done

# The pages are built output the server refuses to start without, and a stale
# build is a page that silently lags its source.
if [[ ! -d "$WIDGETS_DIR/node_modules" ]]; then
  log "Installing MCP page dependencies..."
  token="${NODE_AUTH_TOKEN:-}"
  if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then token="$(gh auth token 2>/dev/null || true)"; fi
  [[ -n "$token" ]] || die "No GitHub Packages token for @ansavva/design-system. Run: export NODE_AUTH_TOKEN=\$(gh auth token)"
  NODE_AUTH_TOKEN="$token" npm --prefix "$WIDGETS_DIR" ci --no-audit --no-fund
fi
pages=(draw-review assignment wishlist groups group)
stale=0
for page in "${pages[@]}"; do [[ -f "$UI_DIR/$page.html" ]] || stale=1; done
if [[ "$stale" -eq 0 ]] && [[ -n "$(find "$WIDGETS_DIR/src" "$WIDGETS_DIR/build.mjs" -newer "$UI_DIR/${pages[0]}.html" -print -quit)" ]]; then
  stale=1
fi
if [[ "$stale" -eq 1 ]]; then
  log "Building the MCP Apps pages..."
  npm --prefix "$WIDGETS_DIR" run build
fi

if [[ "$module" == humbugg_mcp.dev ]]; then
  require_dev_env
  # The backend's origin, from the app's API base (…/api) — the one value every
  # dev-up script agrees on.
  api_base="$(read_env "$DEV_ENV_FILE" EXPO_PUBLIC_API_BASE_URL)"
  export HUMBUGG_API_URL="${HUMBUGG_API_URL:-${api_base%/api}}"
  export HUMBUGG_API_URL="${HUMBUGG_API_URL:-http://127.0.0.1:5001}"
  [[ -z "$as_email" ]] || export HUMBUGG_MCP_DEV_EMAIL="$as_email"
  who="${HUMBUGG_MCP_DEV_EMAIL:-$(read_env "$DEV_ENV_FILE" HUMBUGG_DEV_USER_EMAIL)}"
  [[ -n "$(read_env "$DEV_ENV_FILE" HUMBUGG_DEV_USER_PASSWORD)" ]] ||
    die "HUMBUGG_DEV_USER_PASSWORD is not set in $DEV_ENV_FILE. Run ./humbugg/scripts/dev-aws-seed.sh first."
  # A warning, not a stop: under dev-up.sh the backend is starting beside us.
  curl -fsS -m 2 -o /dev/null "$HUMBUGG_API_URL/health" 2>/dev/null ||
    warn "No backend answering at $HUMBUGG_API_URL yet — start it with ./humbugg/scripts/dev-up-backend.sh."
  ok "MCP connector as $who, API $HUMBUGG_API_URL"
else
  ok "MCP connector against the in-memory stub API"
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "Port $PORT is taken (lsof -nP -iTCP:$PORT). The MCP dev port is fixed so Claude Code's entry keeps working."
fi

log "Connect Claude Code once with: claude mcp add --transport http humbugg-dev http://127.0.0.1:$PORT/mcp"
log "Or the Inspector: npx @modelcontextprotocol/inspector  →  http://127.0.0.1:$PORT/mcp"
log "Pages render only in the desktop app, with the stdio entry in its config — humbugg/mcp/README.md."

cd "$MCP_DIR"
# A host (Claude Code) keeps its connection to /mcp open; without a limit uvicorn
# waits for it forever on Ctrl+C and the port stays taken.
exec uv run --group dev uvicorn "$module:app" --host 127.0.0.1 --port "$PORT" --log-level warning \
  --timeout-graceful-shutdown 2
