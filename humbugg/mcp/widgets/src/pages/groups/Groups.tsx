/**
 * The person's groups (`show_groups`), one card each, with the group's next
 * steps as buttons.
 *
 * A step sends its `prompt` as the person's chat message, verbatim (see
 * `StepButtons`). Group names are organizer-written text: rendered as plain
 * text, never put into a prompt.
 */

import { Badge, Card } from "@ansavva/design-system";

import type { App } from "@modelcontextprotocol/ext-apps";

import { Navigator } from "../../nav/Navigator";
import { useToolPage } from "../../shared/host";
import { appLink, formatDate, formatLimit, isPlus } from "../../shared/logic";
import { ErrorBox, Loading, PageHeader, StaleNote, StepButtons } from "../../shared/Page";
import type { Groups } from "../../shared/types";

const isView = (v: object) => "groups" in v && Array.isArray((v as Groups).groups);

const ROOT_NOTE = "The person is viewing their list of Humbugg groups in the Humbugg page.";

/**
 * The page `show_groups` opens. A group's step opens its view inside this page
 * (see `Navigator`); Back returns here and calls `show_groups` again.
 */
export function GroupsPage() {
  const { app, view, error, stale, reload } = useToolPage<Groups>("humbugg groups", "show_groups", isView, "none");

  if (!view) {
    return (
      <div>
        <PageHeader title="Your groups" app={app} />
        {error ? <ErrorBox>{error}</ErrorBox> : <Loading label="Loading your groups" />}
      </div>
    );
  }

  return (
    <Navigator app={app} rootLabel="Your groups" rootNote={ROOT_NOTE} reloadRoot={reload}>
      <GroupsView app={app} view={view} stale={stale} onReload={reload} />
    </Navigator>
  );
}

export function GroupsView({
  app,
  view,
  stale = false,
  onReload,
}: {
  app: App | null;
  view: Groups;
  stale?: boolean;
  onReload?: () => Promise<void>;
}) {
  return (
    <div className="flex flex-col gap-3">
      <PageHeader title="Your groups" app={app} appUrl={appLink(null)} onReload={onReload} />
      {stale && <StaleNote />}

      {view.groups.length === 0 ? (
        <Card.Root data-testid="empty">
          <h2 className="m-0 font-heading text-base font-semibold">No groups yet</h2>
          <p className="m-0 text-sm text-muted">
            Ask Claude to create a gift exchange — say who it's for, the date and a budget — or join one from an invite link.
          </p>
        </Card.Root>
      ) : (
        <ul className="m-0 flex list-none flex-col gap-3 p-0" data-testid="groups">
          {view.groups.map((g) => {
            const limit = formatLimit(g.spending_limit, g.currency);
            return (
              <li key={g.group_id} data-testid="group" data-group-id={g.group_id}>
                <Card.Root>
                  <div className="flex flex-wrap items-start gap-2">
                    <h2 className="m-0 min-w-0 flex-1 break-words font-heading text-lg font-semibold" data-testid="group-name">
                      {g.name}
                    </h2>
                    {isPlus(g.plan) && (
                      <Badge intent="primary" size="sm" className="mt-1 shrink-0">
                        Plus
                      </Badge>
                    )}
                  </div>
                  <p className="m-0 flex flex-wrap gap-x-3 gap-y-1 text-sm text-muted">
                    <span className={g.status === "drawn" ? "font-semibold text-primary" : ""}>
                      {g.status === "drawn" ? "Names drawn" : "Open"}
                    </span>
                    <span>{g.is_organizer ? "Organizer" : "Participant"}</span>
                    {g.event_date && <span>{formatDate(g.event_date)}</span>}
                    {limit && <span>Budget {limit}</span>}
                  </p>
                  <div className="pt-1">
                    <StepButtons app={app} steps={g.next} groupId={g.group_id} />
                  </div>
                </Card.Root>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
