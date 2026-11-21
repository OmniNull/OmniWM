// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

extension CrossDisplayDragTests {
    func makeRailCrossFixture(
        sourceNiri: Bool = false, targetDwindle: Bool = false,
        orientation: Monitor.Orientation = .horizontal, emptyTarget: Bool = false
    ) throws -> MixedLiveCrossDisplayFixture {
        let fixture: MixedLiveCrossDisplayFixture
        if targetDwindle && !sourceNiri {
            fixture = MixedLiveCrossDisplayFixture(
                common: try makeLiveCrossDisplayFixture(),
                niriOrientation: orientation
            )
            if emptyTarget {
                XCTAssertNotNil(fixture.manager.removeWindow(
                    pid: fixture.tokens[2].pid,
                    windowId: fixture.tokens[2].windowId
                ))
            }
        } else {
            fixture = try makeMixedLiveCrossDisplayFixture(
                sourceNiri: sourceNiri, orientation: orientation, emptyTarget: emptyTarget
            )
        }
        if sourceNiri {
            try stack(fixture.dragged, onto: fixture.tokens[0], in: fixture.base.source, fixture.base)
            let column = try XCTUnwrap(fixture.base.niri.columns(in: fixture.base.source).first)
            fixture.manager.withEngineMutationScope(in: fixture.base.source) {
                XCTAssertTrue(fixture.base.niri.setColumnDisplay(
                    .tabbed, for: column, in: fixture.base.source, motion: fixture.controller.motionPolicy.snapshot(),
                    orientation: orientation, gaps: fixture.controller.innerGap(for: fixture.base.monitors[0])
                ))
            }
        } else {
            fixture.manager.withEngineMutationScope(in: fixture.base.source) {
                XCTAssertTrue(fixture.base.dwindle.groupWindow(
                    fixture.dragged,
                    into: fixture.tokens[0],
                    in: fixture.base.source
                ))
            }
        }
        fixture.controller.settings.gestures.dwindleGroupDragAcrossDisplays = .group
        fixture.completeLayout()
        fixture.focus(fixture.dragged, index: 0)
        fixture.clearHistory()
        return fixture
    }

