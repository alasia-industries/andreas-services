import pytest

from humbugg_mcp.ratelimit import Limiter, RateLimited


class FakeDynamo:
    def __init__(self):
        self.rows: dict[str, int] = {}
        self.requests = []

    def update_item(self, **kw):
        self.requests.append(kw)
        pk = kw["Key"]["pk"]["S"]
        self.rows[pk] = self.rows.get(pk, 0) + 1
        return {"Attributes": {"calls": {"N": str(self.rows[pk])}}}


def test_counts_per_person_per_minute():
    ddb = FakeDynamo()
    limiter = Limiter("t", per_minute=2, client=ddb)
    limiter.hit("a", now=60)
    limiter.hit("a", now=61)
    limiter.hit("b", now=62)  # someone else has their own budget
    with pytest.raises(RateLimited, match="Wait a minute"):
        limiter.hit("a", now=63)
    limiter.hit("a", now=120)  # a new window
    assert ddb.requests[0]["ExpressionAttributeValues"][":exp"] == {"N": str(3 * 60)}  # TTL two windows on


def test_a_broken_table_never_blocks_a_call():
    class Down:
        def update_item(self, **kw):
            raise RuntimeError("throttled")

    Limiter("t", per_minute=1, client=Down()).hit("a")
