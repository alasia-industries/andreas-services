// Bundle the test host (e2e/host/) into one HTML file under e2e/.host/, the
// way build.mjs bundles a page: Playwright serves it, and the SDK's AppBridge
// comes from node_modules rather than a CDN.
import { build } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
await build({
  root: resolve(here, "host"),
  configFile: false,
  logLevel: "warn",
  plugins: [viteSingleFile()],
  build: { outDir: resolve(here, ".host"), emptyOutDir: true },
});
console.log("built e2e/.host/index.html");
