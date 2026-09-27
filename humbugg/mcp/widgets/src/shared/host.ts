/**
 * The page's side of MCP Apps: one `App` per page, the host's theme applied to
 * the design system, the page's own tool called again on load, links out, and
 * "tell the conversation".
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { App } from "@modelcontextprotocol/ext-apps";

import { currentAppOrigin } from "./logic";
import { describeResult, groupIdOf, parseResult, textOf, type ToolResult } from "./result";

/** The design system themes by `[data-theme]`: the host's theme when it says, the OS before. */
function applyTheme(app: App | null): void {
  const fromHost = app?.getHostContext()?.theme;
  const theme =
    fromHost === "dark" || fromHost === "light"
      ? fromHost
      : window.matchMedia?.("(prefers-color-scheme: dark)").matches
        ? "dark"
        : "light";
  document.documentElement.dataset.theme = theme;
}

/** Call a server tool through the host and read its reply; a tool error throws with its text. */
export async function callTool<T>(app: App, name: string, args: Record<string, unknown>): Promise<T> {
  const result = (await app.callServerTool({ name, arguments: args })) as ToolResult;
  return parseResult<T>(result);
}

/**
 * Call a write tool whose reply the page does not draw (it re-calls its own
 * tool instead). Only `isError` fails it: a reply that is plain text, a list,
 * or a JSON text block is all success.
 */
export async function callWrite(app: App, name: string, args: Record<string, unknown>): Promise<void> {
  const result = (await app.callServerTool({ name, arguments: args })) as ToolResult;
  if (result.isError) throw new Error(textOf(result) || `${name} failed`);
}

/**
 * Open a page of the Humbugg app — the only origin a page links to on its own
 * account — or a wish's own link, which the recipient wrote. Always through the
 * host (`openLink`, which may confirm first): the sandbox blocks plain links
 * and `window.open`.
 */
export async function openLink(app: App | null, url: string): Promise<boolean> {
  if (!app) return false;
  try {
    const r = await app.openLink({ url });
    return !(r as { isError?: boolean } | undefined)?.isError;
  } catch {
    return false;
  }
}

export function isAppLink(url: string): boolean {
  const origin = currentAppOrigin();
  return url === origin || url.startsWith(`${origin}/`);
}

/** Add a note to the model's context (silent; read on the next turn). */
export async function addContext(app: App, text: string): Promise<boolean> {
  try {
    await app.updateModelContext({ content: [{ type: "text", text }] });
    return true;
  } catch (e) {
    console.warn("updateModelContext unavailable:", e);
    return false;
  }
}

/** Send text as the person's chat message, so the conversation proceeds. */
export async function sendMessage(app: App, text: string): Promise<boolean> {
  try {
    const r = await app.sendMessage({ role: "user", content: [{ type: "text", text }] });
    return !(r as { isError?: boolean } | undefined)?.isError;
  } catch (e) {
    console.warn("sendMessage unavailable:", e);
    return false;
  }
}

export type ToolPage<T> = {
  app: App | null;
  view: T | null;
  /** Replace the view with a fresh reply (a write that answers with the whole view). */
  setView: (v: T) => void;
  /** The group this page is about, once known. */
  groupId: string | null;
  /** Load failure: the tool's own error text, or what arrived. */
  error: string | null;
  /** True when the live re-call failed and the page shows the replayed result. */
  stale: boolean;
  /** Call the page's own tool again and redraw. */
  reload: () => Promise<void>;
};

/**
 * Connect, and draw the page from its tool — called again, live.
 *
 * A reopened chat replays the tool result from when the page was first shown,
 * so the pushed result is only a snapshot: it names the group, and the page
 * calls its own `tool` for that group and draws the reply. The snapshot is
 * drawn only when that call fails. A tool that takes no arguments
 * (`scope: "none"`, e.g. `show_groups`) is called again with `{}`.
 */
export function useToolPage<T>(
  name: string,
  tool: string,
  isShape: (v: object) => boolean,
  scope: "group" | "none" = "group",
): ToolPage<T> {
  const appRef = useRef<App | null>(null);
  const [app, setApp] = useState<App | null>(null);
  const [view, setView] = useState<T | null>(null);
  const [groupId, setGroupId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [stale, setStale] = useState(false);
  const inputGroup = useRef<string | null>(null);
  const argsRef = useRef<Record<string, unknown> | null>(null);

  const load = useCallback(
    async (args: Record<string, unknown>) => {
      const a = appRef.current;
      if (!a) return;
      const live = (await a.callServerTool({ name: tool, arguments: args })) as ToolResult;
      const v = parseResult<T>(live, isShape);
      setView(v);
      setStale(false);
      setError(null);
    },
    [tool, isShape],
  );

  useEffect(() => {
    applyTheme(null);
    const a = new App({ name, version: "0.1.0" });
    appRef.current = a;
    setApp(a);
    a.ontoolinput = (params) => {
      const id = (params?.arguments as { group_id?: unknown } | undefined)?.group_id;
      if (typeof id === "string" && id) inputGroup.current = id;
    };
    a.ontoolresult = async (result) => {
      let snapshot: T;
      try {
        snapshot = parseResult<T>(result as ToolResult, isShape);
      } catch (e) {
        setError((e as Error).message);
        return;
      }
      const id = groupIdOf(snapshot) ?? inputGroup.current;
      setGroupId(id);
      const args = scope === "none" ? {} : id ? { group_id: id } : null;
      argsRef.current = args;
      if (!args) {
        setView(snapshot);
        return;
      }
      try {
        await load(args);
      } catch (e) {
        console.warn(`live ${tool} failed; drawing the replayed result`, e);
        setView(snapshot);
        setStale(true);
      }
    };
    a.onhostcontextchanged = () => applyTheme(a);
    void a
      .connect()
      .then(() => applyTheme(a))
      .catch((e) => setError(`Could not reach the host: ${(e as Error).message}`));
    return () => {
      void a.close();
    };
    // One connection for the page's life.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const reload = useCallback(async () => {
    if (!argsRef.current) return;
    try {
      await load(argsRef.current);
    } catch (e) {
      setError((e as Error).message);
    }
  }, [load]);

  return { app, view, setView, groupId, error, stale, reload };
}

export { describeResult };
