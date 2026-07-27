// PluginStoreView.swift
// OpenDicomViewer
//
// The plugin store sheet: browse the bundled plugin manifest, install and
// remove local inference models, and satisfy the license gate a task declares.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import AppKit

// MARK: - Store sheet

struct PluginStoreView: View {
    @Environment(\.dismiss) private var dismiss

    /// Owned by the host, not by the sheet: install state must survive the
    /// store being closed and reopened mid-download.
    @ObservedObject var store: PluginStore

    /// The task whose license gate is currently being resolved, if any.
    @State private var gateSelection: PluginGateSelection?
    /// Rows whose install log the user has opened, by task reference string.
    @State private var expandedLogs: Set<String> = []

    init(store: PluginStore) {
        self.store = store
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 520, idealHeight: 660)
        .sheet(item: $gateSelection) { selection in
            if let row = store.row(for: selection.ref) {
                PluginLicenseGateSheet(store: store, row: row)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Plugin Store")
                    .font(.title2.bold())
                Text("Local inference models. Nothing here runs in the cloud.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Close the plugin store")
        }
        .padding()
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search plugins and tasks", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search plugins and tasks")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            Toggle("Installed only", isOn: $store.showInstalledOnly)
                .toggleStyle(.checkbox)
                .accessibilityLabel("Show installed plugins only")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.groups.isEmpty {
            VStack(spacing: 8) {
                Text("No matching plugins")
                    .font(.headline)
                Text("Clear the search field or turn off the installed-only filter.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(store.groups) { group in
                        PluginGroupCard(store: store,
                                        group: group,
                                        gateSelection: $gateSelection,
                                        expandedLogs: $expandedLogs)
                    }
                }
                .padding()
            }
        }
    }

    // MARK: Footer

    /// The privacy line is not collapsible and not dismissable. It is the
    /// user-facing statement of the protocol's egress invariant, and a store
    /// that hides it behind a disclosure would be making a weaker promise than
    /// the one the plugin layer actually enforces.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(PluginStore.privacyStatement)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Privacy. \(PluginStore.privacyStatement)")

            Text(PluginStore.researchUseStatement)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.25))
    }
}

/// Identifiable wrapper for `sheet(item:)`.
///
/// Deliberately a local wrapper rather than a conformance on `PluginTaskRef`:
/// the reference type is shared across the plugin layer, and a presentation
/// concern is a poor reason to add a protocol to it.
private struct PluginGateSelection: Identifiable, Equatable {
    let ref: PluginTaskRef
    var id: String { ref.description }
}

// MARK: - Plugin group

private struct PluginGroupCard: View {
    @ObservedObject var store: PluginStore
    let group: PluginStoreGroup
    @Binding var gateSelection: PluginGateSelection?
    @Binding var expandedLogs: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if store.isExpanded(group.id) {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 12) }
                        PluginTaskRowView(store: store,
                                          row: row,
                                          gateSelection: $gateSelection,
                                          expandedLogs: $expandedLogs)
                    }
                }
            }
        }
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                store.setExpanded(!store.isExpanded(group.id), for: group.id)
            } label: {
                Image(systemName: store.isExpanded(group.id) ? "chevron.down" : "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isExpanded(group.id)
                                ? "Collapse \(group.name)" : "Expand \(group.name)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(group.name)
                        .font(.headline)
                    Text(group.vendor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    executionBadge
                }
                Text(group.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if group.canStart {
                runtimeControl
            }
        }
        .padding(12)
        .contentShape(Rectangle())
    }

    private var executionBadge: some View {
        Text(executionLabel)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel("Execution model: \(executionLabel)")
    }

    private var executionLabel: String {
        switch group.execution {
        case .residentServer: return "Resident"
        case .session: return "Interactive session"
        case .oneShot: return "Runs on demand"
        }
    }

    @ViewBuilder
    private var runtimeControl: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(runtimeText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.trailing)
            Button(group.isRunning ? "Stop" : "Start") {
                Task {
                    if group.isRunning {
                        await store.stop(group.id)
                    } else {
                        await store.start(group.id)
                    }
                }
            }
            .controlSize(.small)
            .accessibilityLabel(group.isRunning
                                ? "Stop \(group.name)" : "Start \(group.name)")
        }
    }

    private var runtimeText: String {
        switch group.runtimeState {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .ready: return "Running"
        case .stopping: return "Stopping…"
        case .error(let message): return "Error: \(message)"
        }
    }
}

