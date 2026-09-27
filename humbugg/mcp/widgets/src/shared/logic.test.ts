import { describe, expect, it } from "vitest";

import {
  acceptableAppOrigin,
  addArgs,
  adoptAppOrigin,
  appLink,
  claimActions,
  claimArgs,
  formatMoney,
  moveWish,
  parsePrice,
  readDraft,
  safeLinkUrl,
  updateArgs,
  emptyDraft,
} from "./logic";
import type { OwnWish } from "./types";

describe("claim buttons", () => {
  const labels = (c: Parameters<typeof claimActions>[0]) => claimActions(c).map((a) => a.label);
  it("unclaimed → plan or buy", () => {
    expect(labels(null)).toEqual(["Planning to buy", "Bought"]);
  });
  it("planned → buy or release", () => {
    expect(labels({ state: "planned", quantity: 1 })).toEqual(["Bought", "Release"]);
  });
  it("purchased → release only", () => {
    expect(labels({ state: "purchased", quantity: 1 })).toEqual(["Release"]);
  });
  it("sends the right arguments", () => {
    const [plan, buy] = claimActions(null);
    expect(claimArgs("g", "w", plan!)).toEqual({ group_id: "g", wish_id: "w", state: "planned" });
    expect(claimArgs("g", "w", buy!)).toEqual({ group_id: "g", wish_id: "w", state: "purchased" });
    const [release] = claimActions({ state: "purchased", quantity: 1 });
    expect(release!.tool).toBe("release_claim");
    expect(claimArgs("g", "w", release!)).toEqual({ group_id: "g", wish_id: "w" });
  });
});

describe("money", () => {
  it("parses a price into cents", () => {
    expect(parsePrice("")).toBeNull();
    expect(parsePrice("25")).toBe(2500);
    expect(parsePrice("12.5")).toBe(1250);
    expect(parsePrice("$1,299.99")).toBe(129999);
    expect(parsePrice("12.345")).toBeUndefined();
    expect(parsePrice("-3")).toBeUndefined();
    expect(parsePrice("abc")).toBeUndefined();
  });
  it("formats cents", () => {
    expect(formatMoney(null, "USD")).toBeNull();
    expect(formatMoney(1250, "USD")).toMatch(/12\.50/);
    expect(formatMoney(1250, "NOPE")).toBe("12.50 NOPE");
  });
});

describe("urls", () => {
  it("links: http(s) only", () => {
    expect(safeLinkUrl("https://shop.example.com/x")).toBe("https://shop.example.com/x");
    expect(safeLinkUrl("http://shop.example.com/x")).toBe("http://shop.example.com/x");
    expect(safeLinkUrl("javascript:alert(1)")).toBeNull();
    expect(safeLinkUrl("data:text/html,hi")).toBeNull();
    expect(safeLinkUrl("/relative")).toBeNull();
  });
  it("deep links into the app", () => {
    expect(appLink(null)).toBe("https://app.humbugg.com/");
    expect(appLink("g/1", "giving")).toBe("https://app.humbugg.com/groups/g%2F1/giving");
    expect(appLink("g1")).toBe("https://app.humbugg.com/groups/g1");
  });
});

