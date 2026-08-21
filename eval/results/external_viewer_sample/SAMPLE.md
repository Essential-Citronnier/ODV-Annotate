# External viewer sample

Produced by `eval/exp1_conformance.py --stages sample`. Load this with
`docs/EXTERNAL_VIEWER_CHECKLIST.md` open beside you and check what you see
against the expectations below.

| Field | Value |
|---|---|
| Case | `fixture/tcia_1556218467652708` |
| Source series UID | `61.7.155621846765270845579077864210007002978` |
| Source instances (as referenced by the SEG) | 411 |
| Segments | 5 |
| SEG frames | 1147 |
| SegmentationType | BINARY |
| FrameOfReferenceUID | `61.7.137788981391685674741566213823757932015` |
| z extent (mm) | -586.2 to -176.2 |
| Run notes | adapter-exporter, synthetic-masks |

## Expected segment labels

These are the names a viewer should show. If it shows `Segment_1`,
`Segment_2`, ... instead, that is check S3/O3 failing.

1. `aorta`
2. `liver`
3. `spleen`
4. `stomach`
5. `urinary_bladder`

## Expected anatomic placement

Use a structure with obvious cranio-caudal asymmetry to test for a z-flip
(check S6/O5). Scroll from the first slice to the last and confirm each
mask stays on the structure its label names.

## Caveat on the source instances

These are a *prepared* copy of a public TCIA series: the archive export
omits `SliceThickness`, which the adapter's SEG export requires, so the
value implied by the slice positions was written in. Nothing else was
changed. See `eval/results/exp1_findings.md`.
