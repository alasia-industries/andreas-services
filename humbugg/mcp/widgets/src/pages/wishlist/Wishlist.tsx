/**
 * The wishlist editor (`edit_wishlist`): the person's own wishes for one
 * group — add, edit inline, delete (after a confirm), move up and down.
 *
 * Every write (`add_wish`, `update_wish`, `delete_wish`, `reorder_wishes`) is
 * followed by `edit_wishlist` again, and the page redraws from that: the server
 * decides positions and ids, never the page.
 */

import { useState } from "react";
import { Badge, Button, Field, IconButton, Input, Textarea, Toggle, ToggleGroup } from "@ansavva/design-system";
import type { App } from "@modelcontextprotocol/ext-apps";

import { callWrite, useToolPage } from "../../shared/host";
import {
  addArgs,
  appLink,
  byPosition,
  draftOf,
  emptyDraft,
  formatMoney,
  hostOf,
  KIND_LABELS,
  moveWish,
  PRIORITY_LABELS,
  readDraft,
  safeLinkUrl,
  updateArgs,
  type WishDraft,
  type WishFields,
} from "../../shared/logic";
import { ErrorBox, Loading, PageHeader, StaleNote, WishImage } from "../../shared/Page";
import type { OwnWish, Priority, WishKind, Wishlist as View } from "../../shared/types";

export const isWishlist = (v: object) => "group" in v && "wishes" in v;

type Editing = { wishId: string } | { adding: true } | null;

/** The standalone page, opened by `edit_wishlist` itself. */
export function WishlistEditor() {
  const { app, view, error, stale, reload } = useToolPage<View>("humbugg wishlist", "edit_wishlist", isWishlist);
  if (!view) {
    return (
      <div>
        <PageHeader eyebrow="Your wishlist" title="Wishlist" app={app} />
        {error ? <ErrorBox>{error}</ErrorBox> : <Loading label="Loading your wishes" />}
      </div>
    );
  }
  return <WishlistView app={app} view={view} reload={reload} stale={stale} />;
}

/** `reload` calls `edit_wishlist` again and redraws; every write is followed by it. */
export function WishlistView({
  app,
  view,
  reload,
  stale = false,
}: {
  app: App | null;
  view: View;
  reload: () => Promise<void>;
  stale?: boolean;
}) {
  const [editing, setEditing] = useState<Editing>(null);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [writeError, setWriteError] = useState<string | null>(null);

  const groupId = view.group.group_id;
  const wishes = byPosition(view.wishes);
  const currency = wishes.find((w) => w.currency)?.currency ?? "USD";

  /** One write, then the list as the server now has it. */
  const write = async (tool: string, args: Record<string, unknown>): Promise<boolean> => {
    if (!app || busy) return false;
    setBusy(true);
    setWriteError(null);
    try {
      await callWrite(app, tool, args);
      await reload();
      return true;
    } catch (e) {
      setWriteError((e as Error).message);
      return false;
    } finally {
      setBusy(false);
    }
  };

  const move = (wishId: string, by: -1 | 1) => {
    const ids = moveWish(wishes.map((w) => w.wish_id), wishId, by);
    if (ids) void write("reorder_wishes", { group_id: groupId, wish_ids: ids });
  };

  return (
    <div className="flex flex-col gap-3">
      <PageHeader eyebrow="Your wishlist" title={view.group.name} app={app} appUrl={appLink(groupId, "you")} onReload={reload}>
        <p className="m-0 mt-1 text-sm text-muted">
          {wishes.length === 0 ? "No wishes yet." : `${wishes.length} ${wishes.length === 1 ? "wish" : "wishes"}, most wanted first.`}
        </p>
      </PageHeader>

      {stale && <StaleNote />}
      {writeError && <ErrorBox onDismiss={() => setWriteError(null)}>{writeError}</ErrorBox>}

      {wishes.length > 0 && (
        <ol className="m-0 flex list-none flex-col gap-2 p-0" data-testid="wishes">
          {wishes.map((w, i) =>
            editing && "wishId" in editing && editing.wishId === w.wish_id ? (
              <li key={w.wish_id} className="rounded-lg border border-line bg-card p-3">
                <WishForm
                  initial={draftOf(w, currency)}
                  submitLabel="Save"
                  busy={busy}
                  onCancel={() => setEditing(null)}
                  onSubmit={async (fields) => {
                    const { args, priceNotCleared } = updateArgs(groupId, w, fields);
                    if (priceNotCleared) return "A price can't be removed here — change it, or remove it in Humbugg.";
                    if (!args) return setEditing(null);
                    if (await write("update_wish", args)) setEditing(null);
                  }}
                />
              </li>
            ) : (
              <WishRow
                key={w.wish_id}
                wish={w}
                app={app}
                first={i === 0}
                last={i === wishes.length - 1}
                busy={busy}
                confirming={confirmDelete === w.wish_id}
                onUp={() => move(w.wish_id, -1)}
                onDown={() => move(w.wish_id, 1)}
                onEdit={() => {
                  setConfirmDelete(null);
                  setEditing({ wishId: w.wish_id });
                }}
                onDelete={() => setConfirmDelete(w.wish_id)}
                onCancelDelete={() => setConfirmDelete(null)}
                onConfirmDelete={async () => {
                  if (await write("delete_wish", { group_id: groupId, wish_id: w.wish_id })) setConfirmDelete(null);
                }}
              />
            ),
          )}
        </ol>
      )}

      {editing && "adding" in editing ? (
        <div className="rounded-lg border border-line bg-card p-3">
          <h2 className="m-0 mb-2 font-heading text-base font-semibold">Add a wish</h2>
          <WishForm
            initial={emptyDraft(currency)}
            submitLabel="Add wish"
            busy={busy}
            onCancel={() => setEditing(null)}
            onSubmit={async (fields) => {
              if (await write("add_wish", addArgs(groupId, fields))) setEditing(null);
            }}
          />
        </div>
      ) : (
        <div>
          <Button intent="primary" onClick={() => setEditing({ adding: true })} disabled={busy}>
            Add a wish
          </Button>
        </div>
      )}
    </div>
  );
}

