# Claude Instructions – humbugg

**Starting work on humbugg? Read [`docs/implementation-plan.md`](docs/implementation-plan.md)
first.** It records what is built, what is next and — the part the issue tracker cannot hold — the
order it has to happen in, plus the traps that have already cost this project time. This file covers
how the service is built and run; that one covers what to build next and why.

## What this service does

Humbugg is a gift-exchange platform, served from three hostnames:

| Surface | URL | What it is |
|---|---|---|
| Marketing | `www.humbugg.com` | React Router v7 SSR. The apex 308s to it. |
| Product app | `app.humbugg.com` | Expo + Expo Router, deployed as a static web export. The same codebase builds iOS/Android later. |
| API | `api.humbugg.com` | ASP.NET Core Lambda behind an API Gateway custom domain. |
| MCP connector | `api.humbugg.com/mcp` | Python MCP server on its own Lambda, same gateway: a member's exchanges as tools for Claude. [`mcp/README.md`](mcp/README.md) |

What it does:

1. Organizers create a group, invite members, and each member fills in a wish list / "do-not-give" list.
2. A matching engine assigns each member a recipient (Secret Santa-style) while respecting exclusions.
3. Members sign in via AWS Cognito and see their assignment in the React SPA.
4. After the draw each member has two anonymous chats — with their recipient (named) and with their giver (shown only as "Your Secret Santa"). Pushed over a WebSocket, poll fallback; no stored row names the giver. **This is the lead feature in marketing** — see [`docs/marketing.md`](docs/marketing.md).

## Stack