    func beginRailCrossPull(_ fixture: MixedLiveCrossDisplayFixture) throws -> (frame: CGRect, anchor: CGPoint) {
        let infos = fixture.manager.activeLayoutKind(for: fixture.base.source) == .niri
            ? fixture.controller.niriLayoutHandler.desiredTabRailInfos()
            : fixture.controller.dwindleLayoutHandler.desiredTabRailInfos()
        let rail = try XCTUnwrap(infos.first {
            $0.workspaceId == fixture.base.source && $0.tabs.contains { $0.token == fixture.dragged }
        })
        let index = try XCTUnwrap(rail.tabs.first { $0.token == fixture.dragged }?.visualIndex)
        let frame: CGRect
        if fixture.manager.activeLayoutKind(for: fixture.base.source) == .niri {
            let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.base.source))
            let window = try XCTUnwrap(fixture.base.niri.findNode(for: fixture.dragged, in: fixture.base.source))
            let column = try XCTUnwrap(fixture.base.niri.findColumn(containing: window, in: fixture.base.source))
            frame = try XCTUnwrap(fixture.base.niri.liveWindowFrame(
                of: window, in: column, context: context,
                state: fixture.manager.niriViewportState(for: fixture.base.source)
            ))
        } else {
            frame = try XCTUnwrap(fixture.base.frame(fixture.dragged))
        }
        let press = CGPoint(x: frame.minX - fixture.controller.tabRailStyle.reservedWidth / 2, y: frame.midY)
        let anchor = CGPoint(x: frame.minX + MoveConfiguration.default.dragThreshold, y: frame.midY)
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        fixture.common.report(frame)
        fixture.handler.handleTabRailDrag(TabRailDrag(
            info: rail, visualIndex: index, token: fixture.dragged, location: anchor, pressLocation: press
        ))
        fixture.completeLayout()
        return (frame, anchor)
    }

    func moveRailCrossPull(_ fixture: MixedLiveCrossDisplayFixture, to point: CGPoint) {
        fixture.handler.dispatchMouseDragged(at: point)
        fixture.completeLayout()
    }

    func endRailCrossPull(_ fixture: MixedLiveCrossDisplayFixture, at point: CGPoint, cancelling: Bool) {
        if cancelling { fixture.handler.handleInputSuppressionBegan() }
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.dispatchMouseUp(at: point)
        fixture.handler.finishPendingLiveStackDrop()
        fixture.completeLayout()
    }

    func assertRailCrossFloating(
        _ fixture: MixedLiveCrossDisplayFixture, at point: CGPoint,
        start: (frame: CGRect, anchor: CGPoint), index: Int
    ) throws {
        let workspace = fixture.base.workspaces[index]
        let expected = start.frame.offsetBy(dx: point.x - start.anchor.x, dy: point.y - start.anchor.y)
        if fixture.manager.activeLayoutKind(for: workspace) == .niri {
            XCTAssertEqual(fixture.base.niri.liveFloatingFrame(for: fixture.dragged, in: workspace), expected)
        } else {
            let snapshot = try XCTUnwrap(fixture.controller.dwindleLayoutHandler.makeWorkspaceSnapshot(
                workspaceId: workspace, monitor: fixture.base.monitors[index], resolveConstraints: false,
                isActiveWorkspace: true
            ))
            let diff = fixture.controller.dwindleLayoutHandler.layoutDiff(
                windows: snapshot.windows, frames: fixture.base.dwindle.currentFrames(in: workspace),
                context: fixture.controller.dwindleLayoutHandler.layoutDiffContext(
                    snapshot: snapshot, engine: fixture.base.dwindle, reassertHidden: true, animationTime: nil
                )
            )
            XCTAssertEqual(
                diff.frameChanges.filter { $0.token == fixture.dragged }.map(\.frame),
                [expected.roundedToPhysicalPixels(scale: snapshot.monitor.scale)]
            )
        }
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
    }

    func testDwindleRailCrossingJoinsOneMemberDespiteWholeGroupPreferenceAndIsUndoable() throws {
        let fixture = try makeRailCrossFixture(targetDwindle: true)
        let start = try beginRailCrossPull(fixture)
        let point = try XCTUnwrap(fixture.base.frame(fixture.tokens[2])).center
        moveRailCrossPull(fixture, to: point)
        fixture.assertGroups([[fixture.tokens[0]]], index: 0)
        fixture.assertGroups([[fixture.tokens[2], fixture.dragged]], index: 1)
        try assertRailCrossFloating(fixture, at: point, start: start, index: 1)
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        endRailCrossPull(fixture, at: point, cancelling: false)
        fixture.assertGroups([[fixture.tokens[0]]], index: 0)
        fixture.assertGroups([[fixture.tokens[2], fixture.dragged]], index: 1)
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 1, redo: 0) }
        fixture.assertTerminal()
        fixture.command(.sizing(.undo), token: fixture.tokens[0], index: 0)
        fixture.assertGroups([[fixture.tokens[0], fixture.dragged]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]]], index: 1)
        fixture.command(.sizing(.redo), token: fixture.dragged, index: 0)
        fixture.assertGroups([[fixture.tokens[0]]], index: 0)
        fixture.assertGroups([[fixture.tokens[2], fixture.dragged]], index: 1)
        fixture.assertHistory(index: 0, undo: 1, redo: 0)
    }

    func testDwindleRailPullJoinsEitherNiriAxisAndUndoRestoresTheOriginalGroup() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let fixture = try makeRailCrossFixture(orientation: orientation)
            let start = try beginRailCrossPull(fixture)
            let point = try XCTUnwrap(fixture.base.frame(fixture.tokens[2])).center
            moveRailCrossPull(fixture, to: point)
            fixture.assertGroups([[fixture.tokens[0]]], index: 0)
            fixture.assertGroups([[fixture.tokens[2], fixture.dragged]], index: 1)
            try assertRailCrossFloating(fixture, at: point, start: start, index: 1)
            endRailCrossPull(fixture, at: point, cancelling: false)
            fixture.assertGroups([[fixture.tokens[2], fixture.dragged]], index: 1)
            for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 1, redo: 0) }
            fixture.assertTerminal()
            fixture.command(.sizing(.undo), token: fixture.tokens[0], index: 0)
            fixture.assertGroups([[fixture.tokens[0], fixture.dragged]], index: 0)
            fixture.assertGroups([[fixture.tokens[2]]], index: 1)
            fixture.assertHistory(index: 0, undo: 0, redo: 1)
        }
    }

    func testPullingOneTabFromEitherNiriAxisIntoDwindleCancelsToItsOriginalColumn() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let fixture = try makeRailCrossFixture(sourceNiri: true, targetDwindle: true, orientation: orientation)
            let start = try beginRailCrossPull(fixture)
            let point = try XCTUnwrap(fixture.base.frame(fixture.tokens[2])).center
            moveRailCrossPull(fixture, to: point)
            fixture.assertGroups([[fixture.tokens[0]]], index: 0)
            fixture.assertGroups([[fixture.tokens[2], fixture.dragged]], index: 1)
            try assertRailCrossFloating(fixture, at: point, start: start, index: 1)
            endRailCrossPull(fixture, at: point, cancelling: true)
            fixture.assertGroups([[fixture.tokens[0], fixture.dragged]], index: 0)
            fixture.assertGroups([[fixture.tokens[2]]], index: 1)
            XCTAssertEqual(fixture.base.niri.columns(in: fixture.base.source).first?.displayMode, .tabbed)
            for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
            fixture.assertTerminal()
        }
    }

    func testDwindleRailPullEntersAnEmptyDisplayAndCancellationReturnsOnlyThatMember() throws {
        let fixture = try makeRailCrossFixture(orientation: .vertical, emptyTarget: true)
        let start = try beginRailCrossPull(fixture)
        let point = fixture.controller.insetWorkingFrame(for: fixture.base.monitors[1]).center
        moveRailCrossPull(fixture, to: point)
        fixture.assertGroups([[fixture.tokens[0]]], index: 0)
        fixture.assertGroups([[fixture.dragged]], index: 1)
        try assertRailCrossFloating(fixture, at: point, start: start, index: 1)
        endRailCrossPull(fixture, at: point, cancelling: true)
        fixture.assertGroups([[fixture.tokens[0], fixture.dragged]], index: 0)
        fixture.assertGroups([], index: 1)
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        fixture.assertTerminal()
    }
}
