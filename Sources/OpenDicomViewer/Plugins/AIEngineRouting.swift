// AIEngineRouting.swift
// OpenDicomViewer
//
// Gemma 4 can run two ways: the built-in server (mlx-server/) or the Gemma
// plugin from the store. The brain button, ⌘⇧G / ⌘G and the AI inspector's
// buttons go to whichever the user picked; until they pick, to the plugin when
// it is installed and the built-in engine has not been set up, else built-in.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

enum AIAnalysisEngine: String, CaseIterable, Identifiable {
    case builtIn
    case gemmaPlugin

    var id: String { rawValue }

    var label: String {
        switch self {
        case .builtIn: return "Built-in"
        case .gemmaPlugin: return "Gemma plugin"
        }
    }

    /// The Gemma plugin's tasks, by what the inspector asks for.
    static let pluginID = "gemma-4-e4b"
    static let pluginAnalyze = PluginTaskRef(pluginID: pluginID, taskID: "analyze")
    static let pluginDescribeROI = PluginTaskRef(pluginID: pluginID, taskID: "describe-roi")
    static let pluginDetect = PluginTaskRef(pluginID: pluginID, taskID: "detect-abnormalities")

    /// UserDefaults key of the explicit choice; views bind it with @AppStorage.
    static let preferenceKey = "AIAnalysisEngine"

    /// The user's explicit choice, if any.
    static var preference: AIAnalysisEngine? {
        get { UserDefaults.standard.string(forKey: preferenceKey).flatMap(AIAnalysisEngine.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: preferenceKey) }
    }

    /// Pure resolution, for tests. `pluginInstalled` means the plugin can
    /// serve the user here: installed and ready, or installed but waiting for
    /// a reinstall after an update changed its dependencies (the run then
    /// says so instead of silently switching to the built-in engine).
    static func resolve(preference: AIAnalysisEngine?,
                        pluginInstalled: Bool,
                        builtInSetUp: Bool) -> AIAnalysisEngine {
        if let preference {
            return preference == .gemmaPlugin && !pluginInstalled ? .builtIn : preference
        }
        return pluginInstalled && !builtInSetUp ? .gemmaPlugin : .builtIn
    }

    /// Whether the Gemma plugin is installed, ready, and supported here.
    @MainActor
    static var isPluginInstalled: Bool {
        GemmaPluginSupport.isSupportedHere
            && PluginRuntime.shared.installState(pluginAnalyze).isReady
    }

    /// Whether the Gemma plugin was installed but an app update changed its
    /// dependencies, so it must be reinstalled before it runs again.
    @MainActor
    static var pluginNeedsReinstall: Bool {
        GemmaPluginSupport.isSupportedHere
            && PluginRuntime.shared.needsReinstall(pluginAnalyze)
    }

    /// The plugin counts for engine resolution: ready, awaiting a reinstall,
    /// or being (re)installed -- a reinstall in progress must not flip the
    /// buttons to the built-in engine.
    @MainActor
    static var isPluginAvailable: Bool {
        isPluginInstalled || pluginNeedsReinstall
            || (GemmaPluginSupport.isSupportedHere
                && PluginRuntime.shared.installState(pluginAnalyze).isBusy)
    }

    /// The engine the AI buttons use right now. "Set up" is whether a
    /// completed install was found, not the live setup state: a server that
    /// failed or has not been checked yet (.failed / .unknown) must not
    /// silently switch the buttons to the plugin. Cached by the manager, so
    /// views can ask on every render.
    @MainActor
    static var current: AIAnalysisEngine {
        resolve(preference: preference,
                pluginInstalled: isPluginAvailable,
                builtInSetUp: AIServerManager.shared.hasCompletedSetup)
    }

    /// The engine for a run the user just asked for. Without an explicit
    /// choice, the resolved default is remembered, so later runs keep using
    /// the same engine whatever transient state the other one is in.
    @MainActor
    static func engineForRun() -> AIAnalysisEngine {
        let engine = current
        if preference == nil { preference = engine }
        return engine
    }
}

/// Whether this Mac can run the Gemma plugin.
///
/// The built-in engine and the plugin hold the same 5 GB model. Below
/// `AIServerManager.lowMemoryThresholdBytes` (12 GiB) the built-in engine
/// still runs after a low-memory warning, but the plugin arbiter's share of
/// an 8 GB Mac (half of it) can never admit 5 GB, so the plugin is marked
/// unsupported there, with a pointer to the built-in engine, rather than
/// failing at first use with a bare memory figure.
enum GemmaPluginSupport {
    static let minimumPhysicalBytes = AIServerManager.lowMemoryThresholdBytes

    static func unsupportedReason(physicalBytes: UInt64) -> String? {
        guard physicalBytes < minimumPhysicalBytes else { return nil }
        return "The Gemma plugin needs a Mac with at least "
            + "\(minimumPhysicalBytes / 1_073_741_824) GB of memory; this Mac has "
            + "\(AIServerManager.memoryGBText(physicalBytes)). Use the built-in AI engine "
            + "instead (AI \u{25B8} Analyze Image): it runs the same Gemma 4 model and asks "
            + "before starting on a low-memory Mac."
    }

    static func unsupportedReason(physicalGB: Double) -> String? {
        unsupportedReason(physicalBytes: UInt64(max(0, physicalGB) * 1_073_741_824))
    }

    static var isSupportedHere: Bool {
        unsupportedReason(physicalBytes: ProcessInfo.processInfo.physicalMemory) == nil
    }
}

