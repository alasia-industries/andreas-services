#!/bin/bash
# SessionStart hook: project-level setup that runs every session (including
# resumed) in both local and cloud environments.
#
# Heavy/cacheable installs (aws cli, tflint, pre-commit) live in the cloud
# environment's Setup script so they benefit from the filesystem snapshot
# cache. This hook only does work that genuinely needs to run per-session.
set -euo pipefail

REPO="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Per-session env vars. Subsequent Bash tool calls inherit these.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "AWS_DEFAULT_REGION=us-east-1"
    echo "AWS_PAGER="
  } >> "$CLAUDE_ENV_FILE"
fi

# Cloud-only steps below. Local dev environments already have these set up.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# pre-commit: install the git hook and pre-download hook environments so
# `pre-commit run` is instant when Claude wants to verify a change.
if command -v pre-commit &>/dev/null && [ -f "$REPO/.pre-commit-config.yaml" ]; then
  (cd "$REPO" && pre-commit install >&2) || true
  (cd "$REPO" && pre-commit install-hooks >&2) || true
fi

# tflint ruleset plugins. Idempotent and fast once the plugin cache is warm.
if command -v tflint &>/dev/null && [ -f "$REPO/.tflint.hcl" ]; then
  tflint --init --config "$REPO/.tflint.hcl" >&2 || true
fi
