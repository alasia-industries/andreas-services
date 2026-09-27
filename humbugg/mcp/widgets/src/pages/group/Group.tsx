/**
 * One group (`show_group`): its date, budget, description and members, and —
 * for organizers, when the server sends them — who is ready and what is
 * missing, pending invitations, the pairs that won't be matched, gift progress
 * and the invite link to copy. The group's next steps are buttons that send
 * their `prompt` verbatim (see `StepButtons`).
 *
 * Names, the description and the instructions are other people's text: plain
 * text only.
 */

import { useRef, useState } from "react";
import { Badge, Button, Card, Input } from "@ansavva/design-system";

import type { App } from "@modelcontextprotocol/ext-apps";

import { appLink, copyShortcut, formatDate, formatDateTime, formatLimit, isPlus } from "../../shared/logic";
import { PageHeader, StaleNote, StepButtons } from "../../shared/Page";
import type { GroupDetail } from "../../shared/types";

export const isGroupDetail = (v: object) => "group" in v && "members" in v;

/** One group's view — the root of `group.html`, or pushed onto another page's stack. */
export function GroupView({
  app,
  view,
  stale = false,
  onReload,
}: {
  app: App | null;
  view: GroupDetail;
  stale?: boolean;
  onReload?: () => Promise<void>;
}) {
  const { group, members, readiness } = view;
  const limit = formatLimit(group.spending_limit, group.currency);
  const readyOf = new Map((readiness?.participants ?? []).map((p) => [p.member_id, p]));
  const inDraw = members.filter((m) => m.is_participating);
  const progress = readiness?.gift_progress ?? null;

  return (
    <div className="flex flex-col gap-3">
      <PageHeader
        eyebrow={group.is_organizer ? "You organize" : "You're in"}
        title={group.name}
        app={app}
        appUrl={appLink(group.group_id)}
        onReload={onReload}
      >
        <p className="m-0 mt-1 flex flex-wrap gap-x-3 gap-y-1 text-sm text-muted">
          <span className={group.status === "drawn" ? "font-semibold text-primary" : ""}>
            {group.status === "drawn" ? "Names drawn" : "Open"}
          </span>
          {group.event_date && <span>Exchange {formatDate(group.event_date)}</span>}
          {group.signup_deadline && <span>Join by {formatDate(group.signup_deadline)}</span>}
          {limit && <span>Budget {limit}</span>}
          {group.requires_address && <span>Shipping address needed</span>}
          {isPlus(group.plan) && (
            <Badge intent="primary" size="sm">
              Plus
            </Badge>
          )}
        </p>
      </PageHeader>

      {stale && <StaleNote />}

      <StepButtons app={app} steps={view.next} groupId={group.group_id} size="md" />

      {(group.description?.trim() || group.instructions?.trim()) && (
        <Card.Root>
          {group.description?.trim() && (
            <p className="m-0 whitespace-pre-wrap" data-testid="description">
              {group.description}
            </p>
          )}
          {group.instructions?.trim() && (
            <section>
              <h2 className="m-0 font-heading text-sm font-semibold text-muted">From the organizer</h2>
              <p className="m-0 mt-1 whitespace-pre-wrap" data-testid="instructions">
                {group.instructions}
              </p>
            </section>
          )}
        </Card.Root>
      )}

      {progress && (
        <Card.Root data-testid="gift-progress">
          <h2 className="m-0 font-heading text-base font-semibold">Gifts</h2>
          <p className="m-0 flex flex-wrap gap-x-4 gap-y-1 text-sm">
            <span>
              {progress.purchased} of {progress.total} bought
            </span>
            <span>{progress.sent} sent</span>
            <span>{progress.received} received</span>
          </p>
        </Card.Root>
      )}

      <Card.Root>
        <div className="flex items-baseline justify-between gap-2">
          <h2 className="m-0 font-heading text-base font-semibold">Members</h2>
          <span className="text-sm text-muted">
            {readiness
              ? `${inDraw.filter((m) => readyOf.get(m.member_id)?.ready).length} of ${inDraw.length} ready`
              : `${inDraw.length} in the draw`}
          </span>
        </div>
        <ul className="m-0 flex list-none flex-col divide-y divide-line p-0" data-testid="members">
          {members.map((m) => {
            const r = readyOf.get(m.member_id);
            return (
              <li key={m.member_id} className="flex flex-wrap items-start gap-x-2 gap-y-1 py-2">
                <div className="min-w-0 flex-1">
                  <span className="font-semibold">{m.display_name}</span>
                  {(m.is_owner || m.is_organizer) && (
                    <span className="ml-2 text-xs text-muted">{m.is_owner ? "Organizer" : "Co-organizer"}</span>
                  )}
                  {!m.is_participating && <span className="ml-2 text-xs text-muted">Sitting out</span>}
                  {r && !r.ready && r.nudges.length > 0 && (
                    <ul className="m-0 mt-0.5 list-none p-0 text-sm text-muted">
                      {r.nudges.map((n, i) => (
                        <li key={i}>{n}</li>
                      ))}
                    </ul>
                  )}
                </div>
                {r && m.is_participating && (
                  <Badge intent={r.ready ? "success" : "warning"} size="sm" data-testid="readiness">
                    {r.ready ? "Ready" : "Not ready"}
                  </Badge>
                )}
              </li>
            );
          })}
        </ul>
      </Card.Root>

      {readiness && readiness.pending_invitations.length > 0 && (
        <Card.Root data-testid="invitations">
          <h2 className="m-0 font-heading text-base font-semibold">Invited, not joined yet</h2>
          <ul className="m-0 flex list-none flex-col gap-1 p-0 text-sm">
            {readiness.pending_invitations.map((i) => (
              <li key={i.invitation_id} className="flex flex-wrap gap-x-2">
                <span className="min-w-0 break-all">{i.email}</span>
                <span className="text-muted">{i.status}</span>
              </li>
            ))}
          </ul>
        </Card.Root>
      )}

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

      {group.invite_url && <InviteLink url={group.invite_url} />}

      {readiness?.drawn_at && <p className="m-0 text-sm text-muted">Names drawn {formatDateTime(readiness.drawn_at)}.</p>}
    </div>
  );
}

/**
 * The invite link with Copy. A host's sandbox may refuse the clipboard (no
 * `clipboard-write` in its permissions policy); then the text is selected and
 * the page says which keys copy it.
 */
function InviteLink({ url }: { url: string }) {
  const input = useRef<HTMLInputElement>(null);
  const [note, setNote] = useState<string | null>(null);
  const copy = async () => {
    try {
      if (!navigator.clipboard) throw new Error("no clipboard");
      await navigator.clipboard.writeText(url);
      setNote("Copied");
    } catch {
      input.current?.focus();
      input.current?.select();
      setNote(copyShortcut(navigator.platform || navigator.userAgent));
    }
  };
  return (
    <Card.Root data-testid="invite">
      <h2 className="m-0 font-heading text-base font-semibold">Invite link</h2>
      <div className="flex gap-2">
        <Input
          ref={input}
          value={url}
          readOnly
          aria-label="Invite link"
          className="min-w-0 flex-1"
          onFocus={(e) => e.currentTarget.select()}
        />
        <Button intent="secondary" onClick={() => void copy()}>
          Copy
        </Button>
      </div>
      {note && (
        <p className="m-0 text-sm text-muted" role="status" data-testid="copy-note">
          {note}
        </p>
      )}
    </Card.Root>
  );
}
