"""Where the server finds the API, and — hosted — the pool, the MCP clients and the limiter.

Everything comes from the environment. The Lambda's is set by the deploy workflow;
locally `HUMBUGG_API_URL` points at the dev backend (http://127.0.0.1:5001).

The server holds no AWS credential beyond the rate-limit table's one write: every
Humbugg byte goes through the API as the signed-in person.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field


@dataclass(frozen=True)
class McpClient:
    """One Cognito app client per MCP host (`claude`, later `chatgpt`), plus `smoke`,
    which has no redirect URIs: its tokens are accepted, but registration never
    hands it out."""

    host: str
    client_id: str
    redirect_uris: tuple[str, ...] = ()


@dataclass(frozen=True)
class Hosted:
    public_url: str  # https://api.humbugg.com — the origin; the protected resource is <origin>/mcp
    cognito_domain: str  # https://auth.humbugg.com — Managed Login
    user_pool_id: str
    clients: tuple[McpClient, ...]
    region: str = "us-east-1"
    ratelimit_table: str | None = None
    rate_limit_per_minute: int = 60

    @property
    def resource(self) -> str:
        return f"{self.public_url}/mcp"

    @property
    def cognito_issuer(self) -> str:
        return f"https://cognito-idp.{self.region}.amazonaws.com/{self.user_pool_id}"

    @property
    def client_ids(self) -> frozenset[str]:
        return frozenset(c.client_id for c in self.clients)


@dataclass(frozen=True)
class Settings:
    api_url: str
    hosted: Hosted | None = field(default=None)
    #: The product app the pages link to — production unless a dev server says otherwise.
    app_url: str = "https://app.humbugg.com"


def parse_clients(raw: str) -> tuple[McpClient, ...]:
    """`HUMBUGG_MCP_CLIENTS`: {"claude": {"client_id": "…", "redirect_uris": […]}, "smoke": {…}}."""
    data = json.loads(raw)
    return tuple(
        McpClient(host=host, client_id=spec["client_id"], redirect_uris=tuple(spec.get("redirect_uris") or ()))
        for host, spec in data.items()
    )


def load() -> Settings:
    api_url = (os.environ.get("HUMBUGG_API_URL") or "https://api.humbugg.com").rstrip("/")
    app_url = (os.environ.get("HUMBUGG_APP_URL") or "https://app.humbugg.com").rstrip("/")
    public_url = os.environ.get("HUMBUGG_MCP_PUBLIC_URL")
    if not public_url:
        return Settings(api_url=api_url, app_url=app_url)
    hosted = Hosted(
        public_url=public_url.rstrip("/"),
        cognito_domain=os.environ["HUMBUGG_COGNITO_DOMAIN"].rstrip("/"),
        user_pool_id=os.environ["HUMBUGG_COGNITO_USER_POOL_ID"],
        clients=parse_clients(os.environ["HUMBUGG_MCP_CLIENTS"]),
        region=os.environ.get("AWS_REGION", "us-east-1"),
        ratelimit_table=os.environ.get("HUMBUGG_MCP_RATELIMIT_TABLE") or None,
        rate_limit_per_minute=int(os.environ.get("HUMBUGG_MCP_RATE_LIMIT_PER_MINUTE") or 60),
    )
    return Settings(api_url=api_url, hosted=hosted, app_url=app_url)
