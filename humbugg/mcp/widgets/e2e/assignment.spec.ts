import { expect, test } from "@playwright/test";

import { GROUP, openPage, result } from "./harness";

const responses = () => ({
  show_assignment: [result("show_assignment")],
  claim_wish: [result("claim_wish-planned")],
});

test("re-calls show_assignment on load", async ({ page }) => {
  const { frame, calls } = await openPage(page, "assignment", { result: result("show_assignment"), responses: responses() });
  await expect(frame.getByRole("heading", { name: "Cai Lindqvist" })).toBeVisible();
  expect(await calls()).toEqual([{ name: "show_assignment", arguments: { group_id: GROUP } }]);
});

test("Planning to buy sends claim_wish and redraws from the reply", async ({ page }) => {
  const { frame, calls } = await openPage(page, "assignment", { result: result("show_assignment"), responses: responses() });
  const scarf = frame.locator('[data-wish-id="wsh_1"]');
  await expect(scarf.getByTestId("claim-state")).toHaveCount(0);
  await scarf.getByRole("button", { name: "Planning to buy" }).click();
  await expect(scarf.getByTestId("claim-state")).toHaveText("You're planning to buy this");
  await expect(scarf.getByRole("button", { name: "Release" })).toBeVisible();
  await expect(scarf.getByRole("button", { name: "Planning to buy" })).toHaveCount(0);
  const claims = (await calls()).filter((c) => c.name !== "show_assignment");
  expect(claims).toEqual([{ name: "claim_wish", arguments: { group_id: GROUP, wish_id: "wsh_1", state: "planned" } }]);
});

test("a bought wish offers only Release, which sends release_claim", async ({ page }) => {
  const { frame, calls } = await openPage(page, "assignment", {
    result: result("show_assignment"),
    responses: { ...responses(), release_claim: [result("show_assignment")] },
  });
  const pottery = frame.locator('[data-wish-id="wsh_3"]');
  await expect(pottery.getByRole("button")).toHaveText(["Release"]);
  await pottery.getByRole("button", { name: "Release" }).click();
  await expect.poll(async () => (await calls()).map((c) => c.name)).toContain("release_claim");
  expect((await calls()).find((c) => c.name === "release_claim")!.arguments).toEqual({ group_id: GROUP, wish_id: "wsh_3" });
});

test("what the recipient wrote renders as text, never HTML", async ({ page }) => {
  let dialogs = 0;
  page.on("dialog", (d) => {
    dialogs += 1;
    void d.dismiss();
  });
  const { frame } = await openPage(page, "assignment", { result: result("show_assignment"), responses: responses() });
  const hostile = frame.locator('[data-wish-id="wsh_2"]');
  await expect(hostile.getByTestId("wish-title")).toHaveText("<img src=x onerror=alert(1)>");
  await expect(hostile.getByText("**not markdown** <b>not html</b>")).toBeVisible();
  await expect(frame.locator('img[src="x"]')).toHaveCount(0);
  await expect(frame.locator("b")).toHaveCount(0);
  // A javascript: link is not offered.
  await expect(hostile.getByRole("button", { name: /Open link/ })).toHaveCount(0);
  await expect(hostile.getByTestId("wish-image-placeholder")).toBeVisible();
  await expect(frame.getByTestId("wishlist-text")).toHaveText("Anything green.\nI like cooking and long walks.");
  await expect(frame.getByTestId("avoidances-text")).toHaveText("No candles, no novelty mugs.");
  expect(dialogs).toBe(0);
});

test("a wish link opens through the host; image_url is never fetched", async ({ page }) => {
  const fetched: string[] = [];
  page.on("request", (r) => {
    if (r.url().includes("example.com")) fetched.push(r.url());
  });
  const { frame, record } = await openPage(page, "assignment", { result: result("show_assignment"), responses: responses() });
  const scarf = frame.locator('[data-wish-id="wsh_1"]');
  await expect(scarf.getByTestId("wish-image-placeholder")).toBeVisible();
  await expect(frame.locator("img")).toHaveCount(0);
  await scarf.getByRole("button", { name: "Open link (shop.example.com)" }).click();
  await expect.poll(async () => (await record()).links).toEqual(["https://shop.example.com/scarf?ref=1"]);
  expect(fetched).toEqual([]);
});
