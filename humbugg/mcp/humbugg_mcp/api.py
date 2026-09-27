"""A thin client over the Humbugg API (backend/Humbugg.Api/Controllers). Every tool in
server.py is one or two of these calls, made as the signed-in person with their own
Cognito access token. The API is where authorization lives — membership, organizer
rights, giver anonymity — and nothing here second-guesses it.

JSON is snake_case both ways (the API's `JsonNamingPolicy.SnakeCaseLower`), and its
refusals are `{"error": {"code", "message"}}`.
"""

from __future__ import annotations

from urllib.parse import quote

import httpx
from mcp.server.mcpserver.exceptions import ToolError


class ApiError(ToolError):
    """What the API refused, in its own words. A `ToolError`, so the SDK hands the
    message to the model as a failed call it can act on; any other exception is a
    crash and the model sees only "Error executing tool"."""

    def __init__(self, message: str, status: int, code: str | None = None):
        super().__init__(message)
        self.status = status
        self.code = code


def _seg(value: str) -> str:
    """One path segment. Ids come from the model; a slash or `..` in one must not
    reach a different route."""
    value = (value or "").strip()
    if not value:
        raise ToolError("an id is empty")
    return quote(value, safe="")


def _body(**fields) -> dict:
    """A request body with the unset fields left out — the API reads absence as
    "leave alone", so a partial edit never blanks a field nobody mentioned."""
    return {k: v for k, v in fields.items() if v is not None}


