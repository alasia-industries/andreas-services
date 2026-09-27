"""The OAuth shim and the access-token verifier, with Cognito stubbed: a local RSA key
signs the tokens, and the token endpoint is an httpx mock."""

import time
from urllib.parse import parse_qs, urlparse

import anyio
import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from mcp.server.mcpserver import MCPServer
from starlette.applications import Starlette
from starlette.routing import Route
from starlette.testclient import TestClient

from humbugg_mcp import oauth
from humbugg_mcp.config import Hosted, McpClient, parse_clients

CLAUDE = McpClient("claude", "claude-client", ("https://claude.ai/api/mcp/auth_callback",
                                               "https://claude.com/api/mcp/auth_callback"))
SMOKE = McpClient("smoke", "smoke-client")
H = Hosted(public_url="https://api.test", cognito_domain="https://auth.test", user_pool_id="us-east-1_pool",
           clients=(CLAUDE, SMOKE))
KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class Jwks:
    def get_signing_key_from_jwt(self, token):
        return type("K", (), {"key": KEY.public_key()})()


def token(**over) -> str:
    claims = {"sub": "sub-1", "iss": H.cognito_issuer, "token_use": "access", "client_id": "claude-client",
              "exp": int(time.time()) + 600, "scope": "openid email profile", **over}
    return jwt.encode(claims, KEY, algorithm="RS256")


VERIFIER = oauth.CognitoAccessTokens(H, jwks=Jwks())


def verify(t):
    return anyio.run(VERIFIER.verify_token, t)


def test_parse_clients():
    clients = parse_clients('{"claude": {"client_id": "a", "redirect_uris": ["https://x"]}, "smoke": {"client_id": "b"}}')
    assert clients == (McpClient("claude", "a", ("https://x",)), McpClient("smoke", "b"))


def test_an_mcp_clients_access_token_is_accepted():
    at = verify(token())
    assert at.subject == "sub-1" and at.client_id == "claude-client" and at.resource == "https://api.test/mcp"
    assert verify(token(client_id="smoke-client")).client_id == "smoke-client"


@pytest.mark.parametrize("bad", [
    {"client_id": "app-client"},  # the app's own token is not a grant to an AI host
    {"token_use": "id"},  # an ID token
    {"exp": int(time.time()) - 5},  # expired
    {"iss": "https://cognito-idp.us-east-1.amazonaws.com/other-pool"},
])
def test_other_tokens_are_refused(bad):
    assert verify(token(**bad)) is None


def test_a_token_signed_by_another_key_is_refused():
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    forged = jwt.encode({"sub": "x", "iss": H.cognito_issuer, "token_use": "access", "client_id": "claude-client",
                         "exp": int(time.time()) + 60}, other, algorithm="RS256")
    assert verify(forged) is None


def shim(transport=None) -> TestClient:
    return TestClient(Starlette(routes=[Route(p, h, methods=m) for p, m, h in oauth.routes(H, transport)]))


def test_metadata_has_what_cognitos_lacks():
    m = shim().get("/.well-known/oauth-authorization-server").json()
    assert m["code_challenge_methods_supported"] == ["S256"]
    assert m["registration_endpoint"] == "https://api.test/oauth/register"
    assert m["token_endpoint_auth_methods_supported"] == ["none"]


def test_registration_hands_out_the_hosts_client():
    r = shim().post("/oauth/register", json={"redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
                                             "client_name": "Claude"})
    assert r.status_code == 201 and r.json()["client_id"] == "claude-client"


@pytest.mark.parametrize("uris", [[], ["https://evil.example/cb"],
                                  ["https://claude.ai/api/mcp/auth_callback", "https://evil.example/cb"]])
def test_registration_refuses_other_redirects_and_never_the_smoke_client(uris):
    r = shim().post("/oauth/register", json={"redirect_uris": uris})
    assert r.status_code == 400 and r.json()["error"] == "invalid_redirect_uri"


def test_authorize_strips_resource_and_forwards_to_managed_login():
    r = shim().get("/oauth/authorize", params={"client_id": "claude-client", "resource": "https://api.test/mcp",
                                               "scope": "openid email profile offline_access", "state": "s",
                                               "code_challenge": "c", "code_challenge_method": "S256"},
                   follow_redirects=False)
    assert r.status_code == 302
    loc = urlparse(r.headers["location"])
    assert f"{loc.scheme}://{loc.netloc}{loc.path}" == "https://auth.test/oauth2/authorize"
    q = parse_qs(loc.query)
    assert "resource" not in q and q["scope"] == ["openid email profile"] and q["state"] == ["s"]


def test_token_strips_resource_and_drops_the_id_token():
    seen = {}

    def cognito(request: httpx.Request):
        seen["form"] = parse_qs(request.content.decode())
        return httpx.Response(200, json={"access_token": "at", "refresh_token": "rt", "id_token": "it",
                                         "token_type": "Bearer", "expires_in": 3600})

    r = shim(httpx.MockTransport(cognito)).post("/oauth/token", data={"grant_type": "authorization_code", "code": "c",
                                                                       "resource": "https://api.test/mcp"})
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    assert r.json() == {"access_token": "at", "refresh_token": "rt", "token_type": "Bearer", "expires_in": 3600}
    assert "resource" not in seen["form"]


def test_token_passes_cognitos_refusal_through():
    r = shim(httpx.MockTransport(lambda req: httpx.Response(400, json={"error": "invalid_grant"}))).post(
        "/oauth/token", data={"grant_type": "refresh_token", "refresh_token": "old"})
    assert r.status_code == 400 and r.json() == {"error": "invalid_grant"}


def protected() -> TestClient:
    s = MCPServer("t", auth=oauth.auth_settings(H), token_verifier=VERIFIER)

    @s.tool()
    def ping() -> str:
        return "pong"

    return TestClient(s.streamable_http_app(stateless_http=True, json_response=True, host="0.0.0.0"))


INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}}
HEADERS = {"Accept": "application/json, text/event-stream"}


def test_no_token_gets_the_specs_401_pointing_at_the_metadata():
    with protected() as c:  # the context runs the app's lifespan, which the transport needs
        r = c.post("/mcp", json=INIT, headers=HEADERS)
        assert r.status_code == 401
        assert "resource_metadata" in r.headers["www-authenticate"]
        meta_url = r.headers["www-authenticate"].split('resource_metadata="')[1].split('"')[0]
        meta = c.get(urlparse(meta_url).path).json()
    assert meta["resource"] == "https://api.test/mcp" and meta["authorization_servers"] == ["https://api.test"]


def test_an_app_client_token_gets_the_401_too():
    with protected() as c:
        r = c.post("/mcp", json=INIT, headers={**HEADERS, "Authorization": f"Bearer {token(client_id='app')}"})
    assert r.status_code == 401


def test_a_valid_token_reaches_the_server():
    with protected() as c:
        r = c.post("/mcp", json=INIT, headers={**HEADERS, "Authorization": f"Bearer {token()}"})
    assert r.status_code == 200 and r.json()["result"]["serverInfo"]["name"] == "t"
