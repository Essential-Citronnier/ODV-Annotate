# CMPB submission checklist — ODV-Annotate plugin-layer manuscript

Generated 2026-10-18 from `docs/paper/manuscript.md` and `docs/paper/references.md`.
Every measured value below was computed from the files, not estimated. Re-run the
measurement cell after any edit pass; a number written here goes stale on the next edit.

## A. Measured, verified

| Item | Measured | Requirement | Status |
|---|---|---|---|
| Abstract | 247 words (incl. 6 structured-heading words) | <= 250 (third-party summary; see §D) | pass |
| Abstract structure | Background and Objective / Methods / Results / Conclusions | CMPB structured abstract | pass |
| Highlights | 5 bullets, 80, 70, 74, 79, 65 characters | 3–5 bullets, <= 85 chars | pass |
| Keywords | 6 | 1–7 | pass |
| Body (Introduction to Conclusions, incl. tables and legends) | 5397 words | no stated hard limit | see §C |
| Tables | 4 | — | see §C |
| Figures | 5 (Fig. 5 not yet produced) | — | see §B |
| References | 42, all cited, numbered by first appearance | Elsevier numbered | pass |
| Citation numbering | strictly ascending by first appearance, no gaps, none uncited | Vancouver | pass |
| Cross-references | every Table/Figure cited has a legend; every legend is cited | — | pass |
| Reference metadata | all 42 resolved from Crossref or the arXiv API | — | pass |

## B. Blocking — cannot submit until resolved

1. **E6 (end-to-end latency) not run.** §3.6 is a placeholder, Figure 5 does not exist, the
   E6 row of Table 2 is a TODO, and the Abstract carries `TODO(E6)`. Scripts and all four
   plugin environments with weights are present (`eval/exp6_latency.py`; 13.5 GB under
   `.eval/plugin-envs/`). A second 16 GB Apple Silicon machine is still unconfirmed.
2. **E7 (prompt-driven and VLM plugins) not run.** §3.7 is a placeholder.
3. **Two of four models have no inference evidence.** Table 4 records SAM 3 and Gemma 4 E4B
   as protocol-conformance only, and §3.3 records that their memory peaks were never
   measured — in a paper arguing that declarations must be audited. E6 should record peak
   memory for both, not only latency. SAM 3 weights are now present locally, so the
   "gated weights unavailable" reason in Table 4 is out of date and must be restated.
4. **Author-supplied front matter.** Affiliations, ORCID iDs, corresponding-author address,
   CRediT roles, competing-interest statement, funding statement, generative-AI
   declaration. Author list settled at two; co-authors of reference 17 should be informed.
5. **Zenodo DOI.** No tagged release archived; the code-availability statement still
   carries a CONFIRM.

## C. Recommended before submission

- **Display items.** 4 tables + 5 figures is high for a full-length article. The draft's own
  note to move Figures 3 and 4 to supplementary material is sound and would also reduce the
  body count, since the legends are counted above.
- **Body length.** 5397 words is long for CMPB in practice. §2 (Methods) is the
  natural donor; a Supplementary Methods file can carry the protocol detail with a pointer
  left at each excision.
- **Graphical abstract.** Encouraged by Elsevier, not present. Figure 1 would adapt.
- **Title.** Three candidates are retained in the title-page comment; the choice is the
  authors'.

## D. Could not be verified here — check on the publisher's page

`https://www.sciencedirect.com/journal/computer-methods-and-programs-in-biomedicine/publish/guide-for-authors`
returns HTTP 403 to automated clients even with the domain allowlisted, so the values below
come from third-party author-guide summaries, not from Elsevier. Where the publisher text
differs, the publisher text wins.

- [ ] Abstract word limit (assumed 250; the manuscript is at 247, which also clears 300)
- [ ] Highlights: permitted number of bullets and character limit (assumed 3–5 and 85)
- [ ] Keyword count (assumed 1–7; manuscript has 6)
- [ ] Article type and any main-text length limit
- [ ] Display-item allowance, and whether items charge against a word count
- [ ] Reference style details, in particular the author-truncation rule (used here: six, then "et al.")
- [ ] Running-title character limit (manuscript running title is 58 characters)
- [ ] Required wording for the generative-AI declaration and its position in the file

## E. Reference-integrity notes

- Two DOIs tried during reference expansion resolved to unrelated articles and were
  replaced after checking the returned titles: XNAT (now 10.1385/NI:5:1:11) and the DICOM
  standard introduction (now 10.1007/s003300101100). Both corrected DOIs were re-queried
  against Crossref and returned the expected titles.
- Entries still carrying a CONFIRM in `references.md`, in the renumbered 42-entry list:
  9 (OHIF subtitle truncated by Crossref), 17 (volume and pages not yet assigned,
  online-first), 18 (article-number convention), 19 and 20 (whether to cite the
  proceedings versions of SAM 2 and SAM 3), 27 (MLX version from the Gemma plugin lock),
  33 (LNCS volume), 36 (DICOM edition year and section anchor).
- Reference 21 (Gemma 3 technical report) is cited alongside reference 22 (Gemma 4 model
  card) because no Gemma 4 technical report exists. The text does not claim otherwise.

## F. Package contents

| File | Status |
|---|---|
| `manuscript.md` | revised 2026-10-18; 18 TODO and 19 CONFIRM markers remain |
| `references.md` | 42 entries, rebuilt and renumbered 2026-10-18 |
| `submission/cover_letter.md` | drafted; addressee and sign-off to confirm |
| `submission/highlights.md` | 5 bullets, measured lengths recorded |
| `submission/checklist.md` | this file |
| `REVIEW_2026-10-18.md` | the review these revisions respond to |
| Figures 1–4 | exist (`docs/figures/`, `eval/figures/`) |
| Figure 5 | not produced — depends on E6 |
| Supplementary methods | not written |
| Graphical abstract | not produced |
