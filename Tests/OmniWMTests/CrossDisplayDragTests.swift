// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class CrossDisplayDragTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let controller: WMController
        let niri: NiriLayoutEngine
        let dwindle: DwindleLayoutEngine
        let monitors: [Monitor]
        let workspaces: [WorkspaceDescriptor.ID]

        var manager: WorkspaceManager {
            controller.workspaceManager
        }

        var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        var source: WorkspaceDescriptor.ID {
            workspaces[0]
        }

        var target: WorkspaceDescriptor.ID {
            workspaces[1]
        }

        func columns(_ workspaceId: WorkspaceDescriptor.ID) -> [[WindowToken]] {
            niri.columns(in: workspaceId).map { $0.windowNodes.map(\.token) }
        }

        func niriNode(_ token: WindowToken) -> NiriWindow? {
            manager.workspace(for: token).flatMap { niri.findNode(for: token, in: $0) }
        }

        func dwindleTile(_ token: WindowToken) -> [WindowToken]? {
            manager.workspace(for: token)
                .flatMap { dwindle.tile(containing: token, in: $0) }?
                .members.map(\.token)
        }

        func frame(_ token: WindowToken) -> CGRect? {
            guard let workspaceId = manager.workspace(for: token) else { return nil }
            return switch manager.activeLayoutKind(for: workspaceId) {
            case .niri: niri.findNode(for: token, in: workspaceId)?.frame
            case .dwindle: dwindle.presentedFrame(for: token, in: workspaceId, at: 0)
            }
        }

        func layout() {
            for (monitor, workspaceId) in zip(monitors, workspaces) {
                let workingFrame = controller.insetWorkingFrame(for: monitor)
                switch manager.activeLayoutKind(for: workspaceId) {
                case .niri:
                    let gap = controller.innerGap(for: monitor)
                    _ = niri.calculateLayout(
                        state: manager.niriViewportState(for: workspaceId),
                        workspaceId: workspaceId,
                        monitorFrame: workingFrame,
                        gaps: (horizontal: gap, vertical: gap),
                        orientation: .horizontal
                    )
                case .dwindle:
                    _ = dwindle.calculateLayout(for: workspaceId, screen: workingFrame)
                    dwindle.cancelAnimations(in: workspaceId)
                }
            }
        }

        func beginDrag(_ token: WindowToken) throws {
            layout()
            let start = try XCTUnwrap(frame(token)).center
            XCTAssertFalse(handler.dispatchMouseDown(at: start, modifiers: .maskControl))
            XCTAssertTrue(handler.state.isMoving)
        }

        func finishDrag(at point: CGPoint) {
            handler.dispatchMouseDragged(at: point)
            handler.dispatchMouseUp(at: point)
            XCTAssertFalse(handler.state.isMoving)
            XCTAssertNil(niri.interactiveMove)
            XCTAssertNil(dwindle.interactiveMove)
        }

        func drag(_ token: WindowToken, to point: CGPoint) throws {
            try beginDrag(token)
            finishDrag(at: point)
        }
    }

    func testNiriColumnEdgesInsertANewColumnOnTheOtherDisplay() throws {
        for (direction, expectedIndex) in [(Direction.left, 0), (.right, 1)] {
            let fixture = try makeFixture([.niri, .niri])
            let moved = addWindow(1, to: fixture.source, fixture)
            let first = addWindow(2, to: fixture.target, fixture)
            let second = addWindow(3, to: fixture.target, fixture)
            fixture.layout()

            try fixture.drag(moved, to: dropPoint(in: XCTUnwrap(fixture.frame(first)), direction))

            var expected = [[first], [second]]
            expected.insert([moved], at: expectedIndex)
            XCTAssertEqual(fixture.columns(fixture.target), expected)
            XCTAssertEqual(fixture.columns(fixture.source).flatMap(\.self), [])
            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
            XCTAssertEqual(
                fixture.manager.niriViewportState(for: fixture.target).selectedNodeId,
                fixture.niriNode(moved)?.id
            )
        }
    }

    func testNiriColumnEdgeStacksIntoTheTargetColumnAndActivatesTheWindow() throws {
        for direction in [Direction.up, .down] {
            let fixture = try makeFixture([.niri, .niri])
            let moved = addWindow(1, to: fixture.source, fixture)
            let target = addWindow(2, to: fixture.target, fixture)
            fixture.layout()

            try fixture.drag(moved, to: dropPoint(in: XCTUnwrap(fixture.frame(target)), direction))
            fixture.layout()

            let column = try XCTUnwrap(fixture.niri.columns(in: fixture.target).first)
            XCTAssertEqual(Set(column.windowNodes.map(\.token)), [target, moved])
            XCTAssertTrue(column.activeWindow === fixture.niriNode(moved))
            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
            let movedFrame = try XCTUnwrap(fixture.frame(moved))
            let targetFrame = try XCTUnwrap(fixture.frame(target))
            XCTAssertEqual(movedFrame.midX, targetFrame.midX, accuracy: 0.5)
            XCTAssertEqual(movedFrame.midY > targetFrame.midY, direction == .up)
        }
    }

    func testRefusedNiriStackFallsBackToANewColumnAtTheEnd() throws {
        let fixture = try makeFixture([.niri, .niri])
        let moved = addWindow(1, to: fixture.source, fixture)
        let target = addWindow(2, to: fixture.target, fixture)
        let other = addWindow(3, to: fixture.target, fixture)
        fixture.manager.setCachedConstraints(constraints(minHeight: 2_000), for: moved)
        fixture.layout()

        try fixture.drag(moved, to: dropPoint(in: XCTUnwrap(fixture.frame(target)), .down))

        XCTAssertEqual(fixture.columns(fixture.target), [[target], [other], [moved]])
        XCTAssertEqual(fixture.niriNode(moved)?.constraints.minSize.height, 2_000)
    }

    func testNiriSwapKeepsBothSlotsAndSelectsTheArrivals() throws {
        let fixture = try makeFixture([.niri, .niri])
        let moved = addWindow(1, to: fixture.source, fixture)
        let sourceSibling = addWindow(2, to: fixture.source, fixture)
        let partnerSibling = addWindow(3, to: fixture.target, fixture)
        let partner = addWindow(4, to: fixture.target, fixture)
        try stack(sourceSibling, onto: moved, in: fixture.source, fixture)
        try stack(partnerSibling, onto: partner, in: fixture.target, fixture)
        let movedNode = try XCTUnwrap(fixture.niriNode(moved))
        let partnerNode = try XCTUnwrap(fixture.niriNode(partner))
        movedNode.size = 1.4
        partnerNode.size = 0.6
        fixture.layout()

        try fixture.drag(moved, to: XCTUnwrap(fixture.frame(partner)).center)

        XCTAssertEqual(fixture.columns(fixture.source), [[partner, sourceSibling]])
        XCTAssertEqual(fixture.columns(fixture.target), [[moved, partnerSibling]])
        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
        XCTAssertEqual(fixture.manager.workspace(for: partner), fixture.source)
        XCTAssertEqual(partnerNode.size, 1.4)
        XCTAssertEqual(movedNode.size, 0.6)
        XCTAssertEqual(fixture.manager.niriViewportState(for: fixture.source).selectedNodeId, partnerNode.id)
        XCTAssertEqual(fixture.manager.niriViewportState(for: fixture.target).selectedNodeId, movedNode.id)
        XCTAssertNil(fixture.niri.findNode(for: moved, in: fixture.source))
        XCTAssertNil(fixture.niri.findNode(for: partner, in: fixture.target))
    }

    func testRefusedNiriSwapLeavesTheWorldUnchanged() throws {
        let fixture = try makeFixture([.niri, .niri])
        let moved = addWindow(1, to: fixture.source, fixture)
        let sourceSibling = addWindow(2, to: fixture.source, fixture)
        let partner = addWindow(3, to: fixture.target, fixture)
        try stack(sourceSibling, onto: moved, in: fixture.source, fixture)
        fixture.manager.setCachedConstraints(constraints(minHeight: 2_000), for: partner)
        fixture.layout()
        let partnerCenter = try XCTUnwrap(fixture.frame(partner)).center
        try fixture.beginDrag(moved)
        let worldSeq = fixture.manager.worldSeq

        fixture.finishDrag(at: partnerCenter)

        XCTAssertEqual(fixture.manager.worldSeq, worldSeq)
        XCTAssertEqual(fixture.columns(fixture.source), [[moved, sourceSibling]])
        XCTAssertEqual(fixture.columns(fixture.target), [[partner]])
        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
        XCTAssertEqual(fixture.manager.workspace(for: partner), fixture.target)
    }

    func testNiriDropBeyondTheColumnStripAppendsAColumn() throws {
        let fixture = try makeFixture([.niri, .niri])
        let moved = addWindow(1, to: fixture.source, fixture)
        let first = addWindow(2, to: fixture.target, fixture)
        let second = addWindow(3, to: fixture.target, fixture)
        for column in fixture.niri.columns(in: fixture.target) {
            column.width = .proportion(0.3)
        }
        fixture.layout()
        let stripEnd = try XCTUnwrap(fixture.frame(second)).maxX
        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitors[1])
        let beyond = CGPoint(x: (stripEnd + workingFrame.maxX) / 2, y: workingFrame.midY)
        XCTAssertLessThan(stripEnd + 100, beyond.x)

        try fixture.drag(moved, to: beyond)

        XCTAssertEqual(fixture.columns(fixture.target), [[first], [second], [moved]])
    }

    func testDropIntoAnEmptyWorkspaceOnTheOtherDisplay() throws {
        for targetLayout in [LayoutType.niri, .dwindle] {
            let fixture = try makeFixture([.niri, targetLayout])
            let moved = addWindow(1, to: fixture.source, fixture)
            let stays = addWindow(2, to: fixture.source, fixture)

            try fixture.drag(moved, to: fixture.monitors[1].frame.center)

            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
            XCTAssertEqual(fixture.columns(fixture.source), [[stays]])
            if targetLayout == .niri {
                XCTAssertEqual(fixture.columns(fixture.target), [[moved]])
            } else {
                XCTAssertEqual(fixture.dwindleTile(moved), [moved])
                XCTAssertTrue(fixture.dwindle.root(for: fixture.target)?.isLeaf == true)
            }
        }
    }

    func testDwindleTileZonesInsertBesideTheTargetInEveryDirection() throws {
        for direction in [Direction.left, .right, .up, .down] {
            let fixture = try makeFixture([.dwindle, .dwindle])
            let moved = addWindow(1, to: fixture.source, fixture)
            let target = addWindow(2, to: fixture.target, fixture)
            let other = addWindow(3, to: fixture.target, fixture)
            fixture.layout()
            let targetSlot = try XCTUnwrap(fixture.frame(target))
            let otherFrame = try XCTUnwrap(fixture.frame(other))

            try fixture.drag(moved, to: dropPoint(in: targetSlot, direction))
            fixture.layout()

            let movedFrame = try XCTUnwrap(fixture.frame(moved))
            let targetFrame = try XCTUnwrap(fixture.frame(target))
            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target, "\(direction)")
            XCTAssertTrue(targetSlot.insetBy(dx: -1, dy: -1).contains(movedFrame), "\(direction)")
            XCTAssertTrue(targetSlot.insetBy(dx: -1, dy: -1).contains(targetFrame), "\(direction)")
            XCTAssertEqual(fixture.frame(other), otherFrame, "\(direction)")
            switch direction {
            case .left: XCTAssertLessThan(movedFrame.maxX, targetFrame.minX + 1)
            case .right: XCTAssertGreaterThan(movedFrame.minX, targetFrame.maxX - 1)
            case .up: XCTAssertGreaterThan(movedFrame.minY, targetFrame.maxY - 1)
            case .down: XCTAssertLessThan(movedFrame.maxY, targetFrame.minY + 1)
            }
        }
    }

    func testDwindleWorkspaceEdgeSplitsTheWholeTargetTree() throws {
        let fixture = try makeFixture([.dwindle, .dwindle])
        let moved = addWindow(1, to: fixture.source, fixture)
        let first = addWindow(2, to: fixture.target, fixture)
        let second = addWindow(3, to: fixture.target, fixture)
        fixture.layout()
        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitors[1])

        try fixture.drag(moved, to: CGPoint(x: workingFrame.midX, y: workingFrame.maxY - 2))
        fixture.layout()

        let movedFrame = try XCTUnwrap(fixture.frame(moved))
        for resident in [first, second] {
            XCTAssertGreaterThan(movedFrame.minY, try XCTUnwrap(fixture.frame(resident)).maxY - 1)
        }
        XCTAssertEqual(movedFrame.width, workingFrame.width, accuracy: 1)
    }

    func testDwindleDividerInsertsBetweenTheTargetSubtrees() throws {
        for sourceLayout in [LayoutType.dwindle, .niri] {
            let fixture = try makeFixture([sourceLayout, .dwindle])
            let moved = addWindow(1, to: fixture.source, fixture)
            let left = addWindow(2, to: fixture.target, fixture)
            let stacked = [addWindow(3, to: fixture.target, fixture), addWindow(4, to: fixture.target, fixture)]
            fixture.layout()
            let root = try XCTUnwrap(fixture.dwindle.root(for: fixture.target))
            let leftFrame = try XCTUnwrap(fixture.frame(left))
            let stackedFrames = try stacked.map { try XCTUnwrap(fixture.frame($0)) }
            let right = stackedFrames.reduce(CGRect.null) { $0.union($1) }
            let point = CGPoint(x: (leftFrame.maxX + right.minX) / 2, y: leftFrame.midY)
            try fixture.beginDrag(moved)

            fixture.handler.dispatchMouseDragged(at: point)
            guard case let .crossDisplay(drop) = fixture.handler.classifyMoveLocation(point) else {
                return XCTFail("expected a cross-display drop from \(sourceLayout)")
            }
            XCTAssertEqual(drop.placement, .dwindleSplitBoundary(root.id), "\(sourceLayout)")
            XCTAssertEqual(drop.previewFrame, WindowMoveGeometry.targetFrame(in: right, direction: .left))
            fixture.finishDrag(at: point)
            fixture.layout()

            let movedFrame = try XCTUnwrap(fixture.frame(moved))
            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target, "\(sourceLayout)")
            XCTAssertEqual(fixture.frame(left), leftFrame, "\(sourceLayout)")
            XCTAssertGreaterThan(movedFrame.minX, leftFrame.maxX, "\(sourceLayout)")
            XCTAssertEqual(movedFrame.minY, right.minY, accuracy: 1, "\(sourceLayout)")
            XCTAssertEqual(movedFrame.height, right.height, accuracy: 1, "\(sourceLayout)")
            for (token, before) in zip(stacked, stackedFrames) {
                let frame = try XCTUnwrap(fixture.frame(token))
                XCTAssertGreaterThan(frame.minX, movedFrame.maxX, "\(sourceLayout)")
                XCTAssertEqual(frame.height, before.height, accuracy: 1, "\(sourceLayout)")
            }
        }
    }

    func testDwindleSwapTradesSingleTiles() throws {
        let fixture = try makeFixture([.dwindle, .dwindle])
        let moved = addWindow(1, to: fixture.source, fixture)
        let sourceSibling = addWindow(2, to: fixture.source, fixture)
        let partner = addWindow(3, to: fixture.target, fixture)
        let partnerSibling = addWindow(4, to: fixture.target, fixture)
        fixture.layout()
        let movedSlot = try XCTUnwrap(fixture.frame(moved))
        let partnerSlot = try XCTUnwrap(fixture.frame(partner))

        try fixture.drag(moved, to: partnerSlot.center)
        fixture.layout()

        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
        XCTAssertEqual(fixture.manager.workspace(for: partner), fixture.source)
        XCTAssertEqual(fixture.frame(moved), partnerSlot)
        XCTAssertEqual(fixture.frame(partner), movedSlot)
        XCTAssertEqual(fixture.dwindleTile(sourceSibling), [sourceSibling])
        XCTAssertEqual(fixture.dwindleTile(partnerSibling), [partnerSibling])
    }

    func testWindowModeSwapIntoAGroupedMemberKeepsTheGroup() throws {
        let fixture = try makeFixture([.dwindle, .dwindle])
        fixture.controller.settings.gestures.dwindleGroupDragAcrossDisplays = .window
        let moved = addWindow(1, to: fixture.source, fixture)
        let member = addWindow(2, to: fixture.target, fixture)
        let partner = addWindow(3, to: fixture.target, fixture)
        fixture.manager.withEngineMutationScope(in: fixture.target) {
            XCTAssertTrue(fixture.dwindle.groupWindow(partner, into: member, in: fixture.target))
        }
        XCTAssertEqual(fixture.dwindleTile(member), [member, partner])
        fixture.layout()
        let groupFrame = try XCTUnwrap(fixture.frame(partner))
        XCTAssertEqual(
            fixture.dwindle.hitTestFocusableWindow(point: groupFrame.center, in: fixture.target, at: 0),
            partner
        )

        try fixture.drag(moved, to: groupFrame.center)

        XCTAssertEqual(fixture.dwindleTile(moved), [member, moved])
        XCTAssertEqual(fixture.dwindleTile(partner), [partner])
        XCTAssertEqual(fixture.manager.workspace(for: partner), fixture.source)
        XCTAssertEqual(fixture.dwindle.tile(containing: moved, in: fixture.target)?.activeToken, moved)
    }

    func testFullscreenTargetCancelsTheDropAndClearsThePreview() throws {
        let fixture = try makeFixture([.niri, .dwindle])
        let moved = addWindow(1, to: fixture.source, fixture)
        let resident = addWindow(2, to: fixture.target, fixture)
        fixture.manager.withEngineMutationScope(in: fixture.target) {
            XCTAssertEqual(fixture.dwindle.toggleFullscreen(in: fixture.target), resident)
        }
        let point = fixture.monitors[1].frame.center
        try fixture.beginDrag(moved)
        let worldSeq = fixture.manager.worldSeq

        fixture.handler.dispatchMouseDragged(at: point)
        XCTAssertEqual(fixture.handler.classifyMoveLocation(point), .cancel)
        XCTAssertNil(fixture.niri.interactiveMove?.currentHoverTarget)
        fixture.handler.dispatchMouseUp(at: point)

        XCTAssertEqual(fixture.manager.worldSeq, worldSeq)
        XCTAssertEqual(fixture.columns(fixture.source), [[moved]])
        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
    }

    func testNiriToDwindleCapturesSizingThatTheReturnTripRestores() throws {
        let fixture = try makeFixture([.niri, .dwindle])
        let moved = addWindow(1, to: fixture.source, fixture)
        let stays = addWindow(2, to: fixture.source, fixture)
        let target = addWindow(3, to: fixture.target, fixture)
        let column = try XCTUnwrap(fixture.niri.columns(in: fixture.source).first)
        column.width = .proportion(0.7)
        fixture.layout()

        try fixture.drag(moved, to: dropPoint(in: XCTUnwrap(fixture.frame(target)), .right))

        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
        XCTAssertEqual(fixture.dwindleTile(moved), [moved])
        XCTAssertEqual(
            fixture.manager.restoreIntent(for: moved)?.detachedNiriContainerSizingState?.width,
            .proportion(0.7)
        )

        fixture.layout()
        try fixture.drag(moved, to: dropPoint(in: XCTUnwrap(fixture.frame(stays)), .right))

        XCTAssertEqual(fixture.columns(fixture.source), [[stays], [moved]])
        XCTAssertEqual(fixture.niri.columns(in: fixture.source).last?.width, .proportion(0.7))
        XCTAssertNil(fixture.dwindle.tile(containing: moved, in: fixture.target))
    }

    func testDwindleToNiriInstallsDestinationConstraints() throws {
        for direction in [Direction.right, .down] {
            let fixture = try makeFixture([.dwindle, .niri])
            let moved = addWindow(1, to: fixture.source, fixture)
            let target = addWindow(2, to: fixture.target, fixture)
            fixture.manager.setCachedConstraints(constraints(minWidth: 3_000, minHeight: 200), for: moved)
            fixture.layout()

            try fixture.drag(moved, to: dropPoint(in: XCTUnwrap(fixture.frame(target)), direction))

            XCTAssertEqual(
                fixture.columns(fixture.target),
                direction == .right ? [[target], [moved]] : [[moved, target]]
            )
            let node = try XCTUnwrap(fixture.niriNode(moved))
            let workArea = fixture.controller.insetWorkingFrame(for: fixture.monitors[1])
            XCTAssertEqual(node.constraints.minSize.width, workArea.width, accuracy: 1)
            XCTAssertEqual(node.constraints.minSize.height, 200)
            XCTAssertNil(fixture.dwindle.tile(containing: moved, in: fixture.source))
        }
    }

    func testMixedSwapTradesSlotsAcrossLayouts() throws {
        let fixture = try makeFixture([.niri, .dwindle])
        let moved = addWindow(1, to: fixture.source, fixture)
        let stays = addWindow(2, to: fixture.source, fixture)
        let partner = addWindow(3, to: fixture.target, fixture)
        let resident = addWindow(4, to: fixture.target, fixture)
        fixture.layout()
        let partnerSlot = try XCTUnwrap(fixture.frame(partner))

        try fixture.drag(moved, to: partnerSlot.center)
        fixture.layout()

        XCTAssertEqual(fixture.columns(fixture.source), [[partner], [stays]])
        XCTAssertEqual(fixture.frame(moved), partnerSlot)
        XCTAssertEqual(fixture.dwindleTile(resident), [resident])
        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
        XCTAssertEqual(fixture.manager.workspace(for: partner), fixture.source)
        XCTAssertNotNil(fixture.manager.restoreIntent(for: moved)?.detachedNiriContainerSizingState)
        XCTAssertEqual(
            fixture.manager.niriViewportState(for: fixture.source).selectedNodeId,
            fixture.niriNode(partner)?.id
        )
    }

    func testDropOutsideTheTargetViewportStartsItsScrollAnimation() throws {
        let fixture = try makeFixture([.niri, .niri])
        let moved = addWindow(1, to: fixture.source, fixture)
        let residents = (2 ... 4).map { addWindow($0, to: fixture.target, fixture) }
        for column in fixture.niri.columns(in: fixture.target) {
            column.width = .proportion(0.5)
        }
        fixture.layout()
        let lastVisible = try XCTUnwrap(fixture.frame(residents[1]))
        XCTAssertTrue(fixture.monitors[1].frame.contains(lastVisible.center))
        fixture.controller.motionPolicy.animationsEnabled = true
        fixture.controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }

        try fixture.drag(moved, to: dropPoint(in: lastVisible, .right))

        XCTAssertEqual(fixture.columns(fixture.target), [[residents[0]], [residents[1]], [moved], [residents[2]]])
        XCTAssertEqual(
            fixture.controller.niriLayoutHandler.scrollAnimationByDisplay[fixture.monitors[1].displayId],
            fixture.target
        )
    }

    func testHoverPreviewsOnTheTargetDisplayWithoutMutatingTheWorld() throws {
        let fixture = try makeFixture([.niri, .niri])
        let moved = addWindow(1, to: fixture.source, fixture)
        let neighbor = addWindow(2, to: fixture.source, fixture)
        let target = addWindow(3, to: fixture.target, fixture)
        fixture.layout()
        let targetFrame = try XCTUnwrap(fixture.frame(target))
        let neighborFrame = try XCTUnwrap(fixture.frame(neighbor))
        try fixture.beginDrag(moved)
        let worldSeq = fixture.manager.worldSeq

        fixture.handler.dispatchMouseDragged(at: neighborFrame.center)
        XCTAssertNotNil(fixture.niri.interactiveMove?.currentHoverTarget)

        fixture.handler.dispatchMouseDragged(at: targetFrame.center)
        guard case let .crossDisplay(drop) = fixture.handler.classifyMoveLocation(targetFrame.center) else {
            return XCTFail("expected a cross-display drop")
        }
        XCTAssertEqual(drop.placement, .swap(target: target))
        XCTAssertEqual(drop.previewFrame, targetFrame)
        XCTAssertTrue(fixture.monitors[1].frame.contains(drop.previewFrame))
        XCTAssertNil(fixture.niri.interactiveMove?.currentHoverTarget)
        XCTAssertEqual(fixture.manager.worldSeq, worldSeq)

        fixture.handler.dispatchMouseDragged(at: neighborFrame.center)
        XCTAssertEqual(fixture.handler.classifyMoveLocation(neighborFrame.center), .sourceDisplay)
        XCTAssertNotNil(fixture.niri.interactiveMove?.currentHoverTarget)
        fixture.handler.dispatchMouseUp(at: neighborFrame.center)

        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
        XCTAssertEqual(fixture.columns(fixture.target), [[target]])
    }

    func testCancelZoneOnAThirdDisplayLeavesTheSourceUnchanged() throws {
        let fixture = try makeFixture([.niri, .niri, .dwindle])
        let tokens = (1 ... 6).map { addWindow($0, to: fixture.source, fixture) }
        for column in fixture.niri.columns(in: fixture.source) {
            column.width = .proportion(1)
        }
        let resident = addWindow(7, to: fixture.workspaces[2], fixture)
        fixture.manager.withEngineMutationScope(in: fixture.workspaces[2]) {
            XCTAssertEqual(fixture.dwindle.toggleFullscreen(in: fixture.workspaces[2]), resident)
        }
        fixture.layout()
        let point = fixture.monitors[2].frame.center
        XCTAssertTrue(tokens.contains { fixture.frame($0)?.contains(point) == true })
        try fixture.beginDrag(tokens[0])
        let worldSeq = fixture.manager.worldSeq

        fixture.finishDrag(at: point)

        XCTAssertEqual(fixture.manager.worldSeq, worldSeq)
        XCTAssertEqual(fixture.columns(fixture.source), tokens.map { [$0] })
    }

    func testGroupMovesKeepTheTileOrderAndActiveMember() throws {
        for drop in ["beside", "edge", "workspace"] {
            let fixture = try makeFixture([.dwindle, .dwindle])
            let first = addWindow(1, to: fixture.source, fixture)
            let second = addWindow(2, to: fixture.source, fixture)
            let stays = addWindow(3, to: fixture.source, fixture)
            group(second, into: first, in: fixture.source, fixture)
            let resident = drop == "workspace" ? nil : addWindow(4, to: fixture.target, fixture)
            fixture.layout()
            let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitors[1])
            let point = switch drop {
            case "beside": try dropPoint(in: XCTUnwrap(fixture.frame(XCTUnwrap(resident))), .right)
            case "edge": CGPoint(x: workingFrame.midX, y: workingFrame.maxY - 2)
            default: workingFrame.center
            }

            try fixture.drag(second, to: point)

            XCTAssertEqual(fixture.dwindleTile(first), [first, second], drop)
            XCTAssertEqual(fixture.dwindle.tile(containing: first, in: fixture.target)?.activeToken, second, drop)
            XCTAssertEqual(fixture.manager.workspace(for: first), fixture.target, drop)
            XCTAssertEqual(fixture.manager.workspace(for: second), fixture.target, drop)
            XCTAssertEqual(fixture.dwindleTile(stays), [stays], drop)
            XCTAssertEqual(fixture.dwindle.tileCount(in: fixture.source), 1, drop)
            XCTAssertEqual(fixture.dwindle.tileCount(in: fixture.target), resident == nil ? 1 : 2, drop)
        }
    }

    func testWindowModeMovesOnlyTheDraggedMember() throws {
        let fixture = try makeFixture([.dwindle, .dwindle])
        fixture.controller.settings.gestures.dwindleGroupDragAcrossDisplays = .window
        let first = addWindow(1, to: fixture.source, fixture)
        let second = addWindow(2, to: fixture.source, fixture)
        group(second, into: first, in: fixture.source, fixture)

        try fixture.drag(second, to: fixture.monitors[1].frame.center)

        XCTAssertEqual(fixture.dwindleTile(second), [second])
        XCTAssertEqual(fixture.dwindleTile(first), [first])
        XCTAssertEqual(fixture.manager.workspace(for: first), fixture.source)
        XCTAssertEqual(fixture.manager.workspace(for: second), fixture.target)
    }

    func testGroupDroppedIntoNiriBecomesOneTabbedColumn() throws {
        let fixture = try makeFixture([.dwindle, .niri])
        let first = addWindow(1, to: fixture.source, fixture)
        let second = addWindow(2, to: fixture.source, fixture)
        let third = addWindow(3, to: fixture.source, fixture)
        group(second, into: first, in: fixture.source, fixture)
        group(third, into: first, in: fixture.source, fixture)
        XCTAssertEqual(fixture.dwindleTile(first), [first, second, third])
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            _ = fixture.dwindle.tile(containing: first, in: fixture.source)?.activate(second)
        }
        fixture.manager.setCachedConstraints(constraints(minWidth: 3_000, minHeight: 100), for: first)
        let resident = addWindow(4, to: fixture.target, fixture)
        fixture.layout()

        try fixture.drag(second, to: dropPoint(in: XCTUnwrap(fixture.frame(resident)), .right))

        XCTAssertEqual(fixture.columns(fixture.target), [[resident], [third, second, first]])
        let column = try XCTUnwrap(fixture.niri.columns(in: fixture.target).last)
        XCTAssertTrue(column.isTabbed)
        XCTAssertEqual(column.activeWindow?.token, second)
        let workArea = fixture.controller.insetWorkingFrame(for: fixture.monitors[1])
        XCTAssertEqual(try XCTUnwrap(fixture.niriNode(first)).constraints.minSize.width, workArea.width, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(fixture.niriNode(first)).constraints.minSize.height, 100)
        XCTAssertNil(fixture.dwindle.tile(containing: first, in: fixture.source))
        for token in [first, second, third] {
            XCTAssertEqual(fixture.manager.workspace(for: token), fixture.target)
        }
    }

    func testGroupOnANiriStackZoneGetsItsOwnColumn() throws {
        let fixture = try makeFixture([.dwindle, .niri])
        let first = addWindow(1, to: fixture.source, fixture)
        let second = addWindow(2, to: fixture.source, fixture)
        group(second, into: first, in: fixture.source, fixture)
        let resident = addWindow(3, to: fixture.target, fixture)
        fixture.layout()
        let point = try dropPoint(in: XCTUnwrap(fixture.frame(resident)), .down)
        try fixture.beginDrag(second)
        fixture.handler.dispatchMouseDragged(at: point)

        guard case let .crossDisplay(drop) = fixture.handler.classifyMoveLocation(point) else {
            return XCTFail("expected a cross-display drop")
        }
        XCTAssertEqual(drop.placement, .workspace)
        XCTAssertEqual(
            drop.previewFrame,
            fixture.controller.niriInteractionGeometry(for: fixture.monitors[1]).workingFrame
        )
        fixture.finishDrag(at: point)

        XCTAssertEqual(fixture.columns(fixture.target), [[resident], [second, first]])
    }

    func testGroupSwapsIntoWholeSlots() throws {
        let niriFixture = try makeFixture([.dwindle, .niri])
        let first = addWindow(1, to: niriFixture.source, niriFixture)
        let second = addWindow(2, to: niriFixture.source, niriFixture)
        let sibling = addWindow(3, to: niriFixture.source, niriFixture)
        group(second, into: first, in: niriFixture.source, niriFixture)
        let partner = addWindow(4, to: niriFixture.target, niriFixture)
        let other = addWindow(5, to: niriFixture.target, niriFixture)
        niriFixture.layout()
        let groupSlot = try XCTUnwrap(niriFixture.frame(second))

        try niriFixture.drag(second, to: XCTUnwrap(niriFixture.frame(partner)).center)
        niriFixture.layout()

        XCTAssertEqual(niriFixture.columns(niriFixture.target), [[second, first], [other]])
        XCTAssertEqual(niriFixture.niri.columns(in: niriFixture.target).first?.activeWindow?.token, second)
        XCTAssertEqual(niriFixture.dwindleTile(partner), [partner])
        let partnerFrame = try XCTUnwrap(niriFixture.frame(partner))
        XCTAssertTrue(partnerFrame.contains(groupSlot))
        XCTAssertEqual(partnerFrame.maxX, groupSlot.maxX)
        XCTAssertEqual(partnerFrame.height, groupSlot.height)
        XCTAssertEqual(niriFixture.dwindleTile(sibling), [sibling])

        let dwindleFixture = try makeFixture([.dwindle, .dwindle])
        let movedFirst = addWindow(1, to: dwindleFixture.source, dwindleFixture)
        let movedSecond = addWindow(2, to: dwindleFixture.source, dwindleFixture)
        _ = addWindow(3, to: dwindleFixture.source, dwindleFixture)
        group(movedSecond, into: movedFirst, in: dwindleFixture.source, dwindleFixture)
        let partnerFirst = addWindow(4, to: dwindleFixture.target, dwindleFixture)
        let partnerSecond = addWindow(5, to: dwindleFixture.target, dwindleFixture)
        _ = addWindow(6, to: dwindleFixture.target, dwindleFixture)
        group(partnerSecond, into: partnerFirst, in: dwindleFixture.target, dwindleFixture)
        dwindleFixture.layout()
        let movedSlot = try XCTUnwrap(dwindleFixture.frame(movedSecond))
        let partnerSlot = try XCTUnwrap(dwindleFixture.frame(partnerSecond))

        try dwindleFixture.drag(movedSecond, to: partnerSlot.center)
        dwindleFixture.layout()

        XCTAssertEqual(dwindleFixture.dwindleTile(movedFirst), [movedFirst, movedSecond])
        XCTAssertEqual(dwindleFixture.dwindleTile(partnerFirst), [partnerFirst, partnerSecond])
        XCTAssertEqual(dwindleFixture.manager.workspace(for: movedFirst), dwindleFixture.target)
        XCTAssertEqual(dwindleFixture.manager.workspace(for: partnerFirst), dwindleFixture.source)
        XCTAssertEqual(dwindleFixture.frame(movedSecond), partnerSlot)
        XCTAssertEqual(dwindleFixture.frame(partnerSecond), movedSlot)
    }

    func testGroupSwapIntoAColumnWithAnExcludedSiblingIsRefused() throws {
        let fixture = try makeFixture([.dwindle, .niri])
        let first = addWindow(1, to: fixture.source, fixture)
        let second = addWindow(2, to: fixture.source, fixture)
        group(second, into: first, in: fixture.source, fixture)
        let partner = addWindow(3, to: fixture.target, fixture)
        let hidden = addWindow(4, to: fixture.target, pid: 8_661, fixture)
        try stack(hidden, onto: partner, in: fixture.target, fixture)
        fixture.manager.setAppHidden(true, pid: 8_661, source: .ax)
        XCTAssertTrue(fixture.niri.projectionExclusions(in: fixture.target).contains(hidden))
        fixture.layout()
        let partnerCenter = try XCTUnwrap(fixture.frame(partner)).center
        try fixture.beginDrag(second)
        let worldSeq = fixture.manager.worldSeq

        fixture.finishDrag(at: partnerCenter)

        XCTAssertEqual(fixture.manager.worldSeq, worldSeq)
        XCTAssertEqual(fixture.columns(fixture.target), [[partner, hidden]])
        XCTAssertEqual(fixture.dwindleTile(first), [first, second])
    }

    func testExcludedGroupMembersTravelWithTheirExclusion() throws {
        for targetLayout in [LayoutType.dwindle, .niri] {
            let fixture = try makeFixture([.dwindle, targetLayout])
            let hidden = addWindow(1, to: fixture.source, pid: 8_661, fixture)
            let visible = addWindow(2, to: fixture.source, fixture)
            group(visible, into: hidden, in: fixture.source, fixture)
            fixture.manager.setAppHidden(true, pid: 8_661, source: .ax)
            XCTAssertTrue(fixture.dwindle.excludedTokens(in: fixture.source).contains(hidden))

            try fixture.drag(visible, to: fixture.monitors[1].frame.center)

            XCTAssertEqual(fixture.manager.workspace(for: hidden), fixture.target, "\(targetLayout)")
            XCTAssertFalse(fixture.dwindle.excludedTokens(in: fixture.source).contains(hidden), "\(targetLayout)")
            if targetLayout == .niri {
                XCTAssertEqual(fixture.columns(fixture.target), [[visible, hidden]])
                XCTAssertTrue(fixture.niri.projectionExclusions(in: fixture.target).contains(hidden))
            } else {
                XCTAssertEqual(fixture.dwindleTile(visible), [hidden, visible])
                XCTAssertTrue(fixture.dwindle.excludedTokens(in: fixture.target).contains(hidden))
            }
        }
    }

    func testNativeMoveDefaultsOffAndSameDisplayStillCorrects() throws {
        for layout in [LayoutType.niri, .dwindle] {
            for (enabled, across) in [(false, false), (false, true), (true, false)] {
                let fixture = try makeNativeFixture([layout, layout], enabled: enabled)
                let moved = addWindow(1, to: fixture.source, fixture)
                let resident = addWindow(2, to: fixture.target, fixture)
                let start = try beginNativeDrag(moved, fixture)
                fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: across ? 1600 : 30, dy: 0) }
                let point = across ? try XCTUnwrap(fixture.frame(resident)).center : start.center
                let before = fixture.manager.worldSeq

                fixture.handler.dispatchMouseUp(at: point)

                XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
                XCTAssertEqual(fixture.manager.worldSeq, before)
                XCTAssertNil(fixture.handler.state.nativeCrossDisplayMove)
                XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.phase, .awaitingCorrection)
            }
        }
    }

    func testNativeMoveReusesCrossDisplayInsertionAndSwapsInEveryLayoutCombination() throws {
        for source in [LayoutType.niri, .dwindle] {
            for target in [LayoutType.niri, .dwindle] {
                for swaps in [false, true] {
                    let fixture = try makeNativeFixture([source, target])
                    fixture.controller.settings.gestures.mouseMoveModifierKey = .off
                    let moved = addWindow(1, to: fixture.source, fixture)
                    let resident = addWindow(2, to: fixture.target, fixture)
                    let start = try beginNativeDrag(moved, fixture)
                    let frame = try XCTUnwrap(fixture.frame(resident))
                    let point = swaps ? frame.center : dropPoint(in: frame, .right)
                    fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: 1600, dy: 0) }

                    fixture.handler.dispatchMouseUp(at: point)

                    XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
                    XCTAssertEqual(fixture.manager.workspace(for: resident), swaps ? fixture.source : fixture.target)
                    XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
                    XCTAssertNil(fixture.handler.state.nativeCrossDisplayMove)
                    XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: moved))
                    if target == .niri, !swaps {
                        XCTAssertEqual(fixture.columns(fixture.target), [[resident], [moved]])
                    }
                }
            }
        }
    }

    func testNativeMoveWaitsForTheFinalFrameAndDoesNotCommitAgain() throws {
        for missing in [false, true] {
            let fixture = try makeNativeFixture([.niri, .dwindle])
            let moved = addWindow(1, to: fixture.source, fixture)
            let resident = addWindow(2, to: fixture.target, fixture)
            let start = try beginNativeDrag(moved, fixture)
            let point = try dropPoint(in: XCTUnwrap(fixture.frame(resident)), .right)
            fixture.handler.nativeWindowFrameProvider = { _ in missing ? nil : start }
            XCTAssertTrue(fixture.controller.axManager.excludeFrameWriteForNativeTitleBarDrag(
                pid: moved.pid, windowId: moved.windowId
            ))
            let before = fixture.manager.worldSeq

            fixture.handler.dispatchMouseUp(at: point)

            XCTAssertEqual(fixture.manager.worldSeq, before)
            XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.phase, .awaitingFrameChange)
            XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
            fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: 1600, dy: 0) }
            let entry = try XCTUnwrap(fixture.manager.entry(for: moved))
            XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: entry))
            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
            let after = fixture.manager.worldSeq
            XCTAssertFalse(fixture.handler.handleNativeTitleBarDragFrameChanged(for: entry))
            XCTAssertEqual(fixture.manager.worldSeq, after)
        }
    }

    func testNativeFallbackUsesTheReleasePointBeforeQueuedFramesDrain() throws {
        let fixture = try makeNativeFixture([.niri, .niri])
        let moved = addWindow(1, to: fixture.source, fixture)
        let resident = addWindow(2, to: fixture.target, fixture)
        let start = try beginNativeDrag(moved, fixture, exactTarget: false)
        let point = try dropPoint(in: XCTUnwrap(fixture.frame(resident)), .right)
        let observed = start.offsetBy(dx: 1600, dy: 0)
        fixture.handler.nativeWindowFrameProvider = { _ in observed }
        fixture.controller.axEventHandler.frameObservations.nativeDragQuery = { windowId in
            WindowServerInfo(id: windowId, pid: moved.pid, level: 0, frame: observed)
        }
        fixture.controller.eventIntake.open(sink: fixture.controller.eventInterpreter)
        defer { fixture.controller.eventIntake.close() }
        XCTAssertTrue(fixture.controller.eventIntake.enqueue(.cgs(.frameChanged(windowId: UInt32(moved.windowId)))))

        fixture.handler.receiveTapMouseUp(at: point)

        XCTAssertEqual(fixture.columns(fixture.target), [[resident], [moved]])
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertNil(fixture.handler.state.nativeCrossDisplayMove)
        XCTAssertFalse(fixture.controller.eventIntake.hasPendingEvents)
    }

    func testDeferredNativeMoveCannotAdoptAHiddenParkedWindow() throws {
        for layout in [LayoutType.niri, .dwindle] {
            for exactTarget in [false, true] {
                let fixture = try makeNativeFixture([layout, .niri])
                let context = "\(layout), exactTarget: \(exactTarget)"
                let moved = addWindow(1, to: fixture.source, fixture)
                let resident = addWindow(2, to: fixture.target, fixture)
                let start = try beginNativeDrag(moved, fixture, exactTarget: exactTarget)
                fixture.handler.dispatchMouseUp(at: try XCTUnwrap(fixture.frame(resident)).center)
                XCTAssertNotNil(fixture.handler.state.nativeCrossDisplayMove)
                XCTAssertTrue(fixture.handler.tracksNativeTitleBarDrag(windowId: moved.windowId))

                let nextWorkspace = try XCTUnwrap(fixture.manager.createDynamicWorkspace(
                    named: "3",
                    on: fixture.monitors[0].id
                ))
                XCTAssertTrue(fixture.manager.setActiveWorkspace(nextWorkspace.id, on: fixture.monitors[0].id))
                let hidden = HiddenState(
                    proportionalPosition: .zero,
                    referenceMonitorId: fixture.monitors[0].id,
                    reason: .workspaceInactive
                )
                fixture.manager.setHiddenState(hidden, for: moved)
                fixture.controller.axManager.markWindowInactive(moved.windowId)
                let entry = try XCTUnwrap(fixture.manager.entry(for: moved))
                let parked = start.offsetBy(dx: fixture.monitors[0].frame.maxX - 1 - start.minX, dy: 0)
                let request = try XCTUnwrap(fixture.controller.axManager.prepareParkFrameApplications([
                    .init(pid: moved.pid, window: entry.axRef, frame: parked)
                ]).first)
                XCTAssertTrue(fixture.controller.axManager.processParkFrameApplyResults([
                    WindowAdmissionTestSupport.successfulFrameResult(request: request)
                ]).isEmpty)
                fixture.handler.nativeWindowFrameProvider = { _ in parked }
                fixture.controller.axEventHandler.frameObservations.nativeDragQuery = { windowId in
                    WindowServerInfo(
                        id: windowId, pid: moved.pid, level: 0,
                        frame: ScreenCoordinateSpace.toWindowServer(rect: parked)
                    )
                }
                let before = fixture.manager.worldSeq

                fixture.controller.axEventHandler.handleCGSEvent(.frameChanged(windowId: UInt32(moved.windowId)))

                XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source, context)
                XCTAssertEqual(fixture.manager.workspace(for: resident), fixture.target, context)
                XCTAssertEqual(fixture.manager.hiddenState(for: moved), hidden)
                XCTAssertEqual(fixture.manager.worldSeq, before, context)
                XCTAssertEqual(fixture.controller.axManager.verifiedParkFrame(for: moved.windowId), parked)
                XCTAssertNil(fixture.handler.state.nativeCrossDisplayMove)
                XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
                XCTAssertNil(fixture.handler.state.nativeTitleBarDragFallbackToken)
            }
        }
    }

    func testNativeMoveCanEnterAnEmptyWorkspace() throws {
        for target in [LayoutType.niri, .dwindle] {
            let fixture = try makeNativeFixture([.niri, target])
            let moved = addWindow(1, to: fixture.source, fixture)
            let start = try beginNativeDrag(moved, fixture)
            fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: 1600, dy: 0) }

            fixture.handler.dispatchMouseUp(at: fixture.monitors[1].frame.center)

            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
            XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        }
    }

    func testFallbackFrameChangeAfterAClickIsNotAdoptedAsADrag() throws {
        let fixture = try makeNativeFixture([.niri, .niri])
        let moved = addWindow(1, to: fixture.source, fixture)
        let resident = addWindow(2, to: fixture.target, fixture)
        fixture.layout()
        let start = try XCTUnwrap(fixture.frame(moved))
        fixture.controller.axManager.confirmFrameWrite(for: moved.windowId, frame: start)
        fixture.controller.hasStartedServices = true
        let observed = start.offsetBy(dx: 1600, dy: 0)
        fixture.handler.nativeWindowFrameProvider = { _ in observed }
        fixture.controller.axEventHandler.frameObservations.nativeDragQuery = { windowId in
            WindowServerInfo(id: windowId, pid: moved.pid, level: 0, frame: observed)
        }
        fixture.controller.eventIntake.open(sink: fixture.controller.eventInterpreter)
        defer { fixture.controller.eventIntake.close() }
        XCTAssertFalse(fixture.handler.dispatchMouseDown(at: start.center, modifiers: []))
        XCTAssertTrue(fixture.controller.eventIntake.enqueue(.cgs(.frameChanged(windowId: UInt32(moved.windowId)))))
        let before = fixture.manager.worldSeq

        fixture.handler.receiveTapMouseUp(at: try XCTUnwrap(fixture.frame(resident)).center)

        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
        XCTAssertEqual(fixture.manager.worldSeq, before)
        XCTAssertNil(fixture.handler.state.nativeCrossDisplayMove)
    }

    func testNativeMovePreservesFocusPolicy() throws {
        for follows in [false, true] {
            let fixture = try makeNativeFixture([.niri, .dwindle])
            fixture.controller.settings.focus.followsWindowToMonitor = follows
            let moved = addWindow(1, to: fixture.source, fixture)
            _ = addWindow(2, to: fixture.source, fixture)
            let resident = addWindow(3, to: fixture.target, fixture)
            let start = try beginNativeDrag(moved, fixture)
            fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: 1600, dy: 0) }

            fixture.handler.dispatchMouseUp(at: try dropPoint(in: XCTUnwrap(fixture.frame(resident)), .right))

            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
            XCTAssertEqual(fixture.controller.activeWorkspace()?.id, follows ? fixture.target : fixture.source)
        }
    }

    func testNativeMoveUsesTheExistingDwindleGroupPolicy() throws {
        for mode in DwindleGroupDrag.allCases {
            let fixture = try makeNativeFixture([.dwindle, .niri])
            fixture.controller.settings.gestures.dwindleGroupDragAcrossDisplays = mode
            let first = addWindow(1, to: fixture.source, fixture)
            let moved = addWindow(2, to: fixture.source, fixture)
            group(moved, into: first, in: fixture.source, fixture)
            let resident = addWindow(3, to: fixture.target, fixture)
            let start = try beginNativeDrag(moved, fixture)
            fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: 1600, dy: 0) }

            fixture.handler.dispatchMouseUp(at: try dropPoint(in: XCTUnwrap(fixture.frame(resident)), .right))

            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
            XCTAssertEqual(fixture.manager.workspace(for: first), mode == .group ? fixture.target : fixture.source)
            let arrived = try XCTUnwrap(fixture.niri.columns(in: fixture.target).last)
            XCTAssertEqual(Set(arrived.windowNodes.map(\.token)), mode == .group ? [first, moved] : [moved])
        }
    }

    func testNativeMoveRefusesFullscreenTargetsAndSlotsThatCannotFit() throws {
        for targetLayout in [LayoutType.niri, .dwindle] {
            let fixture = try makeNativeFixture([.niri, targetLayout])
            let moved = addWindow(1, to: fixture.source, fixture)
            let resident = addWindow(2, to: fixture.target, fixture)
            if targetLayout == .niri {
                let sibling = addWindow(3, to: fixture.source, fixture)
                try stack(sibling, onto: moved, in: fixture.source, fixture)
                fixture.manager.setCachedConstraints(constraints(minHeight: 2_000), for: resident)
            } else {
                fixture.manager.withEngineMutationScope(in: fixture.target) {
                    XCTAssertEqual(fixture.dwindle.toggleFullscreen(in: fixture.target), resident)
                }
            }
            let start = try beginNativeDrag(moved, fixture)
            fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: 1600, dy: 0) }
            let before = fixture.manager.worldSeq

            fixture.handler.dispatchMouseUp(at: try XCTUnwrap(fixture.frame(resident)).center)

            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
            XCTAssertEqual(fixture.manager.worldSeq, before)
            XCTAssertNil(fixture.handler.state.nativeCrossDisplayMove)
            XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.phase, .awaitingCorrection)
        }
    }

    func testNativeResizeWithACrossDisplayPointerStaysInItsWorkspace() throws {
        for layout in [LayoutType.niri, .dwindle] {
            for resizeEnabled in [false, true] {
                let fixture = try makeNativeFixture([layout, .niri])
                fixture.controller.settings.gestures.adoptNativeResize = resizeEnabled
                let moved = addWindow(1, to: fixture.source, fixture)
                let resident = addWindow(2, to: fixture.target, fixture)
                let start = try beginNativeDrag(moved, fixture)
                fixture.handler.nativeWindowFrameProvider = { _ in
                    CGRect(x: start.minX, y: start.minY, width: start.width + 100, height: start.height)
                }

                fixture.handler.dispatchMouseUp(at: try XCTUnwrap(fixture.frame(resident)).center)

                XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
                XCTAssertNil(fixture.handler.state.nativeCrossDisplayMove)
            }
        }
    }

    func testContentDragWithoutWindowDisplacementDoesNotMoveOrCaptureTheWindow() throws {
        let fixture = try makeNativeFixture([.niri, .niri])
        let moved = addWindow(1, to: fixture.source, fixture)
        let resident = addWindow(2, to: fixture.target, fixture)
        _ = try beginNativeDrag(moved, fixture)
        let before = fixture.manager.worldSeq

        fixture.handler.dispatchMouseUp(at: try XCTUnwrap(fixture.frame(resident)).center)

        XCTAssertEqual(fixture.manager.worldSeq, before)
        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
        XCTAssertNil(fixture.handler.state.capturedInteractionButton)
        fixture.handler.retireNativeTitleBarDragAtInputBoundary()
        XCTAssertNil(fixture.handler.state.nativeCrossDisplayMove)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
    }

    func testDeferredNativeMoveRetainsExcludedFrameCorrectionAtNextInput() throws {
        for layout in [LayoutType.niri, .dwindle] {
            for (unreadable, receivesFrameEvent) in [(false, false), (false, true), (true, false), (true, true)] {
                for excluded in [false, true] {
                    let fixture = try makeNativeFixture([layout, .niri])
                    let moved = addWindow(1, to: fixture.source, fixture)
                    let resident = addWindow(2, to: fixture.target, fixture)
                    let start = try beginNativeDrag(moved, fixture)
                    let entry = try XCTUnwrap(fixture.manager.entry(for: moved))
                    let refresh = fixture.controller.layoutRefreshController
                    refresh.layoutState.activeRefresh = .init(
                        kind: .immediateRelayout, reason: .layoutCommand, affectedWorkspaceIds: [fixture.source]
                    )
                    defer { refresh.resetState() }
                    if excluded {
                        fixture.controller.axManager.applyFramesParallel([.init(
                            pid: moved.pid, window: entry.axRef, frame: start.offsetBy(dx: 30, dy: 0)
                        )])
                    }
                    XCTAssertNil(fixture.controller.axManager.pendingFrameWrite(for: moved.windowId))
                    XCTAssertEqual(fixture.controller.axManager.lastAppliedFrame(for: moved.windowId), start)
                    if unreadable {
                        fixture.handler.nativeWindowFrameProvider = { _ in nil }
                    }

                    fixture.handler.dispatchMouseUp(at: try XCTUnwrap(fixture.frame(resident)).center)

                    XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.phase, .awaitingFrameChange)
                    XCTAssertNil(refresh.layoutState.pendingRefresh)
                    fixture.handler.nativeWindowFrameProvider = { _ in start }
                    if receivesFrameEvent {
                        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: entry))
                    }
                    fixture.handler.retireNativeTitleBarDragAtInputBoundary()

                    if excluded {
                        XCTAssertEqual(refresh.layoutState.pendingRefresh?.kind, .immediateRelayout)
                        XCTAssertEqual(refresh.layoutState.pendingRefresh?.reason, .interactiveGesture)
                        XCTAssertEqual(refresh.layoutState.pendingRefresh?.affectedWorkspaceIds, [fixture.source])
                        XCTAssertNil(fixture.controller.axManager.lastAppliedFrame(for: moved.windowId))
                    } else {
                        XCTAssertNil(refresh.layoutState.pendingRefresh)
                        XCTAssertEqual(fixture.controller.axManager.lastAppliedFrame(for: moved.windowId), start)
                    }
                    XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
                    XCTAssertEqual(fixture.manager.workspace(for: resident), fixture.target)
                    XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
                    XCTAssertNil(fixture.handler.state.nativeCrossDisplayMove)
                }
            }
        }
    }

    func testContentDragDoesNotAdoptManagedFramesAcrossDisplays() throws {
        for layout in [LayoutType.niri, .dwindle] {
            for delayed in [false, true] {
                for pending in [false, true] {
                    let fixture = try makeNativeFixture([layout, .niri])
                    let moved = addWindow(1, to: fixture.source, fixture)
                    let resident = addWindow(2, to: fixture.target, fixture)
                    let start = try beginNativeDrag(moved, fixture)
                    let point = try XCTUnwrap(fixture.frame(resident)).center
                    let entry = try XCTUnwrap(fixture.manager.entry(for: moved))
                    if delayed {
                        fixture.handler.dispatchMouseUp(at: point)
                        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.phase, .awaitingFrameChange)
                    }
                    let managedFrame = start.offsetBy(dx: 30, dy: 0)
                    if pending {
                        XCTAssertNotNil(fixture.controller.axManager.stageFrameWrite(for: .init(
                            pid: moved.pid, window: entry.axRef, frame: managedFrame
                        )))
                    } else {
                        fixture.controller.axManager.confirmFrameWrite(for: moved.windowId, frame: managedFrame)
                    }
                    fixture.handler.nativeWindowFrameProvider = { _ in managedFrame }
                    let before = fixture.manager.worldSeq

                    if delayed {
                        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: entry))
                    } else {
                        fixture.handler.dispatchMouseUp(at: point)
                    }

                    XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
                    XCTAssertEqual(fixture.manager.workspace(for: resident), fixture.target)
                    XCTAssertEqual(fixture.manager.worldSeq, before)
                    XCTAssertNil(fixture.handler.state.nativeCrossDisplayMove)
                }
            }
        }
    }

    func testNativeMoveCannotSurviveSuppressionOrDisablingTheSetting() throws {
        for suppresses in [false, true] {
            let fixture = try makeNativeFixture([.niri, .niri])
            let moved = addWindow(1, to: fixture.source, fixture)
            let resident = addWindow(2, to: fixture.target, fixture)
            let start = try beginNativeDrag(moved, fixture)
            if suppresses {
                fixture.handler.handleInputSuppressionBegan()
            } else {
                fixture.controller.settings.gestures.adoptNativeMoveAcrossDisplays = false
            }
            fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: 1600, dy: 0) }
            let before = fixture.manager.worldSeq

            fixture.handler.dispatchMouseUp(at: try XCTUnwrap(fixture.frame(resident)).center)

            XCTAssertEqual(fixture.manager.worldSeq, before)
            XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.source)
            XCTAssertNil(fixture.handler.state.nativeCrossDisplayMove)
        }
    }

    private func makeNativeFixture(_ layouts: [LayoutType], enabled: Bool = true) throws -> Fixture {
        let fixture = try makeFixture(layouts)
        fixture.controller.settings.gestures.adoptNativeMoveAcrossDisplays = enabled
        addTeardownBlock { @MainActor [controller = fixture.controller] in
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
        return fixture
    }

    private func beginNativeDrag(_ token: WindowToken, _ fixture: Fixture, exactTarget: Bool = true) throws -> CGRect {
        fixture.layout()
        let frame = try XCTUnwrap(fixture.frame(token))
        fixture.controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
        fixture.controller.hasStartedServices = true
        fixture.handler.nativeWindowFrameProvider = { _ in frame }
        fixture.handler.nativeWindowFrameFallbackProvider = { _ in nil }
        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: frame.center, modifiers: [], windowIdUnderPointer: exactTarget ? token.windowId : nil
        ))
        fixture.handler.dispatchMouseDragged(at: frame.center)
        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertNil(fixture.handler.state.capturedInteractionButton)
        return frame
    }

    private func makeFixture(_ layouts: [LayoutType]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossDisplayDragTests-\(UUID().uuidString)", isDirectory: true)
        let monitors = layouts.indices.map { index in
            let displayId = CGDirectDisplayID(720_000 + index)
            let frame = CGRect(x: CGFloat(index) * 1600, y: 0, width: 1600, height: 900)
            return Monitor(
                id: .init(displayId: displayId), displayId: displayId,
                frame: frame, visibleFrame: frame, hasNotch: false, name: "Display \(index + 1)"
            )
        }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        settings.animationsEnabled = false
        settings.gestures.mouseMoveModifierKey = .control
        settings.workspaces.configurations = zip(monitors, layouts).enumerated().map { index, pair in
            WorkspaceConfiguration(
                name: "\(index + 1)",
                monitorAssignment: .specificDisplay(OutputId(from: pair.0)),
                layoutType: pair.1
            )
        }
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange(monitors)
        manager.applySettings()
        let niri = NiriLayoutEngine()
        niri.animationClock = controller.animationClock
        controller.niriEngine = niri
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()
        let dwindle = DwindleLayoutEngine()
        dwindle.animationClock = controller.animationClock
        controller.dwindleEngine = dwindle
        let workspaces = try layouts.indices.map { try XCTUnwrap(manager.workspaceId(named: "\($0 + 1)")) }
        for index in workspaces.indices.reversed() {
            XCTAssertTrue(manager.setActiveWorkspace(
                workspaces[index], on: monitors[index].id, updateInteractionMonitor: index == 0
            ))
        }
        controller.layoutRefreshController.resetState()
        controller.mouseEventHandler.pressedMouseButtonsProvider = { 1 }
        return Fixture(
            controller: controller,
            niri: niri,
            dwindle: dwindle,
            monitors: monitors,
            workspaces: workspaces
        )
    }

    private func addWindow(
        _ windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        pid: pid_t = 8_660,
        _ fixture: Fixture
    ) -> WindowToken {
        let manager = fixture.manager
        let token = manager.addWindow(
            WindowAdmissionTestSupport.axRef(for: WindowToken(pid: pid, windowId: windowId)),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        manager.withEngineMutationScope(in: workspaceId) {
            switch manager.activeLayoutKind(for: workspaceId) {
            case .niri:
                let selection = fixture.niri.columns(in: workspaceId).last?.windowNodes.last?.id
                _ = fixture.niri.addWindow(token: token, to: workspaceId, afterSelection: selection)
            case .dwindle:
                _ = fixture.dwindle.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            }
        }
        return token
    }

    private func group(
        _ token: WindowToken,
        into target: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        _ fixture: Fixture
    ) {
        fixture.manager.withEngineMutationScope(in: workspaceId) {
            XCTAssertTrue(fixture.dwindle.groupWindow(token, into: target, in: workspaceId))
        }
    }

    private func stack(
        _ token: WindowToken,
        onto target: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        _ fixture: Fixture
    ) throws {
        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriStack(workspaceId, target: target, position: .after),
            source: .init(tokens: [token], workspaceId: workspaceId, isFloating: false)
        ))
        XCTAssertTrue(try XCTUnwrap(fixture.niri.findColumn(
            containing: XCTUnwrap(fixture.niri.findNode(for: target, in: workspaceId)),
            in: workspaceId
        )).windowNodes.contains { $0.token == token })
    }

    private func dropPoint(in frame: CGRect, _ direction: Direction) -> CGPoint {
        switch direction {
        case .left: CGPoint(x: frame.minX + frame.width * 0.1, y: frame.midY)
        case .right: CGPoint(x: frame.maxX - frame.width * 0.1, y: frame.midY)
        case .up: CGPoint(x: frame.midX, y: frame.maxY - frame.height * 0.1)
        case .down: CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.1)
        }
    }

    private func constraints(minWidth: CGFloat = 0, minHeight: CGFloat) -> WindowSizeConstraints {
        WindowSizeConstraints(minSize: CGSize(width: minWidth, height: minHeight), maxSize: .zero, isFixed: false)
    }
}
