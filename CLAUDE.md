# Claude Instructions – andreas-services Monorepo

## How to report back

Applies to every chat reply, commit message, PR body and code comment in this repo.

- Be extremely concise. Sacrifice grammar for concision — fragments over full sentences, drop articles and filler.
- Start directly with the answer. No preamble, no restating the question.
- Stop after the last relevant fact. No summary, no offer of next steps unless asked.
- Short declarative sentences. One claim each.
- Most important point first, then detail in descending order.

Concision never justifies omitting a failure, a skipped step, or a caveat that changes a decision — cut words, not facts.

## What this repo is

A monorepo of independently deployed services, all under the `andreas.services` domain.
Each subdirectory is a **fully self-contained deployable unit** — it has its own backend, frontend, infra code, and deployment pipeline. Services do **not** share code or libraries.

## Environment access

**AWS CLI — use the `default` profile.** A bare `aws ...` command is correct; no
`--profile` flag is needed:

```bash
aws sts get-caller-identity
```

`default` is AWS account `704202188703` (`user/ansavva`) — the account that hosts
all `andreas.services` and `humbugg.com` infrastructure.

**Credentials are a long-lived IAM access key, not a browser session.** They
arrive one of two ways and both resolve to the same key:

| Where you are | Mechanism |
| --- | --- |
| A machine with a home directory of its own | `[default]` in `~/.aws/credentials` |
| A cloud session, container or CI runner | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in the environment |

Set `AWS_DEFAULT_REGION=us-east-1` alongside the environment variables.
`~/.aws/config` carries the region on a machine that has one, and nothing
carries it on a machine that does not — a missing region fails as
`NoRegionError`, which does not mention credentials and reads like a code bug.

**This replaced `aws login` in August 2026, for portability rather than
convenience.** `aws login` is a browser flow. It cannot complete on a phone
driving a remote-control session, in a Claude cloud session, or over SSH — so
half the places this repo actually gets worked on could not authenticate at
all, and the sessions it did produce expired in under ~15 minutes.

`login_session` is still in `~/.aws/config` and is deliberately left there. It
cannot shadow the key. Measured from the provider chain in awscli 2.35
(`awscli/botocore/credentials.py`, `ProfileProviderBuilder.providers`), the
resolution order is:

```
env vars → assume-role → web-identity → SSO → ~/.aws/credentials → login_session → process → config
```

Environment variables beat the credentials file, the credentials file beats
`login_session`, and `aws login` survives as a fallback that only takes effect
if the key is removed. Confirmed behaviourally too, not just read off the
source: with a deliberately invalid key in `~/.aws/credentials` and a live login
session in the cache, `aws sts get-caller-identity` fails `InvalidClientTokenId`
rather than falling back to the session.

**Terraform no longer needs a credential export.** It used to:

```bash
eval "$(aws configure export-credentials --format env)"
```

That line was load-bearing under `aws login`, which wrote its session to a cache
only the AWS CLI reads: Terraform's S3 **backend** resolved it and the AWS
**provider** did not, so `init` and `state *` worked while `plan`, `apply`,
`import` and `destroy` failed. It cost a half-finished state migration in
August 2026 — a `state rm` succeeded, the `terraform import` on the very next
line failed, and the error was misread as session expiry three times before the
split was found. A key in `~/.aws/credentials` is read natively by the AWS
provider, the S3 backend and boto3 alike, so the split is gone. The export is
now a no-op, not a fix; running it out of habit is harmless.

Keep the failure signature, because it now means something different:

```
Error: No valid credential sources found
failed to refresh cached credentials, no EC2 IMDS role found,
operation error ec2imds: GetMetadata, ... dial tcp 169.254.169.254:80: connect: host is down
```

Under `aws login` it meant "you forgot the export". Now it means the machine has
**no credentials at all** — no `~/.aws/credentials`, no environment variables —
and the fix is to supply them, not to re-run anything. `aws sts
get-caller-identity` is a trustworthy probe again: it and Terraform read the
same source, so if the CLI authenticates, Terraform does.

**The key is long-lived, so treat it as one.** It belongs to the `ansavva` IAM
user and inherits that user's permissions in full, with no expiry. Rotate it
with `aws iam create-access-key` followed by `aws iam delete-access-key` on the
old id. Never commit it, never paste it into a chat session, and never put it in
`.claude/settings*.json` — that file is committed. None of this touches CI,
which assumes a role over OIDC and holds no key at all.

