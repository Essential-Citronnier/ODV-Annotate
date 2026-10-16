# OpenDicomViewer Help

A native macOS DICOM viewer with multi-panel layouts, MPR reconstruction, measurement annotations, and on-device AI for research and education (not for clinical use).

---

## Getting Started

### Opening Files

- **Open Button** -- Click the **Open** button in the sidebar to select a DICOM file (`.dcm`) or a folder containing DICOM files.
- **Drag & Drop** -- Drag a folder or DICOM file from Finder directly onto the viewer area. The app will scan for all DICOM series automatically.
- **Sidebar Series List** -- Once loaded, all discovered series appear in the sidebar. Click a series to display it in the active panel. Drag a series from the sidebar onto any panel to assign it.

### Sidebar

The sidebar shows all loaded series with thumbnails, descriptions, and image counts. A small grid icon next to each series indicates which panel(s) are displaying it. Click the sidebar toggle button to show/hide the sidebar.

---

## Panel Layouts

OpenDicomViewer supports up to four simultaneous panels for comparing series or viewing MPR reconstructions.

| Layout       | Key | Description                     |
|--------------|-----|---------------------------------|
| Single (1x1) | `1` | One panel (default)            |
| Side by Side (2x1) | `2` | Two panels, left and right |
| Stacked (1x2) | `3` | Two panels, top and bottom    |
| Quad (2x2)   | `4` | Four panels in a grid          |

Layout buttons are also available in the **floating toolbar** at the top-right of the viewer, and in the **Layout** menu bar.

### Active Panel

Click on a panel to make it the **active panel** (highlighted with a blue border). All keyboard shortcuts and tool actions apply to the active panel. Press **Tab** to cycle focus between panels.

### Fullscreen Panel

**Double-click** any panel to toggle fullscreen mode for that panel. Double-click again to return to the grid layout.

---

## Series Navigation

| Action             | Input                      |
|--------------------|----------------------------|
| Next image (slice) | `Down Arrow` / Scroll Down |
| Previous image     | `Up Arrow` / Scroll Up     |
| Next series        | `Right Arrow`              |
| Previous series    | `Left Arrow`               |
| Skip 10 images forward  | `Page Down`          |
| Skip 10 images backward | `Page Up`            |
| Jump to first image | `Home`                    |
| Jump to last image  | `End`                     |

A **scrollbar** on the right side of each panel provides visual position feedback and can be dragged for rapid navigation. Hovering over the scrollbar shows a thumbnail preview.

---

## Window / Level

Window Width (WW) and Window Center (WL) control the brightness and contrast of the displayed image.

| Action             | Input                                |
|--------------------|--------------------------------------|
| Adjust W/L         | **Right-click drag** on any panel    |
|                    | Or select the **W/L tool** and left-drag |
| Auto W/L           | Press `A`                            |
| ROI-based W/L      | Select **ROI W/L tool** (`O`), then draw a rectangle |

- **Right-drag horizontally** adjusts Window Width (contrast).
- **Right-drag vertically** adjusts Window Center (brightness).
- Sensitivity scales dynamically based on the current window width for fine or coarse control.
- The current WW/WL values are displayed at the bottom-left of each panel.

A **histogram** is shown in the bottom toolbar of each panel with a yellow indicator representing the current window range.

---

## Tools

Select a tool from the **floating tool palette** on the left side of the viewer, the **Tools** menu, or with keyboard shortcuts.

| Tool         | Key | Description                                       |
|--------------|-----|---------------------------------------------------|
| **Select**   | `V` | Default pointer — click to activate panels |
| **Pan**      | `P` | Left-click drag to pan the image                  |
| **W/L**      | `W` | Left-click drag to adjust Window/Level            |
| **Zoom**     | `Z` | Left-click drag up/down to zoom in/out, or scroll |
| **ROI W/L**  | `O` | Draw a rectangle; W/L auto-adjusts to the ROI     |
| **ROI Stats**| `S` | Draw a rectangle; displays Mean, SD, Min, Max, N  |
| **Ruler**    | `D` | Click two points to measure distance (mm or px)   |
| **Angle**    | `N` | Click three points to measure an angle (degrees)  |
| **Eraser**   | `E` | Click near an annotation to delete it              |

