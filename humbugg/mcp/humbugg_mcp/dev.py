"""The server with auth OFF against your local dev backend, signed in as one seeded
dev-pool person — for trying the tools in Claude Code or the Inspector without OAuth.

    uv run --group dev uvicorn humbugg_mcp.dev:app --host 127.0.0.1 --port 5002   # HTTP (Claude Code, Inspector)
    uv run --group dev python -m humbugg_mcp.dev                                   # stdio (the desktop app)

The desktop app renders MCP Apps pages for servers in its own config
(claude_desktop_config.json), which launches them over stdio — the way aperture is
registered. A server added with `claude mcp add` is reachable from Claude Code but its
pages did not render there (2026-09-27): the model got the view as JSON instead.

Who: `HUMBUGG_MCP_DEV_EMAIL` (default: `HUMBUGG_DEV_USER_EMAIL` from dev.env, the dev
organizer). The password, pool and client come from
~/.config/andreas-services/humbugg/dev.env, the same file every other dev tool reads.
The token is re-minted before it expires. `HUMBUGG_MCP_DEV_TOKEN` overrides all of it.
API: `HUMBUGG_API_URL`, default http://127.0.0.1:5001 (scripts/dev-up-backend.sh).

Local only: refuses hosted mode and the production API.
"""

import os
import sys
import threading
import time
from pathlib import Path

os.environ.setdefault("HUMBUGG_API_URL", "http://127.0.0.1:5001")
# The product app's dev server (dev-up-app.sh, Expo web): the pages' logo links go there.
os.environ.setdefault("HUMBUGG_APP_URL", "http://localhost:8081")

from humbugg_mcp import server as _server  # noqa: E402

if _server.HOSTED is not None:
    raise SystemExit("humbugg_mcp.dev must not run with HUMBUGG_MCP_PUBLIC_URL set")
if "api.humbugg.com" in _server.SETTINGS.api_url:
    raise SystemExit("humbugg_mcp.dev is for a dev API; point HUMBUGG_API_URL at your local backend")

DEV_ENV = Path(os.environ.get("HUMBUGG_DEV_ENV_FILE",
                              Path.home() / ".config" / "andreas-services" / "humbugg" / "dev.env"))


def _dev_env() -> dict:
    out = {}
    for line in DEV_ENV.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


class _SignedIn:
    """SRP against the dev app client — allowed there, and what the dev seeder does."""

    def __init__(self):
        env = _dev_env()
        self.email = os.environ.get("HUMBUGG_MCP_DEV_EMAIL") or env["HUMBUGG_DEV_USER_EMAIL"]
        self.env = env
        self.token, self.expires = None, 0.0
        self.lock = threading.Lock()

    def __call__(self) -> str:
        with self.lock:
            if time.time() > self.expires:
                import boto3
                from botocore import UNSIGNED
                from botocore.config import Config
                from pycognito.aws_srp import AWSSRP

                idp = boto3.client("cognito-idp", region_name=self.env.get("COGNITO_REGION", "us-east-1"),
                                   config=Config(signature_version=UNSIGNED))
                result = AWSSRP(username=self.email, password=self.env["HUMBUGG_DEV_USER_PASSWORD"],
                                pool_id=self.env["COGNITO_USER_POOL_ID"], client_id=self.env["COGNITO_CLIENT_ID"],
                                client=idp).authenticate_user()["AuthenticationResult"]
                self.token, self.expires = result["AccessToken"], time.time() + result["ExpiresIn"] - 120
            return self.token


if not os.environ.get("HUMBUGG_MCP_DEV_TOKEN"):
    _server.DEV_TOKEN_PROVIDER = _SignedIn()
    # stderr: over stdio, stdout is the JSON-RPC channel.
    print(f"humbugg-mcp dev: signed in as {_server.DEV_TOKEN_PROVIDER.email} on demand, "
          f"API {_server.SETTINGS.api_url}", file=sys.stderr)

app = _server.server.streamable_http_app(stateless_http=True, json_response=True)


if __name__ == "__main__":
    _server.server.run(transport="stdio")
