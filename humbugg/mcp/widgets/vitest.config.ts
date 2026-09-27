import { defineConfig } from "vitest/config";

// Pure logic only (result parsing, claim buttons, prices): no DOM, no styles.
// The pages themselves are exercised by Playwright against the built files.
export default defineConfig({
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
  },
});
