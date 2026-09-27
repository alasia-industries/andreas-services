import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { FrameLocator, Page } from "@playwright/test";

import type { HostConfig, HostRecord, Result } from "./host/host";

const here = dirname(fileURLToPath(import.meta.url));
const ui = resolve(here, "../../humbugg_mcp/ui");
const HOST = "https://host.test";
const WIDGET = "https://widget.test";

export const GROUP = "grp_office_2026";

export function fixture(name: string): Record<string, unknown> {
  return JSON.parse(readFileSync(resolve(here, "fixtures", `${name}.json`), "utf8"));
}

/** A tool result the way the Python server sends one: a summary and the object. */
export function result(name: string, summary = name): Result {
  return { content: [{ type: "text", text: summary }], structuredContent: fixture(name) };
}

/**
 * A plain-dict reply the way the server sends one (`add_wish`, `draw`, …): a
 * JSON text block and no structuredContent.
 */
export function textResult(name: string): Result {
  return { content: [{ type: "text", text: JSON.stringify(fixture(name)) }] };
}

export type Open = {
  frame: FrameLocator;
  record: () => Promise<HostRecord>;
  /** The tool calls the page made, in order. */
  calls: () => Promise<HostRecord["calls"]>;
};

/**
 * Load one built page in the test host: push `pushed` as its tool result
 * (what a replayed chat sends) and answer tool calls from `responses`.
 */
export async function openPage(
  page: Page,
  name: "draw-review" | "assignment" | "wishlist" | "groups" | "group",
  cfg: Omit<HostConfig, "src" | "args"> & { args?: Record<string, unknown> },
): Promise<Open> {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.route(`${HOST}/**`, (route) =>
    route.fulfill({ contentType: "text/html", body: readFileSync(resolve(here, ".host/index.html")) }),
  );
  await page.route(`${WIDGET}/**`, (route) => {
    const file = new URL(route.request().url()).pathname.slice(1);
    return route.fulfill({ contentType: "text/html", body: readFileSync(resolve(ui, file)) });
  });
  // Nothing else is reachable: a wish image on another host fails, as it would
  // under a CSP that did not list it.
  await page.route(/^https?:\/\/(?!host\.test|widget\.test)/, (route) => route.abort());
  await page.goto(`${HOST}/`);
  await page.evaluate((c) => window.__host.start(c), {
    ...cfg,
    args: cfg.args ?? { group_id: GROUP },
    src: `${WIDGET}/${name}.html`,
  } satisfies HostConfig);
  const record = () => page.evaluate(() => structuredClone(window.__host.record));
  return { frame: page.frameLocator("iframe"), record, calls: async () => (await record()).calls };
}
