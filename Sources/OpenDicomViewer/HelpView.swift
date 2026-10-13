// HelpView.swift
// OpenDicomViewer
//
// In-app help viewer showing usage guide, tools reference, and keyboard shortcuts.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("OpenDicomViewer Help")
                    .font(.title2.bold())
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Overview
                    helpSection("Overview") {
                        Text("OpenDicomViewer is a native macOS DICOM image viewer built for radiology workflows. It supports multi-panel layouts, MPR (multiplanar reconstruction), window/level adjustment, measurement annotations, and cross-reference lines.")
                    }

                    // Opening Files
                    helpSection("Opening Files") {
                        Text("Use **File > Open** (Cmd+O) or click the **Open** button in the sidebar to select a DICOM folder or file. You can also **drag and drop** a folder onto the viewer.")
                        Text("The sidebar lists all series found in the opened folder. Click a series to display it in the active panel.")
                    }

                    // Panel Layouts
                    helpSection("Panel Layouts") {
                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow("Cmd+1", "Single panel")
                            shortcutRow("Cmd+2", "Side by side (2 horizontal)")
                            shortcutRow("Cmd+3", "Stacked (2 vertical)")
                            shortcutRow("Cmd+4", "Four panels (2x2)")
                            shortcutRow("Cmd+Shift+M", "MPR layout")
                        }
                        Text("Click a panel to make it the active panel. Press **Tab** to cycle through panels. Drag a series from the sidebar onto a panel to assign it.")
                    }

                    // Tools
                    helpSection("Tools") {
                        Text("Select tools from the tool palette (fixed column to the left of the panels), the **Tools** menu, or with keyboard shortcuts:")
                        VStack(alignment: .leading, spacing: 6) {
                            toolRow("V", "cursorarrow", "Select", "Default pointer — click to activate panels")
                            toolRow("P", "arrow.up.and.down.and.arrow.left.and.right", "Pan", "Click and drag to pan the image")
                            toolRow("W", "sun.max", "Window/Level", "Drag to adjust brightness and contrast")
                            toolRow("Z", "magnifyingglass", "Zoom", "Drag up/down to zoom in/out")
                            toolRow("O", "rectangle.dashed", "ROI W/L", "Draw a rectangle to auto-set window/level from that region")
                            toolRow("S", "chart.bar.xaxis", "ROI Stats", "Draw a rectangle to see mean, min, max, std dev of pixel values")
                            toolRow("D", "ruler", "Ruler", "Click two points to measure distance in mm. A dashed preview line follows the cursor after the first click.")
                            toolRow("N", "angle", "Angle", "Click three points (vertex, arm1, arm2) to measure an angle. Dashed preview lines follow the cursor between clicks.")
                            toolRow("E", "eraser", "Eraser", "Click an annotation to delete it")
                        }
                        Text("Hold **Shift** to reveal a selection overlay on each panel. Click panels to toggle them for synchronized scrolling (orange = linked). Press **Escape** to clear.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Modifier Overrides
                    helpSection("Modifier Overrides") {
                        Text("Regardless of which tool is active, hold **Option** or **Control** to temporarily access common actions:")
                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow("Opt/Ctrl + Left-drag", "Pan the image")
                            shortcutRow("Opt/Ctrl + Right-drag", "Adjust Window/Level")
                            shortcutRow("Opt/Ctrl + Scroll", "Zoom in/out")
                        }
                    }

                    // Navigation
                    helpSection("Navigation") {
                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow("Up / Down", "Previous / next image in series")
                            shortcutRow("Left / Right", "Previous / next series")
                            shortcutRow("Page Up / Down", "Jump 10 images")
                            shortcutRow("Home / End", "Jump to first / last image")
                            shortcutRow("Scroll Wheel", "Scroll through images")
                            shortcutRow("Opt/Ctrl + Scroll", "Zoom in/out")
                            shortcutRow("Tab", "Cycle active panel")
                        }
                    }

                    // Window/Level
                    helpSection("Window/Level") {
                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow("A", "Auto window/level")
                            shortcutRow("I", "Invert (negate) the image")
                            Text("With the **W/L tool** active, drag horizontally to adjust window width and vertically to adjust window center.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Display Transforms
                    helpSection("Display Transforms") {
                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow("F", "Fit image to window")
                            shortcutRow("R", "Reset view (zoom, pan, and auto W/L)")
                            shortcutRow("] or .", "Rotate clockwise 90\u{00B0}")
                            shortcutRow("[ or ,", "Rotate counter-clockwise 90\u{00B0}")
                            shortcutRow("H", "Flip horizontal")
                        }
                    }

                    // MPR Views
                    helpSection("MPR (Multiplanar Reconstruction)") {
                        Text("MPR mode reconstructs sagittal and coronal views from an axial volume. Use **Layout > MPR Layout** (Cmd+Shift+M) to enter MPR mode. The viewer automatically builds a 3D volume from the active series and displays axial, sagittal, and coronal planes.")
                    }

                    // Overlays & Panels
                    helpSection("Overlays & Other Features") {
                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow("X", "Toggle cross-reference lines")
                            shortcutRow("T", "Toggle DICOM tags inspector")
                            shortcutRow("L", "Toggle synchronized scrolling and zoom")
                            shortcutRow("Shift (hold)", "Show group selection overlay")
                            shortcutRow("Escape", "Clear group selection")
                        }
                    }

                    // AI Assistant (mirrors HELP.md "AI Assistant")
                    helpSection("AI Assistant (Gemma 4, on-device)") {
                        Text("The AI assistant describes the slice on screen, flags possible abnormalities and describes a region you select, using Google's Gemma 4 E4B model running entirely on your Mac. Images never leave the machine.")

                        helpSubheading("First use")
                        Text("Nothing is downloaded until you ask for AI. The first time you press **G**, **Cmd+G**, the brain button, or an item in the **AI** menu, the app asks once whether to enable local AI. If you choose **Not Now**, press **Enable Local AI** in the AI inspector whenever you like.")
                        bullet("**What it downloads:** about 1.5 GB of Python packages and the 5.2 GB model, once. You need about 8 GB of free disk space.")
                        bullet("**How long it takes:** usually 10–30 minutes, depending on your connection. The AI inspector shows the installation, then the model download with its progress; expand **Server log** for details. You can keep viewing images meanwhile, and the analysis you asked for runs by itself once the model is ready.")
                        bullet("**Afterwards:** the model loads in a few seconds when you first use AI in a session.")
                        bullet("**Proxy:** the proxy set in System Settings ▸ Network is used.")

                        helpSubheading("Using it")
                        VStack(alignment: .leading, spacing: 6) {
                            shortcutRow("G / Cmd+G", "Analyze the current slice (AI ▸ Analyze Image)")
                            shortcutRow("AI menu", "Detect Abnormalities")
                            shortcutRow("S, then AI", "Describe ROI: draw a rectangle with the ROI Stats tool on the slice, then AI ▸ Describe ROI (or Describe ROI in the inspector)")
                            shortcutRow("Mode", "Change what the analysis focuses on (inspector or AI ▸ Analysis Mode)")
                            shortcutRow("Clear", "Clear AI results on this slice; the arrow beside it (or the AI menu) clears all slices. Your measurements are never cleared.")
                        }
                        Text("Describe ROI always uses the most recent **ROI Stats** rectangle on the slice you are looking at; without one it is unavailable. Results belong to the slice they were computed on: scroll away and back to see them again.")

                        helpSubheading("Choosing the engine")
                        Text("If the **Gemma plugin** is installed from the Plugin Store, the AI inspector shows an **Engine** switch: **Built-in** or **Gemma plugin**. Both run the same model. Only one holds it in memory at a time; switching stops the other. Both share one copy of the model on disk: whichever you set up first downloads it, and the other reuses it.")
                        Text("If a plugin will not start because the Mac is short of free memory right now, the app asks whether to **Start Anyway**; the Mac may slow down while it pages. A plugin that needs more memory than the Mac can give plugins at all is refused without that choice.")

                        helpSubheading("Troubleshooting")
                        bullet("**Setup failed:** the AI inspector shows the end of the log. Check your connection or proxy, then press **Retry** (the download resumes). **Reinstall** rebuilds the Python environment.")
                        bullet("**Not enough disk space:** free about 8 GB (about 2 GB if the model is already downloaded), then **Retry**.")
                        bullet("**Describe ROI is unavailable:** draw an **ROI Stats** rectangle (S) on this slice first.")
                        bullet("**No results on this slice:** results belong to the slice they were computed on. Scroll back, or press **G** to analyze this one.")
                        bullet("**Requires Apple Silicon:** the local model runs only on M-series Macs.")
                        bullet("**Still stuck:** **AI ▸ Restart AI Server**, and expand **Server log** in the inspector.")

                        helpSubheading("Disclaimer")
                        Text("AI output is for **research and education only**. Findings, boxes, severities and confidence values are generated by a general-purpose model, are not validated, and may be wrong or missing. Do not use them to make or support clinical decisions. The app shows this notice once before the first analysis.")
                            .foregroundStyle(.orange)
                    }

                    // Full Keyboard Reference
                    helpSection("Keyboard Shortcuts Reference") {
                        VStack(alignment: .leading, spacing: 4) {
                            Group {
                                shortcutCompact("V", "Select tool (default)")
                                shortcutCompact("P", "Pan tool")
                                shortcutCompact("W", "Window/Level tool")
                                shortcutCompact("Z", "Zoom tool")
                                shortcutCompact("O", "ROI W/L tool")
                                shortcutCompact("S", "ROI Stats tool")
                                shortcutCompact("D", "Ruler tool")
                                shortcutCompact("N", "Angle tool")
                                shortcutCompact("E", "Eraser tool")
                            }
                            Divider().padding(.vertical, 4)
                            Group {
                                shortcutCompact("A", "Auto window/level")
                                shortcutCompact("I", "Invert image")
                                shortcutCompact("F", "Fit to window")
                                shortcutCompact("R", "Reset view")
                                shortcutCompact("H", "Flip horizontal")
                                shortcutCompact("] / .", "Rotate CW 90\u{00B0}")
                                shortcutCompact("[ / ,", "Rotate CCW 90\u{00B0}")
                            }
                            Divider().padding(.vertical, 4)
                            Group {
                                shortcutCompact("T", "DICOM tags")
                                shortcutCompact("X", "Cross-reference lines")
                                shortcutCompact("L", "Synchronized scrolling & zoom")
                                shortcutCompact("Shift", "Group selection overlay")
                                shortcutCompact("Tab", "Cycle panel")
                                shortcutCompact("Esc", "Clear selection")
                            }
                            Divider().padding(.vertical, 4)
                            Group {
                                shortcutCompact("1-4", "Layout presets")
                                shortcutCompact("Cmd+1-4", "Layout presets (menu)")
                                shortcutCompact("Cmd+Shift+M", "MPR layout")
                                shortcutCompact("Cmd+Shift+L", "Sync scrolling (menu)")
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 500, idealHeight: 700)
        .preferredColorScheme(.dark)
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func helpSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func helpSubheading(_ title: String) -> some View {
        Text(title)
            .font(.callout.bold())
            .foregroundStyle(.primary)
            .padding(.top, 4)
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcutRow(_ key: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(.callout, design: .monospaced).bold())
                .frame(width: 120, alignment: .trailing)
            Text(description)
                .font(.callout)
        }
    }

    private func toolRow(_ key: String, _ icon: String, _ name: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(.callout, design: .monospaced).bold())
                .frame(width: 24, alignment: .center)
            Image(systemName: icon)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.bold())
                Text(description).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func shortcutCompact(_ key: String, _ description: String) -> some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(.caption, design: .monospaced).bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.1))
                .cornerRadius(4)
                .frame(width: 100, alignment: .trailing)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
