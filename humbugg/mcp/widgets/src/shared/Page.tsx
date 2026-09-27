/**
 * What every page shares: the header (eyebrow, title, a link into the app),
 * the loading and error states, a wish's picture placeholder, and how a
 * page mounts. Composed from the design system; no local component library.
 */

import { useState, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { Alert, Button, IconButton, Spinner } from "@ansavva/design-system";
import type { App } from "@modelcontextprotocol/ext-apps";

import { isAppLink, openLink, sendMessage } from "./host";
import { appLink } from "./logic";
import { MARK_H_PATH, MARK_H_TRANSFORM } from "./mark";
import { useNavigate } from "./nav-context";
import type { NextStep } from "./types";

/** Mount a page. No StrictMode: its double effect would open two host connections. */
export function mount(page: ReactNode): void {
  const root = document.getElementById("root");
  if (!root) throw new Error("#root is missing");
  createRoot(root).render(page);
}

/**
 * The top of every page and every view: the title (with an optional eyebrow
 * that says something the title does not, and whatever goes under it) on the
 * left; on the right a Refresh that calls the current view's tool again, and
 * Humbugg's mark, which opens this same screen in the Humbugg app.
 */
export function PageHeader({
  eyebrow,
  title,
  app,
  appUrl = appLink(null),
  onReload,
  children,
}: {
  eyebrow?: string;
  title: string;
  app: App | null;
  /** This screen in the Humbugg app; anything off its origin falls back to the app's root. */
  appUrl?: string;
  /** Call the current view's tool again and redraw. */
  onReload?: () => Promise<void>;
  children?: ReactNode;
}) {
  const [reloading, setReloading] = useState(false);
  const url = isAppLink(appUrl) ? appUrl : appLink(null);
  const reload = async () => {
    if (!onReload || reloading) return;
    setReloading(true);
    try {
      await onReload();
    } catch (e) {
      console.warn("refresh failed", e);
    } finally {
      setReloading(false);
    }
  };
  return (
    <header className="mb-3 flex items-start gap-3">
      <div className="min-w-0 flex-1">
        {eyebrow && <p className="m-0 mb-0.5 text-xs font-bold uppercase tracking-[0.18em] text-muted">{eyebrow}</p>}
        <h1 className="m-0 font-heading text-xl font-semibold text-ink">{title}</h1>
        {children}
      </div>
      <span className="flex shrink-0 items-center gap-1.5">
        {onReload && (
          <IconButton label="Refresh" size="sm" intent="ghost" onClick={() => void reload()} disabled={reloading} aria-busy={reloading}>
            <RefreshIcon spinning={reloading} />
          </IconButton>
        )}
        <button
          type="button"
          onClick={() => void openLink(app, url)}
          title="Open in Humbugg"
          aria-label="Open in Humbugg"
          data-testid="humbugg-mark"
          data-href={url}
          className="rounded-md hover:opacity-90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <HumbuggMark />
        </button>
      </span>
    </header>
  );
}

/**
 * The mark in the theme's own roles: the square is `primary`, the "H" is
 * `primary-text` — forest green and cream in light, mint and deep green in
 * dark, so it reads on either background without a second asset.
 */
export function HumbuggMark({ className = "size-8" }: { className?: string }) {
  return (
    <svg viewBox="0 0 100 100" aria-hidden="true" className={`block shrink-0 ${className}`}>
      <rect width="100" height="100" rx="20" className="fill-primary" />
      <path d={MARK_H_PATH} transform={MARK_H_TRANSFORM} className="fill-primary-text" />
    </svg>
  );
}

function RefreshIcon({ spinning }: { spinning: boolean }) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" strokeLinecap="round" strokeLinejoin="round"
      className={`size-4 fill-none stroke-current stroke-[1.5] ${spinning ? "animate-spin motion-reduce:animate-none" : ""}`}>
      <path d="M20 11a8 8 0 1 0-2.3 5.7" />
      <path d="M20 4v7h-7" />
    </svg>
  );
}

