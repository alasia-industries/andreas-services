"""Fail on Specmatic's MCP report, which the tool itself does not reliably do. Run
after `specmatic mcp test`:

    python tests/specmatic_check.py <reports dir>/mcp/mcp_test_report.json

One class of verdict is Specmatic's, not ours: for a tool that takes no arguments its
negative case sends `{}` — a valid call — and expects an error. Which tools take none is
read from `tools_schema.json` beside the report (what the server itself declared), so a
new argument-less tool needs no edit here. Every other FAILED verdict fails the run,
with the tool, the case and the reason.
"""

import collections
import json
import sys
from pathlib import Path


def no_argument_tools(report_path: Path) -> set[str]:
    schema = json.loads((report_path.parent / "tools_schema.json").read_text())
    return {t["name"] for t in schema if not (t.get("inputSchema") or {}).get("properties")}


def main(path: str) -> int:
    report_path = Path(path)
    report = json.loads(report_path.read_text())
    argless = no_argument_tools(report_path)
    failed = [r for r in report if r["verdict"] != "PASSED"
              and not (r["negative"] and r["toolName"] in argless and not r["request"])]
    print(f"specmatic: {len(report)} cases, {len(failed)} unexpected failure(s) "
          f"(argument-less tools: {', '.join(sorted(argless)) or 'none'})")
    for (tool, name, error), n in collections.Counter(
            (r["toolName"], r["name"][:160], (r["error"] or "")[:200]) for r in failed).most_common(30):
        print(f"  {n}x {tool}: {name}\n      {error}")
    return 1 if failed or not report else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
