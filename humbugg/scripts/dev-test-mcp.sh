#!/usr/bin/env bash
# The MCP connector's integration tier (humbugg/mcp/tests/test_integration.py): its
# tools against this machine's running backend, as seeded people. Builds a throwaway
# exchange, draws it through the `draw` tool, checks nobody can learn their giver,
# and deletes it. Needs dev-up-backend.sh running and dev-aws-seed.sh run once.
# Extra arguments go to pytest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dev-aws-common.sh
source "$SCRIPT_DIR/dev-aws-common.sh"

for command in uv curl; do require_command "$command"; done
require_dev_env

api_base="$(read_env "$DEV_ENV_FILE" EXPO_PUBLIC_API_BASE_URL)"
api="${HUMBUGG_INTEGRATION_API_URL:-${api_base%/api}}"
api="${api:-http://127.0.0.1:5001}"
curl -fsS -m 3 -o /dev/null "$api/health" ||
  die "No backend answering at $api. Start it with ./humbugg/scripts/dev-up-backend.sh."

cd "$HUMBUGG_DIR/mcp"
HUMBUGG_INTEGRATION=1 HUMBUGG_INTEGRATION_API_URL="$api" HUMBUGG_MCP_ALLOW_MISSING_UI=1 \
  exec uv run --group dev pytest -q -p no:warnings tests/test_integration.py "$@"
