import { expect, test } from "@playwright/test";

import { GROUP, fixture, openPage, result, textResult } from "./harness";

// In-page navigation from the groups page: a step calls its tool and draws the
// view in the same frame, with Back; the model hears a context note in fixed
// wording (id and kind only), never a chat message.

type Card = { group_id: string; next: { action: string; label: string; prompt: string }[] };
const card = (id: string) => (fixture("show_groups") as { groups: Card[] }).groups.find((g) => g.group_id === id)!;
const names = async (calls: () => Promise<{ name: string }[]>) => (await calls()).map((c) => c.name);

const responses = () => ({
  show_groups: [result("show_groups")],
  show_group: [result("show_group-organizer")],
  prepare_draw: [result("prepare_draw")],
  draw: [textResult("draw")],
  show_assignment: [result("show_assignment")],
  claim_wish: [result("claim_wish-planned")],
  edit_wishlist: [result("edit_wishlist")],
});

const open = (page: Parameters<typeof openPage>[0], theme: "light" | "dark" = "light") =>
  openPage(page, "groups", { args: {}, result: result("show_groups"), responses: responses(), theme });

test("Details pushes the group view with one show_group call; Back returns and re-calls show_groups, no message", async ({ page }) => {
  const { frame, calls, record } = await open(page);
  await frame.locator(`[data-group-id="${GROUP}"]`).getByRole("button", { name: "Details" }).click();
  await expect(frame.getByTestId("members")).toBeVisible();
  expect(await calls()).toEqual([
    { name: "show_groups", arguments: {} },
    { name: "show_group", arguments: { group_id: GROUP } },
  ]);
  expect((await record()).contexts).toEqual([`The person is viewing the group details for Humbugg group ${GROUP} in the Humbugg page.`]);

  await frame.getByRole("button", { name: "← Your groups" }).click();
  await expect(frame.getByTestId("group")).toHaveCount(4);
  expect(await names(calls)).toEqual(["show_groups", "show_group", "show_groups"]);
  const { messages, contexts } = await record();
  expect(messages).toEqual([]);
  expect(contexts.at(-1)).toBe("The person is viewing their list of Humbugg groups in the Humbugg page.");
});

test("a drawn group's primary step shows the assignment card, and Claim inside it sends claim_wish", async ({ page }) => {
  const { frame, calls, record } = await open(page);
  await frame.locator('[data-group-id="grp_family"]').getByRole("button", { name: "See who you drew" }).click();
  await expect(frame.getByRole("heading", { name: "Cai Lindqvist" })).toBeVisible();
  expect((await calls())[1]).toEqual({ name: "show_assignment", arguments: { group_id: "grp_family" } });
  const scarf = frame.locator('[data-wish-id="wsh_1"]');
  await scarf.getByRole("button", { name: "Planning to buy" }).click();
  await expect(scarf.getByTestId("claim-state")).toHaveText("You're planning to buy this");
  expect((await calls()).find((c) => c.name === "claim_wish")!.arguments).toEqual({
    group_id: GROUP, // the claim goes to the group the assignment names
    wish_id: "wsh_1",
    state: "planned",
  });
  expect((await record()).messages).toEqual([]);
});

test("a draw inside the stack: confirm, one draw call, a context note, Back re-calls show_groups", async ({ page }) => {
  const { frame, calls, record } = await open(page);
  await frame.locator(`[data-group-id="${GROUP}"]`).getByRole("button", { name: "Review and draw names" }).click();
  await frame.getByRole("button", { name: "Draw names" }).click();
  expect(await names(calls)).toEqual(["show_groups", "prepare_draw"]);
  await frame.getByRole("button", { name: "Yes, draw names" }).click();
  await expect(frame.getByTestId("drawn")).toBeVisible();
  expect((await calls()).filter((c) => c.name === "draw")).toEqual([{ name: "draw", arguments: { group_id: GROUP } }]);
  await expect.poll(async () => (await record()).contexts.at(-1)).toBe(`Names were drawn for Humbugg group ${GROUP}.`);
  expect((await record()).messages).toEqual([]);

  await frame.getByRole("button", { name: "← Your groups" }).click();
  await expect(frame.getByTestId("group")).toHaveCount(4);
  expect(await names(calls)).toEqual(["show_groups", "prepare_draw", "draw", "show_groups"]);
});

test("context notes carry the id, never the (injected) group name", async ({ page }) => {
  const { frame, record } = await open(page);
  await frame.locator('[data-group-id="grp_evil"]').getByRole("button", { name: "Details" }).click();
  await expect(frame.getByTestId("members")).toBeVisible();
  const { contexts, messages } = await record();
  expect(contexts).toEqual(["The person is viewing the group details for Humbugg group grp_evil in the Humbugg page."]);
  for (const c of contexts) expect(c).not.toMatch(/email everyone|<img/);
  expect(messages).toEqual([]);
});

