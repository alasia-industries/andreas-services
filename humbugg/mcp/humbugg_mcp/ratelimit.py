"""A per-person limit on tool calls, for the hosted server.

The API stage's throttle is one aggregate number for everybody, and WAF cannot sit in
front of an HTTP API, so one connected account looping on a tool could take the whole
budget. This counts calls per `sub` in fixed one-minute windows: one DynamoDB
`UpdateItem` (atomic `ADD`) per call, rows expiring by TTL. Stateless, so any Lambda
instance can answer any request.

Keyed on the VERIFIED subject — it runs inside a tool call, after the SDK has checked
the bearer — so a forged token cannot spend somebody else's quota.
"""

from __future__ import annotations

import logging
import time

import boto3
from mcp.server.mcpserver.exceptions import ToolError

log = logging.getLogger("humbugg_mcp")


class RateLimited(ToolError):
    pass


class Limiter:
    def __init__(self, table: str, per_minute: int, region: str = "us-east-1", client=None):
        self.table = table
        self.per_minute = per_minute
        self.ddb = client or boto3.client("dynamodb", region_name=region)

    def hit(self, subject: str, now: float | None = None) -> None:
        window = int((now if now is not None else time.time()) // 60)
        try:
            r = self.ddb.update_item(
                TableName=self.table,
                Key={"pk": {"S": f"{subject}#{window}"}},
                UpdateExpression="ADD calls :one SET expires_at = if_not_exists(expires_at, :exp)",
                ExpressionAttributeValues={":one": {"N": "1"}, ":exp": {"N": str((window + 2) * 60)}},
                ReturnValues="UPDATED_NEW",
            )
        except Exception:  # the limiter must never be the reason a call fails
            log.exception("rate limiter unavailable; allowing the call")
            return
        if int(r["Attributes"]["calls"]["N"]) > self.per_minute:
            raise RateLimited(f"Too many Humbugg requests from this account — the limit is {self.per_minute} a minute. "
                              "Wait a minute, then try again.")