/// What the AI inspector's Retry button repeats for a failed run: a
/// user-facing action (routed to the preferred engine again), the exact
/// plugin task that failed, a plugin reinstall, or nothing.
///
/// Every path that leaves an error on a panel sets this, so Retry never
/// repeats something other than what failed: a failed TotalSegmentator run
/// used to offer "Retry Analysis", which ran the built-in Gemma analysis.
indirect enum AIAction: Equatable {
    case analyze
    case detectAbnormalities
    case describeROI
    /// A plugin task run directly (store menu, a volumetric task).
    case pluginTask(PluginTaskRef)
    /// Reinstall a plugin whose dependencies changed, then run `then`.
    case reinstallPlugin(String, then: AIAction)
    /// Nothing to retry (e.g. a prompt-segmentation error).
    case none

    /// Label for the Retry button of a failed run; nil hides the button.
    @MainActor
    var retryTitle: String? {
        switch self {
        case .analyze: return "Retry Analysis"
        case .detectAbnormalities: return "Retry Detection"
        case .describeROI: return "Retry Describe ROI"
        case .pluginTask(let ref):
            let task = PluginRuntime.shared.manifest.plugin(id: ref.pluginID)?.task(id: ref.taskID)
            return "Retry " + (task?.label ?? ref.taskID)
        case .reinstallPlugin(let pluginID, _):
            let name = pluginID == AIAnalysisEngine.pluginID
                ? "Gemma Plugin"
                : (PluginRuntime.shared.manifest.plugin(id: pluginID)?.name ?? pluginID)
            return "Reinstall \(name)"
        case .none: return nil
        }
    }
}

@MainActor
extension DICOMModel {

    /// Run `action` on the panel's slice with the preferred engine.
    func triggerPreferredAI(_ action: AIAction, for panel: PanelState) {
        switch action {
        case .analyze: triggerPreferredAIAnalysis(for: panel)
        case .detectAbnormalities: triggerPreferredAIAbnormalityDetection(for: panel)
        case .describeROI: triggerPreferredAIDescribeROI(for: panel)
        case .pluginTask(let ref): runPluginTask(ref, for: panel)
        case .reinstallPlugin(let pluginID, let then):
            reinstallPlugin(pluginID, thenRun: then, for: panel)
        case .none: break
        }
    }

    /// Analyze the panel's slice with the preferred engine.
    func triggerPreferredAIAnalysis(for panel: PanelState) {
        panel.lastAIAction = .analyze
        switch AIAnalysisEngine.engineForRun() {
        case .builtIn: triggerAIAnalysis(for: panel)
        case .gemmaPlugin: runGemmaPlugin(AIAnalysisEngine.pluginAnalyze, as: .analyze, for: panel)
        }
    }

    /// Describe the latest ROI Stats rectangle with the preferred engine.
    func triggerPreferredAIDescribeROI(for panel: PanelState) {
        panel.lastAIAction = .describeROI
        switch AIAnalysisEngine.engineForRun() {
        case .builtIn: triggerAIDescribeLatestROI(for: panel)
        case .gemmaPlugin:
            runGemmaPlugin(AIAnalysisEngine.pluginDescribeROI, as: .describeROI, for: panel)
        }
    }

    /// Flag abnormalities with the preferred engine.
    func triggerPreferredAIAbnormalityDetection(for panel: PanelState) {
        panel.lastAIAction = .detectAbnormalities
        switch AIAnalysisEngine.engineForRun() {
        case .builtIn: triggerAIAbnormalityDetection(for: panel)
        case .gemmaPlugin:
            runGemmaPlugin(AIAnalysisEngine.pluginDetect, as: .detectAbnormalities, for: panel)
        }
    }

    /// Run a Gemma plugin task, or, when an app update changed the plugin's
    /// dependencies, say so and offer the reinstall instead of silently
    /// switching to the built-in engine (and its 6–7 GB enable prompt).
    private func runGemmaPlugin(_ ref: PluginTaskRef, as action: AIAction, for panel: PanelState) {
        showAIInspector = true
        let runtime = PluginRuntime.shared
        if !runtime.installState(ref).isReady && runtime.needsReinstall(ref) {
            panel.aiError = Self.gemmaReinstallMessage
            panel.lastAIAction = .reinstallPlugin(ref.pluginID, then: action)
            objectWillChange.send()
            return
        }
        runPluginTask(ref, for: panel, retryAs: action)
    }

    static let gemmaReinstallMessage = "The Gemma plugin needs reinstalling (dependencies updated). "
        + "Reinstalling updates its Python packages and reuses the downloaded model."

    /// Reinstall every task of `pluginID` an update demoted, then run
    /// `action`. The install reuses weights already on disk.
    func reinstallPlugin(_ pluginID: String, thenRun action: AIAction, for panel: PanelState) {
        guard !panel.aiAnalysisInProgress else { return }
        let runtime = PluginRuntime.shared
        guard let plugin = runtime.manifest.plugin(id: pluginID) else { return }
        let refs = plugin.tasks.map { PluginTaskRef(pluginID: pluginID, taskID: $0.id) }
            .filter { runtime.needsReinstall($0) }
        showAIInspector = true
        panel.aiError = nil
        panel.aiAnalysisInProgress = true
        objectWillChange.send()
        Task { @MainActor in
            for ref in refs { await runtime.install(ref, licenseKey: nil) }
            panel.aiAnalysisInProgress = false
            defer { self.objectWillChange.send() }
            if refs.allSatisfy({ runtime.installState($0).isReady }) {
                self.triggerPreferredAI(action, for: panel)
            } else {
                panel.aiError = "Reinstalling \(plugin.name) failed. "
                    + "Open the Plugin Store (AI \u{25B8} Plugin Store\u{2026}) to see the log."
                panel.lastAIAction = .reinstallPlugin(pluginID, then: action)
            }
        }
    }
}
