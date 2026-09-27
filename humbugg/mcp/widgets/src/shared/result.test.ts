import { describe, expect, it } from "vitest";

import { groupIdOf, parseResult } from "./result";

const view = { group: { group_id: "g1", name: "Office" }, wishes: [] };

describe("parseResult reads every shape a host sends", () => {
  it("structuredContent as the object", () => {
    expect(parseResult({ structuredContent: view })).toEqual(view);
  });
  it("structuredContent wrapped as {result}", () => {
    expect(parseResult({ structuredContent: { result: view } })).toEqual(view);
  });
  it("structuredContent wrapped as {result: json string}", () => {
    expect(parseResult({ structuredContent: { result: JSON.stringify(view) } })).toEqual(view);
  });
  it("a JSON text block", () => {
    expect(parseResult({ content: [{ type: "text", text: JSON.stringify(view) }] })).toEqual(view);
  });
  it("a JSON text block wrapped as {result}", () => {
    expect(parseResult({ content: [{ type: "text", text: JSON.stringify({ result: view }) }] })).toEqual(view);
  });
  it("prefers structuredContent over a summary text block", () => {
    expect(parseResult({ content: [{ type: "text", text: "Office: 0 wishes" }], structuredContent: view })).toEqual(view);
  });
  it("throws the tool's own text on isError", () => {
    expect(() => parseResult({ isError: true, content: [{ type: "text", text: "You are not in this group." }] })).toThrow("You are not in this group.");
  });
  it("throws the text when nothing object-shaped arrived", () => {
    expect(() => parseResult({ content: [{ type: "text", text: "plain words" }] })).toThrow("plain words");
    expect(() => parseResult({})).toThrow("empty tool result");
    expect(() => parseResult(null)).toThrow("empty tool result");
  });
  it("checks the shape when asked", () => {
    expect(() => parseResult({ structuredContent: { other: 1 } }, (v) => "group" in v)).toThrow(/unexpected tool result/);
  });
  it("does not unwrap an object that merely has a result key among others", () => {
    const v = { result: 1, other: 2 };
    expect(parseResult({ structuredContent: v })).toEqual(v);
  });
});

describe("groupIdOf", () => {
  it("reads group.group_id", () => {
    expect(groupIdOf(view)).toBe("g1");
    expect(groupIdOf({})).toBeNull();
    expect(groupIdOf({ group: { group_id: 3 } })).toBeNull();
  });
});