| Layer | Choice |
|---|---|
| Backend | ASP.NET Core 10 (C# 14) packaged as a Docker container Lambda behind API Gateway HTTP API, on its own domain |
| Marketing (`marketing/`) | React Router v7 SSR on a Docker Lambda + CloudFront; hashed assets on S3. Vite, Tailwind v4, the design system's **web** leaves |
| Product app (`app/`) | Expo + Expo Router; `expo export -p web` → S3 + CloudFront. Metro, **no Tailwind**, the design system's **native** leaves rendered through react-native-web |
| Auth | AWS Cognito (User Pool + secretless App Client). Sign-in **and sign-up** are hosted **Managed Login** pages at `auth.humbugg.com`; the app runs authorization code + PKCE through `expo-auth-session` and holds one screen, a button. Refresh-token rotation is on, which is why `ALLOW_REFRESH_TOKEN_AUTH` must never return to the client. The API still validates **access** tokens, unchanged. See [`docs/auth-managed-login.md`](docs/auth-managed-login.md). **Social sign-in** (Google, Apple, Facebook, LinkedIn) is buttons on that same page — Cognito identity providers, each optional on its credentials, plus a pre-sign-up trigger (`scripts/auth-trigger/`) that links a social identity onto the password account with the same email so the `sub` every row keys on stays one per person. [`docs/auth-social-login.md`](docs/auth-social-login.md) |
| Data | DynamoDB — profiles, groups, groupmembers, private draws, reveal audit events, and email delivery IDs. **No email address**: Humbugg stores none, and reads a verified one back from Cognito at send time (`IAccountDirectory`, #137) |
| Infra | Terraform in `humbugg/infra/` (`modules/` + `envs/prod` + per-machine `envs/dev`) |

## Directory Structure

```
humbugg/
├── backend/                    # ASP.NET Core app + Dockerfile, shipped as container Lambda
│   ├── Dockerfile
│   ├── Humbugg.slnx
│   ├── Humbugg.Api/             # controllers → services → DynamoDB repositories; Consumers/ (Lambda + Compose entry points)
│   └── Humbugg.Api.Tests/       # matching and domain tests
├── marketing/                  # Marketing site — React Router v7 SSR (www.humbugg.com)
│   ├── app/                     # routes (React Router file conventions)
│   ├── src/                     # pages, Layout, config
│   └── vite.config.ts
├── app/                        # Product app — Expo + Expo Router (app.humbugg.com)
│   ├── app/                     # file-based routes
│   ├── src/                     # api client, contexts, theme
│   └── app.json
├── mcp/                        # MCP connector — Python, calls the API as the signed-in person; widgets/ are its pages
├── infra/                      # Terraform
│   ├── modules/                # auth, compute, hosting, storage, mcp, webhook_relay (dev only)
│   ├── envs/prod/              # Lambda + API Gateway + Cognito, S3 + CloudFront + Route53 alias
│   ├── envs/dev-shared/        # the one shared dev resource: the Cognito pool
│   └── envs/dev/               # per-machine: tables, bucket, Stripe webhook relay
├── seeds/                      # dev.json — who exists on a dev stack and what they are in
├── scripts/                    # dev-*.sh, dev-seed.mjs, webhook-relay/receiver.mjs and auth-trigger/pre-sign-up.mjs (the zips)
└── CLAUDE.md                   # ← this file
```

## Shared Infrastructure

Terraform references (but doesn't own) two shared resources via `data` sources:

- **Route53 hosted zone** (`humbugg.com`) — a Terraform data source

`modules/certificates` provisions one us-east-1 ACM certificate covering the
apex, `www`, `app` and `api`. It is shared by both CloudFront distributions and
the API Gateway custom domain — us-east-1 does double duty here, being both
CloudFront's required region and this deployment's own region.

Two distributions: `modules/hosting_marketing` serves marketing (aliases apex and
`www`; a CloudFront function 308s everything that is not `www` to it) and
`modules/hosting_app` serves the product app plus `/avatars/*`.

## Local Development

Local development uses real, per-machine AWS resources rather than LocalStack
or shared developer resources. `dev-aws-setup.sh` persists a random UUID at
`~/.config/andreas-services/humbugg/machine-id`; that UUID scopes Terraform
state, DynamoDB tables, the private S3 bucket and the webhook relay. A developer
may therefore use multiple machines without collisions.

**The one exception is the Cognito pool, which every machine shares** —
`infra/envs/dev-shared`, pool `humbugg-dev`, Managed Login host
`humbugg-dev.auth.us-east-1.amazoncognito.com`. It was per machine until
September 2026; social sign-in moved it, because each provider console holds an
exact list of redirect URIs and a per-machine domain made every new machine four
console edits. `dev-aws-setup.sh` applies the shared stack (idempotent, locked)
before the machine's own, and the machine's stack reads the pool's ids from
`/humbugg/dev/cognito-*` in SSM. Accounts are therefore shared too: a `.test`
person seeded on one machine exists for all, with whatever password the last
seed set. Data stays per machine. Social credentials for it come from the
applying machine's `dev.env` (from the team password manager); the script
refuses to apply the shared stack while the pool has a provider this machine
has no keys for, so a keyless machine cannot strip what another added —
`--skip-shared` uses the pool untouched, `--allow-provider-removal` is the
override. `docs/auth-social-login.md`.

**Every local value lives in one file: `~/.config/andreas-services/humbugg/dev.env`.**
Backend config, both frontends' inlined values, Stripe test keys, the dev test
account — one file, documented key by key in [`dev.env.sample`](dev.env.sample).
There is no `backend/.env`, `app/.env.local` or `marketing/.env.local` any
more; `dev-aws-setup.sh` imports and deletes them if it finds them. The readers
come to the file: Docker Compose takes it as `env_file`, `dev-up-app.sh` exports
its `EXPO_PUBLIC_*` keys for Metro, `dev-up-marketing.sh` exports its `VITE_*`
keys for Vite, and the integration and e2e tiers parse it. It sits outside the
repo because ignored files vanish on `git clean` and never exist in a fresh
worktree, while this one is per machine and shared by every checkout on it.

```bash
# One-time toolchain and authentication setup (from the repo root).
# The shared setup includes the Stripe CLI from stripe/stripe-cli/stripe.
./humbugg/scripts/dev-setup.sh
stripe login

# Authenticate npm for the private design system package.
# NOT scripts/github-packages-auth.sh --export: it opens a device flow and hangs
# on a non-interactive session.
export NODE_AUTH_TOKEN=$(gh auth token)
npm --prefix humbugg/marketing install
npm --prefix humbugg/app install

# Read-only validation of shared tools, .NET, AWS resources, and env files.
./humbugg/scripts/dev-setup.sh --check

# Start backend (+ the Stripe webhook consumer beside it) and both frontends.
./humbugg/scripts/dev-up.sh

# Put seven .test people and two exchanges — one at the Free ceiling, one on
# Plus — on this machine. Needs dev-up.sh running. seeds/README.md.
./humbugg/scripts/dev-aws-seed.sh
```

The combined launcher supervises three processes — the backend Compose project
(API plus the webhook consumer), marketing, and app. It does not generate Stripe
API keys; `HUMBUGG_STRIPE_MODE=test`, the test publishable key, and the test
secret key must already be configured according to `docs/stripe-setup.md`; with
Stripe disabled the consumer idles with one log line. Ctrl+C stops the complete
session. Mailer and Mailpit remain a separate shared dependency and should be
started with `cd mailer && docker compose up --build`.

**Stripe webhooks take one path in every environment: gateway → receiver →
queue → the backend image.** `modules/webhook_relay` (studio's
`modules/callbacks` shape) is an HTTP API Gateway, a dependency-free Node zip
receiver that only enqueues, and an SQS queue with a DLQ. The consumer is the
API's own container entered through `ConsumerHost`
(`HUMBUGG_CONSUMER=stripe-webhooks`, `Consumers/StripeWebhooks/`): in prod a
Lambda on an event-source mapping, in dev the `webhook-consumer` Compose
service long-polling this machine's queue. It verifies Stripe's signature with
the queue's retention as the timestamp window
(`IBillingService.ProcessQueuedWebhookAsync`), keeps only events carrying its
`HUMBUGG_ENVIRONMENT` (`dev-<short12>` per machine, because every dev
endpoint sits in one sandbox; `production` in prod), and applies them through
the same `ApplyEventAsync` as the HTTP route. `dev-aws-setup.sh` registers the
dev URL with Stripe and writes the endpoint id and `whsec_` into `dev.env`;
prod's is registered by hand. `stripe listen` used to relay locally and lost
every event emitted while it was not running; the queue holds them for 14 days.
**The dev sandbox must not be production's account**: Stripe fans every event
to every endpoint in an account, and prod is test-mode until #159.
`docs/stripe-setup.md` §4.

### Development scripts

All commands run from the repository root:

| Script | Agent/developer usage |
|---|---|
| `scripts/dev-setup.sh` | Idempotently install shared tooling; use `--check` for a read-only prerequisite audit |
| `humbugg/scripts/dev-setup.sh` | Canonical dependency chain: shared setup → .NET 10 → per-machine AWS setup; accepts `--profile`, `--region`, `--yes`, `--check` |
| `humbugg/scripts/dev-aws-setup.sh` | Lower-level AWS provision/check command called by canonical setup; applies the shared pool stack then this machine's; accepts `--profile`, `--region`, `--yes`, `--check`, `--skip-shared`, `--allow-provider-removal` |
| `humbugg/scripts/dev-up.sh` | Preferred full local startup — backend + webhook consumer, both frontends, the MCP connector; accepts `--profile`, `--region` |
| `humbugg/scripts/dev-up-backend.sh` | Backend startup — the API and the Stripe webhook consumer, two services of one Compose project; exports temporary AWS credentials into Docker Compose without writing them to disk |
| `humbugg/scripts/dev-up-marketing.sh` | Marketing-site-only startup; exports `VITE_*` from `dev.env` and checks installed dependencies first |
| `humbugg/scripts/dev-up-mcp.sh` | MCP connector on :5002 against the local backend, signed in as a seeded person (`--as EMAIL`; `--stub` for the in-memory API). Builds the pages when stale; auth off, loopback only. For the Inspector and Claude Code; **pages render only in the desktop app**, from a stdio entry in its config (`python -m humbugg_mcp.dev`) — `mcp/README.md` |
| `humbugg/scripts/dev-test-mcp.sh` | The MCP integration tier against the running backend: draws a throwaway exchange through the tools and checks nobody can learn their giver |
| `humbugg/scripts/dev-up-app.sh` | Product-app-only startup; exports `EXPO_PUBLIC_*` from `dev.env`; defaults to `--web`, pass `--ios`/`--android` for a simulator |
| `humbugg/scripts/dev-logs-backend.sh` | Follow the backend container logs; accepts Docker Compose log options such as `--tail 200` |
| `humbugg/scripts/dev-user.sh` | Create or converge the one dev-stack account `HUMBUGG_DEV_USER_EMAIL` names; `--generate-password` for a non-interactive run, `--check` to report without changing. The address should be one of the people in `seeds/dev.json` |
| `humbugg/scripts/dev-aws-seed.sh` | Create every account in `seeds/dev.json` (one shared password, `HUMBUGG_DEV_USER_PASSWORD`) and load the fixture through the local API — profiles, exchanges, joins, a Plus purchase through Stripe test mode; `--check` reports without writing. Converges; see `seeds/README.md` |
| `humbugg/scripts/dev-aws-reset.sh` | Destructive data reset scoped to this machine — tables and bucket; run with `--dry-run` first. Never touches accounts: the pool is shared |
| `humbugg/scripts/dev-aws-destroy.sh` | Destroy this machine's AWS resources; the persistent UUID is deliberately retained |

`humbugg/scripts/dev-aws-common.sh` is a sourced implementation helper, not a
user command. AWS commands default to `$AWS_PROFILE`/`default` and
`$AWS_REGION`/`$AWS_DEFAULT_REGION`/`us-east-1`; the `default` profile is the
right one for this repo, so `--profile` is only needed to override it.

To start components separately:

```bash
./humbugg/scripts/dev-up-backend.sh                     # http://localhost:5001
./humbugg/scripts/dev-up-marketing.sh                         # http://localhost:5176
./humbugg/scripts/dev-up-app.sh                         # http://localhost:8081
./humbugg/scripts/dev-logs-backend.sh                   # follows backend logs
```

To reset or remove only the current machine's environment:

```bash
./humbugg/scripts/dev-aws-reset.sh --dry-run
./humbugg/scripts/dev-aws-reset.sh
./humbugg/scripts/dev-aws-destroy.sh
```

The reset script verifies the Terraform machine UUID and exact AWS resource
prefix before deleting data. It recreates the DynamoDB tables through Terraform
and empties S3. It never deletes Cognito users — the pool is the team's shared
one. The destroy script removes all per-machine AWS resources but retains the
UUID and state identity for safe reprovisioning; it leaves the shared stack
alone, which is torn down by hand with `terraform -chdir=humbugg/infra/envs/dev-shared destroy`
and only when no machine uses it.

See [`scripts/README.md`](../scripts/README.md) for the setup scripts and GitHub Packages auth.

`dev-aws-setup.sh` writes both frontends' values into `dev.env` — the prefixes
differ because the bundlers do (Vite exposes `VITE_*`, Metro inlines
`EXPO_PUBLIC_*`), and each dev-up script exports only its own prefix so neither
bundler is handed the Stripe secret key. Do not create shared or committed
values manually.

Marketing — no Cognito values, because the marketing site no longer
authenticates anyone:

```
VITE_APP_BASE_URL=http://localhost:5176
VITE_APP_ORIGIN=http://localhost:8081
VITE_API_BASE_URL=http://127.0.0.1:5001
```

`VITE_API_BASE_URL` is read only by the pricing page, which loads the plan
catalogue from `GET /api/plans` server-side rather than restating prices (#158).
Production sets nothing: `src/config/site.ts` defaults to `api.humbugg.com`, the
same way it defaults `APP_ORIGIN`.

Product app:

```
EXPO_PUBLIC_COGNITO_CLIENT_ID=<generated by scripts/dev-aws-setup.sh>
EXPO_PUBLIC_COGNITO_DOMAIN=<generated by scripts/dev-aws-setup.sh>
EXPO_PUBLIC_API_BASE_URL=http://127.0.0.1:5001/api
EXPO_PUBLIC_WEB_BASE_URL=http://localhost:5176
```

`EXPO_PUBLIC_COGNITO_DOMAIN` is the Managed Login **host**, no scheme and no path. A dev stack takes
a default Cognito domain (`<prefix>.auth.<region>.amazoncognito.com`) rather than a custom one, so no
certificate or DNS record is involved. The pool id and the AWS region are no longer app
configuration — Amplify needed them and the hosted flow does not; `dev-aws-setup.sh` strips them from
an existing `dev.env`.

The app calls the backend **cross-origin** in development as well as production,
so the backend's `CORS_ORIGINS` must list `http://localhost:8081` alongside
`http://localhost:5176`.

## Testing

**The map is [`docs/TESTING.md`](docs/TESTING.md)** — tiers, commands, "where does
my test go", and the rules a new test must follow (each traced to a real hazard).
The short version:

| Tier | Runs | Gate |
|---|---|---|
| Backend unit (`Humbugg.Api.Tests`) | every PR | — |
| Backend integration (`Humbugg.Api.IntegrationTests`, real dev-stack AWS) | local only | `HUMBUGG_INTEGRATION=1` via `scripts/dev-test-integration.sh` |
| App unit (jest) + browser stubbed (Playwright, committed fixtures) | every PR | — |
| App browser live (dev stack) | local only | `E2E_LIVE=1` |
| Marketing unit (vitest/jsdom) | every PR | — |
| Prod smoke (`humbugg-prod.yaml` post-deploy) | after deploy | detector, not a gate |
| MCP unit, OAuth shim, pages, conformance, Specmatic (`mcp/`) | every PR | — |
| MCP integration (`mcp/tests/test_integration.py`, dev backend) | local only | `HUMBUGG_INTEGRATION=1` |

Coverage is printed on every PR and gates on nothing, deliberately — the
reasoning is in the map.

**Operating the live service** (billing, email, support inbox, deletion requests, the
emergency reveal, credential rotation, health/alerts/rollback) is
[`docs/runbooks.md`](docs/runbooks.md). A suspected personal-data breach follows
[`docs/breach-response.md`](docs/breach-response.md) instead (GDPR Art. 33/34).

## Environment Variables (Prod)

All secrets/values live in the `humbugg-production` GitHub Actions environment. The `deploy-infra` job writes the resolved values into SSM Parameter Store under `/humbugg/prod/*`, and the `deploy-backend` + `deploy-frontend` jobs read them at deploy time.

| SSM param | Purpose |
|---|---|
| `/humbugg/prod/api-url` | API Gateway invoke URL |
| `/humbugg/prod/lambda-name` | Backend Lambda function name |
| `/humbugg/prod/ecr-url` | Backend ECR repo URL |
| `/humbugg/prod/cognito-user-pool-id` | Cognito pool ID |
| `/humbugg/prod/cognito-client-id` | Cognito app-client ID |
| `/humbugg/prod/mcp-clients` | MCP host → `{client_id, redirect_uris}` JSON (Terraform-owned). The MCP Lambda takes it as `HUMBUGG_MCP_CLIENTS`; the API takes its client ids as `COGNITO_ADDITIONAL_CLIENT_IDS` |
| `/humbugg/prod/cognito-auth-domain` | Managed Login host (`auth.humbugg.com`); inlined into the app export as `EXPO_PUBLIC_COGNITO_DOMAIN` |
| `/humbugg/prod/s3-bucket` | Frontend S3 bucket |
| `/humbugg/prod/cf-dist-id` | CloudFront distribution ID |
| `/humbugg/prod/email-from-address` | Verified transactional sender (`no-reply@humbugg.com`). Outbound app mail is SES via the shared Mailer; **inbound** mail (e.g. `support@humbugg.com`) is Google Workspace — see `docs/support-email.md` |
| _(env var, not SSM)_ `HUMBUGG_APP_BUCKET` | Shared application object bucket (`humbugg-prod-app-files-us-east-1`, the `app_files` bucket in the `storage` module); set literally in `update-lambda`. Profile photos live under the `avatars/` prefix — private, written by the Lambda under `avatars/*` (least-privilege IAM) and served read-only at `/avatars/*` through the app CloudFront distribution via OAC. Local development uses the per-machine AWS bucket created by `scripts/dev-aws-setup.sh`. Avatar URLs derive from `APP_BASE_URL` unless `HUMBUGG_AVATAR_BASE_URL` overrides it. |
| `/humbugg/prod/stripe/publishable-key` | Stripe **test-mode** publishable key (`String`; Terraform `billing` module) |
| `/humbugg/prod/stripe/secret-key` | Stripe **test-mode** secret key (`SecureString`; Terraform `billing` module) |
| `/humbugg/prod/stripe/webhook-secret` | Stripe webhook signing secret (`SecureString`; Terraform `billing` module) |

### Stripe billing (test mode only)

Billing config is **environment/SSM-sourced, never hardcoded**. Product/price IDs
flow through GitHub env `vars.*` into Lambda env; the secret key and webhook secret
are GitHub env `secrets.*`, injected via `TF_VAR_*` into the `billing` Terraform
module (which stores them as SSM `SecureString`) and set as Lambda env vars in
`update-lambda`. `StripeSettings.FromEnvironment()` validates at startup: it fails
fast when `HUMBUGG_STRIPE_MODE=test` without the required test-mode credentials, and
**blocks live mode** (`HUMBUGG_STRIPE_MODE=live` or any `sk_live_`/`pk_live_`/`rk_live_`
key) pending merchant-identity review (issue #159). Backend Stripe env vars:
`HUMBUGG_STRIPE_MODE` (`test`/`disabled`), `HUMBUGG_STRIPE_PUBLISHABLE_KEY`,
`HUMBUGG_STRIPE_SECRET_KEY`, `HUMBUGG_STRIPE_WEBHOOK_SECRET`. Full runbook:
`humbugg/docs/stripe-setup.md`.

## GitHub Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `.github/workflows/humbugg-pr.yml` | PR touching `humbugg/**` | Build backend Docker image (verify only), build frontend, no push |
| `.github/workflows/humbugg-prod.yaml` | Push to `main` touching `humbugg/**`, or `workflow_dispatch`, or `workflow_run` after shared infra applies | Single combined deploy. `detect-changes` → `deploy-infra` (Terraform apply on `humbugg/infra/envs/prod`) → `deploy-backend` + `deploy-frontend` in parallel. Gated by `humbugg-production` environment. |

### Combined deploy workflow (`humbugg-prod.yaml`)

**DAG**

```
detect-changes ─► deploy-infra (if humbugg/infra/** changed)
                       │
                       ├─► update-lambda           (backend + marketing SSR env vars, pin to :sha)
                       ├─► deploy-frontend-assets  (if humbugg/marketing/** changed OR infra ran)
                       └─► deploy-app              (if humbugg/app/** changed OR infra ran)
```

App jobs use `needs: [detect-changes, deploy-infra]` and an `if:` that runs when the app changed OR when `deploy-infra` produced new SSM values. If `deploy-infra` is skipped (app-only change) the app jobs still run because `!cancelled() && needs.deploy-infra.result != 'failure'` is true for skipped upstream jobs.

**`workflow_dispatch` inputs**

- `run_infra` (default `true`) — run the `deploy-infra` job.
- `run_app` (default `true`) — run `deploy-backend` and `deploy-frontend`.

Use `run_infra=true, run_app=false` for infra-only reruns, and `run_infra=false, run_app=true` to redeploy just the app using whatever is already in SSM.

**Concurrency**

Group `humbugg-prod` with `cancel-in-progress: false` — queued pushes wait for the previous run instead of racing on `update-function-code` or SSM writes.

## DynamoDB Tables

- `humbugg-prod-profiles` — per-user profile and wish-list data
- `humbugg-prod-groups` — group metadata (owner, name, member list)
- `humbugg-prod-groupmembers` — group ↔ member relationship + assignment results. Also holds gift
  progress (#132): the giver's own stage (`choosing`/`purchased`/`sent`) on their row, and the
  recipient's "it arrived" written onto their **giver's** row, resolved by inverting the draw — so
  the recipient never learns whose row they wrote to and the giver's record of what they did stays
  theirs. Both are draw-scoped. Also holds each
  member's **purchase claims** (#130): which wishes on their assigned recipient's list they have
  marked planned or bought. They live on the CLAIMANT's row rather than on the wish, which is the
  whole privacy design — a wishlist owner never reads another member's private membership fields, so
  the surprise is preserved by where the data is rather than by a projection somebody must remember
- `humbugg-prod-draws` — private giver → recipient maps, separate from ordinary group responses
- `humbugg-prod-audit-events` — standard append-only audit trail for sensitive exchange actions (creation/deletion, participant/exclusion/role/entitlement/reminder changes, draws, resets, reveals, self-service data clears, membership anonymization, and account deletion); see `infra/README.md`. Account deletion never erases audit records — it anonymizes only the `actor_user_id` via the narrow `IAuditActorAnonymizer` seam. Retention/deletion policy is documented in `docs/data-retention-deletion.md`.
- `humbugg-prod-analytics-events` — privacy-safe product-analytics funnel events (plan + aggregate counts only; no wishlist/address/email/token/assignment). Deduped by `idempotency_key`; disable via `HUMBUGG_ANALYTICS_ENABLED=false`; see `docs/analytics.md`
- `humbugg-prod-questions` — anonymous giver↔recipient question threads (#131), keyed
  `({groupId}:{drawId}:{recipientMemberId}, message_id)`. **No row stores the giver.** A message
  records which SIDE wrote it and the API re-derives who the giver is from the draw on every
  request, so there is no field to project, no id for a URL to carry, and nothing for a later
  endpoint to leak by returning a whole record. The `group_id` index exists for deletion, not
  reading, and projects only the keys plus `recipient_member_id`. The `#thread` control row also
  carries `giver_seen` / `recipient_seen` — the newest message id each SIDE has had on screen,
  written by the explicit `…/questions/seen` routes (fetching is not seeing). They drive the
  `unread` count and the "message waiting" mail, which goes once per unread stretch, not once
  per message. There is no message cap; a 2 s per-side flood gap is the only send limit
- `humbugg-prod-email-messages` — stable transactional message IDs and delivery state

- `humbugg-prod-chat-connections` — the realtime channel (#691). Two kinds of short-lived row
  keyed by `connection_id`: a WebSocket **connection** (`user_id`, two-hour TTL) and a one-time
  **ticket** (`ticket#…`, `user_id`, sixty-second TTL) that a `POST /api/realtime/tickets` mints
  and the `$connect` authorizer spends. Keyed by user, never by who gives to whom. See the
  realtime section below.

## The realtime channel (#691)

The anonymous chat is pushed, not polled. `modules/realtime` is an API Gateway **WebSocket** API on
`wss://ws.humbugg.com` (a custom domain cannot mix WebSocket and HTTP APIs, hence the hostname —
adding it to the certificate's SANs replaced the certificate, survivably). Two Lambdas run the
backend image under `HUMBUGG_CONSUMER` modes: `realtime-authorizer` (a REQUEST authorizer on
`$connect` that consumes the ticket in `?ticket=` and hands the user id on) and
`realtime-connections` (`$connect` records the socket, `$disconnect` forgets it, `$default` drops
client pings). The API Lambda pushes through the management endpoint
(`HUMBUGG_REALTIME_ENDPOINT`, the `execute-api:ManageConnections` grant) when
`QuestionService` appends a message or moves a seen marker.

**A nudge is `{ type, group_id, side }` and nothing else** — no body, no name, no message id. The
client refetches through the existing authorized GET. The access token never travels in the socket
URL; the ticket does, and it is 256 random bits, single-use and dead in a minute.

**A dev stack has no API Gateway**: with `HUMBUGG_REALTIME_ENDPOINT` unset the container hosts
the sockets itself on `ws://127.0.0.1:5001/ws` (`InProcessRealtimeHub`, tickets and connections in
memory) and the app connects to `EXPO_PUBLIC_REALTIME_URL`, which `dev-aws-setup.sh` writes.
Unset in the app, there is no socket and the chat polls: 5 s while on screen, 30 s while not.
Connected, the poll drops to a 60 s safety net.

Profile photos are **not** in DynamoDB: the `humbugg-prod-profiles` row stores only an `avatar_key`
reference, and the image bytes live under the `avatars/` prefix of the shared application object
bucket `humbugg-prod-app-files-us-east-1` (Terraform `storage` module, `app_files` bucket — there is
no separate avatars bucket or module). Uploads are validated and safely re-encoded to a square, metadata-free JPEG
(`SixLabors.ImageSharp`) before storage; when no photo is set, the frontend renders an initials avatar.

Production tables are accessed through the AWS SDK for .NET directly from the
Lambda (no ORM, no VPC). Local app runs use per-machine AWS DynamoDB tables
and the unsigned shared Mailer API with Mailpit for product email. Mailpit never
relays externally. Unit tests retain the in-memory capture adapter and ledger.
Production signs Mailer API requests with the backend Lambda role, and a
separate status Lambda consumes normalized delivery feedback. Local end-to-end
testing uses the containers. `DynamoDbBootstrap` owns local-only table
bootstrap; repository classes own Humbugg persistence operations.
