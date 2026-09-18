import XCTest
import SwiftUI
@testable import HyprMac

final class WorkspaceOverviewPresentationTests: XCTestCase {
    func testOpenOverlayFollowsSystemAppearanceAndLiveOverrides() throws {
        guard ProcessInfo.processInfo.environment["HYPRMAC_HEADLESS_TESTS"] == "1" else {
            throw XCTSkip("requires isolated config")
        }
        let config = UserConfig.shared
        let previous = config.overlayAppearance
        defer { config.overlayAppearance = previous }
        let host = OverlayHostingView(rootView: Text("Appearance"))
        let panel = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        panel.contentView = host
        defer { panel.close() }

        config.overlayAppearance = .system
        panel.appearance = NSAppearance(named: .aqua)
        XCTAssertNil(host.appearance)
        XCTAssertEqual(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        panel.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)

        config.overlayAppearance = .light
        XCTAssertEqual(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        config.overlayAppearance = .dark
        panel.appearance = NSAppearance(named: .aqua)
        XCTAssertEqual(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        config.overlayAppearance = .system
        XCTAssertNil(host.appearance)
        XCTAssertEqual(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
    }

    func testFilterMatchesWorkspaceMonitorWindowAndBundle() {
        let snapshots = [
            WorkspaceSnapshot(id: 1, monitorID: 10, monitorName: "Studio Display", isActive: true,
                              windows: [window(11, "Research Notes", "com.apple.TextEdit")]),
            WorkspaceSnapshot(id: 2, monitorID: 20, monitorName: "Built-in Display", isActive: false,
                              windows: [window(22, "Terminal", "com.apple.Terminal")])
        ]

        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(snapshots, query: "studio").map(\.id), [1])
        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(snapshots, query: "terminal").map(\.id), [2])
        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(snapshots, query: "TextEdit").map(\.id), [1])
        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(snapshots, query: "2").map(\.id), [2])
        XCTAssertEqual(WorkspaceOverviewPresentation.visibleWorkspaces(snapshots, query: "  ").map(\.id), [1, 2])
    }

    func testSearchFindsAppNameWhenNeitherTitleNorBundleContainsIt() {
        let conversation = WorkspaceWindowSnapshot(
            id: 33, title: "Weekend plans", bundleID: "com.apple.MobileSMS", appName: "Messages",
            normalizedFrame: .zero, isFloating: false)
        XCTAssertTrue(WorkspaceOverviewPresentation.windowMatches(conversation, query: "messages"))
        XCTAssertFalse(WorkspaceOverviewPresentation.windowMatches(conversation, query: "Safari"))
    }

    func testOverviewShowsChatGPTAndSafariWithoutClosedWorkspaceGhosts() {
        let displayed = WorkspaceOverviewPresentation.displayedWindowIDs(
            assigned: [11, 12, 13, 14, 15],
            current: [11, 12],
            knownOrCached: [11, 12, 13, 14, 15],
            hidden: [13, 14],
            reservedHidden: [13])

        XCTAssertEqual(displayed, [11, 12, 13, 15],
                       "ChatGPT, Safari, a minimized window, and an unclassified cached window remain")
        XCTAssertFalse(displayed.contains(14),
                       "closed-but-app-alive assignments must not render as open windows")
    }

    func testOverviewPreservesWindowsDuringCompleteAXOutage() {
        XCTAssertEqual(WorkspaceOverviewPresentation.displayedWindowIDs(
            assigned: [21, 22], current: [], knownOrCached: [21, 22],
            hidden: [21, 22], reservedHidden: [21, 22]), [21, 22])
    }

    func testOverviewPreservesKnownUnhiddenWindowUntilDiscoveryVerdict() {
        XCTAssertEqual(WorkspaceOverviewPresentation.displayedWindowIDs(
            assigned: [31], current: [], knownOrCached: [31],
            hidden: [], reservedHidden: []), [31])
    }

    func testOverviewDoesNotRenderAssignmentWithOnlyStaleOwnerMetadata() {
        XCTAssertTrue(WorkspaceOverviewPresentation.displayedWindowIDs(
            assigned: [41], current: [], knownOrCached: [],
            hidden: [], reservedHidden: []).isEmpty)
    }

    func testFreshReopenedWindowOverridesStaleVerifiedClosedClassification() {
        XCTAssertEqual(WorkspaceOverviewPresentation.displayedWindowIDs(
            assigned: [51], current: [51], knownOrCached: [51],
            hidden: [51], reservedHidden: []), [51])
    }

    func testGeometryNormalizesAndClampsToSchematicBounds() {
        let screen = CGRect(x: 100, y: 200, width: 1000, height: 800)
        let result = WorkspaceOverviewPresentation.normalized(
            CGRect(x: 350, y: 400, width: 500, height: 400), in: screen)
        XCTAssertEqual(result, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))

        let outside = WorkspaceOverviewPresentation.normalized(
            CGRect(x: -900, y: -800, width: 10, height: 10), in: screen)
        XCTAssertEqual(outside.minX, 0)
        XCTAssertEqual(outside.minY, 0)
        XCTAssertLessThanOrEqual(outside.maxX, 1)
        XCTAssertLessThanOrEqual(outside.maxY, 1)

        let overflowing = WorkspaceOverviewPresentation.normalized(
            CGRect(x: 900, y: 800, width: 500, height: 500), in: screen)
        XCTAssertLessThanOrEqual(overflowing.maxX, 1)
        XCTAssertLessThanOrEqual(overflowing.maxY, 1)
    }

    func testOnlyLatestHUDGenerationMayHide() {
        var generations = WorkspaceHUDGeneration()
        let first = generations.next()
        let second = generations.next()
        XCTAssertFalse(generations.shouldHide(first))
        XCTAssertTrue(generations.shouldHide(second))
    }

    func testPlainNumberSwitchesWorkspaceButModifiedNumberDoesNot() {
        XCTAssertEqual(WorkspaceOverviewPresentation.workspaceShortcut(characters: "7", modifiers: []), 7)
        XCTAssertNil(WorkspaceOverviewPresentation.workspaceShortcut(characters: "7", modifiers: .command))
        XCTAssertEqual(WorkspaceOverviewPresentation.workspaceShortcut(characters: "0", modifiers: []), 10)
        XCTAssertNil(WorkspaceOverviewPresentation.workspaceShortcut(characters: "0", modifiers: .shift))
        XCTAssertNil(WorkspaceOverviewPresentation.workspaceShortcut(characters: "77", modifiers: []))
    }

    func testOverviewHeightTracksRowsAndRemainsBounded() {
        XCTAssertEqual(WorkspaceOverviewPresentation.columnCount, 5)
        let oneRow = (1...5).map {
            WorkspaceSnapshot(id: $0, monitorID: 1, monitorName: "Studio", isActive: false,
                              windows: [window(CGWindowID($0), "Window", "com.apple.TextEdit")])
        }
        let twoRows = Constants.workspaceRange.map {
            WorkspaceSnapshot(id: $0, monitorID: 1, monitorName: "Studio", isActive: false,
                              windows: [window(CGWindowID($0), "Window", "com.apple.TextEdit")])
        }
        let short = WorkspaceOverviewPresentation.overviewHeight(
            snapshots: oneRow, scratchpadCount: 0, maximum: 900)
        let tall = WorkspaceOverviewPresentation.overviewHeight(
            snapshots: twoRows, scratchpadCount: 2, maximum: 900)
        XCTAssertGreaterThan(tall, short)
        XCTAssertLessThanOrEqual(tall, 900)
    }

    @MainActor
    func testRenderOverviewAtSupportedWidths() throws {
        guard ProcessInfo.processInfo.environment["HYPRMAC_RENDER_OVERVIEW"] == "1" else {
            throw XCTSkip("set HYPRMAC_RENDER_OVERVIEW=1 to render overview snapshots")
        }

        for populated in [false, true] {
            for width in [CGFloat(1400), 976, 852] {
                var frames: [Int: CGRect] = [:]
                let snapshots = Constants.workspaceRange.map { workspace in
                    WorkspaceSnapshot(
                        id: workspace,
                        monitorID: 1,
                        monitorName: "Studio Display",
                        isActive: workspace == 1,
                        windows: populated ? [window(
                            CGWindowID(workspace), "Workspace \(workspace) window",
                            "com.apple.TextEdit")] : [])
                }
                let view = WorkspaceOverviewView(
                    snapshots: snapshots,
                    scratchpad: [],
                    selectWorkspace: { _ in },
                    selectWindow: { _, _ in },
                    onCardFramesChange: { frames = $0 })
                    .frame(width: width, height: 700)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
                host.layoutSubtreeIfNeeded()

                let deadline = Date().addingTimeInterval(0.5)
                while frames.count < Constants.workspaceCount, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                    host.layoutSubtreeIfNeeded()
                }

                XCTAssertEqual(frames.count, 10, "\(width)-point render did not lay out every card")
                let rows = Dictionary(grouping: frames.values) { Int(round($0.minY)) }
                XCTAssertEqual(rows.count, 2, "\(width)-point render must have two rows")
                XCTAssertEqual(rows.values.map(\.count).sorted(), [5, 5])
                XCTAssertTrue(frames.values.allSatisfy { $0.width > 0 })
                XCTAssertGreaterThanOrEqual(frames.values.map(\.minX).min() ?? -1, 24)
                XCTAssertLessThanOrEqual(frames.values.map(\.maxX).max() ?? width + 1, width - 24)

                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let suffix = populated ? "populated" : "empty"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hyprmac-overview-\(Int(width))-\(suffix).png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    private func window(_ id: CGWindowID, _ title: String, _ bundle: String) -> WorkspaceWindowSnapshot {
        WorkspaceWindowSnapshot(id: id, title: title, bundleID: bundle,
                                appName: bundle.components(separatedBy: ".").last ?? bundle,
                                normalizedFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
                                isFloating: false)
    }
}
