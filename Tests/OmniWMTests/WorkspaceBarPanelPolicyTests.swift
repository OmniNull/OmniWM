// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarPanelPolicyTests: XCTestCase {
    private let monitor = Monitor(
        id: .init(displayId: 7),
        displayId: 7,
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        hasNotch: false,
        name: "Plain"
    )

    func testFillModeUsesAboveStatusLevelWithoutFullscreenAuxiliary() {
        let resolved = makeResolved(notchMode: .fillLeftOfNotch, windowLevel: .screensaver)
        let island = makeIsland(resolved: resolved)
        defer { island.panel.close() }

        XCTAssertEqual(
            island.panel.level.rawValue,
            NSWindow.Level.statusBar.rawValue + 1
        )
        let behavior = island.panel.collectionBehavior
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.stationary))
        XCTAssertFalse(behavior.contains(.fullScreenAuxiliary))
    }

    func testNonFillModeUsesConfiguredLevelAndExistingFlags() {
        let resolved = makeResolved(notchMode: .off, windowLevel: .screensaver)
        let island = makeIsland(resolved: resolved)
        defer { island.panel.close() }

        XCTAssertEqual(island.panel.level, .screenSaver)
        XCTAssertEqual(
            island.panel.collectionBehavior,
            [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        )
    }

    func testExistingPanelRestoresConfiguredPolicyWhenLeavingFillMode() {
        let normal = makeResolved(notchMode: .off, windowLevel: .floating)
        let island = makeIsland(resolved: normal)
        defer { island.panel.close() }

        island.applySettings(
            resolved: makeResolved(notchMode: .fillLeftOfNotch, windowLevel: .screensaver),
            monitor: monitor
        )
        XCTAssertEqual(island.panel.level.rawValue, NSWindow.Level.statusBar.rawValue + 1)
        XCTAssertFalse(island.panel.collectionBehavior.contains(.fullScreenAuxiliary))

        island.applySettings(resolved: normal, monitor: monitor)
        XCTAssertEqual(island.panel.level, .floating)
        XCTAssertEqual(island.panel.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
    }

    private func makeIsland(resolved: ResolvedBarSettings) -> WorkspaceBarIslandPanel {
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            backgroundOpacity: 0.6,
            barHeight: 24
        )
        return WorkspaceBarIslandPanel(
            panel: WorkspaceBarPanel.defaultPanel(),
            rootView: WorkspaceBarView(
                model: WorkspaceBarModel(snapshot: snapshot),
                motionPolicy: MotionPolicy(animationsEnabled: false)
            ),
            resolved: resolved,
            monitor: monitor
        )
    }

    private func makeResolved(
        notchMode: WorkspaceBarNotchMode,
        windowLevel: WorkspaceBarWindowLevel
    ) -> ResolvedBarSettings {
        ResolvedBarSettings(
            enabled: true,
            showLabels: true,
            showFloatingWindows: false,
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            excludedBundleIDs: [],
            reserveLayoutSpace: false,
            notchMode: notchMode,
            notchActiveZoneWidth: 180,
            systemStatsButton: false,
            position: .overlappingMenuBar,
            windowLevel: windowLevel,
            height: 24,
            backgroundOpacity: 0.6,
            inactiveIconOpacity: nil,
            transparentBackground: false,
            solidBlackBackground: false,
            showItemBackgrounds: true,
            showAccentHighlights: true,
            xOffset: 0,
            yOffset: 0,
            accentColor: nil,
            textColor: nil
        )
    }
}
