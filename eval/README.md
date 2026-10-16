# Evaluation harness

Scripts behind `docs/EVALUATION.md`: five experiments on the plugin layer,
their figures, and the recorded results. Everything here uses public data and
needs no ethics approval or data use agreement.

| Script | Experiment | Results (`eval/results/`) | Write-up |
|---|---|---|---|
| `fetch_data.py` | data acquisition (TCIA + TotalSegmentator reference set) | data card in the data directory | — |
| `exp1_conformance.py` | 1 · DICOM SEG conformance (dcmqi round trip, IOD audit) | `exp1_conformance.*` | `exp1_findings.md` |
| `exp2_fidelity.py`, `exp2_hygiene.py`, `exp2_tables.py`, `exp2_figures.py` | 2 · pipeline fidelity; hygiene check against reference masks | `exp2_*` | `exp2_REPORT.md`, `exp2_tables.md` |
| `exp3_resources.py`, `exp3_figures.py` | 3 · install cost, peak memory, arbitration scenarios | `exp3_resources*` | `exp3_FINDINGS.md` |
| `exp3_totalseg_lowmem.py` | 3 · TotalSegmentator process-tree memory and low-memory settings | `exp3_totalseg_lowmem.*` | `exp3_FINDINGS.md`, "Low-memory settings" |
| `exp4_session.py` | 4 · session model (encode/decode cost, implicit cache) | `exp4_session*` | `exp4_session_REPORT.md` |
| `exp5_deployability.py` | 5 · packaged-app checks | `exp5_deployability.jsonl` | `docs/EVALUATION.md` §6 |

`harness.py` is shared: one JSON object per case, failures recorded rather
than dropped, and a header line per file with the machine profile,
accelerator visibility and (for files started after October 2026) the versions
of the packages that matter (`packages.harness` for the interpreter running the
script, `packages.target` for the one running the model). `exp3_mp_thread_shim.py`
and `conformance_checks.py` are helpers.

## Environment

- macOS on Apple Silicon. Results were recorded on a MacBook Pro (M5 Max,
  128 GB); TotalSegmentator alone needs about 24 GB free.
- **Harness interpreter** (`python` below): Python 3.11 or later with `numpy`,
  `matplotlib` and `requests`; `pydicom` and `SimpleITK` for experiments 1–2;
  `dcmqi` (`pip install dcmqi`) for experiment 1. A virtualenv outside the
  repository is fine. Run with `PYTHONPATH=eval` from the repository root.
- **`<ts-python>`**: an interpreter with TotalSegmentator installed, passed to
  experiments 1 and 2 as `--python`. Use the TotalSegmentator plugin's own
  environment so the model stack is the one that ships:
  - after `exp3_resources.py --phases install,weights --plugins totalsegmentator`:
    `.eval/plugin-envs/totalsegmentator/.venv/bin/python3`, or
  - after installing the plugin in the app:
    `~/Library/Application Support/OpenDicomViewer/plugins/totalsegmentator/.venv/bin/python3`.

  Older script headers and `exp2_REPORT.md` mention a "seg-engine" venv. That
  was the author's TotalSegmentator environment from a sibling project, which
  the adapter's SEG export was adapted from; it is not part of this repository
  and nothing requires it. Any environment from
  `plugins/totalseg/requirements.txt` is equivalent.
- `.eval/` (git-ignored) holds data, scratch output and the plugin
  environments `exp3_resources.py` creates. Nothing is written to Application
  Support.

## Data

```sh
python eval/fetch_data.py --dest .eval/data --what tcia          # 12 pinned TCIA CT series
python eval/fetch_data.py --dest .eval/data --what ground-truth  # TotalSegmentator reference cases (Zenodo, CC BY 4.0)
```

Series identifiers are pinned in `fetch_data.py`; the script writes a data card
recording provenance and licences. Series land in `.eval/data/tcia/tcia_<id>`;
the reference set is extracted under `.eval/data/zenodo/` (pass the extracted
`ground_truth` directory to `exp2_hygiene.py`).

## Run order

```sh
# 3 first: it creates the plugin environments and fetches weights the others use
PYTHONPATH=eval python eval/exp3_resources.py \
    --series .eval/data/tcia/tcia_1556218467652708 \
    --crosscheck-series .eval/data/tcia/tcia_1556218467652708 \
                        .eval/data/tcia/tcia_2121018880599426
#   --totalseg-threads only where multiprocessing is unavailable (sandboxed runs)
PYTHONPATH=eval python eval/exp3_totalseg_lowmem.py \
    --series .eval/data/tcia/tcia_<id> ... \
    --adapter-tasks total,total_lowmem --seg-variants default,force_split,threads1
PYTHONPATH=eval python eval/exp3_figures.py

# 1
PYTHONPATH=eval python eval/exp1_conformance.py --data .eval/data/tcia --python <ts-python>

# 2
PYTHONPATH=eval <ts-python> eval/exp2_fidelity.py --probes \
    --data-root .eval/data/tcia --python <ts-python> --determinism --resume
PYTHONPATH=eval <ts-python> eval/exp2_hygiene.py \
    --ground-truth <ground_truth dir> --python <ts-python>
PYTHONPATH=eval <ts-python> eval/exp2_figures.py
PYTHONPATH=eval python eval/exp2_tables.py

# 4
PYTHONPATH=eval python eval/exp4_session.py \
    --slices 6 --series 3 --encode-reps 5 --prompts 12 --decode-reps 3

# 5 (needs a packaged build from scripts/package_app.sh)
PYTHONPATH=eval python eval/exp5_deployability.py \
    --app OpenDicomViewer-Annotate.app --out eval/results
```

Each script appends to its JSONL and resumes by case id; delete the file to
start over. `--summary-only` on the exp3 scripts rewrites the CSVs from the
JSONL without measuring anything. Every script's `--help` lists its options.

## Reading the results

- Memory is recorded in decimal gigabytes (10^9 bytes). Manifest `ram_gb` is
  read by the arbiter as GiB (2^30 bytes); convert before comparing (see
  `PLUGIN_PROTOCOL.md`, invariant 4).
- August 2026 files come from a sandbox with no visible GPU and no sockets;
  their timings are CPU-only upper bounds. `exp3_totalseg_lowmem.*` is a native
  October 2026 run. `docs/EVALUATION.md` §1 explains which figures are
  substitution-free.
- Paths in the recorded results are repository-relative or `~`-relative.
