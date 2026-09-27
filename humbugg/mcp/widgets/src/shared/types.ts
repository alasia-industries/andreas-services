/**
 * The tool contract the pages read — `structuredContent` of each tool, as the
 * Python server (`humbugg/mcp/humbugg_mcp/`) returns it. All ids are strings,
 * every key snake_case.
 */

export type Role = "owner" | "co_organizer" | "participant";

export type Member = { member_id: string; display_name: string };

/** `prepare_draw({group_id})` */
export type DrawReview = {
  group: {
    group_id: string;
    name: string;
    status: "open" | "drawn";
    event_date: string | null;
    spending_limit: number | null;
    currency: string;
    plan: string;
  };
  participants: (Member & {
    role: Role;
    is_participating: boolean;
    ready: boolean;
    nudges: string[];
  })[];
  exclusions: { a: Member; b: Member }[];
  warnings: string[];
  can_draw: boolean;
  drawn_at: string | null;
};

/** `draw({group_id})` — app-only. */
export type DrawDone = { group_id: string; status: "drawn"; drawn_at: string };

export type WishKind = "product" | "custom" | "experience" | "charity";
export type Priority = "low" | "normal" | "high";
export type ClaimState = "planned" | "purchased";

type WishBase = {
  wish_id: string;
  kind: WishKind;
  title: string;
  url: string | null;
  image_url: string | null;
  price_cents: number | null;
  currency: string | null;
  quantity: number;
  priority: Priority;
  details: string | null;
};

export type RecipientWish = WishBase & {
  claim: { state: ClaimState; quantity: number } | null;
};

/** `show_assignment({group_id})`, and the reply of `claim_wish` / `release_claim`. */
export type Assignment = {
  group: {
    group_id: string;
    name: string;
    event_date: string | null;
    spending_limit: number | null;
    currency: string;
  };
  recipient: {
    display_name: string;
    wishlist: string;
    avoidances: string;
    wishes: RecipientWish[];
  };
  gift: {
    stage: "choosing" | "purchased" | "sent";
    received: boolean;
    can_change_stage: boolean;
  } | null;
};

export type OwnWish = WishBase & { position: number };

/** `edit_wishlist({group_id})` */
export type Wishlist = {
  group: { group_id: string; name: string };
  wishes: OwnWish[];
};

/** A next step: a chat message the page sends as the person, verbatim. The
 *  server builds `prompt` from fixed wording and ids only — never a name. */
export type NextStep = {
  action: "assignment" | "draw" | "wishlist" | "details";
  label: string;
  prompt: string;
};

/** `show_groups()` */
export type Groups = {
  groups: {
    group_id: string;
    name: string;
    status: "open" | "drawn";
    event_date: string | null;
    spending_limit: number | null;
    currency: string;
    plan: string;
    is_organizer: boolean;
    is_owner: boolean;
    next: NextStep[];
  }[];
};

/** `show_group({group_id})` */
export type GroupDetail = {
  group: {
    group_id: string;
    name: string;
    status: "open" | "drawn";
    event_date: string | null;
    signup_deadline: string | null;
    spending_limit: number | null;
    currency: string;
    plan: string;
    description: string | null;
    instructions: string | null;
    is_organizer: boolean;
    is_owner: boolean;
    requires_address: boolean;
    invite_url: string | null;
  };
  members: (Member & { is_organizer: boolean; is_owner: boolean; is_participating: boolean })[];
  exclusions: { a: Member; b: Member }[];
  readiness: {
    participants: { member_id: string; ready: boolean; nudges: string[] }[];
    pending_invitations: { invitation_id: string; email: string; status: string }[];
    gift_progress: { purchased: number; sent: number; received: number; total: number } | null;
    drawn_at: string | null;
  } | null;
  next: NextStep[];
};
