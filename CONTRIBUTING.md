# Contributing to OpenDicomViewer

Thanks for your interest in contributing. This guide covers everything you need to get started.

## Development Environment

**Requirements:**
- macOS 14.0+ (Sonoma)
- Xcode 15+ or the Swift 5.9+ toolchain
- Apple Silicon Mac (arm64)

No additional package managers or dependency installs are needed. Pre-built static libraries for DCMTK and OpenJPEG ship in `libs/`.

## Building

```bash
# Clone the repo
git clone https://github.com/jnheo-md/open-dicom-viewer.git
cd open-dicom-viewer

# Debug build (fast, for iteration)
swift build

# Release build + .app bundle (what you actually run)
bash scripts/package_app.sh
```

**Important:** `swift build` produces a debug binary only. To run the app, always use `bash scripts/package_app.sh`, which builds a release binary, assembles the `.app` bundle with all required resources (icon, DCMTK dictionary, Info.plist), and creates a DMG. The resulting `OpenDicomViewer.app` can be opened directly or copied to `/Applications`.

To rebuild the native dependencies (DCMTK, OpenJPEG) from source:

```bash
bash scripts/setup_native_deps.sh
```

## Running Tests

```bash
swift test
```

Tests live in `Tests/OpenDicomViewerTests/` and cover the DICOM parser, MPR engine, volume data, and panel state logic.

## Code Structure

```
Sources/
├── OpenDicomViewer/           # Main application (SwiftUI + AppKit)
│   ├── App.swift              # Entry point, menu bar commands
│   ├── ContentView.swift      # Root view, keyboard shortcuts
│   ├── DICOMModel.swift       # Core model: loading, caching, panels
│   ├── SimpleDICOM.swift      # Pure-Swift DICOM parser
│   ├── MultiPanelContainer.swift  # Panel grid, overlays, gesture handling
│   ├── PanelState.swift       # Per-panel state (series, W/L, zoom, tools)
│   ├── MPREngine.swift        # CPU multi-planar reconstruction
│   ├── MetalVolumeRenderer.swift  # GPU MIP/MinIP via Metal compute
│   ├── VolumeData.swift       # 3D voxel buffer
│   └── ...                    # Overlays, toolbars, helpers
└── DCMTKWrapper/              # Objective-C++ bridge to DCMTK/OpenJPEG
    ├── DCMTKHelper.mm
    └── include/DCMTKHelper.h
```

For a full breakdown including what to edit for common tasks (adding tools, shortcuts, overlays), see the **Customization Guide** in the README.

## Contribution Guidelines

### Reporting Issues

[Open an issue](https://github.com/jnheo-md/open-dicom-viewer/issues) with:
- What you expected vs. what happened
- Steps to reproduce (include sample DICOM data characteristics if relevant — modality, transfer syntax, dimensions)
- macOS version

### Pull Requests

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Run `swift test` and verify the app builds with `bash scripts/package_app.sh`
5. Commit with a clear message describing what and why
6. Push and open a PR against `master`

Keep PRs focused. One logical change per PR is easier to review than a bundle of unrelated edits.

### Code Style

- Follow existing conventions in the codebase (Swift standard naming, consistent indentation)
- No external Swift package dependencies without discussion — the project deliberately keeps its dependency footprint minimal
- Use `panel.setDisplayImage()` instead of assigning `panel.image` directly (keeps display dimensions in sync)
- Prefer clear, readable code over clever abstractions — this codebase is designed to be understood by both humans and AI assistants

## Contributing with AI Coding Assistants

This project is explicitly designed to be modified with AI tools like Claude, GitHub Copilot, or similar assistants. This is not just permitted — it is encouraged and is a core part of the project's philosophy.

**How to use AI assistants effectively with this codebase:**

- **Point the AI at the right files.** The README's Customization Guide maps common tasks to specific files. Give the AI that context and it will produce better results.
- **Start small.** Ask the AI to make a single focused change, test it, then iterate. This works much better than requesting sweeping rewrites.
- **Build and verify.** Always run `bash scripts/package_app.sh` after AI-generated changes to confirm the build succeeds, and `swift test` to catch regressions.
- **Review what the AI produces.** AI assistants are powerful but imperfect. Read the diff before committing.

**If your entire contribution was written with an AI assistant, that is fine.** Just note it in your PR description. The quality of the change matters, not how it was written.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE), the same license that covers the rest of the project.