function WishRow(props: {
  wish: OwnWish;
  app: App | null;
  first: boolean;
  last: boolean;
  busy: boolean;
  confirming: boolean;
  onUp: () => void;
  onDown: () => void;
  onEdit: () => void;
  onDelete: () => void;
  onCancelDelete: () => void;
  onConfirmDelete: () => Promise<void>;
}) {
  const { wish, busy } = props;
  const price = formatMoney(wish.price_cents, wish.currency);
  const link = safeLinkUrl(wish.url);
  return (
    <li className="flex flex-col gap-2 rounded-lg border border-line bg-card p-3" data-testid="wish" data-wish-id={wish.wish_id}>
      <div className="flex gap-3">
        <WishImage className="size-12" />
        <div className="flex min-w-0 flex-1 flex-col gap-0.5">
          <div className="flex flex-wrap items-start gap-2">
            <h3 className="m-0 min-w-0 flex-1 text-base font-semibold" data-testid="wish-title">{wish.title}</h3>
            {wish.priority !== "normal" && (
              <Badge intent={wish.priority === "high" ? "primary" : "neutral"} size="sm">
                {wish.priority === "high" ? "Top wish" : "Nice to have"}
              </Badge>
            )}
          </div>
          <p className="m-0 flex flex-wrap gap-x-2 text-sm text-muted">
            <span>{KIND_LABELS[wish.kind]}</span>
            {price && <span>{price}</span>}
            {wish.quantity > 1 && <span>× {wish.quantity}</span>}
            {link && <span>{hostOf(link)}</span>}
          </p>
          {wish.details && <p className="m-0 whitespace-pre-wrap text-sm">{wish.details}</p>}
        </div>
        <div className="flex shrink-0 flex-col gap-1">
          <IconButton size="sm" intent="ghost" label={`Move ${wish.title} up`} disabled={props.first || busy} onClick={props.onUp}>
            <Chevron up />
          </IconButton>
          <IconButton size="sm" intent="ghost" label={`Move ${wish.title} down`} disabled={props.last || busy} onClick={props.onDown}>
            <Chevron />
          </IconButton>
        </div>
      </div>
      {props.confirming ? (
        <div className="flex flex-wrap items-center gap-2 rounded-md bg-surface-alt p-2" data-testid="confirm-delete">
          <span className="text-sm">Delete this wish?</span>
          <Button size="sm" intent="danger" disabled={busy} onClick={() => void props.onConfirmDelete()}>
            Yes, delete
          </Button>
          <Button size="sm" intent="ghost" disabled={busy} onClick={props.onCancelDelete}>
            Keep it
          </Button>
        </div>
      ) : (
        <div className="flex flex-wrap gap-2">
          <Button size="sm" intent="secondary" disabled={busy} onClick={props.onEdit}>
            Edit
          </Button>
          <Button size="sm" intent="ghost" disabled={busy} onClick={props.onDelete}>
            Delete
          </Button>
        </div>
      )}
    </li>
  );
}

