# Third-Party Licenses

OpenDicomViewer includes the following third-party libraries as pre-built
static libraries in the `libs/` directory, and bundles the CPython runtime
described below. This file is copied into the app as
`Contents/Resources/THIRD_PARTY_LICENSES.md`.

---

## DCMTK — DICOM Toolkit

- **Version**: 3.6.8
- **Website**: https://dicom.offis.de/dcmtk.php.en
- **Source**: https://github.com/DCMTK/dcmtk
- **License**: BSD 3-Clause

```
Copyright (C) 1994-2025, OFFIS e.V.
All rights reserved.

This software and supporting documentation are maintained by

  OFFIS e.V.
  R&D Division Health
  Escherweg 2
  26121 Oldenburg, Germany

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

- Neither the name of OFFIS nor the names of its contributors may be used to
  endorse or promote products derived from this software without specific
  prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

DCMTK also includes code from third-party projects under their own permissive
licenses (Independent JPEG Group, CharLS, zlib, among others). See the
[DCMTK COPYRIGHT file](https://github.com/DCMTK/dcmtk/blob/master/COPYRIGHT)
for complete details.

---

## OpenJPEG

- **Version**: 2.5.0
- **Website**: https://www.openjpeg.org/
- **Source**: https://github.com/uclouvain/openjpeg
- **License**: BSD 2-Clause

```
Copyright (c) 2002-2014, Universite catholique de Louvain (UCL), Belgium
Copyright (c) 2002-2014, Professor Benoit Macq
Copyright (c) 2003-2014, Antonin Descampe
Copyright (c) 2003-2009, Francois-Olivier Devaux
Copyright (c) 2005, Herve Drolon, FreeImage Team
Copyright (c) 2002-2003, Yannick Verschueren
Copyright (c) 2001-2003, David Janssens
Copyright (c) 2011-2012, Centre National d'Etudes Spatiales (CNES), France
Copyright (c) 2012, CS Systemes d'Information, France
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

---

## Hugging Face Transformers — SAM 3 checkpoint key mapping

- **Used in**: `plugins/sam3/checkpoint_convert.py` (the key-mapping tables and
  the `adapt_internal_ckpt`, `replace_keys`, `convert_old_keys_to_new_keys`
  and `split_qkv` functions are vendored from
  `src/transformers/models/sam3_video/convert_sam3_video_to_hf.py`, which is
  not shipped in the transformers wheel)
- **Source**: https://github.com/huggingface/transformers
- **License**: Apache License 2.0

```
Copyright 2025 The Meta AI Authors and The HuggingFace Inc. team. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

---

## CPython (python-build-standalone) — bundled Python runtime

- **Version**: CPython 3.11.17, python-build-standalone release `20261013`
  (`cpython-3.11.17+20261013-aarch64-apple-darwin-install_only.tar.gz`,
  SHA-256 `d81d757a9785850393cd695a9a686c765a6370fbdc83738589ef2ecd3e5c44b3`)
- **Location in the app**: `Contents/Resources/python/`
- **Source**: https://github.com/python/cpython,
  https://github.com/astral-sh/python-build-standalone
- **License**: Python Software Foundation License Version 2 (CPython);
  BSD 3-Clause (python-build-standalone build scripts). The full CPython
  license text, including the licenses of code incorporated into CPython, is
  shipped as `Contents/Resources/python/lib/python3.11/LICENSE.txt`, and at
  https://docs.python.org/3.11/license.html.

python-build-standalone links the following libraries into the runtime. They
are distributed under their own licenses:

| Library | Version in this build | License |
|---|---|---|
| OpenSSL | 3.5.9 | Apache License 2.0 |
| SQLite | 3.53.1 | Public domain |
| libffi | (statically linked; version not exposed) | MIT |
| XZ Utils (liblzma) | 5.8.4 | 0BSD / public domain (liblzma) |
| bzip2 (libbz2) | 1.0.8 | bzip2 license (BSD-style) |
| Expat | 2.9.0 | MIT |
| mpdecimal (libmpdec) | 4.0.0 | BSD 2-Clause |
| Tcl / Tk (incl. Itcl, Thread) | 9.0 | Tcl/Tk license (BSD-style) |
| pip, setuptools (site-packages) | 26.2.1, 84.0.0 | MIT |

On macOS the runtime uses the operating system's zlib, ncurses and libedit
(`/usr/lib`) rather than bundling them, so they are not redistributed. The
`tkinter`, `idlelib`, `turtledemo`, `lib2to3` and `test` packages are removed
from the bundle; the Tcl/Tk shared libraries remain. See the
[python-build-standalone documentation](https://gregoryszorc.com/docs/python-build-standalone/main/running.html#licensing)
for the licensing of each component.

---

## Gemma model weights — notice

The app does **not** redistribute Gemma model weights: the DMG contains none.
When the user enables local AI, or installs the Gemma plugin, the app
downloads `mlx-community/gemma-4-E4B-it-4bit` (revision
`475b9088d29754a3379866cf5aeb6b41acd313c2`), a 4-bit MLX conversion of
Google's `google/gemma-4-E4B-it`, from Hugging Face on the user's behalf.

Google publishes Gemma 4 under the Apache License 2.0
(https://ai.google.dev/gemma/docs/gemma_4_license). Earlier Gemma generations
are provided under the Gemma Terms of Use (https://ai.google.dev/gemma/terms)
and the Gemma Prohibited Use Policy
(https://ai.google.dev/gemma/prohibited_use_policy). The user is responsible
for complying with the terms stated on the model card of the weights they
download. Gemma is a trademark of Google LLC.

The SAM 2 (Apache 2.0), SAM 3 (SAM License, Meta) and TotalSegmentator
(Apache 2.0 code, CC BY 4.0 weights; some tasks require a free academic
licence) weights are likewise downloaded or placed by the user from their
publishers, under those publishers' terms, and are not included in the DMG.
