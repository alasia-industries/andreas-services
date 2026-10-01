#!/bin/bash
# SessionStart hook: project-level setup that runs every session (including
# resumed) in both local and cloud environments.
#
# The shared CLI toolchain (aws, gh, tflint, terraform, ...) is owned by
# scripts/dev-setup.sh in this repo rather than by the cloud environment's Setup
# script, so it is versioned with the code and identical on a laptop and in a
# cloud session. dev-setup.sh short-circuits on `command -v` per tool and only
# reaches for Homebrew when something is genuinely missing, so when the image
# already ships these CLIs this costs a handful of lookups.
set -euo pipefail

REPO="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Per-session env vars. Subsequent Bash tool calls inherit these.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "AWS_DEFAULT_REGION=us-east-1"
    echo "AWS_PAGER="
  } >> "$CLAUDE_ENV_FILE"
fi

# Worktrees: the installed agent skills (expo/eas/design-system/runpod/...) are
# machine-local and gitignored — .agents/, the .claude/skills/* symlinks and
# skills-lock.json — so a fresh worktree checkout has only the committed skills.
# Rather than re-running `npx skills add` per worktree (network, duplicated
# trees), link each missing skill straight to the main checkout's .agents/skills
# store. Absolute links on purpose: the main checkout's own symlinks are
# relative (../../.agents/skills/...) and would dangle here, where .agents/ does
# not exist. Per-entry rather than the whole directory so committed skills in
# the worktree are left alone. skills-lock.json is linked too so dev-setup.sh's
# ensure_skills keeps short-circuiting. Non-fatal, like everything else here.
COMMON_DIR="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
MAIN_ROOT="$(dirname "$COMMON_DIR")"
if [ -n "$COMMON_DIR" ] && [ "$MAIN_ROOT" != "$REPO" ] && [ -d "$MAIN_ROOT/.agents/skills" ]; then
  mkdir -p "$REPO/.claude/skills"
  for src in "$MAIN_ROOT"/.claude/skills/*; do
    [ -e "$src" ] || continue
    name="$(basename "$src")"
    target="$(readlink -f "$src" 2>/dev/null || echo "$src")"
    [ -e "$REPO/.claude/skills/$name" ] || ln -s "$target" "$REPO/.claude/skills/$name" || true
  done
  if [ -f "$MAIN_ROOT/skills-lock.json" ] && [ ! -e "$REPO/skills-lock.json" ]; then
    ln -s "$MAIN_ROOT/skills-lock.json" "$REPO/skills-lock.json" || true
  fi
fi

# Cloud-only steps below. Local dev environments already have these set up.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Shared CLI toolchain. Non-fatal: a missing tool should degrade the session,
# not block it. The steps below depend on what this installs, so it runs first.
if [ -f "$REPO/scripts/dev-setup.sh" ]; then
  bash "$REPO/scripts/dev-setup.sh" >&2 || true
fi

# Put Homebrew's prefix on PATH. dev-setup.sh installs the shared CLIs (gh, aws,
# terraform, tflint) there, but it runs as a child process, so its PATH change
# dies with it, and the /etc/profile.d/homebrew.sh entry it writes is read only
# by login shells — neither this hook nor Claude's Bash tool spawns one. Without
# this the tools are on disk and invisible: `which gh` reports nothing while
# /home/linuxbrew/.linuxbrew/bin/gh runs fine. Export it for the rest of this
# hook (the pre-commit and tflint steps below both depend on it) and hand it to
# the session through CLAUDE_ENV_FILE so every later Bash call inherits it.
BREW_PREFIX="/home/linuxbrew/.linuxbrew"
if [ -x "$BREW_PREFIX/bin/brew" ]; then
  eval "$("$BREW_PREFIX/bin/brew" shellenv)"
  # Prepend rather than write an absolute PATH, so earlier PATH lines in this
  # file survive. Guarded so a resumed session does not stack duplicates.
  if [ -n "${CLAUDE_ENV_FILE:-}" ] && ! grep -qs "$BREW_PREFIX/bin" "$CLAUDE_ENV_FILE"; then
    echo "export PATH=\"$BREW_PREFIX/bin:$BREW_PREFIX/sbin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
  fi
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
