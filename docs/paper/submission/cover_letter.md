# Cover letter

<!-- CONFIRM: addressee, date, corresponding author block. -->

Dear Editors,

We submit for your consideration the manuscript "Hosting heterogeneous on-device AI models
in an open-source DICOM viewer: one plugin contract and the case for auditing declared
resources" as an Original Research article.

Clinical interest in running AI models inside the viewer is now ahead of the engineering
that would make it routine. The two prevailing options are to send images to a remote
inference service, or to write one bespoke integration per model. We describe a third: a
single declarative contract under which four models that share no execution
axis — a vision-language model, two promptable segmenters and a whole-body
segmenter — run locally on a consumer Mac, with no per-model code in the viewer and no
image leaving the device.

The result we think matters most to this journal's readers is not the architecture but
what evaluating it showed. The host admits work against the memory a plugin declares for
itself. Our arbiter was correct against its specification in all 38 scenarios tested, and
would nevertheless have admitted a segmentation job larger than the target machine,
because one plugin's declared figure was between 5.5 and 6.1 times below its measured
peak. The corrected figure was itself too low until the measurement counted the model's
worker processes rather than one process. Nor was it an isolated case: a second plugin's
declared memory was also low, and that plugin's own health report agreed with the
declaration rather than with the measurement. Policy correctness is not safety when the
policy's inputs are self-declared; a host that arbitrates local models must audit those
declarations against measurement of the plugin as it actually runs. We report this, and
three other defect classes that code review had passed, alongside the results that passed.

We also report what we could not establish. We make no claim about the accuracy or
clinical utility of any integrated model, and no output of the software was validated
clinically; the models are used unmodified and their accuracy is reported in their
original publications. Segmentation output is written as standard DICOM Segmentation
objects, which an independent reference implementation (dcmqi) decoded losslessly for
30 of 30 structures, but the exported segments carry a generic anatomical code, which we
report as an open interoperability defect rather than a solved problem.

All evaluation data are public and de-identified, drawn from The Cancer Imaging Archive
and the TotalSegmentator reference release, with series pinned by SeriesInstanceUID so the
evaluation can be reproduced exactly. The software is open source under the MIT licence.

This manuscript is original, is not under consideration elsewhere, and all authors have
approved the submission. It builds on our previously published viewer (reference 17 in the
manuscript), which contributed the rendering and DICOM handling and a single fixed
single-model integration; the plugin layer, the execution models, the arbiter and the
entire evaluation reported here are new work and do not overlap with that publication.

<!-- CONFIRM before sending:
 - all authors have approved (assert only once true)
 - preferred/opposed reviewers, if the journal invites them
 - Zenodo DOI for the tagged release
 - competing-interest and funding statements consistent with the manuscript -->

Yours sincerely,

<!-- CONFIRM: corresponding author name, affiliation, email -->
