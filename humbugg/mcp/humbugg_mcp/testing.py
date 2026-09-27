"""The server with auth OFF and the API stubbed — for the PR workflow's conformance run,
Inspector `--strict` and Specmatic fuzzing, which need a real Streamable HTTP endpoint
to talk to and must never reach a real API (Specmatic calls every tool, `draw` and the
email tools included).

    HUMBUGG_MCP_DEV_TOKEN=stub uv run uvicorn humbugg_mcp.testing:app --port 5002

Refuses to load in hosted mode, so it can never be what the Lambda serves.
"""

import os

os.environ.setdefault("HUMBUGG_MCP_DEV_TOKEN", "stub")
os.environ.setdefault("HUMBUGG_API_URL", "http://stub.invalid")

from mcp.server.transport_security import TransportSecuritySettings  # noqa: E402

from humbugg_mcp import server as _server  # noqa: E402
from humbugg_mcp.stub import StubApi  # noqa: E402

if _server.HOSTED is not None:
    raise SystemExit("humbugg_mcp.testing must not run with HUMBUGG_MCP_PUBLIC_URL set")

_server.API_TRANSPORT = StubApi()
# Loopback, plus the name Docker Desktop gives the host, so a containerised tester
# (Specmatic) can reach it on a Mac; DNS-rebinding protection stays on for everything else.
_HOSTS = ["127.0.0.1:*", "localhost:*", "[::1]:*", "host.docker.internal:*"]
app = _server.server.streamable_http_app(
    stateless_http=True, json_response=True,
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=True, allowed_hosts=_HOSTS,
                                                 allowed_origins=[f"http://{h}" for h in _HOSTS]))
