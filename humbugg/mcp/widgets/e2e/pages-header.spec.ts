import { expect, test } from "@playwright/test";

import { GROUP, openPage, result } from "./harness";

// Every standalone page wears the header: Refresh re-calls its own tool, the
// mark opens the same screen in the app.
const pages = [
  { name: "draw-review", tool: "prepare_draw", fixture: "prepare_draw", url: `https://app.humbugg.com/groups/${GROUP}/draw` },
  { name: "assignment", tool: "show_assignment", fixture: "show_assignment", url: `https://app.humbugg.com/groups/${GROUP}/giving` },
  { name: "wishlist", tool: "edit_wishlist", fixture: "edit_wishlist", url: `https://app.humbugg.com/groups/${GROUP}/you` },
  { name: "group", tool: "show_group", fixture: "show_group-organizer", url: `https://app.humbugg.com/groups/${GROUP}` },
  { name: "groups", tool: "show_groups", fixture: "show_groups", url: "https://app.humbugg.com/", args: {} },
] as const;

for (const p of pages) {
  test(`${p.name}: mark opens ${p.url}; Refresh re-calls ${p.tool}`, async ({ page }) => {
    const { frame, record, calls } = await openPage(page, p.name, {
      args: "args" in p ? p.args : undefined,
      result: result(p.fixture),
      responses: { [p.tool]: [result(p.fixture)] },
    });
    const mark = frame.getByRole("button", { name: "Open in Humbugg" });
    await expect(frame.getByRole("button", { name: "Refresh" })).toBeVisible();
    await expect(mark).toHaveCount(1);
    await mark.click();
    await expect.poll(async () => (await record()).links).toEqual([p.url]);
    await frame.getByRole("button", { name: "Refresh" }).click();
    await expect.poll(async () => (await calls()).map((c) => c.name)).toEqual([p.tool, p.tool]);
  });
}

test("a dev server's app_url sends the mark to the local app", async ({ page }) => {
  const local = result("show_groups");
  local.structuredContent = { ...(local.structuredContent as object), app_url: "http://localhost:8081" };
  const { frame, record } = await openPage(page, "groups", { args: {}, result: local, responses: { show_groups: [local] } });
  await frame.getByRole("button", { name: "Open in Humbugg" }).click();
  await expect.poll(async () => (await record()).links).toEqual(["http://localhost:8081/"]);
});
