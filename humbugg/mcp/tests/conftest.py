"""Tests call the server the way a host does — through the SDK's in-memory `Client`, so
initialize, `tools/list`, schema serialization and `isError` are all real — against
`stub.StubApi`, an httpx transport standing in for the Humbugg API."""

import json
import os
from pathlib import Path

import anyio
import pytest

UI = Path(__file__).parents[1] / "humbugg_mcp" / "ui"
if not all((UI / f"{p}.html").is_file() for p in ("draw-review", "assignment", "wishlist", "groups", "group")):
    # CI builds the pages first; a checkout without a widget build still runs the tools.
    os.environ["HUMBUGG_MCP_ALLOW_MISSING_UI"] = "1"
os.environ.pop("HUMBUGG_MCP_PUBLIC_URL", None)
os.environ["HUMBUGG_API_URL"] = "http://api.test"

from mcp import Client  # noqa: E402

from humbugg_mcp import server as srv  # noqa: E402
from humbugg_mcp.stub import StubApi  # noqa: E402


@pytest.fixture
def stub(monkeypatch):
    monkeypatch.setenv("HUMBUGG_MCP_DEV_TOKEN", "tok")
    api = StubApi()
    monkeypatch.setattr(srv, "API_TRANSPORT", api)
    return api


def run(coro_fn):
    return anyio.run(coro_fn)


def tools() -> dict:
    async def go():
        async with Client(srv.server) as c:
            return {t.name: t for t in (await c.list_tools()).tools}

    return run(go)


def call_raw(name: str, /, **args):
    async def go():
        async with Client(srv.server) as c:
            return await c.call_tool(name, args)

    return run(go)


def call(name: str, /, **args):
    """The tool's result as the model reads it — the JSON text block, or the page's
    `structuredContent` for a page tool. Fails the test on `isError`."""
    result = call_raw(name, **args)
    text = result.content[0].text if result.content else ""
    assert not result.is_error, text
    if result.structured_content is not None:
        sc = result.structured_content
        return sc["result"] if set(sc) == {"result"} else sc
    try:
        return json.loads(text)
    except ValueError:
        return text


def error(name: str, /, **args) -> str:
    result = call_raw(name, **args)
    assert result.is_error, "expected the call to fail"
    return result.content[0].text
