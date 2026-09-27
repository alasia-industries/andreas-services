/**
 * The pages' pure logic, kept out of the components so vitest can reach it:
 * which claim buttons a wish offers, money in and out of cents, which URLs a
 * page may use, the Humbugg app's deep links, and what changed in a wish edit.
 */

import type { ClaimState, OwnWish, Priority, RecipientWish, WishKind } from "./types";

/** The product app in production — the default, and the only non-local origin a page accepts. */
export const APP_ORIGIN = "https://app.humbugg.com";

let appOrigin = APP_ORIGIN;

/**
 * Whether a server-sent `app_url` may become the origin the pages link to: production, or
 * a loopback app (the dev server sends http://localhost:8081). Anything else is ignored,
 * so a tampered view cannot aim the logo somewhere else.
 */
export function acceptableAppOrigin(url: unknown): url is string {
  if (typeof url !== "string") return false;
  if (url === APP_ORIGIN) return true;
  return /^http:\/\/(localhost|127\.0\.0\.1|\[::1\]):\d{2,5}$/.test(url);
}

/** Take the app origin from a view's `app_url` (the server's HUMBUGG_APP_URL), when acceptable. */
export function adoptAppOrigin(view: unknown): void {
  const url = (view as { app_url?: unknown } | null)?.app_url;
  if (acceptableAppOrigin(url)) appOrigin = url;
}

export function currentAppOrigin(): string {
  return appOrigin;
}

/** A group's screen in the app — routes from `humbugg/app/src/app/(protected)/groups/[groupId]/`. */
export function appLink(groupId: string | null, screen: "draw" | "giving" | "you" | null = null): string {
  if (!groupId) return `${appOrigin}/`;
  const base = `${appOrigin}/groups/${encodeURIComponent(groupId)}`;
  return screen ? `${base}/${screen}` : base;
}

export type ClaimAction =
  | { label: "Planning to buy"; tool: "claim_wish"; state: "planned" }
  | { label: "Bought"; tool: "claim_wish"; state: "purchased" }
  | { label: "Release"; tool: "release_claim" };

const PLAN = { label: "Planning to buy", tool: "claim_wish", state: "planned" } as const;
const BUY = { label: "Bought", tool: "claim_wish", state: "purchased" } as const;
const RELEASE = { label: "Release", tool: "release_claim" } as const;

/**
 * The buttons a wish offers, from its claim: none yet → plan or buy; planned →
 * bought, or let it go; bought → only let it go.
 */
export function claimActions(claim: RecipientWish["claim"]): ClaimAction[] {
  if (!claim) return [PLAN, BUY];
  if (claim.state === "planned") return [BUY, RELEASE];
  return [RELEASE];
}

export function claimLabel(state: ClaimState): string {
  return state === "planned" ? "You're planning to buy this" : "You bought this";
}

/** The arguments a claim button sends. */
export function claimArgs(groupId: string, wishId: string, action: ClaimAction): Record<string, unknown> {
  return action.tool === "claim_wish"
    ? { group_id: groupId, wish_id: wishId, state: action.state }
    : { group_id: groupId, wish_id: wishId };
}

/** `1250, "USD"` → `$12.50`; a bad currency code falls back to `12.50 XYZ`. */
export function formatMoney(cents: number | null, currency: string | null): string | null {
  if (cents === null || cents === undefined || !Number.isFinite(cents)) return null;
  const amount = cents / 100;
  if (!currency) return amount.toFixed(2);
  try {
    return new Intl.NumberFormat(undefined, { style: "currency", currency }).format(amount);
  } catch {
    return `${amount.toFixed(2)} ${currency}`;
  }
}

/** A whole-unit spending limit, e.g. `50, "EUR"` → `€50`. */
export function formatLimit(limit: number | null, currency: string): string | null {
  if (limit === null || limit === undefined) return null;
  try {
    return new Intl.NumberFormat(undefined, { style: "currency", currency, maximumFractionDigits: 2 }).format(limit);
  } catch {
    return `${limit} ${currency}`;
  }
}

/**
 * What a person typed into a price box, in cents. `""` is no price (null);
 * anything that is not a non-negative amount with at most two decimals is
 * `undefined` — invalid, and the form says so.
 */
export function parsePrice(text: string): number | null | undefined {
  const t = text.trim().replace(/^[$€£]\s*/, "").replace(/,/g, "");
  if (!t) return null;
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return undefined;
  const [whole, frac = ""] = t.split(".");
  return Number(whole) * 100 + Number(frac.padEnd(2, "0"));
}

export function centsToInput(cents: number | null): string {
  return cents === null || cents === undefined ? "" : (cents / 100).toFixed(2);
}

/** A link a wish carries: http(s) only — never `javascript:`, `data:` or a relative path. */
export function safeLinkUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  try {
    const u = new URL(url);
    return u.protocol === "https:" || u.protocol === "http:" ? u.href : null;
  } catch {
    return null;
  }
}

/** `https://www.example.com/x` → `example.com`, to show where a link goes. */
export function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return url;
  }
}

/** The editable fields of a wish, as a form holds them. */
export type WishDraft = {
  title: string;
  kind: WishKind;
  url: string;
  price: string;
  currency: string;
  quantity: string;
  priority: Priority;
  details: string;
};

export function emptyDraft(currency: string): WishDraft {
  return { title: "", kind: "product", url: "", price: "", currency, quantity: "1", priority: "normal", details: "" };
}

