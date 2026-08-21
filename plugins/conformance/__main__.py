# __main__.py
# OpenDicomViewer
#
# `python -m plugins.conformance <adapter dir>...`
#
# Exits non-zero when any check fails or could not be run, so this is usable as
# a CI step. An inconclusive check exits non-zero too: a check that did not run
# has not passed, and a kit that quietly downgraded "I could not look" to "fine"
# would be worse than no kit.
# Licensed under the MIT License. See LICENSE for details.
"""Command-line entry point for the plugin conformance kit."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .kit import Status, run_conformance
from .report import render_many

EPILOG = """\
examples:
  python -m plugins.conformance plugins/sam2
  python -m plugins.conformance plugins/*            check every adapter
  python -m plugins.conformance plugins/totalseg --json > conformance.json
  python -m plugins.conformance plugins/mine --python .venv/bin/python

exit status:
  0  every applicable check passed
  1  at least one check failed or could not be run
  2  the kit could not be started at all
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m plugins.conformance",
        description="Check an ODV plugin adapter against PLUGIN_PROTOCOL.md v1 "
                    "by running it.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("adapter", nargs="+",
                        help="adapter directory, e.g. plugins/sam2")
    parser.add_argument("--manifest", default=None,
                        help="plugins.json to check against "
                             "(default: the app's, found by walking up)")
    parser.add_argument("--python", default=None,
                        help="interpreter to run the adapter with, normally its "
                             "own venv (default: the one running this kit)")
    parser.add_argument("--bare-python", default=None,
                        help="interpreter with none of the adapter's "
                             "dependencies, for the section 4b checks "
                             "(default: /usr/bin/python3)")
    parser.add_argument("--timeout", type=float, default=120.0,
                        help="seconds any single adapter invocation may take "
                             "(default: 120)")
    parser.add_argument("--health-timeout", type=float, default=90.0,
                        help="seconds to wait for a server adapter to answer "
                             "GET /health (default: 90)")
    parser.add_argument("--no-http", action="store_true",
                        help="skip checks that need to bind a socket; they are "
                             "reported as inconclusive, not passed")
    parser.add_argument("--oneshot-result", action="append", default=[],
                        metavar="PATH",
                        help="a result.json from a real successful one-shot run, "
                             "so its output paths can be checked")
    parser.add_argument("--json", action="store_true",
                        help="emit machine-readable JSON instead of a report")
    parser.add_argument("--quiet", action="store_true",
                        help="print only the summary line per adapter")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    directories = [Path(item) for item in args.adapter]
    # A shell glob over plugins/ picks up _shared, the kit itself, and caches;
    # dropping them keeps `plugins/*` a usable invocation rather than a trap.
    if len(directories) > 1:
        directories = [d for d in directories
                       if d.is_dir() and not d.name.startswith((".", "_"))
                       and d.name not in ("conformance",)]
    if not directories:
        print("no adapter directories to check", file=sys.stderr)
        return 2

    reports = [
        run_conformance(
            directory,
            manifest=args.manifest,
            python=args.python,
            bare_python=args.bare_python,
            timeout=args.timeout,
            health_timeout=args.health_timeout,
            allow_http=not args.no_http,
            oneshot_results=args.oneshot_result,
        )
        for directory in directories
    ]

    if args.json:
        json.dump({"protocol": 1,
                   "passed": all(report.passed for report in reports),
                   "reports": [report.to_json() for report in reports]},
                  sys.stdout, indent=2)
        sys.stdout.write("\n")
    elif args.quiet:
        from .report import summary_line

        for report in reports:
            print(summary_line(report))
    else:
        print(render_many(reports, stream=sys.stdout))

    failed = any(result.status in (Status.FAIL, Status.ERROR)
                 for report in reports for result in report.results)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
