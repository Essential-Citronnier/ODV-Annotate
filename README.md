<p align="center">
  <img src="docs/icon.png" alt="OpenDicomViewer-Annotate" width="128">
</p>

<h1 align="center">OpenDicomViewer-Annotate</h1>

<p align="center">
  <strong>AI-powered DICOM annotation on your Mac — fully local, fully private.</strong><br>
  Built on <a href="https://github.com/jnheo-md/open-dicom-viewer">OpenDicomViewer</a>, enhanced with <strong>Gemma 4 E4B</strong> running on Apple Silicon via MLX.<br>
  No cloud. No uploads. Your medical images never leave your machine.
</p>

<p align="center">
  <a href="https://github.com/Essential-Citronnier/ODV-Annotate/releases/download/v1.2.1/OpenDicomViewer-Annotate.dmg">Download DMG</a> &middot;
  <a href="https://github.com/Essential-Citronnier/ODV-Annotate/releases/tag/v1.2.1">Releases</a>
</p>

![Screenshot](screenshot1.png)

![AI Annotation](screenshot2.png)

## What is OpenDicomViewer-Annotate?

OpenDicomViewer-Annotate extends the open-source [OpenDicomViewer](https://github.com/jnheo-md/open-dicom-viewer) with **on-device AI annotation** powered by Google's **Gemma 4 E4B** vision-language model. The AI runs entirely on your Mac through [MLX](https://github.com/ml-explore/mlx) — Apple's machine learning framework optimized for Apple Silicon.

This means you can analyze DICOM images, detect anatomical structures, identify potential abnormalities, and get natural language descriptions of regions of interest — all without sending a single byte to the cloud.

## Key Features

### AI Annotation with Gemma 4 E4B

| Feature | Description |
|---------|-------------|
| **Analyze Image** | Full image analysis with anatomical structure detection and bounding boxes |
| **Describe ROI** | Select any region and get a natural language description from the AI |
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

Download the latest `.dmg` from [Releases](../../releases), open it, and drag **OpenDicomViewer-Annotate** to your Applications folder.

> The app is signed and notarized — no Gatekeeper warnings.

### First-Run AI Setup

On first launch, the app automatically:

1. Extracts the bundled Python 3.11 runtime
2. Creates an isolated virtual environment
3. Installs MLX and dependencies
4. Downloads the Gemma 4 E4B model (~4.5GB, one-time)

After setup, the AI server starts on `http://127.0.0.1:8741`. You can also control it from the **AI** menu.

### System Requirements

- **Apple Silicon Mac** (M1 Pro or better recommended)
- **macOS 14.0+** (Sonoma)
- **16GB+ RAM** recommended (model uses ~4-5GB)
- **5GB+ free disk space** for the AI model

> No Python installation required — a standalone Python runtime is bundled with the app.

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

## Releases

### [v1.2.1](https://github.com/Essential-Citronnier/ODV-Annotate/releases/tag/v1.2.1) — 2025-04-07

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

> Python packages (MLX, mlx-vlm, FastAPI) and the Gemma 4 E4B model are downloaded on first launch into `~/Library/Application Support/OpenDicomViewer/`.

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

Every plugin runs on this machine. The only data that crosses the network is
model weights, downloaded from the sources the manifest names; images, DICOM
metadata, and results never leave the computer. The manifest ships inside the
application, so the set of installable plugins is fixed at build time rather
than fetched at runtime, and each plugin gets its own virtualenv.

### Available plugins

| Plugin | Execution | Produces | Weights | Licence |
|---|---|---|---|---|
| Gemma 4 E4B (MLX) | resident-server | text, boxes | 4.5 GB | Apache-2.0 |
| SAM 2 | session | 2D masks | 0.2 GB | Apache-2.0 |
| SAM 3 | session | 2D masks | 3.4 GB | SAM Licence — accept terms, place checkpoint |
| TotalSegmentator (total) | one-shot | DICOM SEG, volumes | 0.2 GB | Apache-2.0 / CC BY 4.0 |
| TotalSegmentator (heart, high-res) | one-shot | DICOM SEG, volumes | 0.2 GB | free academic licence number |

Open the store from **AI ▸ Plugin Store**, or from the sidebar. Tasks whose
weights require a licence show what is needed and where to obtain it; the
application never transmits your credentials to the licensing site.

Memory is arbitrated from the declared figures: on a 16 GB machine, starting a
segmentation stops a resident language model for the duration and restarts it
afterwards, rather than letting both compete.

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
| `G` | AI Analyze |
| `Cmd+Shift+G` | Analyze Image (menu) |

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
- [Gemma 4](https://deepmind.google/models/gemma/gemma-4/) — Apache 2.0 License
- DCMTK — BSD License
- OpenJPEG — BSD-2-Clause License

See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for full license texts.

## Dependencies

| Library | Version | Purpose | License |
|---------|---------|---------|---------|
| [DCMTK](https://dicom.offis.de/dcmtk.php.en) | 3.6.8 | DICOM image decoding, JPEG/JPEG-LS decompression | BSD |
| [OpenJPEG](https://www.openjpeg.org/) | 2.5.0 | JPEG 2000 decompression | BSD-2-Clause |
| [MLX](https://github.com/ml-explore/mlx) | latest | Apple Silicon ML framework for local inference | MIT |
| [mlx-vlm](https://github.com/Blaizzy/mlx-vlm) | latest | Vision-language model inference on MLX | MIT |
| [Gemma 4 E4B](https://huggingface.co/mlx-community/gemma-4-E4B-it-4bit) | 4-bit | Vision-language model for DICOM annotation | Apache 2.0 |

DCMTK and OpenJPEG are included as pre-built static libraries (`libs/`). Python 3.11, MLX, and Gemma are bundled with or automatically downloaded by the app.