function WishForm({
  initial,
  submitLabel,
  busy,
  onSubmit,
  onCancel,
}: {
  initial: WishDraft;
  submitLabel: string;
  busy: boolean;
  /** A string back is a problem to show on the form. */
  onSubmit: (fields: WishFields) => Promise<string | void> | string | void;
  onCancel: () => void;
}) {
  const [d, setD] = useState<WishDraft>(initial);
  const [problem, setProblem] = useState<string | null>(null);
  const set = <K extends keyof WishDraft>(k: K) => (v: WishDraft[K]) => setD((prev) => ({ ...prev, [k]: v }));

  // No <form> submit: a host's sandbox without `allow-forms` drops the submit
  // event, so the button's click (and Enter in a one-line field) does it.
  const submit = () => {
    const r = readDraft(d);
    if (!r.ok) return setProblem(r.error);
    setProblem(null);
    void Promise.resolve(onSubmit(r.fields)).then((p) => p && setProblem(p));
  };

  return (
    <div
      className="flex flex-col gap-3"
      onKeyDown={(e) => {
        if (e.key === "Enter" && e.target instanceof HTMLInputElement) {
          e.preventDefault();
          submit();
        }
      }}
    >
      <Field.Root name="title" invalid={problem !== null && !d.title.trim()}>
        <Field.Label>Title</Field.Label>
        <Input value={d.title} onValueChange={set("title")} placeholder="What would you like?" />
      </Field.Root>

      <div className="flex flex-col gap-1">
        <span className="text-sm font-medium">Kind</span>
        <ToggleGroup.Root size="sm" value={[d.kind]} onValueChange={(v) => v[0] && set("kind")(v[0] as WishKind)} className="flex-wrap">
          {(Object.keys(KIND_LABELS) as WishKind[]).map((k) => (
            <Toggle key={k} value={k}>
              {KIND_LABELS[k]}
            </Toggle>
          ))}
        </ToggleGroup.Root>
      </div>

      <Field.Root name="url">
        <Field.Label>Link</Field.Label>
        <Input type="url" value={d.url} onValueChange={set("url")} placeholder="https://" />
      </Field.Root>

      <div className="flex flex-wrap gap-3">
        <Field.Root name="price" className="min-w-0 flex-1 basis-28">
          <Field.Label>Price</Field.Label>
          <Input value={d.price} onValueChange={set("price")} placeholder="25.00" inputMode="decimal" />
        </Field.Root>
        <Field.Root name="currency" className="w-24">
          <Field.Label>Currency</Field.Label>
          <Input value={d.currency} onValueChange={set("currency")} maxLength={3} />
        </Field.Root>
        <Field.Root name="quantity" className="w-24">
          <Field.Label>Quantity</Field.Label>
          <Input value={d.quantity} onValueChange={set("quantity")} inputMode="numeric" />
        </Field.Root>
      </div>

      <div className="flex flex-col gap-1">
        <span className="text-sm font-medium">Priority</span>
        <ToggleGroup.Root size="sm" value={[d.priority]} onValueChange={(v) => v[0] && set("priority")(v[0] as Priority)}>
          {(Object.keys(PRIORITY_LABELS) as Priority[]).map((p) => (
            <Toggle key={p} value={p}>
              {PRIORITY_LABELS[p]}
            </Toggle>
          ))}
        </ToggleGroup.Root>
      </div>

      <Field.Root name="details">
        <Field.Label>Details</Field.Label>
        <Textarea value={d.details} onValueChange={set("details")} rows={2} placeholder="Size, colour, anything that helps" />
      </Field.Root>

      {problem && (
        <p className="m-0 text-sm text-danger" role="alert">
          {problem}
        </p>
      )}

      <div className="flex flex-wrap gap-2">
        <Button intent="primary" disabled={busy} onClick={submit}>
          {busy ? "Saving…" : submitLabel}
        </Button>
        <Button type="button" intent="ghost" onClick={onCancel} disabled={busy}>
          Cancel
        </Button>
      </div>
    </div>
  );
}

function Chevron({ up = false }: { up?: boolean }) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" strokeLinecap="round" strokeLinejoin="round" className="size-4 fill-none stroke-current stroke-2">
      <path d={up ? "M6 15l6-6 6 6" : "M6 9l6 6 6-6"} />
    </svg>
  );
}
