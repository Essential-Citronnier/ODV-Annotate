# CMPB submission plan

**Target:** *Computer Methods and Programs in Biomedicine* (Elsevier). Submit through the
subscription (non-open-access) route, which has no APC.
**Fallback cascade:** JIIM → SoftwareX.
**Priority:** fast, low-cost acceptance. Keep the scope to what is needed. Make no
accuracy claims.

The manuscript skeleton is in `manuscript.md`. Results it already carries come from
experiments E1–E5 (`docs/EVALUATION.md`).

## Remaining experiments

### E6 · End-to-end latency on real hardware (required)
- Idle machine: no other heavy work; record the load average at the start of each case.
- Engines: Gemma 4 E4B (built-in and plugin), SAM 2, SAM 3, TotalSegmentator `total`
  and `total_lowmem`.
- Stages: cold start (process spawn + model load), warm inference, result routing and
  display. For one-shots, include the interpreter-startup gap.
- Machines: M5 Max / 128 GB (have). A 16 GB Apple Silicon Mac is needed as the second
  host. CONFIRM availability.
- Reps: ≥5 per engine × series. Report median (IQR).
- Rerun TotalSegmentator memory under the current torch lock (2.14.1; the October runs
  used 2.13.0).
- Script: `eval/exp6_latency.py` (run instructions in `eval/README.md`).
- Found while building it (2026-10-16): the eval plugin environments had been built
  with Homebrew Python 3.14 rather than the bundled 3.11, and had drifted 30–52
  packages from the locks. Under that drift, every Gemma request failed with a
  missing `jinja2`. `exp3_resources.py` now builds environments with the bundled
  interpreter, and exp6 refuses environments that differ from the lock. This is
  worth one sentence in the paper: earlier timings came from a stack users don't get.
- Dry-run observation: SAM 2 reports `ready` before its model is loaded. The first
  session open (4.4 s) and first click (2.0 s) carry the load; later clicks take
  13–21 ms. Report "open + first click" as the user-facing number, not spawn-to-ready.

### E7 · Prompt-driven and VLM plugins on public CT (required)
- SAM 2 / SAM 3: place a click at the centroid of each reference structure on its
  central slice, and compute Dice against the reference mask per structure. Frame the
  result as a coordinate-mapping check, not accuracy.
- Gemma 4 E4B: protocol round trip plus whether the returned boxes land inside the
  image and on the right anatomy. Report it descriptively.
- Optional: add 3–5 TCIA *Pancreas-CT* series to `PINNED_TCIA` (check the licence on
  the data card first).

### Housekeeping before writing Results
- Fix or report the SEG coded-anatomy warning (E1). Either is acceptable; it is cheaper
  to report it.
- Archive a tagged release on Zenodo for a citable code DOI.

## Journal requirements to confirm

Elsevier blocks automated access to the guide, so check these by hand at
<https://www.sciencedirect.com/journal/computer-methods-and-programs-in-biomedicine/publish/guide-for-authors>:

- [ ] Article type and length limit
- [ ] Structured abstract headings and word limit
- [ ] Highlights: number of bullets and character limit
- [ ] Keyword count
- [ ] Display-item allowance
- [ ] Reference style
- [ ] Generative-AI declaration wording
- [ ] Data/code availability statement format

## Timeline (indicative)

| Week | Work |
|---|---|
| 1–2 | E6 runs, both machines |
| 2–3 | E7 runs; figures regenerated |
| 3–4 | Results and Discussion drafted; references built from Crossref |
| 5 | Submission audit (counts, cross-references, stale values); cover letter; submit |
