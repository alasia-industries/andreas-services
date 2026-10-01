# Andreas Services

This repository is a small portfolio of independently deployed applications that share a single source tree for convenience. Each directory under the root represents its own deployable unit with its own tech stack, pipeline, and README:

- **`classroom/`**, **`website/`**, **`mailer/`** – see each folder's README.

Humbugg (the gift-exchange platform) moved to its own repo, `ansavva/humbugg`, on 2026-09-30. It still uses `mailer/` and the shared `infra/`.

Because the projects have separate cloud resources and release cadences, changes should normally be scoped to a single directory. Refer to the README in each folder for details on setup, technology choices, prerequisites, and deployment assumptions.

## Local development setup

Bootstrap the toolchain with the idempotent setup scripts (Homebrew on both macOS
and Linux; safe to re-run — already-installed tools are skipped). From the repo root:

```bash
./scripts/dev-setup.sh

# See what's missing without installing anything:
./scripts/dev-setup.sh --check
```

`scripts/dev-setup.sh` also installs the agent skills for
`@ansavva/design-system`. They are machine-local tooling — `.agents/`,
`.claude/skills/` and `skills-lock.json` are gitignored — so a fresh clone has no
skills until setup runs.

The `website/` and `classroom/` frontends depend on the
`@ansavva/design-system` package, published from the separate
[ansavva/design-system](https://github.com/ansavva/design-system) repo to GitHub
Packages. Every read needs a token with the `read:packages` scope exposed as
`NODE_AUTH_TOKEN`, including for public packages — there is no anonymous install:

```bash
export GITHUB_PACKAGES_TOKEN=<pat-with-read:packages>
eval "$(./scripts/github-packages-auth.sh --export)"   # sets NODE_AUTH_TOKEN
```

Full details (macOS vs. Linux specifics, how the Linux path runs Homebrew as a
non-root user, per-service scripts) are in [`scripts/README.md`](scripts/README.md).

## Pre-commit hooks

`.pre-commit-config.yaml` mirrors the PR-side checks (cfn-lint, terraform fmt + validate) so bad templates never make it into a PR. To enable locally:

```bash
pip install pre-commit
pre-commit install
```

Run manually against the whole tree: `pre-commit run --all-files`.
