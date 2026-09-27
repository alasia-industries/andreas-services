#!/usr/bin/env bash
# Start the backend (with the Stripe webhook consumer beside it, both from
# backend/docker-compose.yml), both frontends and the MCP connector as one
# local development session: marketing site on :5176, product app on :8081,
# MCP on :5002 (skipped, with a warning, when uv is not installed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dev-aws-common.sh
source "$SCRIPT_DIR/dev-aws-common.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) [[ $# -ge 2 ]] || die "--profile requires a value."; AWS_PROFILE_VALUE="$2"; shift ;;
    --region) [[ $# -ge 2 ]] || die "--region requires a value."; AWS_REGION_VALUE="$2"; shift ;;
    --help|-h)
      printf 'Usage: %s [--profile NAME] [--region REGION]\n' "$0"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

for command in aws docker jq npm; do require_command "$command"; done

require_dev_env

# With Stripe in test mode the relay must be registered — a purchase that
# completes with no endpoint is lost, where one that completes with no consumer
# running merely waits in the queue. Said here, before anything starts, rather
# than by the consumer container idling with a log line nobody reads.
if stripe_dev_configured; then
  [[ -n "$(read_env "$DEV_ENV_FILE" HUMBUGG_WEBHOOK_QUEUE_URL)" ]] &&
    [[ "$(read_env "$DEV_ENV_FILE" HUMBUGG_STRIPE_WEBHOOK_SECRET)" == whsec_* ]] ||
    die "Stripe is in test mode but this machine's webhook relay is not registered. Re-run ./humbugg/scripts/dev-aws-setup.sh."
fi

pids=()
names=()
cleaning_up=0

cleanup() {
  local pid
  [[ "$cleaning_up" -eq 0 ]] || return
  cleaning_up=1
  trap - EXIT INT TERM
  printf '\n'
  log "Stopping local development services..."
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}

trap cleanup EXIT
trap 'exit 130' INT TERM

start_service() {
  local name="$1"
  shift
  log "Starting $name..."
  "$@" &
  pids+=("$!")
  names+=("$name")
}

start_service backend "$SCRIPT_DIR/dev-up-backend.sh" \
  --profile "$AWS_PROFILE_VALUE" --region "$AWS_REGION_VALUE"
start_service web "$SCRIPT_DIR/dev-up-marketing.sh"
start_service app "$SCRIPT_DIR/dev-up-app.sh"
if command -v uv >/dev/null 2>&1; then
  start_service mcp "$SCRIPT_DIR/dev-up-mcp.sh"
else
  warn "uv is not installed; skipping the MCP connector (humbugg/mcp). brew install uv to include it."
fi

ok "Humbugg local development is starting. Press Ctrl+C to stop everything."

while true; do
  for index in "${!pids[@]}"; do
    pid="${pids[$index]}"
    if ! kill -0 "$pid" 2>/dev/null; then
      set +e
      wait "$pid"
      status=$?
      set -e
      [[ "$status" -eq 0 ]] || warn "${names[$index]} exited with status $status."
      exit "$status"
    fi
  done
  sleep 1
done