### Select Tool

The **Select** tool (`V`) is the default tool. Click a panel to make it the active panel.

### Modifier Overrides

Regardless of which tool is active, you can use modifier keys to temporarily access common actions:

| Input                        | Action                          |
|------------------------------|-------------------------------- |
| **Option/Control + Left-drag** | Pan the image                 |
| **Option/Control + Right-drag** | Adjust Window/Level          |
| **Option/Control + Scroll**    | Zoom in/out                   |

These overrides work with any active tool, so you don't need to switch tools for quick panning or zooming.

### Measurement Details

- **Ruler**: Click to set the start point, then click again to set the end point. If pixel spacing metadata is available, the distance is shown in millimeters; otherwise, in pixels. A dashed cyan preview line is shown while placing.
- **Angle**: Click three points -- the first arm endpoint, the vertex, and the second arm endpoint. The angle in degrees is displayed at the vertex. A dashed green preview is shown while placing.
- **ROI Stats**: Drag a rectangle over the region of interest. Statistics (Mean, Standard Deviation, Min, Max, pixel count) are computed from raw pixel data and displayed as a persistent annotation.
- **Eraser**: Click near any annotation (ruler, angle, or ROI stats) to remove it. The closest annotation within 15 pixels is deleted.

---

## Display Transforms

| Action                     | Key        | Description                              |
|----------------------------|------------|------------------------------------------|
| Invert (Negative)          | `I`        | Toggle image inversion                   |
| Rotate Clockwise 90deg     | `]` or `.` | Rotate the image 90 degrees clockwise    |
| Rotate Counter-Clockwise   | `[` or `,` | Rotate the image 90 degrees counter-clockwise |
| Flip Horizontal            | `H`        | Mirror the image left-to-right           |
| Flip Vertical              | *(menu)*   | Mirror the image top-to-bottom           |
| Fit to Window              | `F`        | Reset zoom/pan to fit the image in the panel |
| Reset View                 | `R`        | Reset zoom, pan, rotation, flip, and auto-adjust W/L |

Rotate and flip buttons are also available in each panel's **volume toolbar** (top-left corner).

---

## MPR (Multi-Planar Reconstruction)

When a volumetric series (CT/MR with sufficient slices) is loaded, additional display modes become available in the **volume toolbar** at the top-left of each panel:

| Mode          | Description                                             |
|---------------|---------------------------------------------------------|
| **Slice**     | Standard 2D axial slice view (default)                  |
| **Sagittal**  | Reconstructed sagittal plane (left-right cross-section) |
| **Coronal**   | Reconstructed coronal plane (front-back cross-section)  |
| **MIP**       | Maximum Intensity Projection                            |

### MIP Controls

When MIP mode is active, additional controls appear in the volume toolbar:

- **Projection Mode**: Choose between MIP (maximum), MinIP (minimum), or Average intensity projection.
- **Slab Thickness**: Adjust the number of slices included in the projection using the slider.
- Scroll through the volume to move the slab position.

### MPR Layout Shortcut

Use **Layout > MPR Layout** (Cmd+Shift+M) from the menu bar to automatically set up a quad layout with Axial, Sagittal, Coronal, and MIP views of the same series.

---

## Cross-Reference Lines

Press `X` or click the cross icon in the floating toolbar to toggle **cross-reference lines**. When enabled, each panel displays colored lines indicating the slice positions of other panels that share the same study. This is useful for correlating anatomy across axial, sagittal, and coronal views.

Cross-reference lines are only visible when multiple panels are active.

---

## DICOM Tags Inspector

