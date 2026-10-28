# CMPB submission checklist — ODV-Annotate plugin-layer manuscript

Generated 2026-10-18, updated 2026-10-27, from `docs/paper/manuscript.md` and `docs/paper/references.md`.
Every measured value below was computed from the files, not estimated. Re-run the
measurement cell after any edit pass; a number written here goes stale on the next edit.

## A. Measured, verified

| Item | Measured | Requirement | Status |
|---|---|---|---|
| Abstract | 247 words (incl. structured-heading words) | <= 350 (Elsevier guide copy, 2026-10-28) | pass |
| Abstract structure | Background and Objectives / Methods / Results / Conclusions | CMPB structured abstract | pass |
| Highlights | 5 bullets, 80, 70, 79, 79, 65 characters | 3–5 bullets, <= 85 chars | pass |
| Keywords | 6 | 3–6 | pass |
| Body (Introduction to Conclusions) | 3,734 words of prose + 625 in tables (2026-10-28) | should not normally exceed 3,500 (excl. abstract) | near; detail moved to supplementary.md |
| Tables | 4 | — | see §C |
| Figures | 3 main + 2 supplementary (former Figs. 3–4) | no stated limit | pass |
| References | 43 of max 50, all cited, numbered by first appearance | Elsevier numbered | pass |
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
5. Code archived: GitHub release v2.0.1-cmpb (commit 68e36b1), Zenodo
   https://doi.org/10.5281/zenodo.23734091 (concept DOI 10.5281/zenodo.23699123), cited as [43].
6. Gemma 4 E4B declaration raised 5.0 -> 8.0 (plugin manifest and built-in server) after
   E7 measured 7.72 GiB; regression tests added. v2.0.1-cmpb includes this change and
   supersedes v2.0.0-cmpb (10.5281/zenodo.23699124), which predates it.

## C. Recommended before submission

- **Display items.** Done 2026-10-28: Figures 3 and 4 moved to the supplement.
- **Body length.** Done 2026-10-28: cut from 6,486 to about 3,730 words of prose; protocol
  and result detail moved verbatim to `supplementary.md`, with a pointer at each excision.
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
| Figures 1–3 | exist; Fig. 3 is `eval/figures/exp6_latency.png` |
| Figures S1–S2 | former Figs. 3–4, embedded in Supplementary_Material.docx |
| `supplementary.md` | Sections S1–S2, built to Supplementary_Material.docx |
| Graphical abstract | not produced |
