import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test } from "@playwright/test";

import { openPage, result } from "./harness";

// Directory carousel images later: each page at 1200px, light and dark, plus
// a check that nothing scrolls sideways at a phone's ~390px.
const out = resolve(dirname(fileURLToPath(import.meta.url)), "screenshots");
mkdirSync(out, { recursive: true });

const pages = [
  { name: "draw-review", tool: "prepare_draw", ready: "Draw names" },
  { name: "assignment", tool: "show_assignment", ready: "Planning to buy" },
  { name: "wishlist", tool: "edit_wishlist", ready: "Add a wish" },
  { name: "groups", tool: "show_groups", fixture: "show_groups", args: {}, ready: "Details" },
  { name: "group", tool: "show_group", fixture: "show_group-organizer", ready: "Copy" },
] as const;

const fixtureOf = (p: (typeof pages)[number]) => ("fixture" in p ? p.fixture : p.tool);
const argsOf = (p: (typeof pages)[number]) => ("args" in p ? p.args : undefined);

for (const p of pages) {
  for (const theme of ["light", "dark"] as const) {
    test(`screenshot ${p.name} ${theme}`, async ({ page }) => {
      const { frame } = await openPage(page, p.name, {
        args: argsOf(p),
        result: result(fixtureOf(p)),
        responses: { [p.tool]: [result(fixtureOf(p))] },
        theme,
      });
      await expect(frame.getByRole("button", { name: p.ready }).first()).toBeVisible();
      await expect(frame.locator("html")).toHaveAttribute("data-theme", theme);
      await page.waitForTimeout(300); // the host resizes the iframe to the content
      await page.locator("iframe").screenshot({ path: resolve(out, `${p.name}-${theme}.png`) });
    });
  }

  test(`${p.name} fits 390px without sideways scroll`, async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    const { frame } = await openPage(page, p.name, { args: argsOf(p), result: result(fixtureOf(p)), responses: { [p.tool]: [result(fixtureOf(p))] } });
    await expect(frame.getByRole("button", { name: p.ready }).first()).toBeVisible();
    const overflow = await frame.locator("html").evaluate((el) => el.scrollWidth - el.clientWidth);
    expect(overflow).toBeLessThanOrEqual(0);
    await page.waitForTimeout(300);
    await page.locator("iframe").screenshot({ path: resolve(out, `${p.name}-390.png`) });
  });
}

// The groups page with a group's view pushed onto it.
for (const [label, theme, width] of [["light", "light", 1200], ["dark", "dark", 1200], ["390", "light", 390]] as const) {
  test(`screenshot groups with a pushed group view ${label}`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    const { frame } = await openPage(page, "groups", {
      args: {},
      result: result("show_groups"),
      responses: { show_groups: [result("show_groups")], show_group: [result("show_group-organizer")] },
      theme,
    });
    await frame.locator('[data-group-id="grp_office_2026"]').getByRole("button", { name: "Details" }).click();
    await expect(frame.getByRole("button", { name: "← Your groups" })).toBeVisible();
    await expect(frame.locator("html")).toHaveAttribute("data-theme", theme);
    const overflow = await frame.locator("html").evaluate((el) => el.scrollWidth - el.clientWidth);
    expect(overflow).toBeLessThanOrEqual(0);
    await page.waitForTimeout(300);
    await page.locator("iframe").screenshot({ path: resolve(out, `groups-pushed-group-${label}.png`) });
  });
}
