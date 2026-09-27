import { defineConfig, devices } from "@playwright/test";

// The built pages (../humbugg_mcp/ui/*.html) in a test host (e2e/.host/), both
// served by `page.route` from disk — no server. `npm run test:e2e` builds both.
export default defineConfig({
  testDir: "e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : "list",
  use: {
    ...devices["Desktop Chrome"],
    viewport: { width: 1200, height: 900 },
    trace: "retain-on-failure",
  },
});