Prefer the CLI for read-only investigation of live
infrastructure (CloudFront, S3, Lambda, DynamoDB, CloudWatch Logs, SSM, etc.) when
diagnosing issues.

**`curl` against the live sites usually works — test it, do not assume.** This
file used to state flatly that outbound HTTP to `*.andreas.services` was blocked
by the sandbox network policy (`403 host_not_allowed`). That is not true in
general: live service sites answer `200`. The rule was written from one sandbox that did block it and was then
believed rather than retested, which cost a session the check it was in the
middle of — it reported the site unreachable, and it was not. A blocked sandbox
is still possible, so try the request and read what comes back.

**What `curl` can and cannot settle.** It proves reachability, DNS, TLS, CORS
preflight, and what a deployed bundle contains. It cannot exercise an
authenticated route: every `/api` path sits behind the API Gateway Cognito
authorizer, so an unauthenticated call returns the gateway's
`{"message":"Unauthorized"}` and never reaches the application — a 401 there
says nothing about the code. Signing in for real needs a token, which needs a
pool account in the service's **dev** pool.
Final verification against prod is a browser, and that is on the user.

Prefer fixing infrastructure through Terraform + the deploy pipeline over manual
CLI mutations, to avoid IaC drift.

**GitHub access depends on where the session runs — read the `github-access`
skill before any `gh` command or GitHub 403.** In a Claude cloud session the egress
proxy denies nearly every repo-scoped `gh` call (REST `/repos/*`, most GraphQL, all
of `/actions/secrets` and `/actions/variables`), and the `mcp__github__*` tools are
the working channel. The proxy also strips `Authorization` and injects its own App
identity, so `gh auth status` reports `The token in GH_TOKEN is invalid` when the
token is fine — **never rotate a PAT on the strength of that message.** Locally,
with a real PAT and no proxy, `gh` behaves normally. Secret *values* are unreadable
in both, by design.

## Services

| Directory | Purpose | Stack |
|-----------|---------|-------|
| `classroom/` | Classroom app | Flask + React/Vite |
| `website/` | `www.andreas.services` | Flask + React Router/Vite |
| `mailer/` | Shared transactional mail API (SES) — Humbugg's too | Python Lambda |
| `infra/` | Shared infrastructure | Terraform |

**Humbugg lives in its own repo** — `ansavva/humbugg`, checked out at `~/repos/humbugg`
— since 2026-09-30. It still depends on `mailer/`, the Terraform state bucket and
the CI OIDC role in `infra/envs/shared` (whose trust lists `repo:ansavva/humbugg:*`
via `extra_github_repos`). Changing any of those can break Humbugg's deploy, and
no workflow here reruns it: dispatch `humbugg-prod.yaml` in that repo afterwards.

## Dev ports

Every service runs locally at once without a clash. One table, and every
`vite.config`, dev script, Cognito localhost callback and `.claude/launch.json`
entry agrees with it — change a port here first, then everywhere the table
names.

| Service | Backend | Frontend | Also |
|---|---|---|---|
| `classroom/` | 8001 | 5174 | |
| `website/` | 8002 | 5175 | prod build served on 3000 |
| Humbugg (other repo) | 5001 (Docker), 5050/5051 (`dotnet run`) | marketing 5176 · app (Expo web) 8081 | app stubbed e2e 4174 · Mailpit 8025 · MCP 5002 |

Vite is `strictPort` everywhere: a silent hop to the next free port lands on
one the service's Cognito pool has no callback for, and the sign-in fails a
screen later with nothing pointing back here. A service whose port is taken says so and
stops.

Every `docker-compose.yml` sets top-level `name:` to its service (`humbugg`,
`website`, …). Without it Compose names the project after the directory,
and every service keeps its compose file in `backend/`, so `docker ps` showed
`backend-backend-1` with nothing saying which app it was.

## Shared Infrastructure (`infra/`)

The root `infra/` directory owns **cross-cutting AWS resources** shared by all services. Never create these inside an individual service's infra:

- **Route53** hosted zone for `andreas.services`
- **ACM wildcard certificate** for `*.andreas.services` (us-east-1, required for CloudFront)