describe("wish forms", () => {
  const wish: OwnWish = {
    wish_id: "w1", kind: "product", title: "Scarf", url: null, image_url: null, price_cents: 2000, currency: "USD",
    quantity: 1, priority: "normal", details: null, position: 0,
  };
  it("requires a title", () => {
    expect(readDraft(emptyDraft("USD"))).toEqual({ ok: false, error: "Give the wish a title." });
  });
  it("rejects a non-http link and a bad price", () => {
    expect(readDraft({ ...emptyDraft("USD"), title: "x", url: "javascript:1" }).ok).toBe(false);
    expect(readDraft({ ...emptyDraft("USD"), title: "x", price: "ten" }).ok).toBe(false);
  });
  it("add sends the title and only what says something", () => {
    const r = readDraft({ ...emptyDraft("usd"), title: "  Book ", price: "10" });
    if (!r.ok) throw new Error(r.error);
    expect(addArgs("g", r.fields)).toEqual({ group_id: "g", title: "Book", kind: "product", priority: "normal", quantity: 1, price_cents: 1000, currency: "USD" });
  });
  it("update sends only what changed; a cleared link or details is \"\"", () => {
    const withLink = { ...wish, url: "https://shop.example.com/x", details: "Blue" };
    const r = readDraft({ title: "Scarf", kind: "product", url: "", price: "20", currency: "USD", quantity: "1", priority: "high", details: "" });
    if (!r.ok) throw new Error(r.error);
    expect(updateArgs("g", withLink, r.fields)).toEqual({
      args: { group_id: "g", wish_id: "w1", priority: "high", url: "", details: "" },
      priceNotCleared: false,
    });
  });
  it("update cannot clear a price: it is reported, not sent", () => {
    const r = readDraft({ title: "Scarf", kind: "product", url: "", price: "", currency: "USD", quantity: "1", priority: "normal", details: "" });
    if (!r.ok) throw new Error(r.error);
    expect(updateArgs("g", wish, r.fields)).toEqual({ args: null, priceNotCleared: true });
  });
  it("update sends a changed price with its currency", () => {
    const r = readDraft({ title: "Scarf", kind: "product", url: "", price: "25", currency: "USD", quantity: "1", priority: "normal", details: "" });
    if (!r.ok) throw new Error(r.error);
    expect(updateArgs("g", wish, r.fields).args).toEqual({ group_id: "g", wish_id: "w1", price_cents: 2500, currency: "USD" });
  });
  it("update with nothing changed is no call", () => {
    const r = readDraft({ title: "Scarf", kind: "product", url: "", price: "20.00", currency: "USD", quantity: "1", priority: "normal", details: "" });
    if (!r.ok) throw new Error(r.error);
    expect(updateArgs("g", wish, r.fields)).toEqual({ args: null, priceNotCleared: false });
  });
  it("moves a wish", () => {
    expect(moveWish(["a", "b", "c"], "b", -1)).toEqual(["b", "a", "c"]);
    expect(moveWish(["a", "b", "c"], "c", 1)).toBeNull();
    expect(moveWish(["a", "b", "c"], "a", -1)).toBeNull();
  });
});

describe("groups helpers", () => {
  it("badges only the plus plan", async () => {
    const { isPlus } = await import("./logic");
    expect(isPlus("plus")).toBe(true);
    expect(isPlus("Plus")).toBe(true);
    expect(isPlus("free")).toBe(false);
    expect(isPlus(null)).toBe(false);
  });
  it("names the copy keys for the platform", async () => {
    const { copyShortcut } = await import("./logic");
    expect(copyShortcut("MacIntel")).toBe("Press ⌘C to copy");
    expect(copyShortcut("Win32")).toBe("Press Ctrl+C to copy");
  });
});


describe("the app origin a view may set", () => {
  it("accepts production and a loopback dev app only", () => {
    expect(acceptableAppOrigin("https://app.humbugg.com")).toBe(true);
    expect(acceptableAppOrigin("http://localhost:8081")).toBe(true);
    expect(acceptableAppOrigin("http://127.0.0.1:8081")).toBe(true);
    for (const bad of ["https://evil.example", "http://localhost", "https://app.humbugg.com.evil.example",
                       "http://localhost:8081/x", "javascript:alert(1)", 42, null]) {
      expect(acceptableAppOrigin(bad)).toBe(false);
    }
  });

  it("links follow an adopted origin and ignore a bad one", () => {
    adoptAppOrigin({ app_url: "http://localhost:8081" });
    expect(appLink("g1", "draw")).toBe("http://localhost:8081/groups/g1/draw");
    adoptAppOrigin({ app_url: "https://evil.example" });
    expect(appLink(null)).toBe("http://localhost:8081/");
    adoptAppOrigin({ app_url: "https://app.humbugg.com" });
    expect(appLink(null)).toBe("https://app.humbugg.com/");
  });
});
