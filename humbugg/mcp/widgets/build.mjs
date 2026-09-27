// Build every page under src/pages/<name>/ into ../humbugg_mcp/ui/<name>.html:
// one self-contained HTML file each (scripts, styles and fonts inlined), which
// is what an MCP Apps host renders in its sandbox — no CDN, no second request.
//
// One Vite build per page: vite-plugin-singlefile inlines one entry at a time,
// and a page's root is its own folder so its index.html is the entry.
// `node build.mjs <name>` builds one page.
import { build } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { viteSingleFile } from "vite-plugin-singlefile";
import { readdirSync, renameSync, rmSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const pages = resolve(here, "src/pages");
const out = resolve(here, "../humbugg_mcp/ui");

// @ansavva/design-system re-exports extensionless "./button" and leaves leaf
// selection to the bundler: `.web.*` must come first (tsconfig's
// `moduleSuffixes` mirrors this for tsc). Same configuration as marketing/.
const webFirstExtensions = [
  ".web.tsx", ".web.ts", ".web.jsx", ".web.js",
  ".mjs", ".js", ".mts", ".ts", ".jsx", ".tsx", ".json",
];

const only = process.argv[2];
for (const name of readdirSync(pages)) {
  if (only && name !== only) continue;
  const root = resolve(pages, name);
  await build({
    root,
    configFile: false,
    logLevel: "warn",
    plugins: [tailwindcss(), react(), viteSingleFile()],
    resolve: { extensions: webFirstExtensions },
    optimizeDeps: { include: ["@ansavva/design-system"], rollupOptions: { resolve: { extensions: webFirstExtensions } } },
    build: { outDir: out, emptyOutDir: false, cssCodeSplit: false, assetsInlineLimit: 100_000_000 },
  });
  const built = resolve(out, "index.html");
  const target = resolve(out, `${name}.html`);
  if (existsSync(target)) rmSync(target);
  renameSync(built, target);
  console.log(`built ${name}.html`);
}
