<p align="center">
  <img src="docs/icon.png" alt="OpenDicomViewer-Annotate" width="128">
</p>

<h1 align="center">OpenDicomViewer-Annotate</h1>

<p align="center">
  <strong>AI-powered DICOM annotation on your Mac — fully local, fully private.</strong><br>
  Built on <a href="https://github.com/jnheo-md/open-dicom-viewer">OpenDicomViewer</a>, enhanced with <strong>Gemma 4 E4B</strong> running on Apple Silicon via MLX.<br>
  No cloud inference. Your images, DICOM metadata and AI results stay on your Mac
  (see <a href="#privacy-and-network-use">Privacy and network use</a> for the downloads and update check that do use the network).
</p>

<p align="center">
  <a href="https://github.com/Essential-Citronnier/ODV-Annotate/releases/download/v2.0.0/OpenDicomViewer-Annotate.dmg">Download DMG (v2.0.0)</a> &middot;
  <a href="https://github.com/Essential-Citronnier/ODV-Annotate/releases/tag/v2.0.0">Release notes</a><br>
  <sub>Apple Silicon only (M1 or later), macOS 14+</sub>
</p>

![Screenshot](screenshot1.png)

![AI Annotation](screenshot2.png)

## What is OpenDicomViewer-Annotate?

OpenDicomViewer-Annotate extends the open-source [OpenDicomViewer](https://github.com/jnheo-md/open-dicom-viewer) with **on-device AI annotation** powered by Google's **Gemma 4 E4B** vision-language model. The AI runs entirely on your Mac through [MLX](https://github.com/ml-explore/mlx) — Apple's machine learning framework optimized for Apple Silicon.

This means you can analyze DICOM images, detect anatomical structures, identify potential abnormalities, and get natural language descriptions of regions of interest — all without sending your images to the cloud.

## Key Features

### AI Annotation with Gemma 4 E4B

| Feature | Description |
|---------|-------------|
| **Analyze Image** | Full image analysis with anatomical structure detection and bounding boxes |
| **Describe ROI** | Draw a region with ROI Stats (S), then choose AI → Describe ROI for a natural language description of it |
| **Detect Abnormalities** | Highlight potential abnormalities with severity ratings and confidence scores |

**Four analysis modes** to fit your workflow:

- **Clinical** — Only clinically significant findings (max 3 boxes)
- **Detailed Anatomy** — All visible anatomical structures (min 3 boxes)
- **Abnormality Only** — Pathological findings only (max 2 boxes)
- **Educational** — Labeled anatomy for learning (3-5 structures)

AI annotations display as color-coded bounding boxes overlaid on DICOM images with confidence badges. Toggle visibility or clear them per panel at any time.

### Full-Featured DICOM Viewer

All the capabilities of OpenDicomViewer are included:

- **Fast DICOM Parsing** — Pure-Swift parser with incremental scanning; first image displays instantly
- **Multi-Panel Layouts** — Single, side-by-side, stacked, and quad arrangements with drag-and-drop
- **MPR & Volume Rendering** — Sagittal, coronal, and MIP views via Metal compute shaders
- **Window/Level** — Right-click drag, auto W/L, ROI-based W/L with live histogram
- **Measurement Tools** — Ruler, angle, and ROI statistics with real-time preview lines
- **Synchronized Scrolling & Zoom** — Link panels by anatomical z-location matching
- **Cross-Reference Lines** — Slice intersection overlays across panels
- **DICOM Tag Inspector** — Browse all metadata tags for the active image
- **JPEG 2000 Support** — Compressed transfer syntaxes via DCMTK + OpenJPEG

## Quick Start

### Download & Run

Download [`OpenDicomViewer-Annotate.dmg`](https://github.com/Essential-Citronnier/ODV-Annotate/releases/download/v2.0.0/OpenDicomViewer-Annotate.dmg)
from the [v2.0.0 release](https://github.com/Essential-Citronnier/ODV-Annotate/releases/tag/v2.0.0) (**Apple Silicon only (M1 or later), macOS 14+**),
open it, and drag **OpenDicomViewer-Annotate** to your Applications folder.

> The app and the DMG are signed with a Developer ID and notarized by Apple.
> macOS still asks for confirmation the first time you open an app downloaded
> from the Internet.

### First-Run AI Setup

Nothing is downloaded at launch. The first time you use AI (`⌘⇧G` for
**AI ▸ Analyze Image**, `⌘G` while the viewer has focus, the **AI Analyze** tool
selected with `G` and a click on the image, or any item in the **AI** menu), the app asks once whether to enable
local AI. If you agree, it:

1. Creates an isolated virtual environment from the CPython 3.11.17 runtime that
   ships inside the app (it is already unpacked; there is nothing to extract)
   in `~/Library/Application Support/OpenDicomViewer/mlx-server/.venv`
2. Installs MLX and the other pinned Python packages from PyPI (~1.5 GB; the
   full lock is `mlx-server/requirements.txt`: mlx 0.32.0, mlx-vlm 0.6.5,
   transformers 5.14.1, ...)
3. Starts the AI server on a free loopback port (`127.0.0.1`), which downloads the Gemma 4
   E4B model (`mlx-community/gemma-4-E4B-it-4bit` at revision `475b9088…`,
   ~5.2 GB, one-time) from Hugging Face into the Hugging Face cache,
   `~/.cache/huggingface/hub` -- unless the Gemma plugin already installed the
   same pinned model, in which case the server loads that copy and downloads
   nothing (see "Where the model lives" below)
4. Runs the analysis you asked for as soon as the model is loaded

Expect 10–30 minutes on a first run, depending on your connection; the AI
inspector shows download progress and the server log, and you can keep working
meanwhile. Later launches only load the model (a few seconds). The system
proxy configured in System Settings is used for the downloads. You can also
start, restart or stop the server from the **AI** menu.

### System Requirements

- **Apple Silicon only (M1 or later)**; Intel Macs are not supported
- **macOS 14.0+** (Sonoma)
- **RAM:** 8 GB runs the built-in AI; 16 GB recommended (see the table below)
- **~8 GB free disk space** for a first AI setup: ~1.5 GB of Python packages
  plus the ~5.2 GB model, with headroom for the download

> No Python installation required — a standalone CPython 3.11.17 runtime
> (python-build-standalone `20261013`) is bundled with the app.

#### Memory per engine

Declared memory is the figure each plugin states in the manifest
(`Sources/OpenDicomViewer/Resources/plugins.json`). The Plugin Store shows a
plugin as unavailable when its declared memory exceeds half of the Mac's RAM
(three quarters for one-shot jobs such as TotalSegmentator), which is what sets
the minimums below.

| Engine | Declared memory | Minimum Mac RAM | Recommended |
|---|---|---|---|
| Built-in Gemma 4 E4B (AI menu) | ~5 GB while loaded | 8 GB: works, but close other apps; the app warns on Macs with less than 12 GiB | 16 GB |
| Gemma 4 E4B plugin | 5 GB | 16 GB (on an 8 GB Mac use the built-in engine instead) | 16 GB |
| SAM 2 plugin | 3 GB | 8 GB | 16 GB |
| SAM 3 plugin | 6 GB | 16 GB | 16 GB |
| TotalSegmentator plugin | 23.5 GB | 32 GB | 32 GB or more |

### For Developers

```bash
# Clone and build
git clone https://github.com/Essential-Citronnier/ODV-Annotate.git
cd ODV-Annotate

# Build release and package as .app bundle + DMG
./scripts/package_app.sh

# Notarize for distribution (requires Apple Developer ID)
./scripts/package_app.sh --notarize

# Install (optional)
cp -r OpenDicomViewer-Annotate.app /Applications/
```

To run the test suite:

```bash
swift test
```

To rebuild native dependencies from source:

```bash
./scripts/setup_native_deps.sh
```

## Privacy and network use

All AI inference runs on your Mac; images, DICOM metadata and results are never
uploaded. The app uses the network only for:

- **One-time downloads you agree to.** Enabling local AI, or installing a plugin
  from the Plugin Store, downloads pinned Python packages from PyPI and model
  weights from Hugging Face (TotalSegmentator fetches its weights from the
  TotalSegmentator project's release servers). Nothing is downloaded until you
  consent, and the system proxy is used.
- **The update check.** At launch, at most once every 24 hours, and whenever
  you choose **Check for Updates...**, the app requests
  `https://api.github.com/repos/Essential-Citronnier/ODV-Annotate/releases/latest`
  to compare the latest release's version with its own. It sends no data about
  you or your images beyond what any HTTPS request carries (your IP address);
  if a newer version exists it offers to open the download page, and never
  downloads or installs anything by itself.

After setup, AI analysis works offline.

## Releases

### [v2.0.0](https://github.com/Essential-Citronnier/ODV-Annotate/releases/tag/v2.0.0)

**Plugin system and built-in local Gemma 4 E4B.** Download:
[`OpenDicomViewer-Annotate.dmg`](https://github.com/Essential-Citronnier/ODV-Annotate/releases/download/v2.0.0/OpenDicomViewer-Annotate.dmg)
(Apple Silicon only (M1 or later), macOS 14+).

| What's new | Details |
|------------|---------|
| **Plugin system** | AI models are plugins described by a manifest and a versioned protocol ([`PLUGIN_PROTOCOL.md`](PLUGIN_PROTOCOL.md)); three execution models (resident server, session, one-shot), each plugin in its own virtualenv with fully pinned requirements |
| **Plugin Store** | Gemma 4 E4B, SAM 2, SAM 3 and TotalSegmentator, installable from **AI ▸ Plugin Store** or the sidebar; licence gates for SAM 3 and TotalSegmentator's high-res tasks |
| **Built-in local Gemma 4 E4B** | `mlx-community/gemma-4-E4B-it-4bit` pinned to revision `475b9088…` on mlx 0.32.0 / mlx-vlm 0.6.5 / transformers 5.14.1; one copy on disk shared with the Gemma plugin |
| **Consent-gated setup** | Nothing is downloaded at launch; the first AI use asks once, checks disk space and architecture, and shows progress and the server log |
| **Segmentation** | Promptable 2D masks (SAM 2 / SAM 3, click or box) and whole-body CT segmentation written as binary DICOM SEG (TotalSegmentator) |
| **Memory arbitration** | Declared memory is arbitrated across the built-in server and plugins; a resident model is paused for a segmentation job rather than competing with it |
| **AI result safety** | Results are bound to the slice they were computed on; a research-use notice is shown before the first analysis |
| **Viewer** | DICOM detection by content, nested undefined-length sequences, multi-frame decoding by frame table (incl. JPEG 2000), RTSTRUCT/SEG overlay matching, MPR geometry and measurement fixes, modality-derived value units |
| **Packaging** | Bundled CPython 3.11.17, verified by SHA-256; the plugin adapters ship inside the app; the stdlib is precompiled before signing so the signature stays valid; app and DMG signed, notarized and stapled; the app opens DICOM files and folders from Finder |

**Binary contents (what's inside the DMG):**

```
OpenDicomViewer-Annotate.app/
├── Contents/MacOS/OpenDicomViewer       # Swift executable (arm64)
└── Contents/Resources/
    ├── AppIcon.icns
    ├── dicom.dic                         # DCMTK DICOM dictionary
    ├── LICENSE, THIRD_PARTY_LICENSES.md
    ├── plugins.json                      # Plugin Store manifest
    ├── plugins/                          # Plugin adapters (gemma, sam2, sam3, totalseg, _shared)
    ├── mlx-server/
    │   ├── server.py                     # FastAPI + mlx-vlm inference server
    │   └── requirements.txt              # Full lock
    └── python/                           # Bundled CPython 3.11.17 runtime
        └── bin/python3
```

> Python packages are installed on first AI use into `~/Library/Application Support/OpenDicomViewer/`; the Gemma 4 E4B model is downloaded into the Hugging Face cache, `~/.cache/huggingface/hub`. Model weights are not part of the DMG.

#### Where the model lives

There is one ~5.2 GB copy of Gemma 4 E4B (revision `475b9088…`) on disk,
whichever engine fetched it first:

| Installed first | Location | The other engine |
|-----------------|----------|------------------|
| Built-in AI server | `~/.cache/huggingface/hub/models--mlx-community--gemma-4-E4B-it-4bit/` (`HF_HOME` / `HF_HUB_CACHE` move it) | The Gemma plugin's installer hard-links those files into its weight directory instead of downloading |
| Gemma plugin (Plugin Store) | `~/Library/Application Support/OpenDicomViewer/plugins/gemma-4-e4b/weights/gemma-4-e4b-it-4bit/` | The built-in server loads that directory (`ODV_MODEL_DIR`) instead of downloading |

The built-in server uses the plugin's directory only when its
`.odv-download-complete` marker records the same pinned revision. Hard links
share their blocks, so removing either path (clearing the hub cache, or
removing the plugin) frees nothing until the other is removed too, and leaves
the other engine's copy intact. If the plugin is removed while the built-in
server has no hub-cache copy, the server downloads the model again on its next
start.

### [v1.2.1](https://github.com/Essential-Citronnier/ODV-Annotate/releases/tag/v1.2.1) — 2026-04-06

**Zero-dependency install.** Python 3.11 is now bundled inside the app — no Homebrew, Xcode CLT, or system Python required. Drag to Applications and launch.

| What's included | Details |
|-----------------|---------|
| **Bundled Python 3.11** | Standalone runtime (python-build-standalone), no system dependency |
| **Hardened Runtime** | Properly signed with entitlements for Python/MLX execution |
| **Pre-flight checks** | Architecture (Apple Silicon only) and disk space (~5 GB) verified before setup |
| **Auto first-run setup** | Venv creation, pip install, and server start happen automatically |
| **UpdateChecker** | In-app update notifications via GitHub Releases API |

**Binary contents (what's inside the DMG):**

```
OpenDicomViewer-Annotate.app/
├── Contents/MacOS/OpenDicomViewer       # Swift executable (arm64)
└── Contents/Resources/
    ├── AppIcon.icns
    ├── dicom.dic                         # DCMTK DICOM dictionary
    ├── mlx-server/
    │   ├── server.py                     # FastAPI + mlx-vlm inference server
    │   └── requirements.txt
    └── python/                           # Bundled Python 3.11 runtime (~51 MB)
        └── bin/python3
```

> Python packages (MLX, mlx-vlm, FastAPI) are installed on first AI use into `~/Library/Application Support/OpenDicomViewer/`; the Gemma 4 E4B model is downloaded into the Hugging Face cache, `~/.cache/huggingface/hub`.

### [v1.2.0](https://github.com/Essential-Citronnier/ODV-Annotate/releases/tag/v1.2.0)

Initial public release with AI annotation, MPR, and full DICOM viewer.

## How the AI Works

AI models are **plugins**. Each declares what it needs and what it produces in a
manifest, and the application supervises it accordingly — so adding a model does
not mean adding a code path to the viewer.

```
┌──────────────────────────────────────────────────────────────┐
│  SwiftUI application                                         │
│  viewer panels · plugin store · result router · arbiter      │
└──────────────────────────────┬───────────────────────────────┘
                               │  manifest + protocol v1
        ┌──────────────────────┼──────────────────────┐
        ▼                      ▼                      ▼
  resident-server           session                one-shot
  load once,             encode once,            run, write,
  query many             prompt many             exit
        │                      │                      │
   Gemma 4 E4B           SAM 2 · SAM 3         TotalSegmentator
   text + boxes            2D masks         DICOM SEG + volumes
```

Every plugin runs on this machine. What crosses the network is the plugin's
pinned Python packages (from PyPI) and its model weights (from the sources the
manifest names), each downloaded once when you install it, plus the app's
update check (see [Privacy and network use](#privacy-and-network-use)); images,
DICOM metadata, and results never leave the computer. The manifest ships inside the
application, so the set of installable plugins is fixed at build time rather
than fetched at runtime, and each plugin gets its own virtualenv.

### Available plugins

| Plugin | Execution | Produces | Weights | Licence |
|---|---|---|---|---|
| Gemma 4 E4B (MLX) | resident-server | text, boxes | 5.2 GB | Apache-2.0 |
| SAM 2 | session | 2D masks | 0.2 GB | Apache-2.0 |
| SAM 3 | session | 2D masks | 3.4 GB | SAM Licence — accept terms, place checkpoint |
| TotalSegmentator (total) | one-shot | DICOM SEG, volumes | 0.2 GB | Apache-2.0 / CC BY 4.0 |
| TotalSegmentator (heart, high-res) | one-shot | DICOM SEG, volumes | 0.2 GB | free academic licence number |

Open the store from **AI ▸ Plugin Store**, or from the sidebar. Tasks whose
weights require a licence show what is needed and where to obtain it; the
application never transmits your credentials to the licensing site.

Memory is arbitrated from the declared figures: on a 16 GB machine, starting a
segmentation stops a resident language model for the duration and restarts it
afterwards, rather than letting both compete. The built-in AI server counts
too, and it and the Gemma plugin never run at the same time (starting one stops
the other), so the model is never loaded twice. A plugin that declares more
memory than plugins may use on this Mac (half of it; three quarters for one-shot
jobs) is shown as unavailable in the store, before its download. Resident
plugins start on first use; there is no need to press Start first.

Writing a new adapter: [`PLUGIN_PROTOCOL.md`](PLUGIN_PROTOCOL.md) is the
contract, [`plugins/README.md`](plugins/README.md) is the how-to, and
[`docs/PLUGIN_ARCHITECTURE.md`](docs/PLUGIN_ARCHITECTURE.md) explains why the
design is shaped this way.

> **Disclaimer:** AI analysis is for **research and educational purposes only**. It must NOT be used as a clinical diagnosis tool.

## Keyboard Shortcuts

### Navigation

| Key | Action |
|-----|--------|
| `Up` / `Down` | Previous / next image in series |
| `Left` / `Right` | Previous / next series |
| `Scroll` | Navigate slices |
| `Page Up` / `Page Down` | Skip 10 images |
| `Home` / `End` | Jump to first / last image |
| `Tab` | Cycle active panel |
| `Double-click` | Toggle panel fullscreen |

### Layout

| Key | Action |
|-----|--------|
| `1` / `2` / `3` / `4` | Single / side-by-side / stacked / quad |
| `Cmd+Shift+M` | MPR layout |

### Tools

| Key | Tool |
|-----|------|
| `V` | Select (default pointer) |
| `P` | Pan |
| `W` | Window/Level |
| `Z` | Zoom |
| `O` | ROI Window/Level |
| `S` | ROI Statistics |
| `D` | Ruler (distance) |
| `N` | Angle |
| `E` | Eraser |
| `G` | AI Analyze tool (then click the image to analyze it) |
| `Cmd+Shift+G` | AI ▸ Analyze Image (menu) |
| `Cmd+G` | Analyze Image while the viewer has focus |

### Display

| Key | Action |
|-----|--------|
| `A` | Auto window/level |
| `I` | Invert image |
| `F` | Fit to window |
| `R` | Reset view (zoom, pan, W/L) |
| `H` | Flip horizontal |
| `]` or `.` | Rotate clockwise 90 |
| `[` or `,` | Rotate counter-clockwise 90 |

### Overlays & Multi-Panel

| Key | Action |
|-----|--------|
| `T` | Toggle DICOM tag inspector |
| `X` | Toggle cross-reference lines |
| `L` | Toggle synchronized scrolling & zoom |

### Mouse Actions

| Input | Action |
|-------|--------|
| Left-click | Activate panel / tool action |
| Right-drag | Adjust Window/Level |
| Scroll wheel | Navigate slices |
| Option/Ctrl + Left-drag | Pan (any tool) |
| Option/Ctrl + Scroll | Zoom in/out |
| Double-click | Toggle fullscreen panel |
| Drag from sidebar | Assign series to panel |
| Drag from Finder | Open DICOM file/folder |

## Architecture

```
Sources/
├── OpenDicomViewer/              # Main application target
│   ├── App.swift                     # App entry point, menu bar + AI commands
│   ├── ContentView.swift             # Root view: sidebar + detail split
│   ├── DICOMModel.swift              # Core model: loading, caching, AI triggers
│   ├── SimpleDICOM.swift             # Pure-Swift DICOM parser
│   ├── MultiPanelContainer.swift     # Multi-panel grid, overlays, AI annotation UI
│   ├── PanelState.swift              # Per-panel state incl. AI annotations
│   ├── AIService.swift               # HTTP client for Gemma 4 MLX server
│   ├── AIServerManager.swift         # MLX server lifecycle & first-run setup
│   ├── LayoutToolbar.swift           # Floating layout/link toolbar
│   ├── CrossReferenceOverlay.swift   # Slice intersection lines
│   ├── MPREngine.swift               # CPU-based multi-planar reconstruction
│   ├── MetalVolumeRenderer.swift     # GPU MIP/MinIP/Average via Metal
│   ├── VolumeData.swift              # 3D voxel buffer with affine transforms
│   ├── VolumeToolbar.swift           # MPR/MIP mode controls
│   ├── HelpView.swift                # In-app help viewer
│   ├── TagView.swift                 # DICOM tag list view
│   └── Extensions.swift              # Collection helpers
├── DCMTKWrapper/                 # Objective-C++ bridge to DCMTK
│   ├── DCMTKHelper.mm               # DCMTK + JPEG2000 decoding
│   └── include/DCMTKHelper.h
└── mlx-server/                   # Local Gemma 4 inference server
    ├── server.py                     # FastAPI + mlx-vlm inference
    ├── launch.sh                     # Setup & launch script
    └── requirements.txt              # Python dependencies
```

## Acknowledgments

This project is built on top of [OpenDicomViewer](https://github.com/jnheo-md/open-dicom-viewer) by [JoonNyung Heo, MD, PhD](https://jnheo.tistory.com/). The original viewer provides the foundation — fast DICOM parsing, multi-panel layouts, MPR, measurement tools, and more. AI annotation layer developed by [Daeseong Kim, MD](https://www.lemonaa.com/cv).

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.

- [OpenDicomViewer](https://github.com/jnheo-md/open-dicom-viewer) (original project) — MIT License
- [Gemma 4](https://deepmind.google/models/gemma/gemma-4/) — Apache 2.0 License (model weights; not included in the DMG)
- CPython 3.11.17 (python-build-standalone, bundled) — PSF License, with OpenSSL, SQLite, Tcl/Tk and other libraries under their own licences
- DCMTK — BSD License
- OpenJPEG — BSD-2-Clause License

See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for full license texts.

> **Gemma model terms.** The Gemma 4 E4B weights are not redistributed with
> this app: the app downloads them from Hugging Face
> ([`mlx-community/gemma-4-E4B-it-4bit`](https://huggingface.co/mlx-community/gemma-4-E4B-it-4bit),
> a 4-bit MLX conversion of Google's `google/gemma-4-E4B-it`) only after you
> agree. Google publishes Gemma 4 under the
> [Apache License 2.0](https://ai.google.dev/gemma/docs/gemma_4_license); earlier
> Gemma generations were published under the
> [Gemma Terms of Use](https://ai.google.dev/gemma/terms) and
> [Prohibited Use Policy](https://ai.google.dev/gemma/prohibited_use_policy). You
> are responsible for complying with the terms on the model card of the weights
> you download. SAM 2, SAM 3 and TotalSegmentator weights likewise come from
> their publishers under their own licences (see the plugin table above).

## Dependencies

| Library | Version | Purpose | License |
|---------|---------|---------|---------|
| [DCMTK](https://dicom.offis.de/dcmtk.php.en) | 3.6.8 | DICOM image decoding, JPEG/JPEG-LS decompression | BSD |
| [OpenJPEG](https://www.openjpeg.org/) | 2.5.0 | JPEG 2000 decompression | BSD-2-Clause |
| [CPython](https://www.python.org/) ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)) | 3.11.17 (build 20261013) | Bundled runtime for the AI server and plugins | PSF |
| [MLX](https://github.com/ml-explore/mlx) | 0.32.0 | Apple Silicon ML framework for local inference | MIT |
| [mlx-vlm](https://github.com/Blaizzy/mlx-vlm) | 0.6.5 | Vision-language model inference on MLX | MIT |
| [Transformers](https://github.com/huggingface/transformers) | 5.14.1 | Processor and tokenizer library used by mlx-vlm | Apache 2.0 |
| [Gemma 4 E4B](https://huggingface.co/mlx-community/gemma-4-E4B-it-4bit) | 4-bit, revision `475b9088d29754a3379866cf5aeb6b41acd313c2` | Vision-language model for DICOM annotation | Apache 2.0 |

DCMTK and OpenJPEG are included as pre-built static libraries (`libs/`). CPython is bundled in the app; MLX and the other Python packages (pinned exactly in `mlx-server/requirements.txt` and each plugin's `requirements.txt`) and the Gemma weights are downloaded on first use, after you agree.