export function draftOf(w: OwnWish, fallbackCurrency: string): WishDraft {
  return {
    title: w.title,
    kind: w.kind,
    url: w.url ?? "",
    price: centsToInput(w.price_cents),
    currency: w.currency ?? fallbackCurrency,
    quantity: String(w.quantity),
    priority: w.priority,
    details: w.details ?? "",
  };
}

export type WishFields = {
  title: string;
  kind: WishKind;
  url: string | null;
  price_cents: number | null;
  currency: string | null;
  quantity: number;
  priority: Priority;
  details: string | null;
};

/** A draft checked and converted, or the first thing wrong with it. */
export function readDraft(d: WishDraft): { ok: true; fields: WishFields } | { ok: false; error: string } {
  const title = d.title.trim();
  if (!title) return { ok: false, error: "Give the wish a title." };
  const price = parsePrice(d.price);
  if (price === undefined) return { ok: false, error: "The price should be an amount, like 25 or 12.50." };
  const url = d.url.trim();
  if (url && !safeLinkUrl(url)) return { ok: false, error: "The link should start with https://." };
  const quantity = d.quantity.trim() ? Number(d.quantity) : 1;
  if (!Number.isInteger(quantity) || quantity < 1) return { ok: false, error: "The quantity should be a whole number, 1 or more." };
  const currency = d.currency.trim().toUpperCase();
  return {
    ok: true,
    fields: {
      title,
      kind: d.kind,
      url: url || null,
      price_cents: price,
      currency: price === null ? null : currency || null,
      quantity,
      priority: d.priority,
      details: d.details.trim() || null,
    },
  };
}

/** `add_wish` arguments: the title, plus only the optional fields that say something. */
export function addArgs(groupId: string, f: WishFields): Record<string, unknown> {
  const args: Record<string, unknown> = { group_id: groupId, title: f.title, kind: f.kind, priority: f.priority, quantity: f.quantity };
  if (f.url) args.url = f.url;
  if (f.price_cents !== null) {
    args.price_cents = f.price_cents;
    if (f.currency) args.currency = f.currency;
  }
  if (f.details) args.details = f.details;
  return args;
}

/**
 * `update_wish` arguments: only the fields that changed. `null`/absent means
 * "unchanged" to the server, so a cleared text field (link, details) is sent as
 * `""`. A price cannot be cleared through `update_wish` — `price_cents: null`
 * would mean "unchanged" — so a removed price is reported back, not sent.
 * Returns `null` when nothing changed, so no call is made.
 */
export function updateArgs(
  groupId: string,
  before: OwnWish,
  f: WishFields,
): { args: Record<string, unknown> | null; priceNotCleared: boolean } {
  const changed: Record<string, unknown> = {};
  if (f.title !== before.title) changed.title = f.title;
  if (f.kind !== before.kind) changed.kind = f.kind;
  if (f.quantity !== before.quantity) changed.quantity = f.quantity;
  if (f.priority !== before.priority) changed.priority = f.priority;
  if (f.url !== (before.url ?? null)) changed.url = f.url ?? "";
  if (f.details !== (before.details ?? null)) changed.details = f.details ?? "";
  let priceNotCleared = false;
  if (f.price_cents === null) {
    priceNotCleared = before.price_cents !== null && before.price_cents !== undefined;
  } else if (f.price_cents !== before.price_cents || f.currency !== (before.currency ?? null)) {
    // A price is only meaningful with its currency: send them as a pair.
    changed.price_cents = f.price_cents;
    if (f.currency) changed.currency = f.currency;
  }
  const args = Object.keys(changed).length ? { group_id: groupId, wish_id: before.wish_id, ...changed } : null;
  return { args, priceNotCleared };
}

/** The wish ids in position order, with one moved up (-1) or down (+1). */
export function moveWish(ids: string[], wishId: string, by: -1 | 1): string[] | null {
  const i = ids.indexOf(wishId);
  const j = i + by;
  if (i < 0 || j < 0 || j >= ids.length) return null;
  const next = [...ids];
  [next[i], next[j]] = [next[j]!, next[i]!];
  return next;
}

export function byPosition<T extends { position: number }>(wishes: T[]): T[] {
  return [...wishes].sort((a, b) => a.position - b.position);
}

export const KIND_LABELS: Record<WishKind, string> = {
  product: "Product",
  custom: "Custom",
  experience: "Experience",
  charity: "Charity",
};

export const PRIORITY_LABELS: Record<Priority, string> = { low: "Low", normal: "Normal", high: "High" };

export const ROLE_LABELS = { owner: "Organizer", co_organizer: "Co-organizer", participant: "Participant" } as const;

/** `2026-12-18` → `Dec 18, 2026` (in the reader's locale); anything unreadable as given. */
export function formatDate(iso: string): string {
  const d = new Date(/^\d{4}-\d{2}-\d{2}$/.test(iso) ? `${iso}T12:00:00` : iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
}

export function formatDateTime(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

/** A paid plan gets a badge; the free one does not. */
export function isPlus(plan: string | null | undefined): boolean {
  return (plan ?? "").trim().toLowerCase() === "plus";
}

/** The copy shortcut to suggest when the page may not write the clipboard. */
export function copyShortcut(platform: string): string {
  return /mac|iphone|ipad/i.test(platform) ? "Press ⌘C to copy" : "Press Ctrl+C to copy";
}
