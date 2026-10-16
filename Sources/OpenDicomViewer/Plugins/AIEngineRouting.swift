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

    private static let preferenceKey = "AIAnalysisEngine"

    /// The user's explicit choice, if any.
    static var preference: AIAnalysisEngine? {
        get { UserDefaults.standard.string(forKey: preferenceKey).flatMap(AIAnalysisEngine.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: preferenceKey) }
    }

    /// Pure resolution, for tests.
    static func resolve(preference: AIAnalysisEngine?,
                        pluginInstalled: Bool,
                        builtInSetUp: Bool) -> AIAnalysisEngine {
        if let preference {
            return preference == .gemmaPlugin && !pluginInstalled ? .builtIn : preference
        }
        return pluginInstalled && !builtInSetUp ? .gemmaPlugin : .builtIn
    }

    @MainActor
    static var isPluginInstalled: Bool {
        PluginRuntime.shared.installState(pluginAnalyze).isReady
    }

    /// The engine the AI buttons use right now. "Set up" is whether a
    /// completed install was found, not the live setup state: a server that
    /// failed or has not been checked yet (.failed / .unknown) must not
    /// silently switch the buttons to the plugin. Cached by the manager, so
    /// views can ask on every render.
    @MainActor
    static var current: AIAnalysisEngine {
        resolve(preference: preference,
                pluginInstalled: isPluginInstalled,
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

/// A user-facing AI action, independent of which engine runs it.
enum AIAction: Equatable {
    case analyze
    case detectAbnormalities
    case describeROI

    /// Label for the Retry button of a failed run.
    var retryTitle: String {
        switch self {
        case .analyze: return "Retry Analysis"
        case .detectAbnormalities: return "Retry Detection"
        case .describeROI: return "Retry Describe ROI"
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
        }
    }

    /// Analyze the panel's slice with the preferred engine.
    func triggerPreferredAIAnalysis(for panel: PanelState) {
        panel.lastAIAction = .analyze
        switch AIAnalysisEngine.engineForRun() {
        case .builtIn: triggerAIAnalysis(for: panel)
        case .gemmaPlugin:
            showAIInspector = true
            runPluginTask(AIAnalysisEngine.pluginAnalyze, for: panel)
        }
    }

    /// Describe the latest ROI Stats rectangle with the preferred engine.
    func triggerPreferredAIDescribeROI(for panel: PanelState) {
        panel.lastAIAction = .describeROI
        switch AIAnalysisEngine.engineForRun() {
        case .builtIn: triggerAIDescribeLatestROI(for: panel)
        case .gemmaPlugin:
            showAIInspector = true
            runPluginTask(AIAnalysisEngine.pluginDescribeROI, for: panel)
        }
    }

    /// Flag abnormalities with the preferred engine.
    func triggerPreferredAIAbnormalityDetection(for panel: PanelState) {
        panel.lastAIAction = .detectAbnormalities
        switch AIAnalysisEngine.engineForRun() {
        case .builtIn: triggerAIAbnormalityDetection(for: panel)
        case .gemmaPlugin:
            showAIInspector = true
            runPluginTask(AIAnalysisEngine.pluginDetect, for: panel)
        }
    }
}
