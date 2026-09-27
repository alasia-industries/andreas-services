/**
 * In-page navigation for the groups and group pages.
 *
 * In the Claude desktop app `sendMessage` only prefills the composer, so a
 * step that asked the model to open another page took two actions. Instead a
 * step calls its tool here (`app.callServerTool`) and draws the reply with the
 * same view component the standalone page uses, on a stack with a Back button.
 * Every view keeps its whole behaviour — Draw with its confirm, Claim/Release,
 * wish list editing — because those already call tools directly.
 *
 * The model is kept informed with `updateModelContext`, in FIXED wording with
 * the group id and the kind of view only: a group name is organizer-written
 * text and never goes into the conversation. Back re-calls the view it returns
 * to, so a draw made in the stack shows as "Names drawn" there.
 *
 * A reopened chat replays the page's original result; the stack is not kept,
 * so it starts again at the root.
 */

import { useState, type ReactNode } from "react";
import { Button } from "@ansavva/design-system";
import type { App } from "@modelcontextprotocol/ext-apps";

import { AssignmentView, isAssignment } from "../pages/assignment/Assignment";
import { DrawReviewView, isDrawReview } from "../pages/draw-review/DrawReview";
import { GroupView, isGroupDetail } from "../pages/group/Group";
import { WishlistView, isWishlist } from "../pages/wishlist/Wishlist";
import { addContext } from "../shared/host";
import { NavContext, type Navigate } from "../shared/nav-context";
import { parseResult, type ToolResult } from "../shared/result";
import type { Assignment, DrawReview, GroupDetail, NextStep, Wishlist } from "../shared/types";

export type Kind = "group" | "draw" | "assignment" | "wishlist";

const KINDS: Record<Kind, { tool: string; isShape: (v: object) => boolean; label: string; back: string }> = {
  group: { tool: "show_group", isShape: isGroupDetail, label: "group details", back: "Group details" },
  draw: { tool: "prepare_draw", isShape: isDrawReview, label: "draw review", back: "Draw review" },
  assignment: { tool: "show_assignment", isShape: isAssignment, label: "assignment", back: "Assignment" },
  wishlist: { tool: "edit_wishlist", isShape: isWishlist, label: "wish list", back: "Wish list" },
};

const STEP_KIND: Record<NextStep["action"], Kind> = {
  details: "group",
  draw: "draw",
  assignment: "assignment",
  wishlist: "wishlist",
};

/** The context note for a view: fixed wording, the id, the kind. Never a name. */
export function noteFor(kind: Kind, groupId: string): string {
  return `The person is viewing the ${KINDS[kind].label} for Humbugg group ${groupId} in the Humbugg page.`;
}

type Entry = { key: number; kind: Kind; groupId: string; view: unknown };

async function load(app: App, kind: Kind, groupId: string): Promise<unknown> {
  if (!app.getHostCapabilities()?.serverTools) throw new Error("");
  const result = (await app.callServerTool({ name: KINDS[kind].tool, arguments: { group_id: groupId } })) as ToolResult;
  return parseResult<unknown>(result, KINDS[kind].isShape);
}

let nextKey = 1;

export function Navigator({
  app,
  rootLabel,
  rootNote,
  reloadRoot,
  children,
}: {
  app: App | null;
  /** What Back says when it returns to the root ("Your groups"). */
  rootLabel: string;
  /** The context note for the root view. */
  rootNote: string;
  /** Calls the root page's own tool again. */
  reloadRoot: () => Promise<void>;
  children: ReactNode;
}) {
  const [stack, setStack] = useState<Entry[]>([]);
  const [going, setGoing] = useState(false);

  const navigate: Navigate = async (step, groupId) => {
    if (!app) throw new Error("");
    const kind = STEP_KIND[step.action];
    const view = await load(app, kind, groupId);
    setStack((s) => [...s, { key: nextKey++, kind, groupId, view }]);
    window.scrollTo?.(0, 0);
    await addContext(app, noteFor(kind, groupId));
  };

  const replaceTop = (view: unknown) => setStack((s) => (s.length ? [...s.slice(0, -1), { ...s[s.length - 1]!, view }] : s));

  /** Call the top view's tool again and redraw it. */
  const refreshTop = async (entry: Entry) => {
    if (!app) return;
    const view = await load(app, entry.kind, entry.groupId);
    setStack((s) => s.map((e) => (e.key === entry.key ? { ...e, view } : e)));
  };

  const back = async () => {
    if (going) return;
    setGoing(true);
    const rest = stack.slice(0, -1);
    const target = rest[rest.length - 1];
    setStack(rest);
    try {
      if (app) await addContext(app, target ? noteFor(target.kind, target.groupId) : rootNote);
      // What we return to may have changed (a draw, a claim): draw it as it is now.
      if (target) await refreshTop(target).catch(() => undefined);
      else await reloadRoot();
    } finally {
      setGoing(false);
    }
  };

  const top = stack[stack.length - 1];
  const prev = stack[stack.length - 2];

  return (
    <NavContext.Provider value={navigate}>
      {top ? (
        <div className="flex flex-col gap-2" key={top.key}>
          <div>
            <Button size="sm" intent="ghost" onClick={() => void back()} disabled={going}>
              ← {prev ? KINDS[prev.kind].back : rootLabel}
            </Button>
          </div>
          <View app={app} entry={top} replaceTop={replaceTop} refreshTop={() => refreshTop(top)} />
        </div>
      ) : (
        children
      )}
    </NavContext.Provider>
  );
}

function View({
  app,
  entry,
  replaceTop,
  refreshTop,
}: {
  app: App | null;
  entry: Entry;
  replaceTop: (v: unknown) => void;
  refreshTop: () => Promise<void>;
}) {
  switch (entry.kind) {
    case "group":
      return <GroupView app={app} view={entry.view as GroupDetail} onReload={refreshTop} />;
    case "draw":
      return (
        <DrawReviewView
          app={app}
          view={entry.view as DrawReview}
          onReload={refreshTop}
          // In the stack the chat is told by a context note, not a message.
          onDrawn={async (a) => {
            await addContext(a, `Names were drawn for Humbugg group ${entry.groupId}.`);
          }}
        />
      );
    case "assignment":
      return <AssignmentView app={app} view={entry.view as Assignment} setView={replaceTop} onReload={refreshTop} />;
    case "wishlist":
      return <WishlistView app={app} view={entry.view as Wishlist} reload={refreshTop} />;
  }
}
