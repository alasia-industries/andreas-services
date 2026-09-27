# Organizing a Humbugg exchange

1. **Create the group** (`create_group`): a name, and ideally the event date, a sign-up
   deadline and a spending limit per gift. The person creating it is the owner and an
   organizer.
2. **Invite people.** Every group has an invite link (`get_group` → `invite_url`) to share
   however the organizer likes. `new_invite_link` replaces it — the old one stops working.
   On Plus, `invite_by_email` emails invitations and `list_invitations` tracks them;
   `resend_invitation` and `revoke_invitation` manage them. Emailing anyone needs the
   organizer's explicit yes first.
3. **Exclusions** (`set_exclusions`): pairs who must not draw each other, such as partners.
   The call replaces the whole list — read the current pairs from `get_group` and include
   the ones to keep.
4. **Readiness** (`group_readiness`): who has joined, who is taking part, and who still
   needs a wish list (or an address, when `requires_address` is on because gifts are
   posted). `send_reminder` nudges people by email (Plus; needs a yes). An organizer can
   leave someone out of the draw with `set_participation`.
5. **Draw names** (`prepare_draw`): opens a review page with a **Draw names** button. The
   organizer clicks it; Claude cannot draw. At least two participants are needed. Each
   participant is then told who they are buying for — the organizer included — and nobody,
   the organizer included, can see who drew whom.

After the draw, groups can't be reset, deleted or revealed from here; those are in the app
at https://app.humbugg.com, as are payments (Plus) and templates' full editing.
`list_templates`, `duplicate_template` and `apply_template` start a new exchange from a
past one.
