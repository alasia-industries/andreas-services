#!/usr/bin/env bash
#
# Shared developer / CI toolchain bootstrap for the andreas-services monorepo.
#
# Installs the cross-cutting tools every service needs (Terraform, tflint, AWS
# CLI, GitHub CLI + its gh-stack extension, Node.js, jq, zip, Stripe CLI) with
# Homebrew on BOTH macOS and Linux. Service-specific
# runtimes live in per-service scripts, e.g. classroom/scripts/dev-setup.sh.
#
# Homebrew details:
#   - macOS (developer machines): brew runs as the normal user.
#   - Linux (this cloud sandbox / CI): Homebrew refuses to run as root, so it is
#     installed into the default prefix /home/linuxbrew/.linuxbrew owned by the
#     non-root `ubuntu` user, and every `brew` call is run as that user via
#     $AS_BREW_USER (`sudo -H -u ubuntu`) — which applies when this script runs
#     as root too, since root is exactly the case Homebrew rejects.
#     The prefix bin is added to PATH (this run + /etc/profile.d) so root and CI
#     agents can execute the installed tools.
#   - terraform and tflint are NOT in homebrew-core; they come from taps
#     (hashicorp/tap, terraform-linters/tap) on every platform.
#
# IDEMPOTENT: every tool is checked with `command -v` before install, so
# re-running is a no-op once the toolchain is present.
#
# Usage:
#   ./scripts/dev-setup.sh            # install everything missing
#   ./scripts/dev-setup.sh --check    # report status only, install nothing
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

NODE_MAJOR_MIN=20           # repo builds on Node 20+

log()  { printf '\033[1;34m[dev-setup]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
skip() { printf '\033[1;36m[skip]\033[0m %s already present: %s\n' "$1" "$2"; }

# Detect platform from the kernel name. `uname -s` is the kernel identifier: it
# is reliably "Darwin" on every macOS release (it does NOT track the macOS
# marketing version) and "Linux" on Linux. Match with a glob and treat anything
# else as unsupported rather than silently assuming Linux.
OS="$(uname -s)"
case "$OS" in
  Darwin*) PLATFORM="macos" ;;
  Linux*)  PLATFORM="linux" ;;
  *) printf 'Unsupported OS: %s (this repo supports macOS and Linux only).\n' "$OS" >&2; exit 1 ;;
esac
have() { command -v "$1" >/dev/null 2>&1; }
if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

# --- Linux Homebrew (installed & run as the non-root ubuntu user) ----------
LINUXBREW_PREFIX="/home/linuxbrew/.linuxbrew"
LINUX_BREW_USER="ubuntu"
BREW_ENV=(HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1)

# Prefix that DE-escalates to the Homebrew owner. This is not $SUDO and must
# never be written as `$SUDO -u`: $SUDO is empty when we are already root, so
# `$SUDO -u ubuntu git clone ...` expands to `-u ubuntu git clone ...` and the
# shell tries to run a program called `-u`. Root has sudo too, so dropping
# privileges always needs a real command here. Homebrew refuses to run as root
# (unreviewed upstream build scripts would get root, and its sandbox does not
# apply), which is why every brew call goes through this.
if [[ "$(id -un)" == "$LINUX_BREW_USER" ]]; then
  AS_BREW_USER=(env)                                   # already the right user
elif command -v sudo >/dev/null 2>&1; then
  AS_BREW_USER=(sudo -H -u "$LINUX_BREW_USER")         # -H so HOME is the owner's
elif command -v runuser >/dev/null 2>&1; then
  AS_BREW_USER=(runuser -u "$LINUX_BREW_USER" --)
else
  # No way to drop privileges: brew will run as whoever we are and refuse if
  # that is root. Left empty deliberately so the failure is Homebrew's own.
  AS_BREW_USER=()
  [[ "$(id -u)" -eq 0 ]] && warn "neither sudo nor runuser found; Homebrew cannot be run as '$LINUX_BREW_USER'"
fi

