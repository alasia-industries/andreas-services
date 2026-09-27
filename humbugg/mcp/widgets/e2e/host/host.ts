/**
 * A test stand-in for an MCP Apps host (Claude's chat), bundled for Playwright
 * by `e2e/build-host.mjs`. It loads one built page in a sandboxed iframe on
 * another origin, speaks the host side of the protocol through the SDK's own
 * `AppBridge`, pushes the tool input and result, answers `tools/call` from the
 * fixtures it was started with, and records everything the page asks for.
 */

import { AppBridge, PostMessageTransport } from "@modelcontextprotocol/ext-apps/app-bridge";

export type Result = {
  content?: { type: "text"; text: string }[];
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
};

export type HostConfig = {
  /** `https://widget.test/<page>.html` (a secure context, as a real host is) */
  src: string;
  args: Record<string, unknown>;
  /** What the host pushes as the tool's result (a replay, in a reopened chat). */
  result: Result;
  /** Replies per tool name, in order; the last one repeats. */
  responses: Record<string, Result[]>;
  theme?: "light" | "dark";
  /** The iframe's permissions policy, e.g. `clipboard-write` (absent: the page may not write the clipboard). */
  allow?: string;
};

export type HostRecord = {
  calls: { name: string; arguments: Record<string, unknown> }[];
  messages: string[];
  contexts: string[];
  links: string[];
  initialized: boolean;
};

const record: HostRecord = { calls: [], messages: [], contexts: [], links: [], initialized: false };
const textOf = (content: unknown) =>
  ((content as { type: string; text?: string }[] | undefined) ?? []).map((c) => c.text ?? "").join("\n");

async function start(cfg: HostConfig): Promise<void> {
  const iframe = document.createElement("iframe");
  iframe.setAttribute("sandbox", "allow-scripts allow-same-origin");
  iframe.title = "widget";
  if (cfg.allow) iframe.setAttribute("allow", cfg.allow);
  document.body.append(iframe);

  const bridge = new AppBridge(
    null,
    { name: "humbugg-widgets-test-host", version: "0.0.0" },
    { openLinks: {}, serverTools: {}, updateModelContext: { text: {} }, message: { text: {} } },
    { hostContext: { theme: cfg.theme ?? "light", displayMode: "inline" } },
  );
  const queues: Record<string, Result[]> = structuredClone(cfg.responses);
  bridge.oncalltool = async (params) => {
    const args = (params.arguments ?? {}) as Record<string, unknown>;
    record.calls.push({ name: params.name, arguments: args });
    const q = queues[params.name];
    if (!q || q.length === 0) return { isError: true, content: [{ type: "text", text: `no fixture for ${params.name}` }] };
    return (q.length > 1 ? q.shift()! : q[0]!) as never;
  };
  bridge.onmessage = async (p) => {
    record.messages.push(textOf(p.content));
    return {};
  };
  bridge.onupdatemodelcontext = async (p) => {
    record.contexts.push(textOf(p.content));
    return {};
  };
  bridge.onopenlink = async (p) => {
    record.links.push(p.url);
    return {};
  };
  bridge.addEventListener("sizechange", ({ height }) => {
    if (typeof height === "number" && height > 0) iframe.style.height = `${Math.ceil(height)}px`;
  });
  bridge.oninitialized = () => {
    record.initialized = true;
    void bridge.sendToolInput({ arguments: cfg.args }).then(() => bridge.sendToolResult(cfg.result as never));
  };

  // Listen before the page loads: it sends `ui/initialize` as soon as it runs.
  // The iframe's WindowProxy survives its navigation to `src`.
  await bridge.connect(new PostMessageTransport(iframe.contentWindow!, iframe.contentWindow!));
  iframe.src = cfg.src;
}

declare global {
  interface Window {
    __host: { start: typeof start; record: HostRecord };
  }
}

window.__host = { start, record };
