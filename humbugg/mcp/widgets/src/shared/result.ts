/**
 * Reading a tool result, whatever shape the host sends it in.
 *
 * Depending on the host a result reaches the page as `structuredContent` (the
 * object itself), a text block holding the object as JSON, or either of those
 * wrapped as `{"result": …}`. `parseResult` accepts all of them, so a page never
 * depends on which host it is in. No SDK import: this file is pure and tested.
 */

import { adoptAppOrigin } from "./logic";

/** The parts of a tool result a page reads. */
export type ToolResult = {
  content?: { type: string; text?: string }[];
  structuredContent?: unknown;
  isError?: boolean;
};

export function textOf(result: ToolResult | null | undefined): string {
  return result?.content?.find((c) => c.type === "text")?.text ?? "";
}

function unwrap(value: unknown): unknown {
  let v: unknown = value;
  if (typeof v === "string") {
    try {
      v = JSON.parse(v);
    } catch {
      return v;
    }
  }
  if (v && typeof v === "object" && !Array.isArray(v) && Object.keys(v).length === 1 && "result" in v) {
    return unwrap((v as { result: unknown }).result);
  }
  return v;
}

/**
 * The object a tool returned. Throws with the tool's own text when it reported
 * an error, or when nothing object-shaped arrived. `isShape`, when given, is a
 * cheap check that the object is the one the page expects.
 */
export function parseResult<T>(result: ToolResult | null | undefined, isShape?: (v: object) => boolean): T {
  if (!result) throw new Error("empty tool result");
  if (result.isError) throw new Error(textOf(result) || "the tool reported an error");
  let v = unwrap(result.structuredContent);
  if (!v || typeof v !== "object") v = unwrap(textOf(result));
  if (!v || typeof v !== "object") throw new Error(textOf(result) || "empty tool result");
  if (isShape && !isShape(v)) throw new Error(`unexpected tool result: ${describeResult(result)}`);
  adoptAppOrigin(v); // every view names the app it belongs to (production, or a local dev app)
  return v as T;
}

/** What arrived, for the error box when it could not be read. */
export function describeResult(result: unknown): string {
  let shape: string;
  try {
    shape = JSON.stringify(result).slice(0, 400);
  } catch {
    shape = String(result);
  }
  return shape;
}

/** The group id a result is about, for calling its tool again. */
export function groupIdOf(v: unknown): string | null {
  const group = (v as { group?: { group_id?: unknown } } | null)?.group;
  return typeof group?.group_id === "string" && group.group_id ? group.group_id : null;
}