class Api:
    def __init__(self, base_url: str, token: str | None, transport: httpx.BaseTransport | None = None):
        self.base_url = base_url.rstrip("/")
        self.http = httpx.Client(
            base_url=self.base_url,
            headers={"Authorization": f"Bearer {token}"} if token else {},
            timeout=25,  # under the Lambda's 29 s, so a slow call is our error, not the gateway's
            transport=transport,
        )

    def _call(self, method: str, path: str, **kwargs):
        try:
            r = self.http.request(method, path, **kwargs)
        except httpx.HTTPError as exc:
            raise ApiError(f"Humbugg did not answer ({exc.__class__.__name__}). Try again in a minute.", 0) from exc
        if r.status_code == 204:
            return None
        if r.is_success:
            return r.json() if r.content else None
        code, message = None, None
        try:
            err = r.json().get("error")
            if isinstance(err, dict):
                code, message = err.get("code"), err.get("message")
            elif isinstance(r.json().get("message"), str):  # API Gateway's own {"message": "Unauthorized"}
                message = r.json()["message"]
        except (ValueError, AttributeError):
            pass
        if r.status_code == 401:
            raise ApiError("Humbugg did not accept this sign-in. Reconnect the Humbugg connector and try again.", 401, code)
        if r.status_code == 429:
            raise ApiError("Humbugg is receiving too many requests. Wait a minute and try again.", 429, code)
        if r.status_code >= 500:
            raise ApiError(f"Humbugg had a problem (HTTP {r.status_code}). Try again in a minute; nothing was changed "
                           "unless the app shows otherwise.", r.status_code, code)
        raise ApiError(message or f"Humbugg refused the request (HTTP {r.status_code}).", r.status_code, code)

    # -- me

    def me(self) -> dict:
        return self._call("GET", "/api/me")

    # -- groups

    def groups(self) -> list[dict]:
        return self._call("GET", "/api/groups")

    def group(self, group_id: str) -> dict:
        return self._call("GET", f"/api/groups/{_seg(group_id)}")

    def readiness(self, group_id: str) -> dict:
        return self._call("GET", f"/api/groups/{_seg(group_id)}/readiness")

    def create_group(self, **fields) -> dict:
        return self._call("POST", "/api/groups", json=_body(**fields))

    def update_group(self, group_id: str, **fields) -> dict:
        return self._call("PATCH", f"/api/groups/{_seg(group_id)}", json=_body(**fields))

    def customize(self, group_id: str, **fields) -> dict:
        return self._call("PUT", f"/api/groups/{_seg(group_id)}/customization", json=_body(**fields))

    def set_exclusions(self, group_id: str, pairs: list[list[str]]) -> dict:
        return self._call("PUT", f"/api/groups/{_seg(group_id)}/exclusions", json={"exclusions": pairs})

    def rotate_invite(self, group_id: str) -> dict:
        return self._call("POST", f"/api/groups/{_seg(group_id)}/invite")

    def join(self, group_id: str, invite_token: str) -> dict:
        return self._call("POST", f"/api/groups/{_seg(group_id)}/join", json={"invite_token": invite_token})

    def participation(self, group_id: str, member_id: str, is_participating: bool) -> dict:
        return self._call("PATCH", f"/api/groups/{_seg(group_id)}/members/{_seg(member_id)}/participation",
                          json={"is_participating": is_participating})

    def draw(self, group_id: str) -> dict:
        return self._call("POST", f"/api/groups/{_seg(group_id)}/draw")

    # -- my membership, wishes, gift

    def membership(self, group_id: str) -> dict:
        return self._call("GET", f"/api/groups/{_seg(group_id)}/members/me")

    def update_membership(self, group_id: str, **fields) -> dict:
        return self._call("PATCH", f"/api/groups/{_seg(group_id)}/members/me", json=_body(**fields))

    def wishes(self, group_id: str) -> list[dict]:
        return self._call("GET", f"/api/groups/{_seg(group_id)}/members/me/wishes")

    def create_wish(self, group_id: str, **fields) -> dict:
        return self._call("POST", f"/api/groups/{_seg(group_id)}/members/me/wishes", json=_body(**fields))

    def update_wish(self, group_id: str, wish_id: str, **fields) -> dict:
        return self._call("PATCH", f"/api/groups/{_seg(group_id)}/members/me/wishes/{_seg(wish_id)}", json=_body(**fields))

    def delete_wish(self, group_id: str, wish_id: str) -> None:
        self._call("DELETE", f"/api/groups/{_seg(group_id)}/members/me/wishes/{_seg(wish_id)}")

    def reorder_wishes(self, group_id: str, wish_ids: list[str]) -> list[dict]:
        return self._call("PUT", f"/api/groups/{_seg(group_id)}/members/me/wishes/order", json={"wish_ids": wish_ids})

    def gift_receipt(self, group_id: str) -> dict:
        return self._call("GET", f"/api/groups/{_seg(group_id)}/members/me/gift")

    def set_gift_received(self, group_id: str, received: bool) -> dict:
        return self._call("PUT", f"/api/groups/{_seg(group_id)}/members/me/gift", json={"received": received})

    # -- the assignment (the giver's side)

    def assignment(self, group_id: str) -> dict:
        return self._call("GET", f"/api/groups/{_seg(group_id)}/assignment")

    def claim(self, group_id: str, wish_id: str, state: str, quantity: int | None) -> dict:
        return self._call("PUT", f"/api/groups/{_seg(group_id)}/assignment/wishes/{_seg(wish_id)}/claim",
                          json=_body(state=state, quantity=quantity))

    def release_claim(self, group_id: str, wish_id: str) -> dict:
        return self._call("DELETE", f"/api/groups/{_seg(group_id)}/assignment/wishes/{_seg(wish_id)}/claim")

    def set_gift_stage(self, group_id: str, stage: str) -> dict:
        return self._call("PUT", f"/api/groups/{_seg(group_id)}/assignment/gift", json={"stage": stage})

    # -- anonymous questions

    def giver_thread(self, group_id: str) -> dict:
        return self._call("GET", f"/api/groups/{_seg(group_id)}/assignment/questions")

    def ask(self, group_id: str, body: str) -> dict:
        return self._call("POST", f"/api/groups/{_seg(group_id)}/assignment/questions", json={"body": body})

    def recipient_thread(self, group_id: str) -> dict:
        return self._call("GET", f"/api/groups/{_seg(group_id)}/members/me/questions")

    def reply(self, group_id: str, body: str) -> dict:
        return self._call("POST", f"/api/groups/{_seg(group_id)}/members/me/questions", json={"body": body})

    # -- invitations and reminders (organizer)

    def invitations(self, group_id: str) -> list[dict]:
        return self._call("GET", f"/api/groups/{_seg(group_id)}/invitations")

    def invite(self, group_id: str, emails: list[str]) -> dict:
        return self._call("POST", f"/api/groups/{_seg(group_id)}/invitations", json={"emails": emails})

    def resend_invitation(self, group_id: str, invitation_id: str) -> dict:
        return self._call("POST", f"/api/groups/{_seg(group_id)}/invitations/{_seg(invitation_id)}/resend")

    def revoke_invitation(self, group_id: str, invitation_id: str) -> None:
        self._call("POST", f"/api/groups/{_seg(group_id)}/invitations/{_seg(invitation_id)}/revoke")

    def accept_invitation(self, group_id: str, invitation_id: str, token: str, confirm_address_mismatch: bool) -> dict:
        return self._call("POST", f"/api/groups/{_seg(group_id)}/invitations/{_seg(invitation_id)}/accept",
                          json={"token": token, "confirm_address_mismatch": confirm_address_mismatch})

    def reminders(self, group_id: str) -> dict:
        return self._call("GET", f"/api/groups/{_seg(group_id)}/reminders")

    def send_reminder(self, group_id: str, rule: str, invitation_id: str | None) -> dict:
        return self._call("POST", f"/api/groups/{_seg(group_id)}/reminders/send",
                          json=_body(rule=rule, invitation_id=invitation_id))

    # -- templates

    def templates(self) -> list[dict]:
        return self._call("GET", "/api/templates")

    def duplicate_template(self, template_id: str) -> dict:
        return self._call("POST", f"/api/templates/{_seg(template_id)}/duplicate")

    def apply_template(self, template_id: str, **fields) -> dict:
        return self._call("POST", f"/api/templates/{_seg(template_id)}/apply", json=_body(**fields))
