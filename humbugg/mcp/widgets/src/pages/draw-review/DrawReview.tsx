/**
 * The draw review (`prepare_draw`), and the one way to run a draw.
 *
 * Who is in, who is ready and what is missing, the exclusion pairs, the
 * server's warnings, and a Draw names button. The button is the approval: the
 * `draw` tool is app-only, so the model cannot call it, and this page calls it
 * only after the person confirms. Once drawn, the page says so and tells the
 * conversation.
 */

import { useState } from "react";
import { Alert, Badge, Button, Card } from "@ansavva/design-system";
import type { App } from "@modelcontextprotocol/ext-apps";

import { addContext, callTool, useToolPage } from "../../shared/host";
import { appLink, formatDate, formatDateTime, formatLimit, ROLE_LABELS } from "../../shared/logic";
import { ErrorBox, Loading, PageHeader, StaleNote } from "../../shared/Page";
import type { DrawDone, DrawReview as View } from "../../shared/types";

export const isDrawReview = (v: object) => "group" in v && "participants" in v;

type Phase = "idle" | "confirming" | "drawing";

/** The standalone page, opened by `prepare_draw` itself. */
export function DrawReview() {
  const { app, view, error, stale, reload } = useToolPage<View>("humbugg draw review", "prepare_draw", isDrawReview);
  if (!view) {
    return (
      <div>
        <PageHeader eyebrow="Draw names" title="Review" app={app} />
        {error ? <ErrorBox>{error}</ErrorBox> : <Loading label="Checking the group" />}
      </div>
    );
  }
  return <DrawReviewView app={app} view={view} stale={stale} onReload={reload} />;
}

/**
 * On the standalone page a finished draw is told to the conversation as a context note —
 * fixed wording and the group id only, never the name, which is organizer-written text. No
 * chat message: the desktop app only prefills one, and a name inside it would reach the
 * conversation as the person's own words.
 */
async function tellChatDrawn(app: App, view: View, done: DrawDone): Promise<void> {
  await addContext(app, `Names were drawn for Humbugg group ${view.group.group_id} at ${done.drawn_at}, approved on the draw review page.`);
}

