"""Sign-in for the connector: an MCP host's OAuth in front of Humbugg's Cognito pool.

A remote MCP server tells its client how to get a token by the MCP authorization spec
(OAuth 2.1): a 401 pointing at *protected resource metadata*, which names an
*authorization server*, whose metadata lists the authorize and token endpoints, PKCE
and dynamic client registration. Cognito cannot be named directly, for three reasons
(measured on aperture, which this copies):

- its discovery document omits `code_challenge_methods_supported`, and Claude will not
  start a flow without it;
- it rejects the RFC 8707 `resource` parameter Claude sends on every request;
- it has no dynamic client registration.

So this is a thin, stateless shim on the API's own origin: it serves the metadata
Cognito lacks, strips `resource`, forwards `/oauth/authorize` and `/oauth/token` to
Managed Login, and answers registration with the Cognito app client made for the host
whose redirect URI it is — one per host (`humbugg-<env>-mcp-claude`, later `-chatgpt`).
Cognito still does everything that matters: passwords, the social buttons, the
pre-sign-up account linking, PKCE, the codes.

**The token the host holds is Cognito's access token, unchanged** — the API validates
access tokens (`Program.cs`, `token_use=access` plus a client allow-list), so the
server passes the bearer straight through. Aperture's API took ID tokens and its shim
swapped them; Humbugg's does not need to.
"""

from __future__ import annotations

import time
from urllib.parse import urlencode

import httpx
import jwt
from mcp.server.auth.provider import AccessToken
from mcp.server.auth.settings import AuthSettings
from starlette.requests import Request
from starlette.responses import JSONResponse, RedirectResponse, Response

from humbugg_mcp.config import Hosted, McpClient

SCOPES = ["openid", "email", "profile"]


def auth_settings(h: Hosted) -> AuthSettings:
    return AuthSettings(
        issuer_url=h.public_url,
        resource_server_url=h.resource,
        required_scopes=SCOPES,
        # Cognito does not bind tokens to a resource; the verifier checks the client itself.
        validate_token_resource=False,
    )


class CognitoAccessTokens:
    """The SDK's `TokenVerifier`: a Cognito access token issued to one of the MCP
    clients, signed by the pool, unexpired. The app's own client is refused here — a
    token minted for app.humbugg.com is not a grant to an AI host — and so is an ID
    token. Anything refused gets the spec's 401 and the host re-authenticates."""

    def __init__(self, h: Hosted, jwks: jwt.PyJWKClient | None = None):
        self.h = h
        self.jwks = jwks or jwt.PyJWKClient(f"{h.cognito_issuer}/.well-known/jwks.json", cache_keys=True)

    def claims(self, token: str) -> dict | None:
        try:
            key = self.jwks.get_signing_key_from_jwt(token)
            # Access tokens carry `client_id`, not `aud`.
            claims = jwt.decode(token, key.key, algorithms=["RS256"], issuer=self.h.cognito_issuer,
                                options={"verify_aud": False, "require": ["exp", "iss", "sub"]})
        except jwt.PyJWTError:
            return None
        if claims.get("token_use") != "access" or claims.get("client_id") not in self.h.client_ids:
            return None
        return claims

    async def verify_token(self, token: str) -> AccessToken | None:
        claims = self.claims(token)
        if claims is None:
            return None
        return AccessToken(
            token=token, client_id=claims["client_id"], scopes=SCOPES, expires_at=int(claims["exp"]),
            subject=claims["sub"], resource=self.h.resource,
        )


def metadata(h: Hosted) -> dict:
    """RFC 8414 authorization server metadata, for the shim."""
    return {
        "issuer": h.public_url,
        "authorization_endpoint": f"{h.public_url}/oauth/authorize",
        "token_endpoint": f"{h.public_url}/oauth/token",
        "registration_endpoint": f"{h.public_url}/oauth/register",
        "scopes_supported": SCOPES,
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code", "refresh_token"],
        "code_challenge_methods_supported": ["S256"],
        "token_endpoint_auth_methods_supported": ["none"],
    }


def client_for(h: Hosted, redirect_uris: list[str]) -> McpClient | None:
    """The host's client: the one whose registered callbacks include every URI asked for.
    A client without callbacks (`smoke`) is never handed out."""
    if not redirect_uris:
        return None
    for client in h.clients:
        if client.redirect_uris and all(u in client.redirect_uris for u in redirect_uris):
            return client
    return None


def routes(h: Hosted, transport: httpx.AsyncBaseTransport | None = None):
    """(path, methods, handler) for each shim endpoint."""

    async def as_metadata(request: Request) -> Response:
        return JSONResponse(metadata(h))

    async def register(request: Request) -> Response:
        # RFC 7591, answered with a pre-made client: "registering" is confirming the
        # host's redirect URIs are ones a Humbugg MCP client was made for.
        try:
            body = await request.json()
        except ValueError:
            body = {}
        uris = body.get("redirect_uris") if isinstance(body, dict) else None
        client = client_for(h, uris if isinstance(uris, list) else [])
        if client is None:
            return JSONResponse({"error": "invalid_redirect_uri",
                                 "error_description": "redirect_uris are not those of a supported MCP host"}, status_code=400)
        return JSONResponse({
            "client_id": client.client_id,
            "client_id_issued_at": int(time.time()),
            "redirect_uris": uris,
            "client_name": body.get("client_name") or client.host,
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "scope": " ".join(SCOPES),
        }, status_code=201)

    async def authorize(request: Request) -> Response:
        params = {k: v for k, v in request.query_params.items() if k != "resource"}
        asked = (params.get("scope") or "").split()
        params["scope"] = " ".join(s for s in asked if s in SCOPES) or " ".join(SCOPES)
        return RedirectResponse(f"{h.cognito_domain}/oauth2/authorize?{urlencode(params)}", status_code=302)

    async def token(request: Request) -> Response:
        form = {k: v for k, v in (await request.form()).items() if k != "resource"}
        async with httpx.AsyncClient(timeout=9, transport=transport) as client:
            r = await client.post(f"{h.cognito_domain}/oauth2/token", data=form)
        headers = {"Cache-Control": "no-store"}
        try:
            body = r.json()
        except ValueError:
            return Response(r.text, status_code=r.status_code, headers=headers)
        if r.status_code == 200:
            # The host needs the access token (and the refresh token); the ID token would
            # only put the person's email in one more place.
            body.pop("id_token", None)
        return JSONResponse(body, status_code=r.status_code, headers=headers)

    return [
        ("/.well-known/oauth-authorization-server", ["GET"], as_metadata),
        ("/oauth/register", ["POST"], register),
        ("/oauth/authorize", ["GET"], authorize),
        ("/oauth/token", ["POST"], token),
    ]
