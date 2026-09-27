# Humbugg testing — the map

Humbugg's suites follow studio's model: tiers with hard boundaries, one gate per
gated tier, and harnesses that police themselves. Studio's tiers are directories
under one pytest tree; Humbugg's live in four ecosystems (xUnit, Jest, Vitest,
Playwright), so the boundary is a project or a mode rather than a directory — but
the questions "which tier am I in" and "what may I touch" still have one shared
answer, and this file is where it lives.

## The tiers

| Tier | Where | Runs | Talks to | Gate |
|---|---|---|---|---|
| Backend unit | `backend/Humbugg.Api.Tests/` | every PR | hand-written fakes | — |
| Backend integration | `backend/Humbugg.Api.IntegrationTests/` | **local only, never CI** | real dev-stack AWS | `HUMBUGG_INTEGRATION=1` |
| App unit | `app/src/**/*.test.ts(x)` | every PR | jest-expo mocks | — |
| App browser, stubbed | `app/e2e/*.spec.ts` | every PR | committed fixtures | — |
| App browser, live | same specs, plus an API round trip (`session.spec.ts`, #373) | local only | dev backend + dev Cognito | `E2E_LIVE=1` |
| Marketing unit | `marketing/**/*.test.ts(x)` | every PR | jsdom | — |
| Prod smoke | `humbugg-prod.yaml` post-deploy jobs | after deploy | live prod, anonymously **and signed in** (#642) | — |
| MCP unit | `mcp/tests/` | every PR | the in-memory stub API (`humbugg_mcp/stub.py`) | — |
| MCP pages | `mcp/widgets/` (vitest + Playwright) | every PR | a test host + committed fixtures | — |
| MCP conformance | `humbugg-pr.yml` job `mcp` | every PR | `humbugg_mcp.testing:app` — the stub, never AWS | — |
| MCP integration | `mcp/tests/test_integration.py` | **local only** | the dev backend + dev Cognito, seeded people | `HUMBUGG_INTEGRATION=1` |

The prod smoke jobs (the curl assertions over all three surfaces and the SES
mailbox-simulator loop) are a **detector, not a gate**: there is no staging, the
image is already serving, and their unique value is exercising what nothing local
can — the deployed Lambda's own IAM role, CloudFront behaviors, real SES feedback.

Since #642 that includes an **authenticated** round trip. It is the only tier that
crosses a real API Gateway with a real token, which is the gap #586 named: every
other tier stops short of the gateway, so `ANY /api/{proxy+}`'s authorizer — the
thing that 401ed two `[AllowAnonymous]` endpoints for their whole lives (#582) —
was exercised by nothing until a change was already serving. `smoke-session.mjs`
signs in over SRP as the smoke account, and the step asserts that `GET /api/me`
reaches the application, that `GET /api/me/export` reports the token's own `sub`,
that `GET /api/groups` answers 200, and that an ID token and no token are both
refused. It runs against **production**, not a dev stack, because the dev stack has
no gateway and giving each machine one costs more than it returns (#642).

## Commands

```bash
# ── PR tier (what CI runs) ────────────────────────────────────────────────────
cd humbugg/backend  && dotnet test Humbugg.slnx        # unit + integration-as-skips
cd humbugg/app      && npm test                        # jest
cd humbugg/app      && npm run e2e                     # Playwright, stubbed — no AWS
cd humbugg/app      && npm run a11y:check              # accessible names, read off the source
cd humbugg/marketing && npm test                       # vitest

# ── integration tier (local only) ─────────────────────────────────────────────
humbugg/scripts/dev-test-integration.sh                # THE entry point; exports the flag

# ── browser tier, live (local only) ───────────────────────────────────────────
humbugg/scripts/dev-up.sh                              # backend :5001 + app :8081
cd humbugg/app && npm run e2e:live

# ── re-record the e2e fixtures ────────────────────────────────────────────────
humbugg/scripts/dev-up-backend.sh
cd humbugg/app && npm run e2e:capture
```

## The part that is not a test

Accessibility is checked three ways, because it splits three ways:

| Property | Where | Why there |
|---|---|---|
| An accessible name on every control | `app/tool/accessibility-audit.ts` | decidable from the source, and invisible at runtime — an `aria-label` inside a `FieldLabel` is silently overridden by the design system's `aria-labelledby`, so it looks correct and does nothing |
| Colour contrast | `app/src/theme/contrast.test.ts` | decidable from `brand-colors.json`, so editing a brand colour is what runs it |
| Width, keyboard reach, private data on screen | `app/e2e/verification.spec.ts` | needs a rendered page |

What is left after those three needs a person and a real device — a screen reader, gesture
navigation, the largest text size, a two-account walkthrough of the whole exchange. That is
[`free-verification-checklist.md`](free-verification-checklist.md), and it is short on purpose:
everything a machine could take has been taken off it.

## Where does my test go?

- **A service, the matching engine, email composition, validation** — anything a
  hand-written fake can stand in for → `Humbugg.Api.Tests`. This is the default.
- **A repository's actual DynamoDB behavior** (marshalling, key construction, GSI
  queries, conditional writes, transactions) → `Humbugg.Api.IntegrationTests/Data/`.
  The unit tier fakes at the `I*Repository` interfaces, so everything below them is
  invisible to it — that blind spot is this tier's whole reason to exist.
- **The HTTP pipeline** (auth, CORS, error envelopes, model binding, a full flow
  over real tables) → `Humbugg.Api.IntegrationTests/Http/`, in-process via
  `WebApplicationFactory<Program>`.
  **Unless CI has to catch it.** That tier self-skips without `HUMBUGG_INTEGRATION=1`,
  so a pipeline rule whose regression must go red on a PR belongs in the unit tier
  instead, hosting `Program.cs` over stubbed AWS clients — `HostedApi.cs` and
  `GatewayAuthorizerPrincipalTests` are the pattern. #656 is why: the integration tier
  already asserted an ID token is refused, passed, and production accepted one anyway.
- **A screen, context, or util in the app** → colocated `*.test.tsx` under
  `app/src/`. Auth-coupled seams (contexts, session store, redirect) belong here;
  presentational components are exercised more honestly by the browser tier.
- **A user journey in a real browser** → `app/e2e/*.spec.ts` (see
  [`app/e2e/README.md`](../app/e2e/README.md)).
- **Marketing content or links** → colocated `*.test.tsx` in `marketing/`.
- **Only observable on the deployed system** → the post-deploy smoke jobs in
  `humbugg-prod.yaml`.

## What a new test may not do

Each rule traces to a real hazard, most of them already paid for once:

1. **No PR-tier test may touch AWS.** PR workflows never write to AWS (repo rule);
   anything needing real tables goes behind `HUMBUGG_INTEGRATION=1`, and the flag
   is exported in exactly one place — `dev-test-integration.sh`.
2. **No integration test may depend on prod, or on another machine's stack.**
   Configuration comes only from `~/.config/andreas-services/humbugg/dev.env`, written by `dev-aws-setup.sh`
   from the machine-scoped Terraform outputs. The Cognito pool in it is the
   team's shared one, by design; tables and bucket are this machine's. `AWS_PROFILE` in that file is
   deliberately ignored by the fixture.
3. **Integration tests write `itest-`-prefixed ids and register cleanup.** The
   dev-stack tables are shared with your local app; `dev-aws-reset.sh` is the
   blunt fallback, not the plan. Reads through a GSI go through `Eventually(...)`
   — a bare read-after-write on an eventually-consistent index is a flake.
4. **No fixture captured with `curl`.** `app/e2e/support/capture-fixtures.mjs`
   scrubs invite secrets and presigned URLs and asserts the scrub held. (Studio
   put a signing key id into git this way; the rule exists so we never do.)
5. **No auth backdoor compiled into the app.** The e2e session is seeded through
   the app's own `humbugg.auth.*` token store; an `if (E2E)` switch in the bundle
   is a production vulnerability wearing a test's clothes.
6. **No module-level skip.** `test.skip(LIVE, …)` at module level skips a whole
   file and reports green having run nothing; skip per-spec (`stubOnly(...)`).
7. **The Metro export for e2e always runs `--clear`.** Metro's transform cache
   does not key on env vars; without it the export silently reuses whichever
   `EXPO_PUBLIC_*` values the previous export inlined (measured: identical bundle
   hash across env changes).
8. **The app's jest `testTimeout` is 15 s, and that is not a licence for slow tests.** The
   first test in a suite pays for every module its render is the first to reach —
   babel-jest transforms a design-system leaf the first time it is required, and on a
   cold CI cache the first `render(<WishListPanel/>)` alone measured ~5 s, against
   jest's 5 s default. It passed by a hair for weeks and failed the day a second heavy
   suite ran beside it. A test that genuinely needs seconds is doing too much; the
   raised ceiling is for the transform tax, which no test controls.
9. **The prod smoke account stays empty, and read-only.** It is an ordinary user
   in the **production** pool, and everything that makes it safe
   is a property of what it holds: no group, no membership, no profile row, no
   personal data. So the smoke step only ever **reads** — a new assertion may add
   a `GET`, never a `POST`/`PUT`/`DELETE`. That is why `GET /api/me` is asserted
   as *200 or 404* rather than 200: with no profile row the application answers
   404, and creating one to make the check tidier would put the first piece of
   data on an account whose whole defence is having none. The identity assertion
   uses `GET /api/me/export`, which reports the caller's id either way.
   Credentials live only in the `humbugg-production` environment — var
   `HUMBUGG_SMOKE_USER_EMAIL`, secret `HUMBUGG_SMOKE_USER_PASSWORD` — and never in
   the repo — the address included, so there is one place to change it. Rotate
   with `aws cognito-idp admin-set-user-password --permanent` followed by
   updating the secret; nothing else has to change. The address is on a reserved
   `.test` domain (RFC 2606), so no mail can ever be delivered to it.
9. **Env-var table names stay cross-checked.** `CiSmokeEnvironmentTests` parses
   `Program.cs` `RequiredTable` literals against the PR workflow's `-e` flags —
   written after three PRs sat red for weeks on the same one-line omission. Add a
   table, expect that test to tell you where else it must appear.

## Coverage

Coverage is **printed and gates on nothing** — in `validate-backend` (MTP
CodeCoverage → cobertura → a line per project in the job log), `build-app`
(`jest --coverage`), and `build-marketing` (`vitest --coverage`). There is no
`fail-under` threshold, deliberately: a number picked before anyone has read a
real one either sits below reality (and means nothing) or fires on unrelated PRs
until somebody deletes it. Read the number, aim work at what it says is dark —
the repository layer was 2,106 uncovered lines for months while the services
above it sat at near-full coverage, and no threshold would have said so.

Note for the backend: `Microsoft.Testing.Extensions.CodeCoverage` must stay on a
version whose `Microsoft.Testing.Platform` dependency matches what xunit.v3
resolves (currently the 1.9.x family — xunit 3.2.2 ships `mtp-v1` assemblies). A
newer coverage package silently upgrades MTP and every extension in the process
fails to load with `TypeLoadException` at run start.
