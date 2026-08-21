// PromptSessionTests.swift
// The prompt path converts screen gestures into normalized protocol coordinates
// and invalidates a cached embedding when the slice changes. Both are silent
// failure modes: a coordinate convention that disagrees with the adapter
// segments the wrong location, and a stale embedding returns a plausible mask
// for pixels the user is no longer looking at.

import XCTest
@testable import OpenDicomViewer

@MainActor
final class PromptSessionTests: XCTestCase {

    private func session(sliceKey: String = "0#0") -> PromptSession {
        PromptSession(runtime: PluginRuntime.shared,
                      pluginID: "sam2",
                      sliceKey: sliceKey)
    }

    func testPromptStateStartsEmpty() {
        let s = session()
        XCTAssertTrue(s.state.isEmpty)
        XCTAssertNil(s.state.box)
        XCTAssertTrue(s.state.points.isEmpty)
    }

    /// Points accumulate so a mask can be refined by adding a background click;
    /// replacing on each click would make refinement impossible.
    func testPointsAccumulateAndCarryPolarity() {
        var state = PromptState(sliceKey: "0#0")
        state.points.append(PluginPoint(x: 0.4, y: 0.5, isForeground: true))
        state.points.append(PluginPoint(x: 0.6, y: 0.5, isForeground: false))
        XCTAssertEqual(state.points.count, 2)
        XCTAssertTrue(state.points[0].isForeground)
        XCTAssertFalse(state.points[1].isForeground)
        XCTAssertFalse(state.isEmpty)
    }

    /// A slice change must discard prompts: they were placed against different
    /// pixels, and re-applying them would segment the wrong anatomy.
    func testResetClearsPromptsAndRebindsSlice() {
        var state = PromptState(sliceKey: "0#0")
        state.points.append(PluginPoint(x: 0.5, y: 0.5, isForeground: true))
        state.box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)

        state.reset(sliceKey: "0#7")
        XCTAssertEqual(state.sliceKey, "0#7")
        XCTAssertTrue(state.isEmpty, "prompts must not survive a slice change")
        XCTAssertNil(state.box)
    }

    func testSliceChangedIsIdempotentForTheSameSlice() {
        let s = session(sliceKey: "1#4")
        s.sliceChanged(to: "1#4")
        XCTAssertEqual(s.state.sliceKey, "1#4")
        s.sliceChanged(to: "1#5")
        XCTAssertEqual(s.state.sliceKey, "1#5")
    }

    func testTaskIDMatchesTheManifest() throws {
        var dir = URL(fileURLWithPath: #filePath)
        var manifestURL: URL?
        for _ in 0..<6 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(
                "Sources/OpenDicomViewer/Resources/plugins.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                manifestURL = candidate
                break
            }
        }
        let manifest = try PluginManifest.load(contentsOf: try XCTUnwrap(manifestURL))

        // Every session plugin must expose the task the prompt UI drives,
        // otherwise the tool would be unusable for that plugin.
        for plugin in manifest.plugins where plugin.execution == .session {
            XCTAssertNotNil(plugin.task(id: PromptSession.taskID),
                            "\(plugin.id) declares no \(PromptSession.taskID) task")
        }
    }

    /// Mask bounds drive both hit testing and overlay placement, so an off-by-one
    /// here misplaces the rendered mask relative to the image.
    func testMaskBoundsAreTightAndInclusive() {
        // 4x3 grid, foreground at (1,1) and (2,1).
        var mask = [Bool](repeating: false, count: 12)
        mask[1 * 4 + 1] = true
        mask[1 * 4 + 2] = true
        let bounds = DICOMModel.maskBounds(mask, width: 4, height: 3)
        XCTAssertEqual(bounds, CGRect(x: 1, y: 1, width: 2, height: 1))
    }

    func testMaskBoundsOfEmptyMaskIsZero() {
        let bounds = DICOMModel.maskBounds([Bool](repeating: false, count: 9),
                                           width: 3, height: 3)
        XCTAssertEqual(bounds, .zero)
    }

    func testPromptToolsAreFlaggedAndOthersAreNot() {
        XCTAssertTrue(ActiveTool.aiPoint.isPromptTool)
        XCTAssertTrue(ActiveTool.aiBox.isPromptTool)
        for tool in ActiveTool.allCases where tool != .aiPoint && tool != .aiBox {
            XCTAssertFalse(tool.isPromptTool, "\(tool.rawValue) is not a prompt tool")
        }
    }

    func testEveryToolHasIconAndShortcut() {
        for tool in ActiveTool.allCases {
            XCTAssertFalse(tool.icon.isEmpty, "\(tool.rawValue) has no icon")
            XCTAssertFalse(tool.shortcutHint.isEmpty, "\(tool.rawValue) has no shortcut")
        }
        // Shortcut hints are advertised to the user, so a collision would make
        // one of the two tools unreachable by keyboard.
        let hints = ActiveTool.allCases.map(\.shortcutHint)
        XCTAssertEqual(hints.count, Set(hints).count,
                       "duplicate shortcut: \(hints.sorted())")
    }
}
