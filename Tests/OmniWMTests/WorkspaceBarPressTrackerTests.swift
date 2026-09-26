// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarPressTrackerTests: XCTestCase {
    private let workspaceId = WorkspaceDescriptor.ID()
    private let token = WindowToken(pid: 20, windowId: 7)

    func testWindowClickActivatesOnReleaseOverTheSameIcon() {
        var tracker = WorkspaceBarPressTracker()
        let target = WorkspaceBarHitTarget.window(workspaceId, token)

        XCTAssertEqual(tracker.handle(.leftDown, modifiers: [], target: target), .consume)
        XCTAssertEqual(tracker.handle(.leftDragged, modifiers: [], target: target), .consume)
        XCTAssertEqual(tracker.handle(.leftUp, modifiers: [], target: target), .activateWindow(workspaceId, token))
        XCTAssertEqual(tracker.handle(.leftUp, modifiers: [], target: target), .passThrough)
    }

    func testReleaseAwayFromThePressedIconDoesNotActivate() {
        var tracker = WorkspaceBarPressTracker()

        _ = tracker.handle(.leftDown, modifiers: [], target: .window(workspaceId, token))
        XCTAssertEqual(tracker.handle(.leftUp, modifiers: [], target: .workspace(workspaceId)), .consume)
        XCTAssertEqual(tracker.handle(.leftUp, modifiers: [], target: .workspace(workspaceId)), .passThrough)
    }

    func testWorkspaceAndPillLeftClicksPassThroughToSwiftUI() {
        var tracker = WorkspaceBarPressTracker()

        XCTAssertEqual(tracker.handle(.leftDown, modifiers: [], target: .workspace(workspaceId)), .passThrough)
        XCTAssertEqual(tracker.handle(.leftUp, modifiers: [], target: .workspace(workspaceId)), .passThrough)
        XCTAssertEqual(tracker.handle(.leftDown, modifiers: [], target: .scratchpad(1)), .passThrough)
        XCTAssertEqual(tracker.handle(.leftDown, modifiers: [], target: nil), .passThrough)
    }

    func testRightClickAndControlClickShowMenus() {
        var tracker = WorkspaceBarPressTracker()

        XCTAssertEqual(
            tracker.handle(.rightDown, modifiers: [], target: .workspace(workspaceId)),
            .showMenu(.workspace(workspaceId))
        )
        XCTAssertEqual(tracker.handle(.rightDown, modifiers: [], target: nil), .passThrough)
        XCTAssertEqual(
            tracker.handle(.leftDown, modifiers: .control, target: .window(workspaceId, token)),
            .showMenu(.window(workspaceId, token))
        )
        XCTAssertEqual(tracker.handle(.leftUp, modifiers: [], target: nil), .consume)
    }

    func testShiftClickMovesTheFocusedWindowToTheClickedWorkspace() {
        var tracker = WorkspaceBarPressTracker()

        XCTAssertEqual(
            tracker.handle(.leftDown, modifiers: .shift, target: .window(workspaceId, token)),
            .moveFocusedWindow(workspaceId)
        )
        XCTAssertEqual(tracker.handle(.leftUp, modifiers: .shift, target: .window(workspaceId, token)), .consume)
        XCTAssertEqual(
            tracker.handle(.leftDown, modifiers: .shift, target: .workspace(workspaceId)),
            .moveFocusedWindow(workspaceId)
        )
        XCTAssertEqual(tracker.handle(.leftDown, modifiers: .shift, target: .scratchpad(1)), .passThrough)
    }

    func testNewPressDiscardsAPressWhoseReleaseNeverArrived() {
        var tracker = WorkspaceBarPressTracker()

        _ = tracker.handle(.leftDown, modifiers: [], target: .window(workspaceId, token))
        XCTAssertEqual(tracker.handle(.leftDown, modifiers: [], target: .workspace(workspaceId)), .passThrough)
        XCTAssertEqual(tracker.handle(.leftUp, modifiers: [], target: .workspace(workspaceId)), .passThrough)
    }

    func testDraggingAWindowIconPastTheThresholdStartsAndEndsADrag() {
        var tracker = WorkspaceBarPressTracker()
        let target = WorkspaceBarHitTarget.window(workspaceId, token)

        XCTAssertEqual(
            tracker.handle(.leftDown, modifiers: [], target: target, location: CGPoint(x: 100, y: 10)),
            .consume
        )
        XCTAssertEqual(
            tracker.handle(.leftDragged, modifiers: [], target: target, location: CGPoint(x: 104, y: 10)),
            .consume
        )
        XCTAssertEqual(
            tracker.handle(.leftDragged, modifiers: [], target: nil, location: CGPoint(x: 107, y: 10)),
            .beginDrag(workspaceId, token)
        )
        XCTAssertEqual(
            tracker.handle(.leftDragged, modifiers: [], target: nil, location: CGPoint(x: 400, y: 10)),
            .continueDrag
        )
        XCTAssertEqual(
            tracker.handle(.leftUp, modifiers: [], target: target, location: CGPoint(x: 100, y: 10)),
            .endDrag
        )
        XCTAssertEqual(tracker.handle(.leftUp, modifiers: [], target: target), .passThrough)
    }

    func testRightClickDuringADragIsConsumedWithoutAMenu() {
        var tracker = WorkspaceBarPressTracker()
        let target = WorkspaceBarHitTarget.window(workspaceId, token)
        _ = tracker.handle(.leftDown, modifiers: [], target: target, location: .zero)
        _ = tracker.handle(.leftDragged, modifiers: [], target: target, location: CGPoint(x: 20, y: 0))

        XCTAssertEqual(tracker.handle(.rightDown, modifiers: [], target: target), .consume)
        XCTAssertEqual(tracker.handle(.leftUp, modifiers: [], target: nil, location: CGPoint(x: 20, y: 0)), .endDrag)
    }

    func testDraggingFromAWorkspaceLabelDoesNotStartADrag() {
        var tracker = WorkspaceBarPressTracker()

        XCTAssertEqual(
            tracker.handle(.leftDown, modifiers: [], target: .workspace(workspaceId), location: .zero),
            .passThrough
        )
        XCTAssertEqual(
            tracker.handle(.leftDragged, modifiers: [], target: nil, location: CGPoint(x: 50, y: 0)),
            .passThrough
        )
    }

    func testIslandInteractionPrefersWindowAndPillTargetsOverTheirWorkspace() {
        let interaction = WorkspaceBarIslandInteraction()
        interaction.update(.workspace(workspaceId), frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        interaction.update(.window(workspaceId, token), frame: CGRect(x: 40, y: 0, width: 20, height: 20))

        XCTAssertEqual(interaction.target(at: CGPoint(x: 50, y: 10)), .window(workspaceId, token))
        XCTAssertEqual(interaction.target(at: CGPoint(x: 10, y: 10)), .workspace(workspaceId))
        XCTAssertNil(interaction.target(at: CGPoint(x: 150, y: 10)))

        let generation = interaction.generation
        interaction.update(.window(workspaceId, token), frame: CGRect(x: 40, y: 0, width: 20, height: 20))
        XCTAssertEqual(interaction.generation, generation)
        interaction.remove(.window(workspaceId, token), reportedFrame: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(interaction.target(at: CGPoint(x: 50, y: 10)), .window(workspaceId, token))
        interaction.remove(.window(workspaceId, token), reportedFrame: CGRect(x: 40, y: 0, width: 20, height: 20))
        XCTAssertEqual(interaction.target(at: CGPoint(x: 50, y: 10)), .workspace(workspaceId))
    }
}

@MainActor
final class WorkspaceBarIslandInteractionLayoutTests: XCTestCase {
    func testHostedBarRegistersRegionsThatMapBackToTheirScreenLocation() throws {
        try assertHostedRegions(orientation: .horizontal)
        try assertHostedRegions(orientation: .vertical)
    }

    private func assertHostedRegions(orientation: WorkspaceBarOrientation) throws {
        let token = WindowToken(pid: 30, windowId: 1)
        let handle = WindowHandle(id: token)
        let window = WorkspaceBarWindowItem(
            id: token,
            handle: handle,
            windowId: token.windowId,
            appName: "App",
            bundleId: nil,
            icon: nil,
            isFocused: false,
            windowCount: 1,
            hiddenWindowCount: 0,
            allWindows: [
                WorkspaceBarWindowInfo(
                    id: token,
                    handle: handle,
                    windowId: token.windowId,
                    title: "Doc",
                    isFocused: false,
                    isAppHidden: false
                )
            ]
        )
        let item = WorkspaceBarItem(
            id: UUID(),
            name: "1",
            rawName: "1",
            isFocused: true,
            tiledWindows: [window],
            floatingWindows: []
        )
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [item], scratchpads: []),
            showLabels: true,
            showSystemStatsButton: false,
            backgroundOpacity: 0.6,
            barHeight: 24,
            accentColor: nil,
            textColor: nil,
            orientation: orientation
        )
        let interaction = WorkspaceBarIslandInteraction()
        let panel = WorkspaceBarPanel.defaultPanel()
        let island = WorkspaceBarIslandPanel(
            panel: panel,
            rootView: WorkspaceBarView(
                model: WorkspaceBarModel(snapshot: snapshot),
                motionPolicy: MotionPolicy(animationsEnabled: false),
                onFocusWorkspace: { _ in },
                onFocusWindow: { _ in },
                onActivateScratchpad: { _ in },
                interaction: interaction
            ),
            interaction: interaction,
            resolved: ResolvedBarSettings(
                enabled: true,
                showLabels: true,
                showFloatingWindows: false,
                deduplicateAppIcons: false,
                hideEmptyWorkspaces: false,
                excludedBundleIDs: [],
                reserveLayoutSpace: false,
                notchMode: .off,
                notchActiveZoneWidth: 180,
                systemStatsButton: false,
                position: orientation.isVertical ? .left : .overlappingMenuBar,
                windowLevel: .popup,
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
        )
        defer { panel.close() }
        let panelFrame = orientation.isVertical
            ? CGRect(x: 200, y: 300, width: 24, height: 200)
            : CGRect(x: 200, y: 700, width: 200, height: 28)
        panel.setFrame(panelFrame, display: true)
        island.hostingView.layoutSubtreeIfNeeded()

        let workspaceFrame = try XCTUnwrap(interaction.frames[.workspace(item.id)])
        let iconFrame = try XCTUnwrap(interaction.frames[.window(item.id, token)])
        XCTAssertNotNil(interaction.labelFrames[item.id])
        XCTAssertTrue(workspaceFrame.contains(CGPoint(x: iconFrame.midX, y: iconFrame.midY)))
        XCTAssertEqual(
            interaction.target(at: CGPoint(x: iconFrame.midX, y: iconFrame.midY)),
            .window(item.id, token)
        )

        let screenIcon = try XCTUnwrap(island.hostingView.workspaceBarScreenRect(forLocalRect: iconFrame))
        XCTAssertTrue(panelFrame.contains(screenIcon))
        let windowPoint = panel.convertPoint(fromScreen: CGPoint(x: screenIcon.midX, y: screenIcon.midY))
        let local = island.hostingView.workspaceBarLocalPoint(forWindowPoint: windowPoint)
        XCTAssertEqual(interaction.target(at: local), .window(item.id, token))
    }
}
