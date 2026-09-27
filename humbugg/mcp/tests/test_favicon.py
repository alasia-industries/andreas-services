from starlette.applications import Starlette
from starlette.routing import Route
from starlette.testclient import TestClient

from humbugg_mcp import favicon


def test_the_domain_has_an_icon():
    c = TestClient(Starlette(routes=[Route(p, h, methods=m) for p, m, h in favicon.ROUTES]))
    ico = c.get("/favicon.ico")
    assert ico.status_code == 200 and ico.headers["content-type"] == "image/x-icon"
    assert ico.content[:4] == b"\x00\x00\x01\x00"  # an ICO header, not something renamed
    svg = c.get("/favicon.svg")
    assert svg.status_code == 200 and svg.headers["content-type"].startswith("image/svg+xml")
    assert b"<svg" in svg.content and "max-age" in svg.headers["cache-control"]
