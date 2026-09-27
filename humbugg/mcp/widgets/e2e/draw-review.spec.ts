import { expect, test } from "@playwright/test";

import { GROUP, fixture, openPage, result, textResult } from "./harness";

test("re-calls prepare_draw on load and draws the live reply, not the replay", async ({ page }) => {
  // The replay says "drawn"; the live call says open — the page must show open.
  const { frame, calls } = await openPage(page, "draw-review", {
    result: result("prepare_draw-drawn"),
    responses: { prepare_draw: [result("prepare_draw")] },
  });
  await expect(frame.getByRole("button", { name: "Draw names" })).toBeVisible();
  expect(await calls()).toEqual([{ name: "prepare_draw", arguments: { group_id: GROUP } }]);
});

test("renders participants, readiness, exclusions and warnings", async ({ page }) => {
  const { frame } = await openPage(page, "draw-review", {
    result: result("prepare_draw"),
    responses: { prepare_draw: [result("prepare_draw")] },
  });
  const people = frame.getByTestId("participants");
  await expect(people.getByRole("listitem").filter({ hasText: "Ana Ruiz" })).toContainText("Ready");
  await expect(people.getByRole("listitem").filter({ hasText: "Cai Lindqvist" })).toContainText("Not ready");
  await expect(people).toContainText("No wishes yet");
  await expect(frame.getByText("3 of 4 ready")).toBeVisible();
  await expect(frame.getByText("Sitting out: Eli Novak")).toBeVisible();
  await expect(frame.getByTestId("exclusions")).toContainText("Ana Ruiz and Ben Okafor");
  await expect(frame.getByTestId("warnings")).toContainText("Cai Lindqvist hasn't added any wishes");
});

test("Draw names is disabled when can_draw is false", async ({ page }) => {
  const { frame, calls } = await openPage(page, "draw-review", {
    result: result("prepare_draw-blocked"),
    responses: { prepare_draw: [result("prepare_draw-blocked")] },
  });
  await expect(frame.getByTestId("warnings")).toContainText("no valid draw exists");
  await expect(frame.getByRole("button", { name: "Draw names" })).toBeDisabled();
  expect((await calls()).map((c) => c.name)).toEqual(["prepare_draw"]);
});

test("Draw sends nothing until confirmed, then exactly one draw call, and tells the chat", async ({ page }) => {
  const { frame, calls, record } = await openPage(page, "draw-review", {
    result: result("prepare_draw"),
    responses: { prepare_draw: [result("prepare_draw")], draw: [textResult("draw")] },
  });
  await frame.getByRole("button", { name: "Draw names" }).click();
  await expect(frame.getByTestId("confirm")).toContainText("This can't be undone from here");
  expect((await calls()).map((c) => c.name)).toEqual(["prepare_draw"]);

  // Cancel backs out without a call.
  await frame.getByRole("button", { name: "Cancel" }).click();
  await frame.getByRole("button", { name: "Draw names" }).click();
  expect((await calls()).map((c) => c.name)).toEqual(["prepare_draw"]);

  await frame.getByRole("button", { name: "Yes, draw names" }).click();
  await expect(frame.getByTestId("drawn")).toContainText("Names are drawn");
  await expect(frame.getByRole("button", { name: /draw names/i })).toHaveCount(0);
  await expect.poll(async () => (await record()).contexts.length).toBe(1);
  const draws = (await calls()).filter((c) => c.name === "draw");
  expect(draws).toEqual([{ name: "draw", arguments: { group_id: GROUP } }]);
  const { contexts } = await record();
  expect(contexts).toHaveLength(1);
  expect(contexts[0]).toContain(GROUP);
  expect(contexts[0]).not.toContain("Office Secret Santa"); // organizer-written; never forwarded
  expect((await record()).messages).toEqual([]); // no chat message: a host may only prefill it
});

test("a draw error shows the tool's text and leaves the button", async ({ page }) => {
  const { frame } = await openPage(page, "draw-review", {
    result: result("prepare_draw"),
    responses: {
      prepare_draw: [result("prepare_draw")],
      draw: [{ isError: true, content: [{ type: "text", text: "Only an organizer can draw names." }] }],
    },
  });
  await frame.getByRole("button", { name: "Draw names" }).click();
  await frame.getByRole("button", { name: "Yes, draw names" }).click();
  await expect(frame.getByRole("alert").filter({ hasText: "Only an organizer" })).toContainText("Only an organizer can draw names.");
  await expect(frame.getByRole("button", { name: "Draw names" })).toBeEnabled();
});

test("already drawn: says so, no button", async ({ page }) => {
  const { frame } = await openPage(page, "draw-review", {
    result: result("prepare_draw-drawn"),
    responses: { prepare_draw: [result("prepare_draw-drawn")] },
  });
  await expect(frame.getByTestId("drawn")).toBeVisible();
  await expect(frame.getByRole("button", { name: /draw names/i })).toHaveCount(0);
});

test("reads a replay sent as a JSON text block wrapped in {result}", async ({ page }) => {
  const { frame, calls } = await openPage(page, "draw-review", {
    result: { content: [{ type: "text", text: JSON.stringify({ result: fixture("prepare_draw") }) }] },
    responses: { prepare_draw: [result("prepare_draw")] },
  });
  await expect(frame.getByRole("heading", { name: "Office Secret Santa" })).toBeVisible();
  expect((await calls())[0]).toEqual({ name: "prepare_draw", arguments: { group_id: GROUP } });
});

test("Open in Humbugg asks the host to open the group's draw screen", async ({ page }) => {
  const { frame, record } = await openPage(page, "draw-review", {
    result: result("prepare_draw"),
    responses: { prepare_draw: [result("prepare_draw")] },
  });
  await frame.getByRole("button", { name: "Open in Humbugg" }).click();
  await expect.poll(async () => (await record()).links).toEqual([`https://app.humbugg.com/groups/${GROUP}/draw`]);
});
