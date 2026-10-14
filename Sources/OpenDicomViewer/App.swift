// App.swift
// OpenDicomViewer
//
// Application entry point. Configures the main window with a hidden titlebar
// and registers menu bar commands for layout switching, view operations
// (window/level, transforms, overlays), MPR mode, and synchronized scrolling.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

extension Notification.Name {
    /// Files or folders handed to the app by Finder (double-click, Open With,
    /// a drop on the Dock icon). `object` is the `[URL]`.
    static let odvOpenURLs = Notification.Name("odv.openURLs")
}

/// Receives Finder open requests (CFBundleDocumentTypes in Info.plist). URLs
/// that arrive before a window exists -- the app launched by a double-click --
/// are held until the window asks for them.
final class AppOpenDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            Self.pendingURLs.append(contentsOf: urls)
            NotificationCenter.default.post(name: .odvOpenURLs, object: urls)
        }
    }

    /// Take the URLs not yet handled.
    @MainActor static func takePending() -> [URL] {
        defer { pendingURLs = [] }
        return pendingURLs
    }

    /// What to load for a set of opened items: the item itself when there is
    /// one, else the folder holding them all (several files of one series
    /// selected in Finder), else the first.
    static func loadTarget(for urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        guard urls.count > 1 else { return first }
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL })
        return parents.count == 1 ? parents.first : first
    }
}

@main
struct OpenDicomViewerApp: App {
    @NSApplicationDelegateAdaptor(AppOpenDelegate.self) private var openDelegate
    @StateObject private var model = DICOMModel()
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var aiServerManager = AIServerManager.shared
    @ObservedObject private var aiService = AIService.shared
    @ObservedObject private var pluginStore = PluginStore.shared

    init() {
        // Loads the plugin manifest and stops adapter processes at quit.
        PluginRuntime.bootstrapForApplication()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    // Adopt a server already running (launch.sh) and sweep one
                    // orphaned by a crash. Runs once per process; it starts
                    // nothing (the server starts on first AI use) and does not
                    // wait for the update check below.
                    aiServerManager.checkExistingServer()
                    // Auto-open directory if passed via --benchmark /path
                    if let benchIdx = CommandLine.arguments.firstIndex(of: "--benchmark"),
                       benchIdx + 1 < CommandLine.arguments.count {
                        let path = CommandLine.arguments[benchIdx + 1]
                        let url = URL(fileURLWithPath: path)
                        model.load(url: url)
                    } else {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await updateChecker.checkForUpdates()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .odvOpenURLs)) { _ in
                    openPendingURLs()
                }
                .onAppear { openPendingURLs() }
                .onOpenURL { url in
                    if url.isFileURL { model.load(url: url) }
                }
                .alert(
                    updateAlertTitle,
                    isPresented: $updateChecker.showUpdateAlert
                ) {
                    updateAlertButtons
                } message: {
                    Text(updateAlertMessage)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    Task { await updateChecker.checkForUpdates(userInitiated: true) }
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    model.openFolder()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                // ─ Window/Level ─
                Button("Auto Window/Level (A)") {
                    if let panel = model.activePanel {
                        model.autoWindowLevelForPanel(panel)
                    }
                }

                Button("Invert (I)") {
                    model.invertForPanel(model.activePanel)
                }

                Divider()

                // ─ Transform ─
                Button("Fit to Window (F)") {
                    model.fitToWindowForPanel(model.activePanel)
                }

                Button("Reset View (R)") {
                    model.resetViewForPanel(model.activePanel)
                }

                Divider()

                Button("Rotate Clockwise 90° (])") {
                    model.rotateClockwiseForPanel(model.activePanel)
                }

                Button("Rotate Counter-Clockwise 90° ([)") {
                    model.rotateCounterClockwiseForPanel(model.activePanel)
                }

                Button("Flip Horizontal (H)") {
                    model.flipHorizontalForPanel(model.activePanel)
                }

                Button("Flip Vertical") {
                    model.flipVerticalForPanel(model.activePanel)
                }

                Divider()

                // ─ Overlays ─
                Toggle("Cross-Reference Lines (X)", isOn: $model.showCrossReference)

                Toggle("DICOM Tags Inspector (T)", isOn: Binding(
                    get: { model.showTags },
                    set: { model.showTags = $0 }
                ))
            }

