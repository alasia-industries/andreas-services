# Developer / CI toolchain scripts

Idempotent bootstrap scripts that install the tools needed to build and test
this monorepo. Safe to re-run: every tool is checked before install, so an
already-installed dependency is never reinstalled. **Homebrew is the installer
on both macOS and Linux.**

Two layers — a shared base plus thin per-service scripts:

| Script | Scope | Installs |
|---|---|---|
| `scripts/dev-setup.sh` | Shared base (all services) | Terraform, tflint (+ pinned AWS ruleset, best-effort), AWS CLI, Node.js, jq, zip, Stripe CLI (+ Docker check), agent skills |
| `scripts/github-packages-auth.sh` | Shared base (all frontends) | Ensures a `read:packages` token is available as `NODE_AUTH_TOKEN` so `npm ci` can install `@ansavva/design-system` from GitHub Packages |
| `classroom/scripts/dev-setup.sh` | Classroom | Writes `frontend/.env.local` from this machine's dev stack, then installs the backend's Poetry env and the frontend's `node_modules` |

## Targets (both use Homebrew)

- **macOS** (developer machines) — `brew` runs as your normal user. Docker
  Desktop and Homebrew itself are the only interactive/GUI steps.
- **Linux** (this cloud sandbox / GitHub Actions) — Homebrew **refuses to run as
  root**, and these environments are root, so the script installs Homebrew into
  the default prefix `/home/linuxbrew/.linuxbrew` **owned by the non-root
  `ubuntu` user** and runs every `brew` call as that user via `sudo -u ubuntu`.
  The prefix `bin` is put on `PATH` for the current run and for future shells via
  `/etc/profile.d/homebrew.sh`, so root and CI agents can execute the tools.

Notes:
- **Terraform** and **tflint** are not in homebrew-core; the scripts install them
  from taps (`hashicorp/tap/terraform`, `terraform-linters/tap/tflint`) on every
  platform.
- **Stripe CLI** is installed from Stripe's official Homebrew tap with
  `brew install stripe/stripe-cli/stripe`.
- The pinned tflint **AWS ruleset plugin** is installed best-effort on Linux/CI,
  where that release archive is used. macOS skips the Linux-only plugin. The
  download is cached and time-bounded; tflint's bundled `terraform` ruleset
  still catches common failures such as `terraform_unused_declarations`.

## Usage

```bash
# From the repo root:
./scripts/dev-setup.sh

# Check without installing anything:
./scripts/dev-setup.sh --check
```

On Linux, if `brew`/its tools aren't on your `PATH` in a fresh non-login shell:

```bash
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```

## Agent skills

`scripts/dev-setup.sh` installs the `@ansavva/design-system` consumer skill set
(`ansavva/design-system`) with the `skills` CLI. The Expo/EAS set moved to the
Humbugg repo with the app that uses it.

```bash
npx --yes skills@latest add ansavva/design-system
```

These are **machine-local tooling, not source**. `.agents/`, `.claude/skills/`
and `skills-lock.json` are all gitignored, so a fresh clone has no skills until
setup runs, and re-running setup is a no-op once `skills-lock.json` exists.

The real `SKILL.md` files live under `.agents/skills/`; the entries in
`.claude/skills/` are **symlinks** into them, which is how Claude Code discovers
them. They are not duplicates — deleting the symlinks makes every skill
invisible while orphaning the real files.

The one exception is `.claude/skills/design-system-ui/`, which this repo authors
and commits: it is our own rule that UI comes from the design system, and it
points at the four installed consumer skills for the package's own mechanics.

## GitHub Packages auth (`@ansavva/design-system`)

The `website/` and `classroom/` frontends depend on the `@ansavva/design-system`
package, published from the separate
[ansavva/design-system](https://github.com/ansavva/design-system) repo to
`npm.pkg.github.com`. Their
`.npmrc` reads the token from `${NODE_AUTH_TOKEN}`, and installing the package
requires a token with the **`read:packages`** scope (classic PAT) / **Packages:
Read-only** permission (fine-grained PAT). The default `GH_TOKEN` in CI/sandboxes
does not have it, so `npm ci` fails with `403 ... does not match expected scopes`.

`scripts/github-packages-auth.sh` resolves this idempotently:

```bash
# CI / sandbox: provide a read:packages PAT, then the script picks it up:
export GITHUB_PACKAGES_TOKEN=<pat-with-read:packages>
eval "$(./scripts/github-packages-auth.sh --export)"   # sets NODE_AUTH_TOKEN

# Developer machine with gh: adds the scope to your existing login:
./scripts/github-packages-auth.sh                       # runs `gh auth refresh -s read:packages`

# Verify only (no changes):
./scripts/github-packages-auth.sh --check
```

The script never writes a token into a committed file — the repo `.npmrc` uses the
`${NODE_AUTH_TOKEN}` env indirection. The only non-scriptable step is creating a
token with the scope in the first place (a GitHub UI / `gh` action); the script
does everything after that.

## Adding a new service

Give each service its own `<service>/scripts/dev-setup.sh` for stack-specific
runtimes (following `classroom/scripts/dev-setup.sh`), and keep cross-cutting
tools in the shared `scripts/dev-setup.sh`.
