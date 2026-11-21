// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleLayoutHistoryTests: XCTestCase {
    func testRatioChangeRestoresExactGeometryAndTreeIdentityThroughUndoAndRedo() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            let fixture = try Fixture(orientation: orientation)
            let before = try XCTUnwrap(fixture.engine.layoutSnapshot(in: fixture.workspace, focused: fixture.first))
            XCTAssertTrue(fixture.engine.resizeSelected(
                by: 1 / 4, orientation: orientation, in: fixture.workspace
            ))
            fixture.engine.recordLayoutChange(in: fixture.workspace, since: before)
            try fixture.assertSplit(ratio: 1 + 1 / 4)
            try fixture.assertFrames(ratio: 1 + 1 / 4)
            fixture.assertCounts(undo: 1, redo: 0)

            let undone = try XCTUnwrap(fixture.engine.stepLayoutHistory(
                .undo, in: fixture.workspace, focused: fixture.first
            ))
            XCTAssertEqual(undone.focused, fixture.first)
            try fixture.assertSplit(ratio: 1)
            try fixture.assertFrames(ratio: 1)
            fixture.assertCounts(undo: 0, redo: 1)

            let redone = try XCTUnwrap(fixture.engine.stepLayoutHistory(
                .redo, in: fixture.workspace, focused: fixture.first
            ))
            XCTAssertEqual(redone.focused, fixture.first)
            try fixture.assertSplit(ratio: 1 + 1 / 4)
            try fixture.assertFrames(ratio: 1 + 1 / 4)
            fixture.assertCounts(undo: 1, redo: 0)
            XCTAssertNil(fixture.engine.stepLayoutHistory(.redo, in: fixture.workspace))
        }
    }

    func testGroupingReplayRestoresMembersActiveFullscreenSelectionAndPreselection() throws {
        let fixture = try Fixture(orientation: .horizontal)
        XCTAssertTrue(fixture.engine.toggleFullscreen(for: fixture.second, in: fixture.workspace))
        XCTAssertTrue(fixture.engine.setPreselection(.up, in: fixture.workspace))
        let before = try XCTUnwrap(fixture.engine.layoutSnapshot(in: fixture.workspace, focused: fixture.first))

        XCTAssertTrue(fixture.engine.groupWindow(fixture.second, into: fixture.first, in: fixture.workspace))
        XCTAssertTrue(fixture.engine.setPreselection(.left, in: fixture.workspace))
        fixture.engine.recordLayoutChange(in: fixture.workspace, since: before)
        try fixture.assertGroup()
        XCTAssertEqual(fixture.engine.existingState(for: fixture.workspace)?.preselection, .left)
        fixture.assertCounts(undo: 1, redo: 0)

        let undone = try XCTUnwrap(fixture.engine.stepLayoutHistory(
            .undo, in: fixture.workspace, focused: fixture.second
        ))
        XCTAssertEqual(undone.focused, fixture.first)
        try fixture.assertSplit(ratio: 1, secondFullscreen: true)
        XCTAssertEqual(fixture.engine.existingState(for: fixture.workspace)?.preselection, .up)
        fixture.assertCounts(undo: 0, redo: 1)

        let redone = try XCTUnwrap(fixture.engine.stepLayoutHistory(
            .redo, in: fixture.workspace, focused: fixture.first
        ))
        XCTAssertEqual(redone.focused, fixture.second)
        try fixture.assertGroup()
        XCTAssertEqual(fixture.engine.existingState(for: fixture.workspace)?.preselection, .left)
        fixture.assertCounts(undo: 1, redo: 0)
    }

    func testMoveToRootReplayRestoresParentLinksForAncestorResizeAndNavigation() throws {
        let fixture = try Fixture(orientation: .horizontal)
        let nested = WindowToken(pid: 3, windowId: 3)
        fixture.engine.setPreselection(.up, in: fixture.workspace)
        fixture.engine.addWindow(token: nested, to: fixture.workspace, activeWindowFrame: nil)
        _ = fixture.engine.calculateLayout(for: fixture.workspace, screen: fixture.screen)
        try assertNestedTopology(fixture, inside: nested, outside: fixture.second)
        let before = try XCTUnwrap(fixture.engine.layoutSnapshot(in: fixture.workspace, focused: nested))

        XCTAssertTrue(fixture.engine.moveSelectionToRoot(stable: false, in: fixture.workspace))
        fixture.engine.recordLayoutChange(in: fixture.workspace, since: before)
        try assertNestedTopology(fixture, inside: fixture.second, outside: nested)
        XCTAssertNotNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspace, focused: nested))
        try assertNestedTopology(fixture, inside: nested, outside: fixture.second)

        let branch = try XCTUnwrap(fixture.engine.root(for: fixture.workspace)?.firstChild())
        XCTAssertTrue(fixture.engine.resizeSelected(by: 1 / 4, orientation: .vertical, in: fixture.workspace))
        XCTAssertEqual(branch.splitRatio, 1 - 1 / 4)
        XCTAssertTrue(fixture.engine.resizeSelected(by: -1 / 4, orientation: .vertical, in: fixture.workspace))
        XCTAssertEqual(branch.splitRatio, 1)
        _ = fixture.engine.calculateLayout(for: fixture.workspace, screen: fixture.screen)
        XCTAssertEqual(fixture.engine.moveFocus(direction: .down, in: fixture.workspace), fixture.first)
        fixture.engine.setSelectedNode(
            fixture.engine.findNode(for: nested, in: fixture.workspace),
            in: fixture.workspace
        )

        XCTAssertNotNil(fixture.engine.stepLayoutHistory(.redo, in: fixture.workspace, focused: nested))
        try assertNestedTopology(fixture, inside: fixture.second, outside: nested)
        XCTAssertTrue(fixture.engine.resizeSelected(by: 1 / 4, orientation: .horizontal, in: fixture.workspace))
        XCTAssertEqual(fixture.engine.root(for: fixture.workspace)?.splitRatio, 1 - 1 / 4)
        XCTAssertTrue(fixture.engine.resizeSelected(by: -1 / 4, orientation: .horizontal, in: fixture.workspace))
        try assertNestedTopology(fixture, inside: fixture.second, outside: nested)
    }

    func testClosingAnUnrelatedInactiveGroupMemberKeepsNativeResizeRunning() throws {
        let fixture = try Fixture(orientation: .horizontal)
        let inactive = WindowToken(pid: 3, windowId: 3)
        fixture.engine.setSelectedNode(
            fixture.engine.findNode(for: fixture.second, in: fixture.workspace), in: fixture.workspace
        )
        fixture.engine.setPreselection(.up, in: fixture.workspace)
        fixture.engine.addWindow(token: inactive, to: fixture.workspace, activeWindowFrame: nil)
        XCTAssertTrue(fixture.engine.groupWindow(inactive, into: fixture.second, in: fixture.workspace))
        XCTAssertEqual(fixture.engine.activateWindowOutcome(fixture.second, in: fixture.workspace), .activated)
        _ = fixture.engine.calculateLayout(for: fixture.workspace, screen: fixture.screen)
        XCTAssertEqual(fixture.engine.inactiveGroupTokens(in: fixture.workspace), [inactive])
        let start = fixture.screen.center
        XCTAssertTrue(fixture.engine.interactiveResizeBegin(
            token: fixture.first, edges: .right, startLocation: start,
            in: fixture.workspace, innerGap: fixture.engine.settings.innerGap
        ))
        XCTAssertTrue(fixture.engine.interactiveResizeUpdate(currentLocation: CGPoint(
            x: start.x + fixture.screen.width / 16, y: start.y
        )))
        XCTAssertEqual(fixture.engine.root(for: fixture.workspace)?.splitRatio, 1 + 1 / 8)

        fixture.engine.removeWindow(token: inactive, from: fixture.workspace)

        XCTAssertEqual(fixture.engine.interactiveResize?.token, fixture.first)
        XCTAssertEqual(fixture.engine.interactiveResize?.horizontal?.splitId, fixture.rootId)
        fixture.assertCounts(undo: 0, redo: 0)
        XCTAssertFalse(fixture.engine.containsWindow(inactive, in: fixture.workspace))
        XCTAssertEqual(
            fixture.engine.activeTileMember(containing: fixture.second, in: fixture.workspace),
            fixture.second
        )
        XCTAssertTrue(fixture.engine.interactiveResizeUpdate(currentLocation: CGPoint(
            x: start.x + fixture.screen.width / 8, y: start.y
        )))
        XCTAssertEqual(fixture.engine.root(for: fixture.workspace)?.splitRatio, 1 + 1 / 4)
        try fixture.assertFrames(ratio: 1 + 1 / 4)
        XCTAssertTrue(fixture.engine.interactiveResizeEnd())
        XCTAssertNil(fixture.engine.interactiveResize)
        fixture.assertCounts(undo: 1, redo: 0)
        XCTAssertNotNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspace))
        XCTAssertFalse(fixture.engine.containsWindow(inactive, in: fixture.workspace))
        try fixture.assertFrames(ratio: 1)
    }

    func testOptionUnilateralChangeSurvivesLaterBilateralObservationWithoutAnOppositeBoundary() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            let fixture = try Fixture(orientation: orientation)
            let horizontal = orientation == .horizontal
            let extent = horizontal ? fixture.screen.width : fixture.screen.height
            let start = fixture.screen.center
            let location = CGPoint(
                x: start.x + (horizontal ? extent / 16 : 0),
                y: start.y + (horizontal ? 0 : extent / 16)
            )
            XCTAssertTrue(fixture.engine.interactiveResizeBegin(
                token: fixture.first, edges: horizontal ? .right : .top, startLocation: start,
                in: fixture.workspace, innerGap: fixture.engine.settings.innerGap, allowsCentered: true
            ))
            XCTAssertTrue(fixture.engine.interactiveResizeUpdate(currentLocation: location))
            XCTAssertFalse(fixture.engine.interactiveResizeUpdate(
                currentLocation: location, edges: horizontal ? [.left, .right] : [.bottom, .top]
            ))
            XCTAssertEqual(fixture.engine.root(for: fixture.workspace)?.splitRatio, 1 + 1 / 8)
            fixture.assertCounts(undo: 0, redo: 0)
            XCTAssertTrue(fixture.engine.interactiveResizeEnd())
            fixture.assertCounts(undo: 1, redo: 0)
            XCTAssertNotNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspace))
            try fixture.assertSplit(ratio: 1)
            try fixture.assertFrames(ratio: 1)
        }
    }

    func testOrdinaryCenteredAndCornerGesturesRecordOnlyTheirFinalRatioDifference() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            for mode in [GestureMode.ordinary, .centered, .corner] {
                let fixture = try Fixture(orientation: orientation)
                let horizontal = orientation == .horizontal
                if mode != .ordinary {
                    fixture.engine.setPreselection(
                        mode == .centered ? (horizontal ? .left : .down) : (horizontal ? .up : .right),
                        in: fixture.workspace
                    )
                    fixture.engine.addWindow(
                        token: WindowToken(pid: 3, windowId: 3),
                        to: fixture.workspace,
                        activeWindowFrame: nil
                    )
                }
                _ = fixture.engine.calculateLayout(for: fixture.workspace, screen: fixture.screen)
                let root = try XCTUnwrap(fixture.engine.root(for: fixture.workspace))
                let inner = mode == .ordinary ? nil : root.firstChild()
                let extent = horizontal ? fixture.screen.width : fixture.screen.height
                let halfGrowth = extent / 32
                let centeredInnerRatio = 2 * (1 - (extent / 4 + 2 * halfGrowth) / (extent / 2 + halfGrowth))
                for returnsToStart in [true, false] {
                    let start = fixture.screen.center
                    XCTAssertTrue(fixture.engine.interactiveResizeBegin(
                        token: fixture.first, edges: mode.edges(horizontal: horizontal), startLocation: start,
                        in: fixture.workspace, innerGap: fixture.engine.settings.innerGap,
                        allowsCentered: mode == .centered
                    ))
                    XCTAssertTrue(fixture.engine.interactiveResizeUpdate(
                        currentLocation: mode.location(in: fixture.screen, horizontal: horizontal)
                    ))
                    XCTAssertEqual(root.splitRatio, mode == .centered ? 1 + 1 / 16 : 1 + 1 / 8)
                    if let inner {
                        XCTAssertEqual(inner.splitRatio, mode == .centered ? centeredInnerRatio : 1 + 1 / 16)
                    }
                    fixture.assertCounts(undo: 0, redo: 0)
                    if returnsToStart {
                        XCTAssertTrue(fixture.engine.interactiveResizeUpdate(currentLocation: start))
                    }
                    XCTAssertTrue(fixture.engine.interactiveResizeEnd())
                    fixture.assertCounts(undo: returnsToStart ? 0 : 1, redo: 0)
                    if !returnsToStart {
                        XCTAssertNotNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspace))
                    }
                    XCTAssertEqual(root.splitRatio, 1)
                    if let inner { XCTAssertEqual(inner.splitRatio, 1) }
                    assertParentLinks(root, parent: nil)
                }
            }
        }
    }

    func testNativeHistoryKeepsAGroupAdmittedDuringTheGestureAndItsCurrentSelection() throws {
        let fixture = try Fixture(orientation: .horizontal)
        let admitted = WindowToken(pid: 3, windowId: 3)
        XCTAssertTrue(fixture.beginResize())
        XCTAssertTrue(fixture.engine.interactiveResizeUpdate(currentLocation: CGPoint(
            x: fixture.screen.midX + fixture.screen.width / 16, y: fixture.screen.midY
        )))
        fixture.engine.setSelectedNode(
            fixture.engine.findNode(for: fixture.second, in: fixture.workspace),
            in: fixture.workspace
        )
        fixture.engine.setPreselection(.up, in: fixture.workspace)
        fixture.engine.addWindow(token: admitted, to: fixture.workspace, activeWindowFrame: nil)
        XCTAssertTrue(fixture.engine.groupWindow(admitted, into: fixture.second, in: fixture.workspace))
        XCTAssertTrue(fixture.engine.setPreselection(.left, in: fixture.workspace))
        fixture.assertCounts(undo: 0, redo: 0)
        XCTAssertTrue(fixture.engine.interactiveResizeEnd())
        XCTAssertNotNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspace))
        XCTAssertEqual(fixture.engine.root(for: fixture.workspace)?.splitRatio, 1)
        let group = try XCTUnwrap(fixture.engine.tileSnapshot(for: admitted, in: fixture.workspace))
        XCTAssertEqual(group.members.map(\.token), [fixture.second, admitted])
        XCTAssertEqual(group.activeToken, admitted)
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspace), admitted)
        XCTAssertEqual(fixture.engine.existingState(for: fixture.workspace)?.preselection, .left)
        XCTAssertNotNil(fixture.engine.stepLayoutHistory(.redo, in: fixture.workspace))
        XCTAssertEqual(fixture.engine.root(for: fixture.workspace)?.splitRatio, 1 + 1 / 8)
        XCTAssertEqual(
            fixture.engine.tileSnapshot(for: admitted, in: fixture.workspace)?.members.map(\.token),
            [fixture.second, admitted]
        )
    }

    func testNoOpsKeepRedoAndANewMutationClearsIt() throws {
        let fixture = try Fixture(orientation: .horizontal)
        fixture.recordRatioChange(by: 1 / 4)
        XCTAssertNotNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspace))
        let before = fixture.engine.layoutSnapshot(in: fixture.workspace)
        XCTAssertTrue(fixture.engine.resizeSelected(by: 1 / 4, orientation: .horizontal, in: fixture.workspace))
        XCTAssertTrue(fixture.engine.resizeSelected(by: -1 / 4, orientation: .horizontal, in: fixture.workspace))
        fixture.engine.recordLayoutChange(in: fixture.workspace, since: before)
        fixture.assertCounts(undo: 0, redo: 1)
        fixture.recordRatioChange(by: -1 / 4)
        fixture.assertCounts(undo: 1, redo: 0)
        XCTAssertNil(fixture.engine.stepLayoutHistory(.redo, in: fixture.workspace))
        try fixture.assertFrames(ratio: 1 - 1 / 4)
    }

    func testHistoryRingKeepsItsDeclaredLimitAndReplaysInOrder() throws {
        let fixture = try Fixture(orientation: .horizontal)
        let limit = DwindleLayoutHistory.limit
        let changes = limit + limit / 2
        let delta = CGFloat(1) / CGFloat(2 * changes)
        for _ in 0 ..< changes { fixture.recordRatioChange(by: delta) }
        fixture.assertCounts(undo: limit, redo: 0)
        for remaining in (changes - limit ..< changes).reversed() {
            XCTAssertNotNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspace))
            let expected = (0 ..< remaining).reduce(CGFloat(1)) { ratio, _ in ratio + delta }
            XCTAssertEqual(fixture.engine.root(for: fixture.workspace)?.splitRatio, expected)
        }
        XCTAssertNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspace))
        fixture.assertCounts(undo: 0, redo: limit)
        for completed in changes - limit + 1 ... changes {
            XCTAssertNotNil(fixture.engine.stepLayoutHistory(.redo, in: fixture.workspace))
            let expected = (0 ..< completed).reduce(CGFloat(1)) { ratio, _ in ratio + delta }
            XCTAssertEqual(fixture.engine.root(for: fixture.workspace)?.splitRatio, expected)
        }
        fixture.assertCounts(undo: limit, redo: 0)
    }

    func testClosedMembersStayClosedAndEntirelyNewGroupsSurviveReplay() throws {
        let fixture = try Fixture(orientation: .horizontal)
        let before = fixture.engine.layoutSnapshot(in: fixture.workspace)
        XCTAssertTrue(fixture.engine.toggleFullscreen(for: fixture.first, in: fixture.workspace))
        fixture.engine.recordLayoutChange(in: fixture.workspace, since: before)
        fixture.engine.removeWindow(token: fixture.second, from: fixture.workspace)
        let opened = WindowToken(pid: 3, windowId: 3)
        let grouped = WindowToken(pid: 4, windowId: 4)
        for token in [opened, grouped] {
            fixture.engine.setPreselection(.right, in: fixture.workspace)
            fixture.engine.addWindow(token: token, to: fixture.workspace, activeWindowFrame: nil)
        }
        XCTAssertTrue(fixture.engine.groupWindow(grouped, into: opened, in: fixture.workspace))
        let groupId = try XCTUnwrap(fixture.engine.tileSnapshot(for: opened, in: fixture.workspace)?.id)
        for direction in [DwindleLayoutHistoryDirection.undo, .redo] {
            XCTAssertNotNil(fixture.engine.stepLayoutHistory(direction, in: fixture.workspace))
            if case .undo = direction { XCTAssertFalse(fixture.engine.isWindowFullscreen(
                fixture.first,
                in: fixture.workspace
            )) }
            XCTAssertFalse(fixture.engine.containsWindow(fixture.second, in: fixture.workspace))
            XCTAssertEqual(fixture.engine.windowCount(in: fixture.workspace), 3)
            XCTAssertEqual(fixture.engine.tileCount(in: fixture.workspace), 2)
            let group = try XCTUnwrap(fixture.engine.tileSnapshot(for: opened, in: fixture.workspace))
            XCTAssertEqual(group.id, groupId)
            XCTAssertEqual(group.members.map(\.token), [opened, grouped])
            XCTAssertEqual(group.activeToken, grouped)
        }
        XCTAssertTrue(fixture.engine.isWindowFullscreen(fixture.first, in: fixture.workspace))
    }

    func testHistoryRestoresTheEdgeExpansionReturnIntent() throws {
        for orientation in [DwindleOrientation.horizontal, .vertical] {
            let fixture = try Fixture(orientation: orientation)
            let horizontal = orientation == .horizontal
            let extent = horizontal ? fixture.screen.width : fixture.screen.height
            let minimum = extent / 64 - fixture.engine.settings.innerGap / 2
            fixture.engine.updateWindowConstraints(for: fixture.second, constraints: WindowSizeConstraints(
                minSize: CGSize(width: horizontal ? minimum : 1, height: horizontal ? 1 : minimum),
                maxSize: .zero, isFixed: false
            ))
            let before = fixture.engine.layoutSnapshot(in: fixture.workspace)
            XCTAssertTrue(fixture.engine.toggleEdgeExpansion(
                for: fixture.first,
                edge: horizontal ? .right : .top,
                in: fixture.workspace
            ))
            fixture.engine.recordLayoutChange(in: fixture.workspace, since: before)
            XCTAssertNotNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspace))
            try fixture.assertFrames(ratio: 1)
            XCTAssertNil(fixture.engine.root(for: fixture.workspace)?.edgeExpansion)
            XCTAssertNotNil(fixture.engine.stepLayoutHistory(.redo, in: fixture.workspace))
            XCTAssertEqual(fixture.engine.root(for: fixture.workspace)?.splitRatio, 63 / 32)
            _ = fixture.engine.calculateLayout(for: fixture.workspace, screen: fixture.screen)
            XCTAssertTrue(fixture.engine.toggleEdgeExpansion(
                for: fixture.first,
                edge: horizontal ? .right : .top,
                in: fixture.workspace
            ))
            try fixture.assertFrames(ratio: 1)
            XCTAssertNil(fixture.engine.root(for: fixture.workspace)?.edgeExpansion)
        }
    }

    func testActiveInteractionsRefuseHistoryWithoutConsumingAndWorkspacesStayIsolated() throws {
        let fixture = try Fixture(orientation: .horizontal)
        fixture.recordRatioChange(by: 1 / 4)
        let other = WorkspaceDescriptor.ID()
        fixture.engine.addWindow(token: WindowToken(pid: 3, windowId: 3), to: other, activeWindowFrame: nil)
        XCTAssertNil(fixture.engine.stepLayoutHistory(.undo, in: other))
        for moving in [false, true] {
            XCTAssertTrue(moving ? fixture.engine.interactiveMoveBegin(
                token: fixture.first,
                startLocation: fixture.screen.center,
                in: fixture.workspace
            ) : fixture.beginResize())
            XCTAssertNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspace))
            fixture.assertCounts(undo: 1, redo: 0)
            if moving { fixture.engine.interactiveMoveCancel() } else { fixture.engine.clearInteractiveResize() }
        }
        XCTAssertNotNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspace))
        try fixture.assertFrames(ratio: 1)
        XCTAssertEqual(fixture.engine.windowCount(in: other), 1)
        fixture.engine.removeLayout(for: fixture.workspace)
        fixture.assertCounts(undo: 0, redo: 0)
        XCTAssertNil(fixture.engine.stepLayoutHistory(.redo, in: fixture.workspace))
    }

    func testRatioReplayKeepsCurrentNodesTilesCachesAndPresentedAnimation() throws {
        let fixture = try Fixture(orientation: .horizontal)
        fixture.recordRatioChange(by: 1 / 4)
        _ = fixture.engine.calculateLayout(for: fixture.workspace, screen: fixture.screen)
        let root = try XCTUnwrap(fixture.engine.root(for: fixture.workspace))
        let node = try XCTUnwrap(fixture.engine.findNode(for: fixture.first, in: fixture.workspace))
        let tile = try XCTUnwrap(node.tile)
        let raw = fixture.engine.splitRect(
            fixture.screen,
            orientation: .horizontal,
            ratio: 1 + 1 / 4,
            minimums: (first: .zero, second: .zero)
        ).0
        let target = DwindleGapCalculator.applyGaps(
            nodeRect: raw,
            tilingArea: fixture.screen,
            settings: fixture.engine.settings
        )
        let origin = target.offsetBy(dx: -fixture.screen.width / 16, dy: fixture.screen.height / 16)
        let config = fixture.engine.windowMovementAnimationConfig
        let sampleTime = config.duration / 2
        node.animateFrom(oldFrame: origin, newFrame: target, startTime: 0, config: config, animated: true)
        let progress = CGFloat(config.value(at: sampleTime / config.duration))
        let presented = CGRect(
            x: origin.minX + (target.minX - origin.minX) * progress,
            y: origin.minY + (target.minY - origin.minY) * progress,
            width: target.width,
            height: target.height
        )
        XCTAssertEqual(node.presentedFrame(at: sampleTime), presented)

        XCTAssertNotNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspace, at: sampleTime))

        XCTAssertTrue(fixture.engine.root(for: fixture.workspace) === root)
        XCTAssertTrue(fixture.engine.findNode(for: fixture.first, in: fixture.workspace) === node)
        XCTAssertTrue(node.tile === tile)
        XCTAssertEqual(root.splitRatio, 1)
        XCTAssertEqual(node.cachedFrame, target)
        XCTAssertEqual(node.cachedContentFrame, target)
        XCTAssertEqual(node.frameAnimation?.fromFrame, origin)
        XCTAssertEqual(node.frameAnimation?.toFrame, target)
        XCTAssertEqual(node.presentedFrame(at: sampleTime), presented)
        XCTAssertTrue(node.hasActiveAnimations(at: sampleTime))
        XCTAssertTrue(try XCTUnwrap(fixture.engine.existingState(for: fixture.workspace)).pendingMovementFrameSeeds
            .isEmpty)
    }

    func testStructuralReplaySeedsCurrentPresentedOriginsForTheExistingTransitionOwner() throws {
        let fixture = try Fixture(orientation: .horizontal)
        let before = fixture.engine.layoutSnapshot(in: fixture.workspace)
        XCTAssertTrue(fixture.engine.groupWindow(fixture.second, into: fixture.first, in: fixture.workspace))
        fixture.engine.recordLayoutChange(in: fixture.workspace, since: before)
        _ = fixture.engine.calculateLayout(for: fixture.workspace, screen: fixture.screen)
        var oldFrames: [WindowToken: CGRect] = [:]
        var previousTargets: [WindowToken: CGRect] = [:]
        fixture.engine.consumePendingMovementFrameSeeds(
            in: fixture.workspace,
            oldFrames: &oldFrames,
            previousTargetFrames: &previousTargets
        )
        let root = try XCTUnwrap(fixture.engine.root(for: fixture.workspace))
        let rail = fixture.engine.tabRailWidth
        let target = CGRect(
            x: fixture.screen.minX + rail,
            y: fixture.screen.minY,
            width: fixture.screen.width - rail,
            height: fixture.screen.height
        )
        let origin = target.offsetBy(dx: -fixture.screen.width / 8, dy: fixture.screen.height / 8)
        let config = fixture.engine.windowMovementAnimationConfig
        let sampleTime = config.duration / 2
        root.animateFrom(oldFrame: origin, newFrame: target, startTime: 0, config: config, animated: true)
        let progress = CGFloat(config.value(at: sampleTime / config.duration))
        let presented = CGRect(
            x: origin.minX + (target.minX - origin.minX) * progress,
            y: origin.minY + (target.minY - origin.minY) * progress,
            width: target.width,
            height: target.height
        )
        XCTAssertEqual(root.presentedFrame(at: sampleTime), presented)
        XCTAssertTrue(root.hasActiveAnimations(at: sampleTime))

        XCTAssertNotNil(fixture.engine.stepLayoutHistory(.undo, in: fixture.workspace, at: sampleTime))

        let state = try XCTUnwrap(fixture.engine.existingState(for: fixture.workspace))
        let expectedOrigins = [fixture.first: presented, fixture.second: presented]
        XCTAssertEqual(state.pendingMovementFrameSeeds, expectedOrigins)
        fixture.engine.consumePendingMovementFrameSeeds(
            in: fixture.workspace,
            oldFrames: &oldFrames,
            previousTargetFrames: &previousTargets
        )
        XCTAssertEqual(oldFrames, expectedOrigins)
        XCTAssertEqual(previousTargets, expectedOrigins)
        XCTAssertTrue(state.pendingMovementFrameSeeds.isEmpty)
        let newFrames = fixture.engine.calculateLayout(for: fixture.workspace, screen: fixture.screen)
        fixture.engine.animateWindowMovements(
            .init(oldFrames: oldFrames, previousTargetFrames: previousTargets, newFrames: newFrames),
            in: fixture.workspace, startTime: sampleTime, motion: .enabled
        )
        XCTAssertEqual(fixture.engine.calculateAnimatedFrames(
            baseFrames: newFrames,
            in: fixture.workspace,
            at: sampleTime
        ), expectedOrigins)
        XCTAssertEqual(fixture.engine.calculateAnimatedFrames(
            baseFrames: newFrames,
            in: fixture.workspace,
            at: sampleTime + config.duration
        ), newFrames)
    }

    private func assertNestedTopology(_ fixture: Fixture, inside: WindowToken, outside: WindowToken) throws {
        let root = try XCTUnwrap(fixture.engine.root(for: fixture.workspace))
        let branch = try XCTUnwrap(root.firstChild())
        XCTAssertEqual(root.id, fixture.rootId)
        XCTAssertEqual(root.children.count, 2)
        XCTAssertEqual(root.splitOrientation, .horizontal)
        XCTAssertEqual(root.splitRatio, 1)
        XCTAssertEqual(branch.children.count, 2)
        XCTAssertEqual(branch.splitOrientation, .vertical)
        XCTAssertEqual(branch.splitRatio, 1)
        XCTAssertEqual(branch.firstChild()?.windowToken, fixture.first)
        XCTAssertEqual(branch.secondChild()?.windowToken, inside)
        XCTAssertEqual(root.secondChild()?.windowToken, outside)
        XCTAssertEqual(fixture.engine.tileCount(in: fixture.workspace), 3)
        XCTAssertEqual(fixture.engine.windowCount(in: fixture.workspace), 3)
        assertParentLinks(root, parent: nil)
    }

    private func assertParentLinks(_ node: DwindleNode, parent: DwindleNode?) {
        XCTAssertTrue(node.parent === parent)
        for child in node.children {
            assertParentLinks(child, parent: node)
        }
    }

    private enum GestureMode {
        case ordinary, centered, corner

        func edges(horizontal: Bool) -> ResizeEdge {
            switch self {
            case .ordinary: horizontal ? .right : .top
            case .centered: horizontal ? [.left, .right] : [.bottom, .top]
            case .corner: [.right, .top]
            }
        }

        func location(in screen: CGRect, horizontal: Bool) -> CGPoint {
            switch self {
            case .ordinary:
                CGPoint(
                    x: screen.midX + (horizontal ? screen.width / 16 : 0),
                    y: screen.midY + (horizontal ? 0 : screen.height / 16)
                )
            case .centered:
                CGPoint(
                    x: screen.midX - (horizontal ? screen.width / 32 : 0),
                    y: screen.midY - (horizontal ? 0 : screen.height / 32)
                )
            case .corner:
                CGPoint(
                    x: screen.midX + screen.width / (horizontal ? 16 : 32),
                    y: screen.midY + screen.height / (horizontal ? 32 : 16)
                )
            }
        }
    }

    private struct Fixture {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        let screen = CGRect(x: 160, y: 96, width: 2048, height: 1536)
        let orientation: DwindleOrientation
        let rootId: DwindleNodeId
        let firstNodeId: DwindleNodeId
        let secondNodeId: DwindleNodeId
        let firstTileId: DwindleTileId
        let secondTileId: DwindleTileId

        init(orientation: DwindleOrientation) throws {
            self.orientation = orientation
            engine.settings.defaultSplitRatio = 1
            engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)
            engine.setPreselection(orientation == .horizontal ? .right : .up, in: workspace)
            engine.addWindow(token: second, to: workspace, activeWindowFrame: nil)
            let root = try XCTUnwrap(engine.root(for: workspace))
            let firstNode = try XCTUnwrap(engine.findNode(for: first, in: workspace))
            let secondNode = try XCTUnwrap(engine.findNode(for: second, in: workspace))
            rootId = root.id
            firstNodeId = firstNode.id
            secondNodeId = secondNode.id
            firstTileId = try XCTUnwrap(firstNode.tile?.id)
            secondTileId = try XCTUnwrap(secondNode.tile?.id)
            engine.setSelectedNode(firstNode, in: workspace)
            _ = engine.calculateLayout(for: workspace, screen: screen)
        }

        func assertCounts(undo: Int, redo: Int) {
            let counts = engine.layoutHistoryCounts(in: workspace)
            XCTAssertEqual(counts.undo, undo)
            XCTAssertEqual(counts.redo, redo)
        }

        func beginResize() -> Bool {
            engine.interactiveResizeBegin(
                token: first, edges: orientation == .horizontal ? .right : .top, startLocation: screen.center,
                in: workspace, innerGap: engine.settings.innerGap
            )
        }

        func recordRatioChange(by delta: CGFloat) {
            let before = engine.layoutSnapshot(in: workspace)
            XCTAssertTrue(engine.resizeSelected(by: delta, orientation: orientation, in: workspace))
            engine.recordLayoutChange(in: workspace, since: before)
        }

        func assertSplit(ratio: CGFloat, secondFullscreen: Bool = false) throws {
            let root = try XCTUnwrap(engine.root(for: workspace))
            XCTAssertEqual(root.id, rootId)
            XCTAssertEqual(root.splitOrientation, orientation)
            XCTAssertEqual(root.splitRatio, ratio)
            XCTAssertEqual(root.children.count, 2)
            XCTAssertEqual(root.firstChild()?.id, firstNodeId)
            XCTAssertEqual(root.secondChild()?.id, secondNodeId)
            XCTAssertEqual(root.firstChild()?.windowToken, first)
            XCTAssertEqual(root.secondChild()?.windowToken, second)
            XCTAssertEqual(engine.tileCount(in: workspace), 2)
            XCTAssertEqual(engine.windowCount(in: workspace), 2)
            XCTAssertEqual(engine.activeToken(in: workspace), first)
            let firstTile = try XCTUnwrap(engine.tileSnapshot(for: first, in: workspace))
            let secondTile = try XCTUnwrap(engine.tileSnapshot(for: second, in: workspace))
            XCTAssertEqual(firstTile.id, firstTileId)
            XCTAssertEqual(secondTile.id, secondTileId)
            XCTAssertEqual(firstTile.members, [DwindleTileMember(token: first, isFullscreen: false)])
            XCTAssertEqual(secondTile.members, [DwindleTileMember(token: second, isFullscreen: secondFullscreen)])
            XCTAssertEqual(firstTile.activeToken, first)
            XCTAssertEqual(secondTile.activeToken, second)
            XCTAssertEqual(firstTile.activeIndex, 0)
            XCTAssertEqual(secondTile.activeIndex, 0)
        }

        func assertFrames(ratio: CGFloat) throws {
            let raw = engine.splitRect(
                screen, orientation: orientation, ratio: ratio, minimums: (first: .zero, second: .zero)
            )
            let frames = engine.calculateLayout(for: workspace, screen: screen)
            XCTAssertEqual(Set(frames.keys), [first, second])
            for (token, frame) in [(first, raw.0), (second, raw.1)] {
                XCTAssertEqual(try XCTUnwrap(frames[token]), DwindleGapCalculator.applyGaps(
                    nodeRect: frame, tilingArea: screen, settings: engine.settings
                ))
            }
        }

        func assertGroup() throws {
            let root = try XCTUnwrap(engine.root(for: workspace))
            XCTAssertEqual(root.id, rootId)
            XCTAssertTrue(root.children.isEmpty)
            XCTAssertNil(root.splitRatio)
            XCTAssertEqual(engine.findNode(for: first, in: workspace)?.id, rootId)
            XCTAssertEqual(engine.findNode(for: second, in: workspace)?.id, rootId)
            let group = try XCTUnwrap(engine.tileSnapshot(for: first, in: workspace))
            XCTAssertEqual(group.id, firstTileId)
            XCTAssertEqual(group.members, [
                DwindleTileMember(token: first, isFullscreen: false),
                DwindleTileMember(token: second, isFullscreen: true)
            ])
            XCTAssertEqual(group.activeIndex, 1)
            XCTAssertEqual(group.activeToken, second)
            XCTAssertEqual(engine.activeToken(in: workspace), second)
            XCTAssertEqual(engine.inactiveGroupTokens(in: workspace), [first])
            XCTAssertEqual(engine.tileCount(in: workspace), 1)
            XCTAssertEqual(engine.windowCount(in: workspace), 2)
            XCTAssertEqual(engine.calculateLayout(for: workspace, screen: screen), [second: screen])
        }
    }
}