// MARK: - Task row

private struct PluginTaskRowView: View {
    @ObservedObject var store: PluginStore
    let row: PluginStoreRow
    @Binding var gateSelection: PluginGateSelection?
    @Binding var expandedLogs: Set<String>

    private var isLogExpanded: Bool { expandedLogs.contains(row.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A vertical stack rather than a single line: at accessibility text
            // sizes the badges and the state string need to wrap rather than
            // truncate, and the state string is the one thing that must never
            // be elided.
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.taskLabel)
                        .font(.body.weight(.medium))
                    Text(row.taskSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    badges
                }
                Spacer(minLength: 8)
                actionColumn
            }

            if let progress = row.installState.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("\(row.taskLabel) install progress")
                    .accessibilityValue("\(Int(progress * 100)) percent")
            }

            if let reason = row.disabledReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Unavailable. \(reason)")
            }

            logDisclosure
        }
        .padding(12)
    }

    private var badges: some View {
        // A wrapping layout keeps every badge readable at large dynamic type
        // instead of pushing the license identifier off the row.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { badgeViews }
            VStack(alignment: .leading, spacing: 4) { badgeViews }
        }
    }

    @ViewBuilder
    private var badgeViews: some View {
        MetadataBadge(text: row.sizeText, systemImage: "arrow.down.circle",
                      accessibility: "Download size \(row.sizeText)")
        MetadataBadge(text: row.ramText, systemImage: "memorychip",
                      accessibility: "Declared peak memory \(row.ramText)")
        MetadataBadge(text: licenseBadgeText,
                      systemImage: licenseBadgeIcon,
                      accessibility: "License: \(licenseAccessibilityText)",
                      tint: row.license.gate == .open ? .secondary : .orange)
        Text(row.installState.displayText)
            .font(.caption.weight(.medium))
            .foregroundStyle(stateColor)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("State: \(row.installState.displayText)")
    }

    private var licenseBadgeText: String {
        switch row.license.gate {
        case .open: return row.license.identifier
        case .licenseKey: return "\(row.license.identifier) — key required"
        case .gatedDownload: return "\(row.license.identifier) — terms required"
        }
    }

    private var licenseBadgeIcon: String {
        row.license.gate == .open ? "checkmark.seal" : "lock"
    }

    private var licenseAccessibilityText: String {
        switch row.license.gate {
        case .open: return "\(row.license.identifier), no conditions"
        case .licenseKey: return "\(row.license.identifier), license key required"
        case .gatedDownload:
            return "\(row.license.identifier), terms must be accepted externally"
        }
    }

    private var stateColor: Color {
        switch row.installState {
        case .ready: return .green
        case .failed: return .red
        case .resolvingLicense: return .orange
        default: return .secondary
        }
    }

    private var actionColumn: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button(role: row.action.isDestructive ? .destructive : nil) {
                if row.action.opensGateSheet {
                    gateSelection = PluginGateSelection(ref: row.ref)
                } else {
                    Task { await store.perform(row.action, on: row.ref) }
                }
            } label: {
                Text(row.action.title)
                    .frame(minWidth: 64)
            }
            .disabled(row.action == .unavailable)
            .accessibilityLabel(actionAccessibilityLabel)
            .accessibilityHint(row.disabledReason ?? "")

            if row.isInstalled && row.runtimeState == .ready {
                Text("Loaded")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }

    private var actionAccessibilityLabel: String {
        switch row.action {
        case .install: return "Install \(row.taskLabel), \(row.sizeText) download"
        case .retryInstall: return "Retry installing \(row.taskLabel)"
        case .resolveLicenseKey: return "Enter a license key for \(row.taskLabel)"
        case .acquireCheckpoint: return "Resolve the license for \(row.taskLabel)"
        case .cancel: return "Cancel installing \(row.taskLabel)"
        case .remove: return "Remove \(row.taskLabel)"
        case .unavailable: return "\(row.taskLabel) is unavailable on this Mac"
        }
    }

    /// The streamed installer log stays one click away rather than on screen.
    /// A pip resolution that hangs is otherwise indistinguishable from a slow
    /// download, and the user has no other way to tell them apart.
    @ViewBuilder
    private var logDisclosure: some View {
        let log = store.installLog(for: row.ref)
        if !log.isEmpty {
            DisclosureGroup(isExpanded: Binding(
                get: { isLogExpanded },
                set: { expanded in
                    if expanded { expandedLogs.insert(row.id) }
                    else { expandedLogs.remove(row.id) }
                }
            )) {
                ScrollView {
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxHeight: 140)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            } label: {
                Text("Installation log")
                    .font(.caption)
            }
            .accessibilityLabel("Installation log for \(row.taskLabel)")
        }
    }
}

