# CMPB submission sheet (paste into Editorial Manager)

Generated 2026-10-28 from manuscript.md. Files to upload are in `submission/build/`
(rebuild with `.eval/harness-venv/bin/python docs/paper/build_submission.py`).

## Upload order and item types

| Item type in Editorial Manager | File |
|---|---|
| Cover Letter | cover_letter.docx |
| Highlights | highlights.docx |
| Manuscript (title page included, editable text, tables inline) | manuscript.docx |
| Figure | Fig1.png, Fig2.png, Fig3.png (300 dpi) |
| Supplementary Material | Supplementary_Material.docx |
| Declaration of Interest Statement | generate with Elsevier's declarations tool if asked: "no competing interests" |

## Metadata

**Article type:** Original Research (full-length article)

**Title:** Hosting heterogeneous on-device AI models in an open-source DICOM viewer: one plugin contract and the case for auditing declared resources

**Running title:** Auditing declared resources in a DICOM viewer plugin layer

**Author:** Daeseong Kim (sole and corresponding author)
ORCID 0009-0009-9944-9206, lemonaatree@gmail.com

**Affiliations:**
1. Division of Medical Oncology, Department of Internal Medicine, Yonsei Cancer Center,
   Yonsei University College of Medicine, 50-1 Yonsei-ro, Seodaemun-gu, Seoul 03722,
   Republic of Korea
2. David M. Rubenstein Center for Pancreas Cancer Research, Memorial Sloan Kettering
   Cancer Center, New York, NY, USA

**Keywords:** DICOM; medical image viewer; on-device inference; plugin architecture; segmentation; software evaluation

**Abstract (plain text):**

Background and Objectives: AI in an image viewer usually means one integration per
model, or a remote service. Models differ in process lifetime, memory, input and output,
dependencies and licence. We asked whether such models can run locally under one
declarative contract, and whether a host can safely admit them against declared
resources.

Methods: We extended an open-source macOS DICOM viewer with a plugin layer: a manifest
schema, three execution models (resident server, session, one-shot), routing by output
kind, licence gates and a memory arbiter, hosting Gemma 4 E4B, SAM 2, SAM 3 and
TotalSegmentator. We evaluated it on public CT from The Cancer Imaging Archive and the
TotalSegmentator dataset.

Results: An independent decoder read 30/30 exported structures losslessly, and routing
through the layer was lossless across 689 per-structure comparisons (minimum Dice
1.000000). The arbiter matched its specification in 38/38 scenarios, yet would have
admitted a job larger than the target machine: TotalSegmentator's declared memory was
5.5–6.1 times below its measured peak. The Gemma plugin peaked at 1.54 times its
declaration, unseen by its own health report; both were corrected. Evaluation found four defect
classes that code review had passed. A new process returned its first result in 1.9 s
(SAM 2) and 3.5 s (Gemma), no slower than the pre-plugin server. 

Conclusions: One contract can host heterogeneous local AI models, but an arbiter
correct against its specification is unsafe when its inputs are self-declared. Hosts
must audit declarations against measurement. The software is open source (MIT).

**Highlights:**

- One declarative contract hosts four local AI models under three execution models
- Evaluation on public CT found four defects that code review had missed
- Two of three audited plugins under-declared memory; hosts must audit, not trust
- Plugin output is DICOM SEG, decoded losslessly by an independent reference tool
- All inference stays on a consumer Mac; no image leaves the device

## Questionnaire answers

- Funding: none. "This research did not receive any specific grant from funding agencies
  in the public, commercial, or not-for-profit sectors."
- Competing interests: none.
- Ethics: public, de-identified data only; no IRB approval or consent required.
- Data availability: public data, series pinned in `eval/fetch_data.py`; code
  https://github.com/Essential-Citronnier/ODV-Annotate, archive
  https://doi.org/10.5281/zenodo.23734091.
- Generative AI: declared in the manuscript (Claude, Anthropic), before the references.
- Previously published/under consideration elsewhere: no. Builds on reference 17
  (OpenDicomViewer, J Imaging Inform Med 2026), disclosed in the cover letter.
- Open access: choose the subscription route (no APC).
- Suggested reviewers: optional; none prepared.