Press `T` or click the tag icon in the floating toolbar to open the **DICOM Tags Inspector** sidebar. This displays all DICOM metadata tags (Tag ID, VR, Name, Value) for the image currently displayed in the active panel.

---

## Synchronized Scrolling

Press `L` or click the link icon in the floating toolbar to toggle **synchronized scrolling**. When enabled, scrolling through slices in one panel automatically scrolls all other panels that have series assigned.

---

## Group Selection

Hold **Shift** to reveal a selection overlay on each panel (multi-panel mode only). Click panels to toggle them for synchronized scrolling. Selected panels show an **orange overlay**; unselected panels show a dark overlay with instructional text. Release Shift to dismiss the overlays — selected panels retain their **orange border**.

| Action                 | Input              | Description                             |
|------------------------|--------------------|-----------------------------------------|
| Show selection overlay | Hold `Shift`       | Reveals clickable overlay on each panel |
| Toggle panel in group  | Click (while Shift held) | Add/remove a panel from the scroll group |
| Clear group selection  | `Escape`           | Remove all panels from the group        |

Group-selected panels scroll simultaneously. If only one panel remains selected, the group is automatically cleared.

---

## HU Readout

Move your mouse cursor over any image to see a real-time readout in the **top-right corner** of the panel:

- **HU value**: The raw pixel/Hounsfield Unit value at the cursor position
- **Pixel coordinates**: `[x, y]` position in image pixel space
- **Patient coordinates**: `x, y, z` position in patient coordinate space (when spatial metadata is available)

---

## Orientation Labels

When DICOM orientation metadata is available, anatomical direction labels are displayed on each edge of the image:

- **R** / **L** -- Right / Left
- **A** / **P** -- Anterior / Posterior
- **S** / **I** -- Superior / Inferior

These labels automatically update when you rotate or flip the image.

---

## AI Assistant (Gemma 4, on-device)

The AI assistant describes the slice on screen, flags possible abnormalities
and describes a region you select, using Google's Gemma 4 E4B model running
entirely on your Mac. Images, DICOM metadata and results are never uploaded;
see **Network use** below for what does use the network.

### First use

Nothing is downloaded until you ask for AI. The first time you press `Cmd+Shift+G`
(or `Cmd+G` while the viewer has focus), click the image with the **AI Analyze**
tool (`G`), press the brain button, or choose an item in the **AI** menu, the
app asks once
whether to enable local AI:

- **What it downloads:** about 1.5 GB of pinned Python packages from PyPI
  (mlx 0.32.0, mlx-vlm 0.6.5, transformers 5.14.1, ...) and the 5.2 GB model
  (`mlx-community/gemma-4-E4B-it-4bit`, revision `475b9088…`) from Hugging
  Face, once. You need about 8 GB of free disk space.
- **How long it takes:** usually 10–30 minutes, depending on your connection.
  The AI inspector shows the installation, then the model download with its
  progress; expand **Server log** to see details. You can keep viewing images
  meanwhile, and the analysis you asked for runs by itself once the model is
  ready.
- **Afterwards:** the model loads in a few seconds when you first use AI in a
  session.
- **Proxy:** the proxy set in System Settings ▸ Network is used. If setup
  fails, the inspector shows the end of the log; **Retry** resumes.

If you choose **Not Now**, open the AI inspector (brain button) and press
**Enable Local AI** whenever you like.

### Memory

| Engine | Minimum Mac RAM | Recommended |
|--------|-----------------|-------------|
| Built-in Gemma 4 E4B | 8 GB (close other apps; the app warns on Macs with less than 12 GiB) | 16 GB |
| Gemma plugin | 16 GB (on an 8 GB Mac, use the built-in engine) | 16 GB |
| SAM 2 plugin | 8 GB (declares 3 GB) | 16 GB |
| SAM 3 plugin | 16 GB (declares 6 GB) | 16 GB |
| TotalSegmentator plugin | 32 GB (declares 23.5 GB) | 32 GB or more |