private struct MetadataBadge: View {
    let text: String
    let systemImage: String
    let accessibility: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibility)
    }
}

// MARK: - License gate

/// Both non-open gates land here. They share the license header and the terms
/// link, and differ in what the user has to supply: a key we can pass to the
/// installer, or a file we can only tell them where to put.
private struct PluginLicenseGateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PluginStore
    let row: PluginStoreRow

    @State private var licenseKey: String = ""
    @State private var validationMessage: String?
    @State private var verifyOutcome: (found: Bool, message: String)?
    @State private var didCopyPath = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(gateTitle)
                    .font(.title3.bold())
                Text("\(row.pluginName) — \(row.taskLabel)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(row.license.identifier, systemImage: "doc.plaintext")
                    .font(.callout.weight(.medium))
                if let instructions = row.license.instructions {
                    Text(instructions)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let terms = row.license.termsURL, let url = URL(string: terms) {
                    Link(destination: url) {
                        Label("Open the license terms", systemImage: "arrow.up.right.square")
                    }
                    .accessibilityLabel("Open the license terms for \(row.license.identifier) in your browser")
                }
            }

            Divider()

            switch row.license.gate {
            case .licenseKey: keyEntry
            case .gatedDownload: checkpointInstructions
            case .open: EmptyView()
            }

            Spacer(minLength: 0)

            Text(PluginStore.privacyStatement)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                primaryButton
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 380)
    }

    private var gateTitle: String {
        row.license.gate == .licenseKey ? "License Number Required" : "Accept Terms and Place Checkpoint"
    }

    // MARK: license-key gate

    /// A SecureField, so the key is not left legible on a screen that may be
    /// shared or recorded. The value lives only in this sheet's `@State` and is
    /// handed to the installer as a call argument; nothing persists it.
    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("License number")
                .font(.callout.weight(.medium))
            SecureField(placeholder, text: $licenseKey)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("License number for \(row.taskLabel)")
                .onSubmit { submitKey() }
            if let message = validationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("License number problem. \(message)")
            }
            Text("The number is passed to the plugin's installer and is not written to the application's settings or to the installation log.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var placeholder: String {
        if let format = row.license.keyFormat, !format.isEmpty {
            return "\(format)…"
        }
        return "License number"
    }

    // MARK: gated-download gate

    private var checkpointInstructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This checkpoint cannot be downloaded by OpenDicomViewer. Accept the terms at the link above, download the file yourself, and place it here:")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let location = row.checkpointLocation {
                HStack(spacing: 8) {
                    Text(location.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(.quaternary.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 6))
                    Button(didCopyPath ? "Copied" : "Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(location.path, forType: .string)
                        didCopyPath = true
                    }
                    .accessibilityLabel("Copy the checkpoint path to the clipboard")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Checkpoint destination: \(location.path)")
            } else {
                Text("The runtime has not reported a destination path for this checkpoint yet.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let outcome = verifyOutcome {
                Text(outcome.message)
                    .font(.caption)
                    .foregroundStyle(outcome.found ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Verification result. \(outcome.message)")
            }
        }
    }

    // MARK: primary action

    @ViewBuilder
    private var primaryButton: some View {
        switch row.license.gate {
        case .licenseKey:
            Button("Install") { submitKey() }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Submit the license number and install \(row.taskLabel)")
        case .gatedDownload:
            Button("Verify") {
                Task {
                    let present = await store.verifyCheckpoint(for: row.ref)
                    verifyOutcome = present
                        ? (true, "Found the checkpoint. This task is ready to use.")
                        : (false, "No file at that path yet. Place the checkpoint and verify again.")
                    if present { dismiss() }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(row.checkpointLocation == nil)
            .accessibilityLabel("Verify that the checkpoint for \(row.taskLabel) is in place")
        case .open:
            EmptyView()
        }
    }

    private func submitKey() {
        let validation = store.validate(licenseKey: licenseKey, for: row.ref)
        guard validation.isValid else {
            validationMessage = validation.message
            return
        }
        validationMessage = nil
        Task {
            await store.submitLicenseKey(licenseKey, for: row.ref)
            // Clear the key from view state as soon as it has been handed over.
            licenseKey = ""
            dismiss()
        }
    }
}

// MARK: - Entry points

/// Sidebar entry point. Shows how many tasks are installed so the store is not
/// a blind door: a user with nothing installed sees that, and a user who has
/// installed a model can confirm it at a glance.
struct PluginStoreSidebarButton: View {
    @ObservedObject var store: PluginStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension")
                Text("Plugins")
                Spacer(minLength: 4)
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help("Install and manage local inference models")
        .accessibilityLabel("Open the plugin store. \(countText).")
    }

    private var countText: String {
        let installed = store.rows.filter(\.isInstalled).count
        return installed == 0 ? "None installed" : "\(installed) installed"
    }
}