            CommandMenu("Layout") {
                Button("Single Panel") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.single) }
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Side by Side") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoHorizontal) }
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Stacked") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoVertical) }
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Four Panels") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.quad) }
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button("MPR Layout") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setupMPRLayout() }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()

                Toggle("Synchronized Scrolling", isOn: $model.synchronizedScrolling)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }

            CommandMenu("Tools") {
                Button("Select (V)") { model.activeTool = .select }
                Button("Pan (P)") { model.activeTool = .pan }
                Button("Window/Level (W)") { model.activeTool = .windowLevel }
                Button("Zoom (Z)") { model.activeTool = .zoom }

                Divider()

                Button("ROI W/L (O)") { model.activeTool = .roiWL }
                Button("ROI Stats (S)") { model.activeTool = .roiStats }

                Divider()

                Button("Ruler (D)") { model.activeTool = .ruler }
                Button("Angle (N)") { model.activeTool = .angle }

                Divider()

                Button("Eraser (E)") { model.activeTool = .eraser }

                Divider()

                Button("AI Analyze (G)") { model.activeTool = .aiAnalyze }
            }

            CommandMenu("AI") {
                // Enabled whenever there is an image: the engine starts on
                // demand (asking once to enable local AI), and the AI
                // inspector opens to show progress, the result or the error.
                Button("Analyze Image") {
                    if let panel = model.activePanel {
                        model.showAIInspector = true
                        model.triggerPreferredAIAnalysis(for: panel)
                    }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.activePanel?.image == nil)

                Button("Detect Abnormalities") {
                    if let panel = model.activePanel {
                        model.showAIInspector = true
                        model.triggerPreferredAIAbnormalityDetection(for: panel)
                    }
                }
                .disabled(model.activePanel?.image == nil)

                Button("Describe ROI") {
                    if let panel = model.activePanel {
                        model.showAIInspector = true
                        model.triggerPreferredAIDescribeROI(for: panel)
                    }
                }
                .disabled(model.activePanel?.image == nil
                          || model.activePanel.map { model.latestROIForAIDescription(in: $0) == nil } ?? true)
                .help("Describes the latest ROI Stats rectangle (S) on this slice")

                Divider()

                if !aiService.availableModes.isEmpty {
                    Picker("Analysis Mode", selection: $aiService.selectedMode) {
                        ForEach(aiService.availableModes) { mode in
                            Text("\(mode.label)").tag(mode.key)
                        }
                    }

                    Divider()
                }

                Button("Clear AI Annotations on This Slice") {
                    model.activePanel?.clearAIAnnotations()
                    model.objectWillChange.send()
                }
                Button("Clear AI Annotations on All Slices") {
                    model.activePanel?.clearAIAnnotations(allSlices: true)
                    model.objectWillChange.send()
                }

                Toggle("Show AI Annotations", isOn: Binding(
                    get: { model.activePanel?.showAIAnnotations ?? true },
                    set: { model.activePanel?.showAIAnnotations = $0 }
                ))

                Divider()

                // The menu is a separate view tree from ContentView, so it asks
                // for the store by notification rather than through shared state.
                PluginStoreMenuSection(
                    store: pluginStore,
                    run: { ref in
                        guard let panel = model.activePanel else { return }
                        model.runPluginTask(ref, for: panel)
                    },
                    openStore: {
                        NotificationCenter.default.post(name: .odvOpenPluginStore, object: nil)
                    })

                Divider()

                Button(aiServerManager.isServerRunning ? "Restart AI Server" : "Start AI Server") {
                    model.showAIInspector = true
                    if aiServerManager.isServerRunning {
                        aiServerManager.restartServer()
                    } else {
                        aiServerManager.startServer()
                    }
                }

                if aiServerManager.isServerRunning {
                    Button("Stop AI Server") {
                        aiServerManager.stopServer()
                    }
                }

                Divider()

                Text(aiService.serverStatus.displayText)
            }

            CommandGroup(replacing: .help) {
                Button("OpenDicomViewer Help") {
                    model.showHelp = true
                }
            }
        }
    }

    @MainActor
    private func openPendingURLs() {
        let urls = AppOpenDelegate.takePending()
        if let target = AppOpenDelegate.loadTarget(for: urls) { model.load(url: target) }
    }

    private var updateAlertTitle: String {
        switch updateChecker.state {
        case .updateAvailable:
            return "Update Available"
        case .upToDate:
            return "You're Up to Date"
        case .error:
            return "Couldn't Check for Updates"
        default:
            return ""
        }
    }

    private var updateAlertMessage: String {
        switch updateChecker.state {
        case .updateAvailable(let version, let notes, _):
            return "Version \(version) is available (current: \(updateChecker.currentVersion)).\n\n\(String(notes.prefix(300)))"
        case .upToDate:
            return "OpenDicomViewer \(updateChecker.currentVersion) is the latest version."
        case .error(let message):
            return message
        default:
            return ""
        }
    }

    @ViewBuilder
    private var updateAlertButtons: some View {
        switch updateChecker.state {
        case .updateAvailable(let version, _, let url):
            Button("Download") { updateChecker.openDownload(url) }
            Button("Skip This Version") { updateChecker.skipVersion(version) }
            Button("Later", role: .cancel) { }
        case .upToDate:
            Button("OK", role: .cancel) { }
        default:
            Button("OK", role: .cancel) { }
        }
    }
}
