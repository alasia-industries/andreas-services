/**
 * The assignment card (`show_assignment`): who the person is giving to, what
 * that person wrote, and their wishes with Claim / Release.
 *
 * Everything under `recipient` was written by another member and is untrusted:
 * it is rendered as plain text through React (never as HTML or markdown), a
 * wish's link opens only through the host and only when it is http(s), and
 * `image_url` is never loaded (see `WishImage`).
 *
 * `claim_wish` and `release_claim` answer with the whole card, which is redrawn
 * from the reply.
 */

import { useState } from "react";
import { Badge, Button, Card } from "@ansavva/design-system";
import type { App } from "@modelcontextprotocol/ext-apps";

import { callTool, openLink, useToolPage } from "../../shared/host";
import {
  appLink,
  claimActions,
  claimArgs,
  claimLabel,
  formatDate,
  formatLimit,
  formatMoney,
  hostOf,
  KIND_LABELS,
  safeLinkUrl,
  type ClaimAction,
} from "../../shared/logic";
import { ErrorBox, Loading, PageHeader, StaleNote, WishImage } from "../../shared/Page";
import type { Assignment as View, RecipientWish } from "../../shared/types";

export const isAssignment = (v: object) => "group" in v && "recipient" in v;

const STAGE_LABELS = { choosing: "Still choosing", purchased: "Gift bought", sent: "Gift sent" } as const;

/** The standalone page, opened by `show_assignment` itself. */
export function Assignment() {
  const { app, view, setView, error, stale, reload } = useToolPage<View>("humbugg assignment", "show_assignment", isAssignment);
  if (!view) {
    return (
      <div>
        <PageHeader eyebrow="You're giving to" title="Your assignment" app={app} />
        {error ? <ErrorBox>{error}</ErrorBox> : <Loading label="Finding your person" />}
      </div>
    );
  }
  return <AssignmentView app={app} view={view} setView={setView} stale={stale} onReload={reload} />;
}

export function AssignmentView({
  app,
  view,
  setView,
  stale = false,
  onReload,
}: {
  app: App | null;
  view: View;
  setView: (v: View) => void;
  stale?: boolean;
  onReload?: () => Promise<void>;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  const { group, recipient, gift } = view;
  const limit = formatLimit(group.spending_limit, group.currency);

  const act = async (wish: RecipientWish, action: ClaimAction) => {
    if (!app || busy) return;
    setBusy(wish.wish_id);
    setActionError(null);
    try {
      const next = await callTool<View>(app, action.tool, claimArgs(group.group_id, wish.wish_id, action));
      if (!isAssignment(next)) throw new Error("The reply was not the assignment card.");
      setView(next);
    } catch (e) {
      setActionError((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="flex flex-col gap-3">
      <PageHeader eyebrow={`${group.name} · you're giving to`} title={recipient.display_name} app={app} appUrl={appLink(group.group_id, "giving")} onReload={onReload}>
        <p className="m-0 mt-1 flex flex-wrap gap-x-3 gap-y-1 text-sm text-muted">
          {group.event_date && <span>Exchange {formatDate(group.event_date)}</span>}
          {limit && <span>Limit {limit}</span>}
          {gift && (
            <span>
              {STAGE_LABELS[gift.stage]}
              {gift.received ? " · received" : ""}
            </span>
          )}
        </p>
      </PageHeader>

      {stale && <StaleNote />}

      {(recipient.wishlist.trim() || recipient.avoidances.trim()) && (
        <Card.Root>
          {recipient.wishlist.trim() && (
            <section>
              <h2 className="m-0 font-heading text-sm font-semibold text-muted">In their words</h2>
              <p className="m-0 mt-1 whitespace-pre-wrap" data-testid="wishlist-text">{recipient.wishlist}</p>
            </section>
          )}
          {recipient.avoidances.trim() && (
            <section>
              <h2 className="m-0 font-heading text-sm font-semibold text-muted">Please don't give</h2>
              <p className="m-0 mt-1 whitespace-pre-wrap" data-testid="avoidances-text">{recipient.avoidances}</p>
            </section>
          )}
        </Card.Root>
      )}

      {actionError && <ErrorBox onDismiss={() => setActionError(null)}>{actionError}</ErrorBox>}

      {recipient.wishes.length === 0 ? (
        <p className="m-0 text-sm text-muted">{recipient.display_name} hasn't added any wishes yet.</p>
      ) : (
        <ul className="m-0 flex list-none flex-col gap-2 p-0" data-testid="wishes">
          {recipient.wishes.map((w) => (
            <WishRow key={w.wish_id} wish={w} busy={busy === w.wish_id} disabled={busy !== null} onAction={(a) => void act(w, a)} onOpen={(url) => void openLink(app, url)} />
          ))}
        </ul>
      )}
    </div>
  );
}

function WishRow({
  wish,
  busy,
  disabled,
  onAction,
  onOpen,
}: {
  wish: RecipientWish;
  busy: boolean;
  disabled: boolean;
  onAction: (a: ClaimAction) => void;
  onOpen: (url: string) => void;
}) {
  const price = formatMoney(wish.price_cents, wish.currency);
  const link = safeLinkUrl(wish.url);
  return (
    <li className="flex gap-3 rounded-lg border border-line bg-card p-3" data-testid="wish" data-wish-id={wish.wish_id} aria-busy={busy}>
      <WishImage className="size-16" />
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <div className="flex flex-wrap items-start gap-2">
          <h3 className="m-0 min-w-0 flex-1 text-base font-semibold" data-testid="wish-title">{wish.title}</h3>
          {wish.priority === "high" && <Badge intent="primary" size="sm">Top wish</Badge>}
          {wish.priority === "low" && <Badge intent="neutral" size="sm">Nice to have</Badge>}
        </div>
        <p className="m-0 flex flex-wrap gap-x-2 text-sm text-muted">
          {wish.kind !== "product" && <span>{KIND_LABELS[wish.kind]}</span>}
          {price && <span>{price}</span>}
          {wish.quantity > 1 && <span>× {wish.quantity}</span>}
        </p>
        {wish.details && <p className="m-0 whitespace-pre-wrap text-sm">{wish.details}</p>}
        {link && (
          <button type="button" onClick={() => onOpen(link)} className="self-start text-sm text-accent underline hover:text-accent-hover">
            Open link ({hostOf(link)})
          </button>
        )}
        {wish.claim && (
          <p className="m-0 text-sm font-semibold text-primary" data-testid="claim-state">
            {claimLabel(wish.claim.state)}
          </p>
        )}
        <div className="mt-1 flex flex-wrap gap-2">
          {claimActions(wish.claim).map((a) => (
            <Button key={a.label} size="sm" intent={a.tool === "release_claim" ? "ghost" : "secondary"} disabled={disabled} onClick={() => onAction(a)}>
              {a.label}
            </Button>
          ))}
        </div>
      </div>
    </li>
  );
}