# Run a brew command the right way for the platform.
brew_run() {
  if [[ "$PLATFORM" == "macos" ]]; then
    env "${BREW_ENV[@]}" brew "$@"
  else
    "${AS_BREW_USER[@]}" env "${BREW_ENV[@]}" "$LINUXBREW_PREFIX/bin/brew" "$@"
  fi
}

apt_install() { $SUDO apt-get update -y >/dev/null && $SUDO apt-get install -y "$@"; }

ensure_brew() {
  if [[ "$PLATFORM" == "macos" ]]; then
    if have brew; then return 0; fi
    if [[ "$CHECK_ONLY" -eq 1 ]]; then warn "Homebrew is MISSING (required on macOS)"; return 1; fi
    log "installing Homebrew ..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    return 0
  fi

  # ---- Linux ----
  if [[ ! -x "$LINUXBREW_PREFIX/bin/brew" ]]; then
    if [[ "$CHECK_ONLY" -eq 1 ]]; then warn "Homebrew (Linux) is MISSING (would install as user '$LINUX_BREW_USER')"; return 1; fi
    if ! id "$LINUX_BREW_USER" >/dev/null 2>&1; then
      warn "non-root user '$LINUX_BREW_USER' not found; Homebrew cannot run as root."
      return 1
    fi
    log "installing Homebrew prerequisites ..."
    apt_install build-essential procps curl file git >/dev/null 2>&1 || \
      warn "could not apt-get prerequisites (continuing; they may already be present)"
    log "installing Homebrew into $LINUXBREW_PREFIX (owned by $LINUX_BREW_USER) ..."
    $SUDO mkdir -p "$LINUXBREW_PREFIX"
    $SUDO chown -R "$LINUX_BREW_USER:$LINUX_BREW_USER" "$(dirname "$LINUXBREW_PREFIX")"
    "${AS_BREW_USER[@]}" git clone --depth=1 https://github.com/Homebrew/brew "$LINUXBREW_PREFIX/Homebrew"
    "${AS_BREW_USER[@]}" mkdir -p "$LINUXBREW_PREFIX/bin"
    "${AS_BREW_USER[@]}" ln -sf "$LINUXBREW_PREFIX/Homebrew/bin/brew" "$LINUXBREW_PREFIX/bin/brew"
  fi

  # A bootstrap that got this far without producing a brew binary must fail
  # loudly: `eval "$(missing-binary shellenv)"` evaluates an empty string and
  # returns 0, so every later `brew install` fails one by one instead.
  if [[ ! -x "$LINUXBREW_PREFIX/bin/brew" ]]; then
    warn "Homebrew bootstrap did not produce $LINUXBREW_PREFIX/bin/brew"
    return 1
  fi

  # Expose brew + its tools on PATH for this run and for future login shells.
  eval "$("$LINUXBREW_PREFIX/bin/brew" shellenv)"
  local profile="/etc/profile.d/homebrew.sh"
  if [[ "$CHECK_ONLY" -ne 1 && ! -f "$profile" ]]; then
    echo "eval \"\$($LINUXBREW_PREFIX/bin/brew shellenv)\"" | $SUDO tee "$profile" >/dev/null || true
  fi
  return 0
}

# Homebrew is installed lazily, the first time a tool actually turns out to be
# missing. A machine that already has the toolchain — a developer laptop, or a
# cloud image whose own setup already installed these CLIs — then costs nothing:
# every tool short-circuits on `command -v` and Homebrew is never touched. That
# is what makes this script cheap enough to run on every session start.
BREW_STATE=unknown   # unknown | ready | unavailable
require_brew() {
  case "$BREW_STATE" in
    ready)       return 0 ;;
    unavailable) return 1 ;;
  esac
  if ensure_brew; then BREW_STATE=ready; return 0; fi
  BREW_STATE=unavailable
  return 1
}

