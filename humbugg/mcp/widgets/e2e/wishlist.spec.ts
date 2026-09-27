import { expect, test } from "@playwright/test";

import { GROUP, openPage, result, textResult } from "./harness";

test("re-calls edit_wishlist on load", async ({ page }) => {
  const { frame, calls } = await openPage(page, "wishlist", {
    result: result("edit_wishlist"),
    responses: { edit_wishlist: [result("edit_wishlist")] },
  });
  await expect(frame.getByTestId("wish")).toHaveCount(3);
  expect(await calls()).toEqual([{ name: "edit_wishlist", arguments: { group_id: GROUP } }]);
});

test("Add sends add_wish, then re-calls edit_wishlist and redraws", async ({ page }) => {
  const { frame, calls } = await openPage(page, "wishlist", {
    result: result("edit_wishlist"),
    responses: {
      edit_wishlist: [result("edit_wishlist"), result("edit_wishlist-after-add")],
      add_wish: [textResult("add_wish")],
    },
  });
  await expect(frame.getByTestId("wish")).toHaveCount(3);
  await frame.getByRole("button", { name: "Add a wish" }).click();
  await frame.getByLabel("Title").fill("Hiking socks");
  await frame.getByLabel("Price").fill("15");
  await frame.getByLabel("Quantity").fill("2");
  await frame.getByRole("button", { name: "Add wish" }).click();
  await expect(frame.getByTestId("wish")).toHaveCount(4);
  await expect(frame.getByTestId("wish").last()).toContainText("Hiking socks");
  expect(await calls()).toEqual([
    { name: "edit_wishlist", arguments: { group_id: GROUP } },
    {
      name: "add_wish",
      arguments: { group_id: GROUP, title: "Hiking socks", kind: "product", priority: "normal", quantity: 2, price_cents: 1500, currency: "USD" },
    },
    { name: "edit_wishlist", arguments: { group_id: GROUP } },
  ]);
});

test("Add without a title sends nothing", async ({ page }) => {
  const { frame, calls } = await openPage(page, "wishlist", {
    result: result("edit_wishlist"),
    responses: { edit_wishlist: [result("edit_wishlist")] },
  });
  await frame.getByRole("button", { name: "Add a wish" }).click();
  await frame.getByRole("button", { name: "Add wish" }).click();
  await expect(frame.getByRole("alert")).toHaveText("Give the wish a title.");
  expect((await calls()).map((c) => c.name)).toEqual(["edit_wishlist"]);
});

test("move down sends reorder_wishes with the new order", async ({ page }) => {
  const { frame, calls } = await openPage(page, "wishlist", {
    result: result("edit_wishlist"),
    responses: { edit_wishlist: [result("edit_wishlist")], reorder_wishes: [{ content: [{ type: "text", text: '["own_2","own_1","own_3"]' }] }] },
  });
  await frame.getByRole("button", { name: "Move Noise-cancelling headphones down" }).click();
  await expect.poll(async () => (await calls()).map((c) => c.name)).toEqual(["edit_wishlist", "reorder_wishes", "edit_wishlist"]);
  expect((await calls())[1]!.arguments).toEqual({ group_id: GROUP, wish_ids: ["own_2", "own_1", "own_3"] });
});

test("edit sends only what changed", async ({ page }) => {
  const { frame, calls } = await openPage(page, "wishlist", {
    result: result("edit_wishlist"),
    responses: { edit_wishlist: [result("edit_wishlist")], update_wish: [textResult("add_wish")] },
  });
  const row = frame.locator('[data-wish-id="own_3"]');
  await row.getByRole("button", { name: "Edit" }).click();
  await frame.getByLabel("Title").fill("A mixtape, on cassette");
  await frame.getByRole("button", { name: "Save" }).click();
  await expect.poll(async () => (await calls()).map((c) => c.name)).toEqual(["edit_wishlist", "update_wish", "edit_wishlist"]);
  expect((await calls())[1]!.arguments).toEqual({ group_id: GROUP, wish_id: "own_3", title: "A mixtape, on cassette" });
});

test("delete asks first, then sends delete_wish", async ({ page }) => {
  const { frame, calls } = await openPage(page, "wishlist", {
    result: result("edit_wishlist"),
    responses: { edit_wishlist: [result("edit_wishlist")], delete_wish: [{ content: [{ type: "text", text: '{"deleted":"own_2"}' }] }] },
  });
  const row = frame.locator('[data-wish-id="own_2"]');
  await row.getByRole("button", { name: "Delete" }).click();
  await expect(row.getByTestId("confirm-delete")).toBeVisible();
  expect((await calls()).map((c) => c.name)).toEqual(["edit_wishlist"]);
  await row.getByRole("button", { name: "Yes, delete" }).click();
  await expect.poll(async () => (await calls()).map((c) => c.name)).toEqual(["edit_wishlist", "delete_wish", "edit_wishlist"]);
  expect((await calls())[1]!.arguments).toEqual({ group_id: GROUP, wish_id: "own_2" });
});
