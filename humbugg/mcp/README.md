# humbugg-mcp — Humbugg as an MCP connector

A remote MCP server at `https://api.humbugg.com/mcp`: a Humbugg member's own exchanges as
tools for Claude (and later ChatGPT). Modelled on aperture's `mcp/`, whose README is the
longer MCP primer. The plan and its decisions are issue #828; agent evals are #827.

## How it is built

- **Only an API client.** Every tool is one or two calls on `api.humbugg.com/api/*` as the
  signed-in person, with that person's Cognito access token (`api.py`). The server holds
  no Humbugg data and no AWS permission beyond its rate-limit table. Authorization —
  membership, organizer rights, giver anonymity — stays in the API.
- **Hosted only.** Stateless Streamable HTTP on a container Lambda (Lambda Web Adapter),
  `hosted.py`. Routes on the API's own gateway, no authorizer: `ANY /mcp`,
  `GET /.well-known/{proxy+}`, `ANY /oauth/{proxy+}` (`infra/modules/mcp`).
- **OAuth shim over Cognito** (`oauth.py`): the metadata Cognito lacks, `resource`
  stripped, registration answered with the pre-made client for the host whose redirect
  URI it is. One Cognito client per host, `humbugg-<env>-mcp-<host>`, plus `mcp-smoke`
  (SRP only, for the prod smoke test). The API accepts them in two places that must agree:
  the gateway authorizer's audience and `Program.cs`'s `COGNITO_ADDITIONAL_CLIENT_IDS`.
- **One decorator per tool** (`server.py`, `tool` / `app_tool`) sets the `title` and all
  three hints the directories require, turns each docstring `Args:` entry into the
  argument's schema description, rate-limits per verified `sub` (`ratelimit.py`), and
  logs one JSON line: tool, hashed user, outcome, milliseconds — never arguments or
  results.
- **Other members' words are data.** Results that carry text other people wrote come back
  as `{"note", "data"}`, and the server instructions tell the model never to act on them.
- **Pages** (MCP Apps, `widgets/` → `humbugg_mcp/ui/*.html`, gitignored): the groups list
  and a group's details (the hub: each group's next step), the draw review (the only way
  to call `draw`, which is `visibility: ["app"]`), the assignment card and the wish-list
  editor. The groups pages navigate in place: a next-step button calls the view's tool itself
  (`app.callServerTool`), pushes it with a Back button, and tells Claude where the person is
  with `app.updateModelContext` — ids and view kind only, never a group's name, which is
  organizer-written text. Only if that fails does it fall back to `app.sendMessage` with a
  server-built prompt, which the desktop app merely prefills in the composer (`ui/message`
  has no auto-send). No remote images: the CSP allows none, so a shop's host never
  learns who is looking.

## Not here, on purpose

Payments, deleting a group or account, reset, the organizer's emergency reveal, avatars,
data export. The instructions send people to the app for those.

## Run it

```bash
./humbugg/scripts/dev-up.sh                      # everything, the connector on :5002 included
./humbugg/scripts/dev-up-mcp.sh                  # or just the connector (backend must be up)
./humbugg/scripts/dev-up-mcp.sh --as p1@humbugg.test
./humbugg/scripts/dev-up-mcp.sh --stub           # the in-memory stub API, no backend
claude mcp add --transport http humbugg-dev http://127.0.0.1:5002/mcp   # once
```

`dev-up-mcp.sh` builds the pages when their source is newer than the build and serves
`humbugg_mcp.dev:app` over HTTP: auth off, loopback only, signed in as a seeded person from
`dev.env` (refuses the production API). Good for the Inspector
(`npx @modelcontextprotocol/inspector`) and for tools from Claude Code — but **pages do not
render for a server added with `claude mcp add`**: the host hands the model the view as JSON
(measured 2026-09-27). The desktop app renders them for servers in its own config, launched
over stdio — how aperture is registered. Add to
`~/Library/Application Support/Claude/claude_desktop_config.json` under `mcpServers`, then
quit and reopen the app:

```json
"Humbugg": {
  "command": "/Users/<you>/.local/bin/uv",
  "args": ["--directory", "/Users/<you>/repos/andreas-services/humbugg/mcp", "run", "--group", "dev",
           "python", "-m", "humbugg_mcp.dev"]
}
```

The pages link to the app a server names in `HUMBUGG_APP_URL` (default `https://app.humbugg.com`; the
dev server defaults it to the local Expo app, `http://localhost:8081`, so run `dev-up-app.sh` to
follow the logo). A page accepts only production or a loopback origin. The app starts it itself; the backend (`dev-up-backend.sh`) must be up, and the pages built
(`dev-up-mcp.sh` builds them, or `npm run build` in `widgets/`). Port 5002 is humbugg's MCP
dev port (root CLAUDE.md).

## Tests

| Tier | Command | Talks to |
|---|---|---|
| Unit, directory rules, OAuth shim, rate limit | `uv run --group dev pytest -q` | the stub API, a local RSA key |
| Pages | `cd widgets && npm test && npm run test:e2e` | a test host + fixtures |
| Conformance, Inspector `--strict`/`--app-info`, Specmatic | CI (`humbugg-pr.yml`, job `mcp`) against `testing:app` | the stub API only — Specmatic calls every tool |
| Integration | `./humbugg/scripts/dev-test-mcp.sh` | the running dev backend, as seeded people |
| Prod smoke | `humbugg-prod.yaml`, after deploy | `api.humbugg.com/mcp` as the smoke account |

Specmatic locally (Docker; `testing:app` accepts Docker Desktop's `host.docker.internal`),
with `testing:app` running on 0.0.0.0:5002:

```bash
docker run --rm -v /tmp/specmatic:/usr/src/app/build/reports/specmatic \
  -v "$PWD/tests/specmatic-dictionary.json:/usr/src/app/specmatic-dictionary.json:ro" \
  specmatic/specmatic:2.55.0 mcp test --url http://host.docker.internal:5002/mcp \
  --transport-kind=STREAMABLE_HTTP --dictionary-file specmatic-dictionary.json --enable-resiliency-tests
python3 tests/specmatic_check.py /tmp/specmatic/mcp/mcp_test_report.json   # the gate; Specmatic exits 0 regardless
```

It found that lax argument coercion let `price_cents: false` through as 0; numeric and
boolean arguments are strict since.

`tests/conformance-baseline.yml` lists the conformance scenarios that exercise the
reference server's fixtures; a new failure outside it fails the PR.