# brew_ensure <cli-name> <formula>  (formula may be tap-qualified)
brew_ensure() {
  local cli="$1" formula="$2"
  if have "$cli"; then skip "$cli" "$(command -v "$cli")"; return 0; fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then warn "$cli is MISSING (would: brew install $formula)"; return 0; fi
  if ! require_brew; then
    warn "$cli is MISSING and Homebrew is unavailable; skipping (see messages above)"
    return 0
  fi
  # ensure_brew puts an already-installed Homebrew prefix on PATH, which may be
  # exactly where this tool lives — re-check before shelling out to brew.
  if have "$cli"; then skip "$cli" "$(command -v "$cli")"; return 0; fi
  # Homebrew 6 stopped loading formulae, casks and commands from a third-party
  # tap until they are trusted ("Skipping <tap> because it is not trusted").
  # Trust this one entry rather than the whole tap, which Homebrew warns is
  # broader than needed — `brew trust <user>/<tap>/<name>` works out for itself
  # whether that is a formula or a cask. Non-fatal: older Homebrew has no
  # `trust` subcommand and needs none.
  if [[ "$formula" == */*/* ]]; then
    brew_run trust "$formula" >/dev/null 2>&1 || \
      warn "could not trust $formula (continuing; install may be skipped)"
  fi
  log "installing $formula ..."
  brew_run install "$formula"
}

# gh-stack: GitHub's stacked-PR extension (github/gh-stack). The canonical
# install resolves a release binary through api.github.com, which is the normal
# path on a laptop and in CI. Some sandboxes (including Claude cloud sessions)
# serve GitHub through a proxy that blocks the REST API while still allowing
# anonymous git clones, so a source build is used as a fallback there. Both
# paths end at `gh extension install`, so `gh stack` is the same command either
# way. Non-fatal: without it, stacked PRs are still workable with plain git.
# `gh extension install .` names the extension after the directory's basename
# and requires the executable inside to match, so this path must end in
# `gh-stack` — that is what makes the command `gh stack`.
GH_STACK_SRC="$HOME/.local/share/gh-extensions-src/gh-stack"
ensure_gh_stack() {
  if ! have gh; then warn "gh not present; skipping gh-stack extension"; return 0; fi
  if gh extension list 2>/dev/null | grep -q 'gh stack'; then
    skip "gh-stack extension" "gh stack"
    return 0
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    warn "gh-stack extension is MISSING (would: gh extension install github/gh-stack)"
    return 0
  fi

  log "installing gh-stack extension ..."
  if gh extension install github/gh-stack >/dev/null 2>&1; then
    ok "gh stack ready (release binary)"
    return 0
  fi

  warn "gh-stack release download failed (GitHub API unreachable?); trying source build"
  if ! have go; then
    warn "go not present; gh-stack unavailable (stacked-PR commands will not work)"
    return 0
  fi
  # The symlink gh creates points at this directory, so it has to outlive the
  # build — keep it under $HOME rather than a temp dir.
  if [[ -d "$GH_STACK_SRC/.git" ]]; then
    git -C "$GH_STACK_SRC" fetch --depth 1 origin HEAD >/dev/null 2>&1 \
      && git -C "$GH_STACK_SRC" reset --hard FETCH_HEAD >/dev/null 2>&1 || true
  else
    rm -rf "$GH_STACK_SRC"
    mkdir -p "$(dirname "$GH_STACK_SRC")"
    git clone --depth 1 https://github.com/github/gh-stack "$GH_STACK_SRC" >/dev/null 2>&1 || {
      warn "could not clone github/gh-stack; gh-stack unavailable"; return 0; }
  fi
  ( cd "$GH_STACK_SRC" && go build -o ./gh-stack . ) >/dev/null 2>&1 || {
    warn "gh-stack source build failed; gh-stack unavailable"; return 0; }
  # gh only accepts "." for a local extension; an absolute path is parsed as
  # OWNER/REPO and rejected. So install from inside the directory.
  ( cd "$GH_STACK_SRC" && gh extension install . ) >/dev/null 2>&1 \
    && ok "gh stack ready (built from source)" \
    || warn "gh extension install failed; gh-stack unavailable"
}

# Agent skills for the tools this repo builds on: the
# @ansavva/design-system consumer set. They are machine-local tooling, not
# source — .agents/, .claude/skills/ and skills-lock.json are all gitignored, so
# a fresh clone has no skills until this runs. The `skills` CLI writes the real
# SKILL.md files under .agents/skills/ and symlinks them into .claude/skills/,
# which is where Claude Code looks; do not delete the symlinks.
ensure_skills() {
  if [[ -f "$REPO_ROOT/skills-lock.json" ]]; then
    skip "agent skills" "$REPO_ROOT/skills-lock.json"
    return 0
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    warn "agent skills are MISSING (would: npx skills@latest add ansavva/design-system)"
    return 0
  fi
  if ! have npx; then warn "npx not found; skipping agent skills"; return 0; fi
  log "installing agent skills ..."
  ( cd "$REPO_ROOT" \
    && npx --yes skills@latest add ansavva/design-system ) \
    || warn "agent skill install failed; re-run scripts/dev-setup.sh to retry"
}

# tflint's AWS ruleset plugin (CI parity). GitHub-release download; best-effort.
install_tflint_aws_plugin_best_effort() {
  [[ "$CHECK_ONLY" -eq 1 ]] && return 0
  if [[ "$PLATFORM" != "linux" ]]; then
    log "skipping tflint AWS ruleset plugin (pinned archive is Linux/CI only)."
    return 0
  fi
  local script="$REPO_ROOT/.github/scripts/install-tflint-aws-plugin.sh"
  [[ -f "$script" ]] || return 0
  local plugin="$HOME/.tflint.d/plugins/github.com/terraform-linters/tflint-ruleset-aws/0.47.0/tflint-ruleset-aws"
  if [[ -x "$plugin" ]]; then
    skip "tflint AWS ruleset plugin" "$plugin"
    return 0
  fi
  log "installing pinned tflint AWS ruleset plugin (best-effort) ..."
  if bash "$script" >/dev/null 2>&1; then
    ok "tflint AWS ruleset plugin installed (full CI parity)"
  else
    warn "tflint AWS plugin not installed (network-restricted?); bundled terraform ruleset still catches unused-declaration errors"
  fi
}

# ---------------------------------------------------------------------------
log "OS detected: $OS  (check-only: $CHECK_ONLY)"

# Adopt an already-installed Homebrew prefix before the first `have` check.
# brew_ensure short-circuits on `command -v` and only reaches require_brew (which
# is what puts the prefix on PATH) when a tool is missing — and in --check mode it
# returns before require_brew entirely. So on a machine where Homebrew installed
# these tools in an earlier run, every one of them reads as MISSING until
# something triggers the lazy bootstrap. Doing it here costs one `-x` test.
if [[ "$PLATFORM" == "linux" && -x "$LINUXBREW_PREFIX/bin/brew" ]]; then
  eval "$("$LINUXBREW_PREFIX/bin/brew" shellenv)"
fi

brew_ensure terraform hashicorp/tap/terraform
brew_ensure tflint    terraform-linters/tap/tflint
install_tflint_aws_plugin_best_effort
brew_ensure aws  awscli
brew_ensure gh   gh
brew_ensure node node
brew_ensure jq   jq
brew_ensure zip  zip
brew_ensure stripe stripe/stripe-cli/stripe

ensure_gh_stack

# Node version floor (the OS may already ship a newer/older node than brew's).
if have node; then
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [[ "$major" -ge "$NODE_MAJOR_MIN" ]] || warn "node $(node --version) is below required v${NODE_MAJOR_MIN}"
fi

ensure_skills

# Docker is a daemon/GUI concern — check only, never auto-install.
if have docker; then skip docker "$(command -v docker)"; else
  if [[ "$PLATFORM" == "macos" ]]; then
    warn "docker not found — install Docker Desktop: https://www.docker.com/products/docker-desktop/"
  else
    warn "docker not found — see https://docs.docker.com/engine/install/ubuntu/"
  fi
fi

log "shared toolchain ready. For complete service setup run its orchestrator, e.g.:"
log "    ./classroom/scripts/dev-setup.sh"
[[ "$PLATFORM" == "linux" && "$CHECK_ONLY" -ne 1 && "$BREW_STATE" == "ready" ]] && log "Tools are on PATH via /etc/profile.d/homebrew.sh (new shells) or: eval \"\$($LINUXBREW_PREFIX/bin/brew shellenv)\"" || true
ok "done."
