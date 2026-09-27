/**
 * The page `show_group` opens: the group's view as the root of a view stack,
 * so its steps open the draw review, assignment or wish list in place.
 */

import { Navigator, noteFor } from "../../nav/Navigator";
import { useToolPage } from "../../shared/host";
import { ErrorBox, Loading, PageHeader } from "../../shared/Page";
import type { GroupDetail } from "../../shared/types";
import { GroupView, isGroupDetail } from "./Group";

export function GroupPage() {
  const { app, view, error, stale, reload } = useToolPage<GroupDetail>("humbugg group", "show_group", isGroupDetail);

  if (!view) {
    return (
      <div>
        <PageHeader title="Group" app={app} />
        {error ? <ErrorBox>{error}</ErrorBox> : <Loading label="Loading the group" />}
      </div>
    );
  }

  return (
    <Navigator app={app} rootLabel="Group details" rootNote={noteFor("group", view.group.group_id)} reloadRoot={reload}>
      <GroupView app={app} view={view} stale={stale} onReload={reload} />
    </Navigator>
  );
}
