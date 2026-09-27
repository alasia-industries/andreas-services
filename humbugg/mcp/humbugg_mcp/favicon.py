"""`/favicon.ico` and `/favicon.svg` on the connector's origin (api.humbugg.com).

A host showing a custom connector by its URL can only find an icon on that URL's
domain, and until now the API domain answered 404 there. The .ico is Humbugg's own
favicon (copied from marketing/public/); the .svg is the "H" mark the pages wear.
"""

from pathlib import Path

from starlette.requests import Request
from starlette.responses import Response

ASSETS = Path(__file__).parent / "assets"
_CACHE = {"Cache-Control": "public, max-age=86400"}


async def favicon_ico(request: Request) -> Response:
    return Response((ASSETS / "favicon.ico").read_bytes(), media_type="image/x-icon", headers=_CACHE)


async def favicon_svg(request: Request) -> Response:
    return Response((ASSETS / "icon-light.svg").read_bytes(), media_type="image/svg+xml", headers=_CACHE)


ROUTES = [("/favicon.ico", ["GET"], favicon_ico), ("/favicon.svg", ["GET"], favicon_svg)]
