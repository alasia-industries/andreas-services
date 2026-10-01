---
name: design-system-ui
description: >-
  Repo rule. Build every UI change in andreas-services from @ansavva/design-system —
  check the catalogue before writing a component, import from the package root so the
  bundler picks the platform leaf, and express brand through the theming seams rather
  than hard-coded colours. Use before adding or changing any screen, form, dialog or
  styled component in website/ or classroom/.
---

# UI in this repo comes from the design system

> Humbugg (`humbugg/marketing`, `humbugg/app`) moved to its own repo,
> `ansavva/humbugg`, on 2026-09-30. Its rows below are kept as the reference
> for a Metro/React Native consumer; its paths no longer exist here.

`@ansavva/design-system` is published from
[ansavva/design-system](https://github.com/ansavva/design-system) and is the **only** component
library in this monorepo. There is no local one, and there must not become one.

Four consumer skills — `design-system-catalogue`, `design-system-platforms`,
`design-system-setup`, `design-system-theming` — describe how the package itself works. They are
installed by `scripts/dev-setup.sh` and this skill points at them rather than restating them. What
follows is the part that is **ours**: the rules for working in this repo.

## 1. Check the catalogue before you write a component

Hand-rolling something the package already ships is the failure this skill exists to prevent.

- `node_modules/@ansavva/design-system/README.md` — ships in the tarball, so it matches the version
  you actually installed. Read it for "does this exist and what is it called".
- The workbench, <https://ansavva.github.io/design-system/> — every component rendered with its web
  leaf and native leaf **side by side**. Read it for "what does it look like".

→ `design-system-catalogue` for the five shelves, compound components (`Dialog.Trigger`, never a
`DialogTrigger` export), the controlled/uncontrolled pair every input supports, and why `Field`
composes with a control rather than rendering one.

## 2. Import from the package root — never a `.web` or `.native` path

```tsx
import { Button, Field, Input } from '@ansavva/design-system';  // ✅
import { Button } from '@ansavva/design-system/button.web';      // ❌
```

Every component is a `.web.tsx` / `.native.tsx` pair behind one extensionless export, and **your
bundler picks the leaf**. An explicit leaf path hard-codes one platform at the call site — and it
compiles cleanly, so nothing tells you until the other platform renders wrong.

→ `design-system-platforms` for the three-file split and the resolution failure table.

## 3. Know which surface you are in

| Directory | Bundler | Leaf | Styling |
|---|---|---|---|
| `humbugg/marketing` (marketing, `www.humbugg.com`) | Vite | `.web.tsx` | Tailwind v4 + `theme.css` |
| `website/frontend` (`www.andreas.services`) | Vite | `.web.tsx` | Tailwind v4 + `theme.css` |
| `humbugg/app` (product, `app.humbugg.com`) | Metro | `.native.tsx` | **No Tailwind** — RN `StyleSheet` |

`humbugg/app` is a React Native codebase that also runs in a browser through `react-native-web`. It
keeps its native leaf there — that is deliberate, not a bug, and it is why there is no Tailwind
pipeline on that side. Reaching for a Tailwind class string in `humbugg/app` means you are in the
wrong mental model.

**Neither bundler picks the right leaf on its own. Both are configured to, and the configuration is
load-bearing:**

- **Vite** (`humbugg/marketing`, `website/frontend`) — the default `resolve.extensions` stop at `.tsx`, so
  the package's extensionless `export * from './button'` resolves to *nothing*. The `.web`-suffixed
  forms are listed first in `resolve.extensions` **and** in `optimizeDeps.rollupOptions.resolve`
  (the dependency optimizer resolves separately). Symptom if broken: unresolved component.
- **Metro** (`humbugg/app`) — for `platform: 'web'` the candidates are `.web.tsx` then `.tsx`;
  **`.native` is not considered at all.** An unconfigured web export silently takes the *web* leaves.
  `humbugg/app/metro.config.js` corrects it for intra-package relative imports. Symptom if broken:
  everything renders completely unstyled, because a Tailwind class string means nothing here. It
  compiles, bundles and passes every test.

`tsconfig.json`'s `moduleSuffixes` mirrors the order in both, for `tsc`.

Because that failure is silent, CI asserts the resolved leaf in both directions —
`humbugg/scripts/assert-design-system-leaves.mjs`, run by `humbugg-pr.yml`. Run it yourself after
changing anything about resolution. **Do not "verify" the native side by grepping the bundle for
`react-native-web`**: it is present in any Expo web build because the app's own primitives use it, so
it passes whichever leaf resolved. The source-map audit is the only trustworthy signal.

## 4. Never hard-code a colour, font or radius a semantic role covers

Both sites have an established brand and it is expressed through the design system's theming seams,
not through literals at call sites:

- **Web** — override the CSS custom properties *after* importing `theme.css`. Roles are kebab-case:
  `primaryText` is `--color-primary-text`. Dark mode is the `[data-theme='dark']` selector.
  Typography is `--font-heading` / `--font-body`.
- **Native** — one `ThemeProvider` at the root of `humbugg/app/app/_layout.tsx`.

Raw palette names are exported nowhere, in either direction. That is deliberate: it is what keeps a
re-brand a one-place change. If you want one, the role you need is missing — say so upstream rather
than hard-coding a hex.

**Two traps that bite in this repo specifically:**

- **On native, derived states are pre-computed, not live blends.** Overriding `primary` does *not*
  move `primaryHover` / `primaryActive` — on web they follow via `color-mix()`, on native they do
  not. Humbugg's pressed greens must be set explicitly. The symptom is "the button is our colour
  until you press it".
- **Theme overrides are a loose record, so a misspelled role key is silently ignored** — you get a
  default-coloured component, not an error. Check spelling against the role table.

→ `design-system-theming` for the full role list and both seams.

## 5. When the package is genuinely missing something

Compose from what exists, or raise it upstream in `ansavva/design-system`. Do **not** start a local
component library, and do not vendor a copy.

Some absences are documented and intentional — menubar, navigation menu, number field, scroll area,
context menu, preview card — because each needs a desktop-first interaction model with no touch
counterpart. Those are decisions, not gaps waiting to be filled locally.

Some platform differences are intentional too: native `Popover` and `Dropdown` have no press-outside
dismissal, because React Native has no document to listen to. Give those an explicit close
affordance rather than working around the package.

Before filing a difference as a bug, compare the two leaves in the workbench. If they disagree
*there*, it is the package's problem; if they agree there and not here, it is our resolution or our
theming.

## 6. Installing and staying current

Both packages live on GitHub Packages, which requires a token for **every** read — there is no
anonymous install. The committed `.npmrc` reads `${NODE_AUTH_TOKEN}`; get one with
`export NODE_AUTH_TOKEN=$(gh auth token)`. **Not** `scripts/github-packages-auth.sh --export` — it
opens a device flow and hangs on a non-interactive session. A `401`/`404` on the `@ansavva` scope
almost always means unauthenticated, not missing; a `404` naming `registry.npmjs.org` instead means
you ran `npm` outside a directory with an `.npmrc`, so the scope never got routed to GitHub.

**Every consumer pins an exact version**, so no release of any kind reaches you on its own.
There are five, and each one moves on its own schedule:

```
website/frontend  classroom/frontend  humbugg/marketing  humbugg/app
```

**Bump only the consumers your change is actually about.** A shared version across the monorepo is
not a goal, and chasing one is how a visual overhaul lands in a service nobody was working on: the
package is pre-1.0 and a minor can restyle every component, so `npm install` in a service you did
not intend to touch is a redesign of it. Version drift between services is the normal state.

The one place a version really is coupled is a single deployable: `humbugg/marketing` and
`humbugg/app` are one product on two platforms, so a difference between them shows up as the two
halves of Humbugg not matching. Move those two together. Across services, don't.

What drift costs you is smaller than it looks, and worth knowing precisely:

- **The workbench renders the design system's `main`**, not your pin. A consumer that is behind is
  comparing against a page that may already have moved on — read the CHANGELOG for the delta rather
  than trusting what you see there.
- **The CI leaf assertion is per-service** (`humbugg/scripts/assert-design-system-leaves.mjs`, run
  by `humbugg-pr.yml`), so it proves nothing about any other service either way. Drift does not
  weaken it.
- **`@ansavva/tokens` is pinned separately and only where a consumer imports it directly** — today
  just `humbugg/app`. A design-system minor that needs a new tokens minor says so at the top of its
  CHANGELOG entry; take both or the components it named render wrong.

Read `node_modules/@ansavva/design-system/CHANGELOG.md` before bumping — it ships in the tarball, so
it needs no network. A struck-through prop in your editor is a deprecation with a deadline, not a
suggestion; fix it before the next bump, because you take every removal since your last move in one
step. Note that this is a `0.x` package, so if you ever loosen a pin, npm's caret rules are narrower
than most people expect: `^0.14.0` means `>=0.14.0 <0.15.0` and will not resolve a minor.

**A minor can be breaking on one platform only.** 0.15.0 changed nothing on web and broke every
native `Accordion.Panel` / `Collapsible.Panel` that held bare text. So `humbugg/app` is the surface
to re-check on any bump, and a green Vite build proves nothing about it.

→ `design-system-setup` for the `.npmrc`, the Tailwind `@source` line the package needs, and the
failure table.