export function Loading({ label }: { label: string }) {
  return (
    <div className="flex items-center justify-center gap-2 py-8 text-muted">
      <Spinner size="md" label={label} />
      <span className="text-sm">{label}…</span>
    </div>
  );
}

export function ErrorBox({ children, onDismiss }: { children: ReactNode; onDismiss?: () => void }) {
  return (
    <Alert.Root intent="danger" onDismiss={onDismiss} role="alert">
      <Alert.Description className="whitespace-pre-wrap">{children}</Alert.Description>
      {onDismiss && <Alert.Close />}
    </Alert.Root>
  );
}

export function StaleNote() {
  return (
    <Alert.Root intent="warning" className="mb-3">
      <Alert.Description>Couldn't refresh — this may be out of date.</Alert.Description>
    </Alert.Root>
  );
}

/**
 * A wish's picture slot. Always the placeholder: the server declares no
 * `resource_domains`, because a wish's `image_url` points at an arbitrary shop
 * and fetching it would tell that shop who is looking. `image_url` is never
 * loaded.
 */
export function WishImage({ className = "" }: { className?: string }) {
  return (
    <div
      className={`flex shrink-0 items-center justify-center overflow-hidden rounded-md bg-surface-alt text-muted ${className}`}
      aria-hidden="true"
      data-testid="wish-image-placeholder"
    >
      <GiftIcon />
    </div>
  );
}

function GiftIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" strokeLinecap="round" strokeLinejoin="round" className="size-6 fill-none stroke-current stroke-[1.5]">
      <path d="M20 12v9H4v-9M2 7h20v5H2zM12 21V7M12 7H7.5a2.5 2.5 0 1 1 0-5C11 2 12 7 12 7zM12 7h4.5a2.5 2.5 0 1 0 0-5C13 2 12 7 12 7z" />
    </svg>
  );
}

/**
 * A group's next steps as buttons. The first is primary; `details` goes last.
 *
 * Inside a `Navigator` a click opens the step's view in this same page (one
 * click — in the desktop app `sendMessage` only prefills the composer). When
 * that fails, or there is no navigator, the step's `prompt` goes to the chat
 * as the person's message, VERBATIM: the server builds it from ids only,
 * because a group name is organizer-written text, so it is never composed here.
 */
export function StepButtons({
  app,
  steps,
  groupId,
  size = "sm",
}: {
  app: App | null;
  steps: NextStep[];
  groupId: string;
  size?: "sm" | "md";
}) {
  const navigate = useNavigate();
  const [pending, setPending] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const ordered = [...steps.filter((s) => s.action !== "details"), ...steps.filter((s) => s.action === "details")];
  if (!ordered.length) return null;

  const fallback = async (step: NextStep): Promise<boolean> =>
    app ? sendMessage(app, step.prompt) : false;

  const go = async (step: NextStep, i: number) => {
    if (!app || pending !== null) return;
    setPending(i);
    setError(null);
    setNote(null);
    try {
      if (!navigate) throw new Error("");
      await navigate(step, groupId);
    } catch (e) {
      const message = (e as Error).message;
      if (message) setError(message);
      const sent = await fallback(step);
      setNote(sent ? "Asked Claude to open it instead." : `Couldn't send it from here — ask Claude: "${step.prompt}"`);
    } finally {
      setPending(null);
    }
  };

  return (
    <div className="flex flex-col gap-1">
      <div className="flex flex-wrap gap-2" data-testid="steps">
        {ordered.map((step, i) => (
          <Button
            key={`${step.action}-${i}`}
            size={size}
            intent={i === 0 ? "primary" : "secondary"}
            disabled={pending !== null}
            aria-busy={pending === i}
            onClick={() => void go(step, i)}
          >
            {pending === i ? "Opening…" : step.label}
          </Button>
        ))}
      </div>
      {error && <ErrorBox onDismiss={() => setError(null)}>{error}</ErrorBox>}
      {note && <p className="m-0 text-sm text-muted" data-testid="step-note">{note}</p>}
    </div>
  );
}