> **Note:** The VPC, NAT Gateway, and DocumentDB cluster have been removed. All services use DynamoDB (IAM-controlled, no VPC required), which eliminates the ~$230/month NAT Gateway cost.

State is in S3: `s3://andreas-services-terraform-state/`
- Shared: `shared/terraform.tfstate`
- Per-service: `<service>/<env>/terraform.tfstate` (e.g. `humbugg/prod/`, `website/prod/`)

Services reference shared resources via Terraform data sources — never duplicate them:
```hcl
data "aws_acm_certificate" "wildcard" {
  provider = aws.us_east_1
  domain   = "*.andreas.services"
  statuses = ["ISSUED"]
}

data "aws_route53_zone" "main" {
  name = "andreas.services"
}
```

## Patterns Every Service Follows

### Frontend
- **Design system**: all UI comes from **`@ansavva/design-system`**, published from the separate
  [ansavva/design-system](https://github.com/ansavva/design-system) repo. There is no local component
  library in this monorepo and there must not become one. **Read the `design-system-ui` skill before
  adding or changing any screen, form, dialog or styled component** — it covers the catalogue, the
  platform-leaf import rule, and the theming seams that carry each service's brand.
- **Build tool**: Vite (not Create React App) for web surfaces. **Expo + Metro** for
  React Native surfaces (Humbugg's app, in its own repo). The bundler is what selects the design system's
  platform leaf, so this choice is not cosmetic.
- **Framework**: React 18
- **Styling**: Tailwind CSS (v3 or v4) on Vite surfaces. Expo surfaces have **no
  Tailwind pipeline** — they use React Native `StyleSheet` and the design system's
  `ThemeProvider`.
- **Language**: TypeScript preferred, strict mode
- **Folder structure**:
  ```
  frontend/src/
  ├── apis/          # API call wrappers
  ├── components/    # Feature-grouped components
  ├── pages/         # Page-level components
  ├── hooks/         # Custom React hooks
  ├── context/       # React context providers
  ├── utils/         # Pure utility functions
  └── types/         # TypeScript type definitions
  ```
- **Environment variables**: `VITE_` prefix, set as GitHub Actions vars

### Backend (Flask services — e.g. website, classroom)
- **Framework**: Flask with Blueprint-based routing
- **Pattern**: routes → controllers → services → repositories
- **Logging**: structured JSON (structlog or watchtower → CloudWatch)
- **Auth**: AWS Cognito JWT validation
- **DB access**: DynamoDB via boto3 (no ORM, no VPC needed)

### Backend (ASP.NET Core services — humbugg)
- **Framework**: ASP.NET Core 10 (C# 14), packaged as a Docker container Lambda behind API Gateway HTTP API
- **Pattern**: controllers → services → DynamoDB repositories
- **Auth**: AWS Cognito access-token validation (SRP via Amplify Auth on the SPA)
- **DB access**: DynamoDB via the AWS SDK for .NET (no ORM, no VPC needed)
- **Note**: Humbugg now lives in its own repo (`ansavva/humbugg`); see its `CLAUDE.md`.

### Backend (Lambda-only Python services)
- **Language**: Python 3.11
- **Logging**: Standard `logging` module; output goes to CloudWatch automatically
- **AWS SDK**: boto3 — never hardcode credentials; rely on IAM role

### Infrastructure
- All services use **Terraform** (`<service>/infra/`). CloudFormation is not used.
- All CloudFront distributions use the shared ACM certificate and Route53 zone from `infra/`
- S3 + CloudFront for all static frontends
- Lambda for all backends (containerised Docker images in ECR — Flask, ASP.NET Core, and pure Lambda functions alike)

### AWS resource naming

Every AWS resource is named `[project]-[env]-[component]-[identifier]` — lowercase
kebab, environment always **second** (`prod` / `dev`), component
named for what it **serves** rather than which tier it sits in. S3 buckets take a
region suffix because their names are globally unique
(`humbugg-prod-marketing-us-east-1`).

Most resources are just `[project]-[env]-[component]`. These need more:

| Resource | Pattern | Example |
| --- | --- | --- |
| **S3 bucket** | `[project]-[env]-[component]-[region]` | `humbugg-prod-marketing-us-east-1` |
| **IAM role** | `[project]-[env]-[component]-role` | `humbugg-prod-api-role` |
| **IAM policy** | `[project]-[env]-[component]-[grant]` | `humbugg-prod-api-dynamodb` |
| **SQS DLQ** | `[project]-[env]-[component]-dlq` | `mailer-prod-feedback-dlq` |
| **CloudFront OAC** | `[project]-[env]-[component]-oac` | `humbugg-prod-app-files-oac` |
| **Log group** | `/aws/lambda/[function-name]` | derived — never hand-written |
| **SSM parameter** | `/[project]/[env]/[name]` | `/humbugg/prod/api-domain` |

Names describe identity; **tags** carry everything else. Every resource that
supports tagging gets all four of `Project`, `Environment`, `Owner`, `ManagedBy`,
set once in `local.common_tags` and passed into every module. Don't add a fifth
name segment for something a tag should hold.

**Renaming is a destroy-and-recreate for most resources.** Lambda, IAM, API
Gateway, log groups, alarms and SSM parameters lose nothing. A Cognito pool
loses every account and password, a DynamoDB table every row, an S3 bucket
every object, an SQS queue its in-flight messages, and an SES identity its
verification. Renaming a Terraform *address* is free and costs nothing when
done with a `moved` block — only a change to the `name`/`bucket`/`function_name`
argument replaces the AWS resource.

**"Loses nothing" is not the same as "succeeds".** ECR repositories and
CloudFront functions carry no data worth keeping and still fail the destroy:
`DeleteRepository` refuses a repository holding images, and CloudFront refuses
to delete a function, OAC or policy a distribution still references. Both broke
a prod deploy in August 2026 (#226, #227).

The fix depends on which kind of failure it is, and the difference matters:

- **`force_delete` / `force_destroy` do not work on the rename that adds them.**
  Terraform applies the destroy half of a replacement against *prior state*, not
  the new configuration — the destroy node gets the old object with `Config`
  null — so the provider reads the flag recorded in state and never sees the
  `true` you just wrote next to the new name. Set the flag, apply, *then*
  rename. Measured, not assumed: renaming a bucket and setting
  `force_destroy = true` in one apply fails `BucketNotEmpty`; doing it in two
  applies succeeds.
- **`create_before_destroy` does work immediately**, because it changes
  Terraform's ordering rather than an argument read off the old object. It is
  the fix for anything a live resource still references — CloudFront functions,
  OACs and origin request policies attached to a distribution.

So: give every ECR repository `force_delete = true` and every regenerable
bucket `force_destroy = true` *when you create it*, and give CloudFront config
objects `create_before_destroy`. Retrofitting them during a rename is too late,
and the recovery is out-of-band state surgery.

### Infrastructure directory naming

All per-service and shared infrastructure directories must be named `infra/` — never `terraform/` or any other name.

### Terraform directory structure

Every service's `infra/` directory must follow this layout:

```
infra/
├── modules/          # One subdirectory per logical concern (auth, storage, compute, hosting, …)
│   └── <module>/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── envs/             # One subdirectory per deployed environment
    └── <env>/        # e.g. prod, dev
        ├── main.tf
        ├── variables.tf
        ├── providers.tf
        ├── backend.tf
        ├── outputs.tf
        └── terraform.tfvars.example
```

- Modules contain reusable resource definitions; environments wire them together with environment-specific values.
- Sensitive variables are declared with `sensitive = true` and passed via `TF_VAR_*` in CI — never committed to the repo.
- `lifecycle { ignore_changes = [image_uri, environment] }` on Lambda resources — the deploy workflow owns both: `update-function-code` for the image and `update-function-configuration` for env vars. Terraform sets initial values on first creation only.

### Deployment (CI/CD)
- **Standard**: GitHub Actions. Filenames follow `<service>-<env>.yaml` (combined deploy) and `<service>-pr.yml` (combined PR workflow) — e.g. `humbugg-prod.yaml`, `humbugg-pr.yml` — so the service and the trigger environment (PR vs Prod) are visible at a glance. Auxiliary workflows append a scope suffix after the env segment (e.g. `shared-prod-infra-plan.yaml`).
- **One combined PR workflow per service**: each service has a single `<service>-pr.yml` that runs on every PR. It validates only — lint, unit tests, Terraform validate, and a build to prove the image compiles. Where a service has a browser suite it runs there too, stubbed: its Playwright specs answer every `/api/**` from committed fixtures. **PR workflows never write to AWS**, which is also why no service's integration suite runs on PR — those are local, behind a flag. There are no ephemeral preview environments; they were removed because the maintenance and teardown cost outweighed their value for a solo repo.
- **One combined prod deploy per service**: each service has a single `<service>-prod.yaml` with four jobs chained via `needs:`: `detect-changes → build-and-push → deploy-infra → update-lambda + deploy-frontend`. Image build runs **before** Terraform applies because Lambda resources reference `${ecr_repo}:latest` with `lifecycle { ignore_changes = [image_uri, environment] }`, so the image must already exist before Terraform creates the Lambda. Putting build-and-push first eliminates the chicken-and-egg trap on fresh AWS accounts. `update-lambda` then sets env vars and pins the function code to `:${{ github.sha }}` for traceability. This eliminates races between separate infra and app workflows that shared SSM params.
- **Path filtering**: `dorny/paths-filter@v3` — only deploy when the service's files change
- **Separate jobs**: `update-lambda` and `deploy-frontend` run independently after `deploy-infra`
- **AWS auth**: OIDC role assumption (`aws-actions/configure-aws-credentials@v4`) — never long-lived keys
- **Secrets/vars**: GitHub environment secrets and vars; never in code or `.env` files committed to repo
- **Frontend cache-control**:
  - Hashed assets → `public, max-age=31536000, immutable`
  - HTML files → `no-cache, no-store, must-revalidate`
- **CloudFront**: always invalidate `/*` after S3 sync
- **Concurrency groups** (prevent racing deploys to the same environment):
  - `<service>-prod` (`cancel-in-progress: false`) on every prod deploy workflow
  - `shared-infra` (`cancel-in-progress: false`) on the shared Terraform apply
- **Chaining on shared infra**: each service's combined prod deploy workflow declares a `workflow_run` trigger on `Shared infra · Terraform apply · Prod` with a job-level guard (`if: github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success'`) so a cert or zone change reapplies every downstream service's infra only when the shared apply succeeds. `workflow_run` doesn't inherit path filters; this is intentional — a shared cert/zone change should reapply everything downstream.
- **Manual triggers**: every combined workflow accepts `workflow_dispatch` inputs `run_infra` (default `true`) and `run_app` (default `true`) for targeted reruns.

## AWS Credentials — Critical Rule

**Never hardcode AWS credentials in any file.**

```python
# CORRECT — boto3 uses Lambda IAM role automatically in AWS, AWS CLI profile locally
boto3.client('s3', region_name='us-east-1')

# WRONG — never do this
boto3.client('s3', aws_access_key_id='AKIA...', aws_secret_access_key='...')
```

## Adding a New Service

1. Create `<service>/` directory — self-contained with own backend, frontend, infra
2. Reference shared Terraform outputs (Route53 zone, ACM cert, VPC) — do not recreate them
3. Add GitHub Actions workflows at `.github/workflows/<service>-<env>.yaml` following the humbugg pattern:
   - `<service>-pr.yml` — PR checks only (lint, test, Terraform validate, Docker build verification). No AWS writes.
   - `<service>-prod.yaml` — single combined deploy (detect-changes → build-and-push → deploy-infra → update-lambda + deploy-frontend), with `concurrency: { group: <service>-prod, cancel-in-progress: false }`, `workflow_dispatch` inputs `run_infra` and `run_app`, and a `workflow_run` trigger on `Shared infra · Terraform apply · Prod`.
   Use path filtering, OIDC auth, and SSM params for cross-job values.
4. **Add `arn:aws:ssm:*:*:parameter/<service>/*` to the SSM statement in
   `infra/envs/shared/main.tf`.** It is the only resource-scoped statement in the
   CI role's policy, and it is applied by a *different* workflow, so forgetting it
   is invisible until the end of the new service's first `terraform apply` — which
   by then has already created the CloudFront distribution. Add it in the same PR
   as the service, and expect the shared apply to run before the service deploy
   can succeed.
5. Use Vite for the frontend (not CRA)
6. Add TypeScript
7. Add a `CLAUDE.md` inside the service directory with service-specific context
8. Document subdomain in the service README (e.g., `events.andreas.services`)

## Branch Conventions

Development branches follow the pattern `claude/<feature-name>-<id>`.
Production deployments trigger from `main`.