/// Contents of the AI menu's plugin section.
///
/// Every task in the manifest is listed whether or not it is installed. A
/// silently absent menu item teaches the user that a capability does not exist;
/// a disabled item that says why teaches them it is one install away, which is
/// the whole point of shipping a store.
struct PluginStoreMenuSection: View {
    @ObservedObject var store: PluginStore
    /// Invoked with the task the user picked. The host routes it to the panel.
    let run: (PluginTaskRef) -> Void
    let openStore: () -> Void

    var body: some View {
        Button("Plugin Store…") { openStore() }
            .accessibilityLabel("Open the plugin store")

        Divider()

        ForEach(store.groups) { group in
            ForEach(group.rows) { row in
                Button(title(for: row)) { run(row.ref) }
                    .disabled(!isRunnable(row))
                    .accessibilityLabel(accessibilityLabel(for: row))
            }
        }
    }

    private func isRunnable(_ row: PluginStoreRow) -> Bool {
        store.menuAvailability(for: row).isRunnable
    }

    private func title(for row: PluginStoreRow) -> String {
        let name = "\(row.pluginName): \(row.taskLabel)"
        guard let reason = reason(for: row) else { return name }
        return "\(name) \u{2014} \(reason)"
    }

    private func reason(for row: PluginStoreRow) -> String? {
        store.menuAvailability(for: row).reason
    }

    private func accessibilityLabel(for row: PluginStoreRow) -> String {
        guard let reason = reason(for: row) else {
            return "Run \(row.taskLabel) with \(row.pluginName)"
        }
        return "\(row.taskLabel) with \(row.pluginName) is unavailable: \(reason)"
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Plugin Store") {
    PluginStoreView(store: PluginStore.previewStore())
}

extension PluginStore {
    /// Preview store backed by the bundled manifest and the mock facade, with
    /// one task of each interesting state so the layout can be judged.
    static func previewStore() -> PluginStore {
        let manifest = (try? PluginManifest.loadBundled())
            ?? PluginManifest(schemaVersion: 1, protocolVersion: kPluginProtocolVersion,
                              plugins: [])
        let facade = MockPluginRuntimeFacade(manifest: manifest)
        if let first = manifest.plugins.first?.tasks.first,
           let pluginID = manifest.plugins.first?.id {
            let ref = PluginTaskRef(pluginID: pluginID, taskID: first.id)
            facade.set(.downloading(progress: 0.42), for: ref)
            facade.appendLog("Fetching mlx-community/gemma-4-E4B-it-4bit", for: ref)
        }
        return PluginStore(facade: facade)
    }
}

#Preview("Plugin Store Entry Points") {
    PluginStoreWiringExample()
}

/// The call sites App.swift and ContentView.swift are expected to adopt,
/// assembled here so they are type-checked in this file rather than discovered
/// to be wrong when the host wires them up.
struct PluginStoreWiringExample: View {
    @StateObject private var pluginStore = PluginStore.previewStore()
    @State private var showPluginStore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Sidebar entry point.
            PluginStoreSidebarButton(store: pluginStore) { showPluginStore = true }

            // AI menu entry point. `run` receives the task the user picked.
            Menu("AI") {
                PluginStoreMenuSection(
                    store: pluginStore,
                    run: { _ in },
                    openStore: { showPluginStore = true })
            }
        }
        .padding()
        .sheet(isPresented: $showPluginStore) {
            PluginStoreView(store: pluginStore)
        }
    }
}
#endif