export function DrawReviewView({
  app,
  view,
  stale = false,
  onDrawn = tellChatDrawn,
  onReload,
}: {
  app: App | null;
  view: View;
  stale?: boolean;
  onReload?: () => Promise<void>;
  onDrawn?: (app: App, view: View, done: DrawDone) => Promise<void>;
}) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [drawError, setDrawError] = useState<string | null>(null);
  const [done, setDone] = useState<DrawDone | null>(null);

  const { group } = view;
  const drawn = done !== null || group.status === "drawn";
  const drawnAt = done?.drawn_at ?? view.drawn_at;
  const inDraw = view.participants.filter((p) => p.is_participating);
  const out = view.participants.filter((p) => !p.is_participating);
  const ready = inDraw.filter((p) => p.ready).length;
  const limit = formatLimit(group.spending_limit, group.currency);

  const draw = async () => {
    if (!app || phase === "drawing") return;
    setPhase("drawing");
    setDrawError(null);
    try {
      const r = await callTool<DrawDone>(app, "draw", { group_id: group.group_id });
      setDone(r);
      setPhase("idle");
      await onDrawn(app, view, r);
    } catch (e) {
      setDrawError((e as Error).message);
      setPhase("idle");
    }
  };

  return (
    <div className="flex flex-col gap-3">
      <PageHeader eyebrow="Draw names" title={group.name} app={app} appUrl={appLink(group.group_id, "draw")} onReload={onReload}>
        <p className="m-0 mt-1 flex flex-wrap gap-x-3 gap-y-1 text-sm text-muted">
          {group.event_date && <span>Exchange {formatDate(group.event_date)}</span>}
          {limit && <span>Limit {limit}</span>}
          <span>{group.plan} plan</span>
        </p>
      </PageHeader>

      {stale && <StaleNote />}

      {drawn ? (
        <Alert.Root intent="success" data-testid="drawn">
          <Alert.Title>Names are drawn</Alert.Title>
          <Alert.Description>
            {drawnAt ? `Drawn ${formatDateTime(drawnAt)}. ` : ""}Everyone can now see who they're giving to in Humbugg.
          </Alert.Description>
        </Alert.Root>
      ) : (
        view.warnings.length > 0 && (
          <Alert.Root intent="warning">
            <Alert.Title>Before you draw</Alert.Title>
            <Alert.Description>
              <ul className="m-0 list-disc pl-5" data-testid="warnings">
                {view.warnings.map((w, i) => (
                  <li key={i}>{w}</li>
                ))}
              </ul>
            </Alert.Description>
          </Alert.Root>
        )
      )}

      <Card.Root>
        <div className="flex items-baseline justify-between gap-2">
          <h2 className="m-0 font-heading text-base font-semibold">In the draw</h2>
          <span className="text-sm text-muted">
            {ready} of {inDraw.length} ready
          </span>
        </div>
        <ul className="m-0 flex list-none flex-col divide-y divide-line p-0" data-testid="participants">
          {inDraw.map((p) => (
            <li key={p.member_id} className="flex flex-wrap items-start gap-x-2 gap-y-1 py-2">
              <div className="min-w-0 flex-1">
                <span className="font-semibold">{p.display_name}</span>
                {p.role !== "participant" && <span className="ml-2 text-xs text-muted">{ROLE_LABELS[p.role]}</span>}
                {!p.ready && p.nudges.length > 0 && (
                  <ul className="m-0 mt-0.5 list-none p-0 text-sm text-muted">
                    {p.nudges.map((n, i) => (
                      <li key={i}>{n}</li>
                    ))}
                  </ul>
                )}
              </div>
              <Badge intent={p.ready ? "success" : "warning"} size="sm">
                {p.ready ? "Ready" : "Not ready"}
              </Badge>
            </li>
          ))}
        </ul>
        {out.length > 0 && (
          <p className="m-0 text-sm text-muted">Sitting out: {out.map((p) => p.display_name).join(", ")}</p>
        )}
      </Card.Root>

      {view.exclusions.length > 0 && (
        <Card.Root>
          <h2 className="m-0 font-heading text-base font-semibold">Won't be paired</h2>
          <ul className="m-0 flex list-none flex-col gap-1 p-0 text-sm" data-testid="exclusions">
            {view.exclusions.map((x, i) => (
              <li key={i}>
                {x.a.display_name} <span className="text-muted">and</span> {x.b.display_name}
              </li>
            ))}
          </ul>
        </Card.Root>
      )}

      {drawError && <ErrorBox onDismiss={() => setDrawError(null)}>{drawError}</ErrorBox>}

      {!drawn && (
        <div className="flex flex-col gap-2 border-t border-line pt-3">
          {phase === "idle" ? (
            <div className="flex flex-wrap items-center gap-2">
              <Button intent="primary" disabled={!view.can_draw} onClick={() => setPhase("confirming")}>
                Draw names
              </Button>
              {!view.can_draw && <span className="text-sm text-muted">Not ready to draw yet.</span>}
            </div>
          ) : (
            <div className="flex flex-col gap-2 rounded-md bg-surface-alt p-3" data-testid="confirm">
              <p className="m-0 text-sm">
                Draw names for <strong>{group.name}</strong> among {inDraw.length} people? This can't be undone from here.
              </p>
              <div className="flex flex-wrap gap-2">
                <Button intent="primary" onClick={() => void draw()} disabled={phase === "drawing"}>
                  {phase === "drawing" ? "Drawing…" : "Yes, draw names"}
                </Button>
                <Button intent="ghost" onClick={() => setPhase("idle")} disabled={phase === "drawing"}>
                  Cancel
                </Button>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
