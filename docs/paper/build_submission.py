#!/usr/bin/env python3
"""Build the CMPB submission files from the Markdown sources.

    python docs/paper/build_submission.py            # build
    python docs/paper/build_submission.py --check    # report blockers only

Outputs go to docs/paper/submission/build/ (git-ignored except by choice):
  manuscript.docx   title page, highlights, abstract, body, declarations,
                    references (inlined from references.md), tables, legends
  highlights.docx   Elsevier asks for highlights as a separate file
  cover_letter.docx
  Supplementary_Material.docx  supplementary.md, figures embedded
  Fig1.png ... FigN.png  copied from the paths named in the figure legends

HTML comments (source pointers, CONFIRM notes) are stripped from every output.
The build refuses to run, unless --draft is passed, while any TODO( or CONFIRM
marker survives outside a comment, or any figure file is missing: those are
exactly the things a desk editor would bounce.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
OUT = HERE / "submission" / "build"

COMMENT = re.compile(r"<!--.*?-->", re.S)
FIGURE_PATH = re.compile(r"\(`([^`]+\.(?:png|tif|tiff|pdf|eps))`\)")


def strip_comments(text: str) -> str:
    text = COMMENT.sub("", text)
    return re.sub(r"\n{3,}", "\n\n", text)


def reference_list() -> str:
    lines = []
    for line in (HERE / "references.md").read_text().splitlines():
        if re.match(r"^\d+\. ", line):
            lines.append(COMMENT.sub("", line).rstrip())
    return "\n".join(lines)


def manuscript_text() -> tuple[str, list[Path]]:
    text = (HERE / "manuscript.md").read_text()
    text = strip_comments(text)
    text = re.sub(r"See `references\.md` \(\d+ entries\)\.", reference_list(), text)
    figures = [REPO / p for p in FIGURE_PATH.findall(text)]
    # The legends name source files for the authors; the submission names Fig N.
    text = FIGURE_PATH.sub("", text)
    return text, figures


def blockers(text: str, figures: list[Path]) -> list[str]:
    found = []
    for marker in ("TODO(", "CONFIRM", "[REF:"):
        for line in text.splitlines():
            if marker in line:
                found.append(f"marker {marker!r}: {line.strip()[:100]}")
    # Fields whose only content was a CONFIRM comment are empty once comments
    # are stripped; a desk editor checks every one of these.
    required = ("**Affiliations:**", "**Corresponding author", "**CRediT authorship",
                "**Declaration of competing interest:**", "**Funding:**",
                "**Declaration of generative AI")
    lines = text.splitlines()
    for index, line in enumerate(lines):
        for field in required:
            if line.startswith(field):
                body = line.split(":**", 1)[-1].strip()
                following = lines[index + 1].strip() if index + 1 < len(lines) else ""
                if not body and (not following or following.startswith("**")
                                 or following == "---"):
                    found.append(f"empty field: {field.strip('*')}")
    if re.search(r"\^\d\^\s*\^\d\^", text) or re.search(r"\^1\^\s*$", text, re.M):
        found.append("affiliation lines are empty")
    for figure in figures:
        if not figure.is_file():
            found.append(f"missing figure: {figure.relative_to(REPO)}")
    return found


def pandoc(markdown: str, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    # Image paths in the supplement are relative to the repository root.
    subprocess.run(["pandoc", "--from", "markdown+superscript", "--to", "docx",
                    "--resource-path", str(REPO), "--output", str(target)],
                   input=markdown.encode(), check=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--draft", action="store_true",
                        help="Build even with open markers (output is marked DRAFT)")
    args = parser.parse_args()

    text, figures = manuscript_text()
    supplement = strip_comments((HERE / "supplementary.md").read_text())
    supplement_figures = [REPO / p for p in re.findall(r"!\[[^\]]*\]\(([^)]+)\)", supplement)]
    problems = blockers(text, figures)
    problems += [f"supplement: {p}" for p in blockers(supplement, supplement_figures)]
    for problem in problems:
        print(f"  [blocker] {problem}")
    print(f"{len(problems)} blocker(s)")
    if args.check:
        return 1 if problems else 0
    if problems and not args.draft:
        print("refusing to build; pass --draft for a review copy")
        return 1

    if OUT.exists():
        shutil.rmtree(OUT)
    suffix = "_DRAFT" if problems else ""
    pandoc(text, OUT / f"manuscript{suffix}.docx")
    pandoc(strip_comments((HERE / "submission/highlights.md").read_text()),
           OUT / "highlights.docx")
    pandoc(strip_comments((HERE / "submission/cover_letter.md").read_text()),
           OUT / f"cover_letter{suffix}.docx")
    pandoc(supplement, OUT / f"Supplementary_Material{suffix}.docx")
    for index, figure in enumerate(figures, start=1):
        if figure.is_file():
            shutil.copy2(figure, OUT / f"Fig{index}{figure.suffix}")
    print(f"built: {OUT.relative_to(REPO)}")
    for path in sorted(OUT.iterdir()):
        print(f"  {path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