The Plugin Store shows a plugin as unavailable when its declared memory is more
than half of the Mac's RAM (three quarters for TotalSegmentator, which runs
once and exits).

### Network use

- **Setup downloads:** the Python packages (PyPI) and model weights (Hugging
  Face; TotalSegmentator's own release servers for its weights) are downloaded
  once, only after you agree, for local AI or for a plugin you install.
- **Update check:** at launch, at most once every 24 hours, and when you choose
  **Check for Updates...**, the app asks GitHub's releases API
  (`api.github.com/repos/Essential-Citronnier/ODV-Annotate/releases/latest`)
  for the latest version number. It sends nothing about you or your images and
  never installs anything by itself.

Once set up, AI analysis works offline.

### Using it

| Action | How |
|--------|-----|
| Analyze the current slice | **AI ▸ Analyze Image** (`Cmd+Shift+G`; `Cmd+G` also works while the viewer has focus), or select the **AI Analyze** tool with `G` and click the image |
| Flag possible abnormalities | **AI ▸ Detect Abnormalities** |
| Describe a region | Draw a rectangle with the **ROI Stats** tool (`S`) on the slice, then **AI ▸ Describe ROI** (or **Describe ROI** in the AI inspector) |
| Change what the analysis focuses on | **Mode** in the AI inspector, or **AI ▸ Analysis Mode** |
| Hide results | **AI ▸ Show AI Annotations** |
| Clear results | **Clear** in the AI inspector, or **AI ▸ Clear AI Annotations on This Slice**. To clear every slice, use the arrow beside **Clear** or **AI ▸ Clear AI Annotations on All Slices**. Measurements you drew are never cleared |

Describe ROI always uses the most recent ROI Stats rectangle on the slice you
are looking at; without one it is unavailable. Results belong to the slice
they were computed on: scroll away and back to see them again.

### Choosing the engine

If the **Gemma plugin** is installed from the Plugin Store, the AI inspector
shows an **Engine** switch: **Built-in** (the AI server that ships with the
app) or **Gemma plugin**. Both run the same model and give the same kind of
results. Only one of them holds the model in memory at a time; switching stops
the other.

Both engines share one copy of the model on disk. Whichever you set up first
downloads it; the other reuses it:

- Built-in first: `~/.cache/huggingface/hub/models--mlx-community--gemma-4-E4B-it-4bit/`
- Plugin first: `~/Library/Application Support/OpenDicomViewer/plugins/gemma-4-e4b/weights/gemma-4-e4b-it-4bit/`

If a plugin will not start because the Mac is short of free memory right now,
the app asks whether to **Start Anyway**. Starting anyway may make the Mac slow
while it pages memory; quitting other apps first is better. A plugin that needs
more memory than the Mac can give plugins at all is refused without that
choice.

### Troubleshooting

- **Setup failed:** open the AI inspector; it shows the end of the log. Check
  your internet connection or proxy, then press **Retry** (the download
  resumes where it stopped). **Reinstall** rebuilds the Python environment
  from scratch.
- **Not enough disk space:** free about 8 GB (about 2 GB if the model is
  already downloaded), then **Retry**.
- **The model takes a long time to appear:** the first download is 5.2 GB;
  the inspector shows its progress. Later launches load in seconds.
- **Describe ROI is unavailable:** draw a rectangle with **ROI Stats** (`S`)
  on the slice you are looking at first.
- **No results on this slice:** results belong to the slice they were computed
  on. Scroll back, or press `Cmd+Shift+G` (or choose the AI Analyze tool with `G` and click the image) to analyze this slice.
- **Requires Apple Silicon:** the app runs only on Apple Silicon Macs (M1 or
  later) with macOS 14 or later.
- **Still stuck:** **AI ▸ Restart AI Server**; expand **Server
  log** in the inspector for details.

### Disclaimer

AI output is for **research and education only**. Findings, boxes,
severities and confidence values are generated by a general-purpose model, are
not validated, and may be wrong or missing. Do not use them to make or support
clinical decisions. The app shows this notice once before the first analysis.

---

## Menu Bar Commands

### View Menu

| Command                          | Shortcut |
|----------------------------------|----------|
| Auto Window/Level                | `A`      |
| Invert                           | `I`      |
| Fit to Window                    | `F`      |
| Reset View                       | `R`      |
| Rotate Clockwise 90deg          | `]`      |
| Rotate Counter-Clockwise 90deg  | `[`      |
| Flip Horizontal                  | `H`      |
| Flip Vertical                    | --       |
| Cross-Reference Lines            | `X`      |
| DICOM Tags Inspector             | `T`      |

### Layout Menu

| Command                  | Shortcut      |
|--------------------------|---------------|
| Single Panel             | `Cmd+1`       |
| Side by Side             | `Cmd+2`       |
| Stacked                  | `Cmd+3`       |
| Four Panels              | `Cmd+4`       |
| MPR Layout               | `Cmd+Shift+M` |
| Synchronized Scrolling   | `Cmd+Shift+L` |

---

## Complete Keyboard Shortcuts Reference

### Navigation

| Shortcut     | Action                     |
|--------------|----------------------------|
| `Up`         | Previous image (slice)     |
| `Down`       | Next image (slice)         |
| `Left`       | Previous series            |
| `Right`      | Next series                |
| `Page Up`    | Skip 10 images backward    |
| `Page Down`  | Skip 10 images forward     |
| `Home`       | Jump to first image        |
| `End`        | Jump to last image         |
| `Scroll`     | Navigate slices            |
| `Tab`        | Cycle active panel         |

### Layout

| Shortcut     | Action                     |
|--------------|----------------------------|
| `1`          | Single panel (1x1)         |
| `2`          | Side by side (2x1)         |
| `3`          | Stacked (1x2)              |
| `4`          | Quad (2x2)                 |
| Double-click | Toggle panel fullscreen    |

### Tools

| Shortcut | Tool                        |
|----------|-----------------------------|
| `V`      | Select (default pointer)    |
| `P`      | Pan                         |
| `W`      | Window/Level                |
| `Z`      | Zoom                        |
| `O`      | ROI Window/Level            |
| `S`      | ROI Statistics              |
| `D`      | Ruler (distance)            |
| `N`      | Angle                       |
| `E`      | Eraser                      |

### Display

| Shortcut     | Action                            |
|--------------|-----------------------------------|
| `I`          | Invert (negative)                 |
| `]` or `.`   | Rotate clockwise 90deg           |
| `[` or `,`   | Rotate counter-clockwise 90deg   |
| `H`          | Flip horizontal                   |
| `F`          | Fit to window                     |
| `R`          | Reset view (zoom, pan, W/L)       |
| `A`          | Auto Window/Level                 |

### Overlays & Multi-Panel

| Shortcut     | Action                            |
|--------------|-----------------------------------|
| `T`          | Toggle DICOM Tags Inspector       |
| `X`          | Toggle cross-reference lines      |
| `L`          | Toggle synchronized scrolling     |
| `Shift` (hold) | Show group selection overlay     |
| `Escape`     | Clear group selection             |

### Mouse Actions

| Input                         | Action                          |
|-------------------------------|---------------------------------|
| Left-click                    | Activate panel / Tool action    |
| Left-drag                     | Tool-dependent (Pan, W/L, Zoom, ROI, drag-to-select, etc.) |
| Right-drag                    | Adjust Window/Level             |
| Scroll wheel                  | Navigate slices                 |
| Option/Control + Left-drag    | Pan (any tool)                  |
| Option/Control + Right-drag   | Adjust Window/Level (any tool)  |
| Option/Control + Scroll       | Zoom in/out                     |
| Shift (hold)                  | Show group selection overlay (click panels to toggle) |
| Double-click                  | Toggle fullscreen panel         |
| Drag from sidebar             | Assign series to panel          |
| Drag from Finder              | Open DICOM file/folder          |
