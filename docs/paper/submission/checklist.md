# CMPB submission checklist — ODV-Annotate plugin-layer manuscript

Generated 2026-10-18, updated 2026-10-27, from `docs/paper/manuscript.md` and `docs/paper/references.md`.
Every measured value below was computed from the files, not estimated. Re-run the
measurement cell after any edit pass; a number written here goes stale on the next edit.

## A. Measured, verified

| Item | Measured | Requirement | Status |
|---|---|---|---|
| Abstract | 247 words (incl. structured-heading words) | <= 250 (third-party summary; see §D) | pass |
| Abstract structure | Background and Objective / Methods / Results / Conclusions | CMPB structured abstract | pass |
| Highlights | 5 bullets, 80, 70, 79, 79, 65 characters | 3–5 bullets, <= 85 chars | pass |
| Keywords | 6 | 1–7 | pass |
| Body (Introduction to Conclusions, incl. tables and legends) | 5397 words | no stated hard limit | see §C |
| Tables | 4 | — | see §C |
| Figures | 5 | — | see §C |
| References | 43, all cited, numbered by first appearance | Elsevier numbered | pass |
| Citation numbering | strictly ascending by first appearance, no gaps, none uncited | Vancouver | pass |
| Cross-references | every Table/Figure cited has a legend; every legend is cited | — | pass |
| Reference metadata | all 43 resolved from Crossref, DataCite or the arXiv API | — | pass |

## B. Blocking — all resolved as of 2026-10-27

`python docs/paper/build_submission.py --check` reports 0 blockers.

1. E6 run on one machine (M5 Max, 128 GB); §3.6, Table 2 and Figure 5 filled. A second
   16 GB machine was not used; stated as a limitation.
2. E7 run; §3.7 filled.
3. Gemma 4 E4B memory and inference measured (§3.3, §3.6, §3.7). SAM 3 was not executed:
   its gated weights were never obtained (the 10-18 note that they were present was wrong);
   Table 4 and Limitations say so.
4. Front matter filled: sole author Daeseong Kim, two affiliations (Yonsei Cancer Center;
   MSKCC), corresponding author, CRediT, no competing interests, no funding. ORCID is
   entered in the submission system.
5. Code archived: GitHub release v2.0.0-cmpb (commit 73f18f8), Zenodo
   https://doi.org/10.5281/zenodo.23699124 (concept DOI 10.5281/zenodo.23699123), cited as [43].
6. Gemma 4 E4B declaration raised 5.0 -> 8.0 (plugin manifest and built-in server) after
   E7 measured 7.72 GiB; regression tests added. The archived v2.0.0-cmpb predates this
   change, so a new release is needed for the archive to match the paper.

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
