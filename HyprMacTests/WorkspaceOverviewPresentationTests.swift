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
        XCTAssertNil(WorkspaceOverviewPresentation.workspaceShortcut(characters: "0", modifiers: []))
        XCTAssertNil(WorkspaceOverviewPresentation.workspaceShortcut(characters: "77", modifiers: []))
    }

    func testOverviewHeightTracksRowsAndRemainsBounded() {
        let oneRow = (1...3).map {
            WorkspaceSnapshot(id: $0, monitorID: 1, monitorName: "Studio", isActive: false,
                              windows: [window(CGWindowID($0), "Window", "com.apple.TextEdit")])
        }
        let threeRows = (1...9).map {
            WorkspaceSnapshot(id: $0, monitorID: 1, monitorName: "Studio", isActive: false,
                              windows: [window(CGWindowID($0), "Window", "com.apple.TextEdit")])
        }
        let short = WorkspaceOverviewPresentation.overviewHeight(
            snapshots: oneRow, scratchpadCount: 0, maximum: 900)
        let tall = WorkspaceOverviewPresentation.overviewHeight(
            snapshots: threeRows, scratchpadCount: 2, maximum: 900)
        XCTAssertGreaterThan(tall, short)
        XCTAssertLessThanOrEqual(tall, 900)
    }

    private func window(_ id: CGWindowID, _ title: String, _ bundle: String) -> WorkspaceWindowSnapshot {
        WorkspaceWindowSnapshot(id: id, title: title, bundleID: bundle,
                                appName: bundle.components(separatedBy: ".").last ?? bundle,
                                normalizedFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
                                isFloating: false)
    }
}
