"""The rules a listing is reviewed against, as tests, so a new tool cannot break one
unnoticed. Claude's: https://claude.com/docs/connectors/building/review-criteria —
OpenAI's: https://developers.openai.com/plugins/deploy/submission."""

import logging

from conftest import call, error, tools

from humbugg_mcp import server as srv

#: Tools that email or notify another person: they must say so and be open-world.
SENDS = {"invite_by_email", "resend_invitation", "send_reminder", "ask_my_recipient", "answer_my_secret_santa", "draw"}
#: Tools that change or lose something the person can't simply redo.
DESTRUCTIVE = {"delete_wish", "set_exclusions", "new_invite_link", "revoke_invitation", "apply_template", "draw"}
#: Never exposed: payments, deletion, reset, the emergency reveal, account data.
FORBIDDEN = {"reveal", "reset", "delete_group", "remove_member", "checkout", "delete_account", "export", "leave_group",
             "clear_private_data", "upload_avatar"}


def test_every_tool_has_a_title_all_three_hints_and_a_short_name():
    for name, tool in tools().items():
        a = tool.annotations
        assert a is not None, name
        assert a.title and tool.title, f"{name}: no title"
        assert a.read_only_hint is not None and a.destructive_hint is not None and a.open_world_hint is not None, name
        assert len(name) <= 64 and name.isidentifier(), name
        assert tool.description and "Args:" not in tool.description, name


def test_every_argument_is_described():
    for name, tool in tools().items():
        for arg, schema in tool.input_schema.get("properties", {}).items():
            assert schema.get("description"), f"{name}.{arg} has no description"


def test_hints_match_what_the_tool_does():
    ts = tools()
    for name, tool in ts.items():
        a = tool.annotations
        assert a.open_world_hint is (name in SENDS), name
        assert a.destructive_hint is (name in DESTRUCTIVE), name
        if a.read_only_hint:
            assert not a.destructive_hint, name
    assert not FORBIDDEN & set(ts)


def test_the_draw_is_only_reachable_from_its_page():
    ts = tools()
    assert ts["draw"].meta["ui"]["visibility"] == ["app"]
    assert ts["prepare_draw"].meta["ui"]["resourceUri"] == ts["draw"].meta["ui"]["resourceUri"]
    assert ts["prepare_draw"].annotations.read_only_hint


def test_tools_that_email_people_ask_for_a_yes_in_their_description():
    ts = tools()
    for name in SENDS - {"draw"}:
        assert "yes" in ts[name].description.lower(), name


def test_errors_are_actionable_not_generic(stub):
    assert "Wish not found" in error("delete_wish", group_id="g-open", wish_id="nope")
    assert "Assignments have not been created yet" in error("my_assignment", group_id="g-open")
    assert "Plus feature" in error("invite_by_email", group_id="g-drawn", emails=["a@example.test"])
    assert "invitation link" in error("join_with_link", link="https://evil.example/join/g-open#invite=x")


def test_server_errors_say_what_to_do(stub, monkeypatch):
    import httpx

    monkeypatch.setattr(srv, "API_TRANSPORT", httpx.MockTransport(lambda r: httpx.Response(502, text="bad gateway")))
    assert "Try again in a minute" in error("list_groups")
    monkeypatch.setattr(srv, "API_TRANSPORT", httpx.MockTransport(
        lambda r: httpx.Response(401, json={"message": "Unauthorized"})))
    assert "Reconnect the Humbugg connector" in error("list_groups")


def test_no_argument_or_result_reaches_a_log_line(stub, caplog):
    secret = "Zebra-print-sock-7f3k"
    with caplog.at_level(logging.DEBUG):
        call("add_wish", group_id="g-open", title=secret, details=secret)
        call("my_assignment", group_id="g-drawn")
        call("ask_my_recipient", group_id="g-drawn", body=secret)
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert secret not in text
    assert "Tea sampler" not in text and "g-open" not in text.replace('"tool"', "")
    assert '"tool": "add_wish"' in text  # the audit line itself is there