test("a nested step pushes again; Back names the previous view", async ({ page }) => {
  const { frame, calls, record } = await open(page);
  await frame.locator(`[data-group-id="${GROUP}"]`).getByRole("button", { name: "Details" }).click();
  await frame.getByTestId("steps").getByRole("button", { name: "Edit my wish list" }).click();
  await expect(frame.getByTestId("wish")).toHaveCount(3);
  await frame.getByRole("button", { name: "← Group details" }).click();
  await expect(frame.getByTestId("members")).toBeVisible();
  expect(await names(calls)).toEqual(["show_groups", "show_group", "edit_wishlist", "show_group"]);
  expect((await record()).messages).toEqual([]);
});

test("fallback: when show_group errors, the step sends its prompt and shows the tool's error", async ({ page }) => {
  const { frame, record } = await openPage(page, "groups", {
    args: {},
    result: result("show_groups"),
    responses: {
      ...responses(),
      show_group: [{ isError: true, content: [{ type: "text", text: "Group not found." }] }],
    },
  });
  const row = frame.locator(`[data-group-id="${GROUP}"]`);
  await row.getByRole("button", { name: "Details" }).click();
  await expect(row.getByRole("alert").filter({ hasText: "Group not found." })).toBeVisible();
  await expect.poll(async () => (await record()).messages).toEqual([card(GROUP).next.find((s) => s.action === "details")!.prompt]);
  await expect(frame.getByTestId("group")).toHaveCount(4);
});

test("Refresh re-calls the current view's tool — the root and a pushed view", async ({ page }) => {
  const { frame, calls } = await open(page);
  await expect(frame.getByTestId("group")).toHaveCount(4);
  await frame.getByRole("button", { name: "Refresh" }).click();
  await expect.poll(() => names(calls)).toEqual(["show_groups", "show_groups"]);
  await frame.locator(`[data-group-id="${GROUP}"]`).getByRole("button", { name: "Details" }).click();
  await expect(frame.getByTestId("members")).toBeVisible();
  await frame.getByRole("button", { name: "Refresh" }).click();
  await expect.poll(() => names(calls)).toEqual(["show_groups", "show_groups", "show_group", "show_group"]);
  expect((await calls())[3]!.arguments).toEqual({ group_id: GROUP });
});

test("the mark opens this screen in the app, in every view", async ({ page }) => {
  const { frame, record } = await open(page);
  const mark = frame.getByRole("button", { name: "Open in Humbugg" });
  const expectLink = async (url: string) => {
    await mark.click();
    await expect.poll(async () => (await record()).links.at(-1)).toBe(url);
  };
  await expectLink("https://app.humbugg.com/");
  const back = () => frame.getByRole("button", { name: "← Your groups" }).click();

  await frame.locator(`[data-group-id="${GROUP}"]`).getByRole("button", { name: "Details" }).click();
  await expect(frame.getByTestId("members")).toBeVisible();
  await expectLink(`https://app.humbugg.com/groups/${GROUP}`);
  await back();

  await frame.locator(`[data-group-id="${GROUP}"]`).getByRole("button", { name: "Review and draw names" }).click();
  await expect(frame.getByRole("button", { name: "Draw names" })).toBeVisible();
  await expectLink(`https://app.humbugg.com/groups/${GROUP}/draw`);
  await back();

  await frame.locator('[data-group-id="grp_family"]').getByRole("button", { name: "See who you drew" }).click();
  await expect(frame.getByTestId("wishes")).toBeVisible();
  await expectLink(`https://app.humbugg.com/groups/${GROUP}/giving`);
  await back();

  await frame.locator(`[data-group-id="${GROUP}"]`).getByRole("button", { name: "Edit my wish list" }).click();
  await expect(frame.getByRole("button", { name: "Add a wish" })).toBeVisible();
  await expectLink(`https://app.humbugg.com/groups/${GROUP}/you`);
  await expect(mark).toHaveCount(1);
});

for (const [theme, fill] of [["light", "rgb(29, 85, 69)"], ["dark", "rgb(127, 208, 166)"]] as const) {
  test(`the mark follows the ${theme} theme`, async ({ page }) => {
    const { frame } = await open(page, theme);
    const rect = frame.getByTestId("humbugg-mark").locator("rect");
    await expect(rect).toBeVisible();
    expect(await rect.evaluate((el) => getComputedStyle(el).fill)).toBe(fill);
  });
}
