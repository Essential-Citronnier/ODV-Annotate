#!/usr/bin/env python3
"""Acquire the public evaluation cohort.

Two sources, both public and redistributable, neither requiring ethics approval
or a data use agreement:

  TCIA  — de-identified CT series via the NBIA public API. Used for the DICOM
          input path: conformance and pipeline-fidelity experiments need real
          DICOM series with real geometry, not NIfTI.

  Zenodo — the TotalSegmentator ground-truth release (CC BY 4.0), which pairs
          CT volumes with expert-corrected label masks. Used as the reference
          the plugin path is checked against.

The series identifiers are pinned in this file rather than discovered at run
time. TCIA query results are not stable across API revisions, and an evaluation
whose cohort silently changes between runs is not reproducible.

Usage:
    python fetch_data.py --dest ../.eval/data --what discover
    python fetch_data.py --dest ../.eval/data --what tcia
    python fetch_data.py --dest ../.eval/data --what ground-truth
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import zipfile
from dataclasses import dataclass, asdict
from pathlib import Path

import requests

NBIA = "https://services.cancerimagingarchive.net/nbia-api/services/v1"
ZENODO_RECORD = "10047292"  # TotalSegmentator v2: 1204 CT, 117 structures

# Pinned cohort. Selection criteria, applied once and recorded here:
#   - Collection is fully public (no DUA, no request form).
#   - Modality CT, axial, contiguous.
#   - Body region covered by TotalSegmentator's `total` task.
#   - 100-800 slices: a realistic study, but the cohort stays a sane download.
#   - Two body regions in balance, so a result is not an artefact of one anatomy.
PINNED_TCIA: list[tuple[str, str, str]] = [
    # (collection, SeriesInstanceUID, note)
    ("CT Lymph Nodes", "61.7.155621846765270845579077864210007002978", "abdomen"),      # 411 slices
    ("CT Lymph Nodes", "61.7.161580241154366015366471722739845851315", "abdomen"),      # 481
    ("CT Lymph Nodes", "61.7.102821090586639164486750605848666065663", "abdomen"),      # 485
    ("CT Lymph Nodes", "61.7.208302441747821793767821332243277973217", "abdomen"),      # 485
    ("CT Lymph Nodes", "61.7.318283198733206547078942712688129724229", "abdomen"),      # 489
    ("CT Lymph Nodes", "61.7.212101888059942679496406227616932192594", "abdomen"),      # 493
    ("CT Lymph Nodes", "61.7.338133024060269626651520600539598241004", "mediastinum"),  # 148
    ("CT Lymph Nodes", "61.7.79628140284133470198605465153142714675", "mediastinum"),   # 429
    ("CT Lymph Nodes", "61.7.165782612538761479349524122796947298715", "mediastinum"),  # 454
    ("CT Lymph Nodes", "61.7.178964818681337758599703390927532543012", "mediastinum"),  # 457
    ("CT Lymph Nodes", "61.7.12299931762111763624694258430205214360", "mediastinum"),   # 457
    ("CT Lymph Nodes", "61.7.145906379107184456902992005646062309709", "mediastinum"),  # 461
]


@dataclass
class SeriesRecord:
    """What we know about a fetched series, for the data card."""

    collection: str
    series_uid: str
    note: str
    image_count: int | None
    body_part: str | None
    manufacturer: str | None
    slice_thickness: str | None
    path: str


def _log(message: str) -> None:
    print(message, flush=True)


def _get_with_retry(url: str, *, params: dict, timeout: float,
                    attempts: int = 4, stream: bool = False):
    """GET with exponential backoff.

    The TCIA endpoint intermittently exceeds a 60 s read timeout under load; a
    single-attempt fetch dropped 5 of 12 series on the first run, which would
    have quietly unbalanced the cohort. Transient timeouts are retried; an HTTP
    error is raised immediately since retrying will not fix it.
    """
    last: Exception | None = None
    for attempt in range(attempts):
        try:
            r = requests.get(url, params=params, timeout=timeout, stream=stream)
            r.raise_for_status()
            return r
        except (requests.Timeout, requests.ConnectionError) as exc:
            last = exc
            if attempt < attempts - 1:
                delay = 5 * (2 ** attempt)
                _log(f"    timeout, retrying in {delay}s "
                     f"({attempt + 1}/{attempts - 1})")
                time.sleep(delay)
    raise last if last else RuntimeError("unreachable")


def tcia_series_metadata(series_uid: str) -> dict:
    r = _get_with_retry(f"{NBIA}/getSeriesMetaData",
                        params={"SeriesInstanceUID": series_uid}, timeout=120)
    rows = r.json()
    return rows[0] if rows else {}


def fetch_tcia_series(collection: str, series_uid: str, note: str,
                      dest: Path) -> SeriesRecord:
    """Download one series as DICOM files into dest/tcia_<short uid>/."""
    short = series_uid.rsplit(".", 1)[-1][:16]
    out = dest / f"tcia_{short}"

    # Existence is checked BEFORE any network call: the metadata endpoint times
    # out intermittently, and fetching it first meant a series already complete
    # on disk was discarded because its description could not be re-read.
    existing = list(out.glob("*.dcm")) if out.exists() else []

    # Metadata is descriptive only, so a failure degrades the data card rather
    # than losing the series.
    try:
        meta = tcia_series_metadata(series_uid)
    except Exception as exc:  # noqa: BLE001
        _log(f"  {short}: metadata unavailable ({type(exc).__name__})")
        meta = {}

    if existing:
        _log(f"  {short}: already present ({len(existing)} files)")
    else:
        out.mkdir(parents=True, exist_ok=True)
        archive = out.parent / f"{out.name}.zip"
        _log(f"  {short}: downloading…")
        t0 = time.time()
        with _get_with_retry(f"{NBIA}/getImage",
                             params={"SeriesInstanceUID": series_uid},
                             timeout=1800, stream=True) as r:
            with open(archive, "wb") as f:
                for chunk in r.iter_content(1 << 22):
                    f.write(chunk)
        with zipfile.ZipFile(archive) as z:
            z.extractall(out)
        archive.unlink()
        _log(f"  {short}: {len(list(out.glob('*.dcm')))} files in {time.time()-t0:.0f}s")

    return SeriesRecord(
        collection=collection,
        series_uid=series_uid,
        note=note,
        image_count=int(meta["ImageCount"]) if meta.get("ImageCount") else None,
        body_part=meta.get("BodyPartExamined"),
        manufacturer=meta.get("Manufacturer"),
        slice_thickness=meta.get("SliceThickness"),
        path=str(out),
    )


def discover_tcia_candidates(collection: str, limit: int = 40,
                             min_slices: int = 100,
                             max_slices: int = 800) -> list[dict]:
    """List candidate series in a public collection.

    Deliberately separate from fetching: run this to choose a cohort, then pin
    the chosen identifiers in PINNED_TCIA so later runs are reproducible.
    """
    r = requests.get(f"{NBIA}/getSeries",
                     params={"Collection": collection, "Modality": "CT"},
                     timeout=120)
    r.raise_for_status()
    out = []
    for s in r.json():
        count = int(s.get("ImageCount") or 0)
        if min_slices <= count <= max_slices:
            out.append({
                "series_uid": s["SeriesInstanceUID"],
                "image_count": count,
                "body_part": s.get("BodyPartExamined"),
                "description": s.get("SeriesDescription"),
            })
        if len(out) >= limit:
            break
    return out


def fetch_ground_truth(dest: Path, max_cases: int | None = None) -> dict:
    """Fetch the TotalSegmentator ground-truth archive.

    The release is one large archive; `max_cases` extracts only a prefix of the
    cases, which suffices for a fidelity check without unpacking 23 GB.
    """
    meta = requests.get(f"https://zenodo.org/api/records/{ZENODO_RECORD}",
                        timeout=60).json()
    files = meta.get("files", [])
    if not files:
        raise SystemExit("Zenodo record exposes no files")
    entry = files[0]
    size_gb = entry.get("size", 0) / 1e9

    dest.mkdir(parents=True, exist_ok=True)
    archive = dest / entry["key"]
    if not archive.exists():
        _log(f"  downloading {entry['key']} ({size_gb:.1f} GB)…")
        t0 = time.time()
        with requests.get(entry["links"]["self"], stream=True, timeout=7200) as r:
            r.raise_for_status()
            written = 0
            next_mark = 1 << 30
            with open(archive, "wb") as f:
                for chunk in r.iter_content(1 << 23):
                    f.write(chunk)
                    written += len(chunk)
                    if written >= next_mark:
                        _log(f"    {written/1e9:.1f} / {size_gb:.1f} GB")
                        next_mark += 1 << 30
        _log(f"  done in {time.time()-t0:.0f}s")
    else:
        _log(f"  {entry['key']}: already present")

    extract_dir = dest / "ground_truth"
    if not extract_dir.exists():
        extract_dir.mkdir(parents=True)
        _log("  extracting…")
        with zipfile.ZipFile(archive) as z:
            names = z.namelist()
            cases = sorted({n.split("/")[0] for n in names if "/" in n})
            keep = set(cases[:max_cases] if max_cases else cases)
            for n in names:
                if n.split("/")[0] in keep:
                    z.extract(n, extract_dir)
            _log(f"  extracted {len(keep)} of {len(cases)} cases")

    return {
        "record": ZENODO_RECORD,
        "title": meta["metadata"]["title"],
        "license": (meta["metadata"].get("license") or {}).get("id"),
        "doi": meta["metadata"].get("doi"),
        "archive": str(archive),
        "extracted": str(extract_dir),
    }


def write_data_card(dest: Path, tcia: list[SeriesRecord],
                    ground_truth: dict | None) -> Path:
    """Record provenance and licensing beside the data.

    An evaluation that cannot say where its data came from is not auditable, and
    licence terms should travel with the files rather than living only in a paper.
    """
    card = {
        "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "ethics": (
            "No ethics approval required. All data are public, de-identified "
            "releases obtained without a data use agreement. No patient-identifying "
            "information is present and none was sought."
        ),
        "sources": [],
    }
    if tcia:
        card["sources"].append({
            "name": "The Cancer Imaging Archive (TCIA)",
            "access": "NBIA public API, no authentication",
            "licence": "public collections; cite collection and TCIA per their policy",
            "series": [asdict(s) for s in tcia],
        })
    if ground_truth:
        card["sources"].append({
            "name": "TotalSegmentator ground-truth dataset (Zenodo)",
            "access": "Zenodo public record",
            "licence": ground_truth.get("license"),
            "doi": ground_truth.get("doi"),
            "title": ground_truth.get("title"),
            "extracted": ground_truth.get("extracted"),
        })

    path = dest / "DATA_CARD.json"
    path.write_text(json.dumps(card, indent=2))
    return path


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dest", required=True, type=Path)
    p.add_argument("--what", choices=["tcia", "ground-truth", "both", "discover"],
                   default="both")
    p.add_argument("--collection", default="CT Lymph Nodes",
                   help="for --what discover")
    p.add_argument("--max-cases", type=int, default=12,
                   help="ground-truth cases to extract")
    args = p.parse_args(argv)

    if args.what == "discover":
        print(json.dumps(discover_tcia_candidates(args.collection), indent=2))
        return 0

    dest: Path = args.dest
    dest.mkdir(parents=True, exist_ok=True)

    fetched: list[SeriesRecord] = []
    if args.what in ("tcia", "both"):
        _log("TCIA series:")
        for collection, uid, note in PINNED_TCIA:
            try:
                fetched.append(fetch_tcia_series(collection, uid, note, dest / "tcia"))
            except Exception as exc:  # noqa: BLE001 — report and continue
                _log(f"  FAILED {uid[:20]}: {type(exc).__name__}: {exc}")

    gt = None
    if args.what in ("ground-truth", "both"):
        _log("Ground truth:")
        gt = fetch_ground_truth(dest / "zenodo", max_cases=args.max_cases)

    card = write_data_card(dest, fetched, gt)
    _log(f"\nData card: {card}")
    _log(f"TCIA series fetched: {len(fetched)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
