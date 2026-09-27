/**
 * How a step button opens its view in place. `Navigator` provides it; a step
 * button outside one (or whose navigation fails) falls back to sending the
 * step's prompt as a chat message.
 */

import { createContext, useContext } from "react";

import type { NextStep } from "./types";

export type Navigate = (step: NextStep, groupId: string) => Promise<void>;

export const NavContext = createContext<Navigate | null>(null);

export function useNavigate(): Navigate | null {
  return useContext(NavContext);
}
