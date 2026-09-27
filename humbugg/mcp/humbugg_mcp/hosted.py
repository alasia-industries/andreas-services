"""The server as an ASGI app, for the Lambda.

    uvicorn humbugg_mcp.hosted:app --port 8080

Stateless Streamable HTTP with JSON responses: every POST /mcp stands alone, so any
Lambda instance can answer any request and nothing is kept between them. Needs the
environment `config.load` reads for the hosted case; without it this module refuses to
load rather than serve an unauthenticated server.
"""

import logging

from starlette.requests import Request
from starlette.responses import PlainTextResponse

from humbugg_mcp import favicon, oauth
from humbugg_mcp.server import HOSTED, server

if HOSTED is None:
    raise SystemExit("humbugg_mcp.hosted needs HUMBUGG_MCP_PUBLIC_URL and the Cognito settings (see config.load)")

# One JSON line per tool call (server.py) and nothing else of ours: CloudWatch keeps it.
logging.basicConfig(level=logging.INFO, format="%(message)s")

for path, methods, handler in [*oauth.routes(HOSTED), *favicon.ROUTES]:
    server.custom_route(path, methods=methods)(handler)


@server.custom_route("/healthz", methods=["GET"])
async def healthz(request: Request) -> PlainTextResponse:
    return PlainTextResponse("ok")


# host="0.0.0.0": behind API Gateway the Host header is the gateway's, so the SDK's
# localhost-only DNS-rebinding guard must stay off; the bearer is the guard.
app = server.streamable_http_app(stateless_http=True, json_response=True, host="0.0.0.0")
