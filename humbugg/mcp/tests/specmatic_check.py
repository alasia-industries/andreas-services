"""Fail on Specmatic's MCP report, which the tool itself never does (it exits 0 whatever
its verdicts). Run after `specmatic mcp test`:

    python tests/specmatic_check.py <reports dir>/mcp/mcp_test_report.json

One class of verdict is Specmatic's, not ours: for a tool that takes no arguments its
negative case sends `{}` — a valid call — and expects an error. Those are allowed; every
other FAILED verdict fails the run, with the tool, the case and the reason.
"""

import collections
import json
import sys

NO_ARGUMENT_TOOLS = {"whoami", "list_groups", "list_templates"}


def main(path: str) -> int:
    report = json.load(open(path))
    failed = [r for r in report if r["verdict"] != "PASSED"
              and not (r["negative"] and r["toolName"] in NO_ARGUMENT_TOOLS and not r["request"])]
    print(f"specmatic: {len(report)} cases, {len(failed)} unexpected failure(s)")
    for (tool, name, error), n in collections.Counter(
            (r["toolName"], r["name"][:160], (r["error"] or "")[:200]) for r in failed).most_common(30):
        print(f"  {n}x {tool}: {name}\n      {error}")
    return 1 if failed or not report else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
