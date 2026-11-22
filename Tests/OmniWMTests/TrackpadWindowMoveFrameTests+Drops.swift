// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
extension TrackpadWindowMoveFrameTests {
    private static let ownShare = WeightedSize.auto(weight: 2)
    private static let hiddenAppPid: pid_t = 965_802

    private func part(_ side: Direction?, of frame: CGRect) -> CGPoint {
        WindowMoveGeometry.targetFrame(in: frame, direction: side).center
    }

    private func move(_ fixture: Fixture, to point: CGPoint) {
        fixture.begin()
        fixture.send(fixture.event(at: fixture.touch(at: point)))
        XCTAssertTrue(fixture.handler.state.isMoving)
    }

    private func lift(_ fixture: Fixture, at point: CGPoint) {
        fixture.send(fixture.event(at: fixture.touch(at: point), phase: .ended, sample: 3))
        XCTAssertFalse(fixture.handler.state.isMoving)
    }

    private func drop(_ fixture: Fixture, on side: Direction?, of target: WindowToken) throws {
        let frame = try XCTUnwrap(fixture.initialFrames[target])
        let point = part(side, of: frame)
        XCTAssertEqual(WindowMoveGeometry.insertionDirection(at: point, in: frame), side)
        move(fixture, to: point)
        lift(fixture, at: point)
    }

    private func frames(_ fixture: Fixture) throws -> [WindowToken: CGRect] {
        Dictionary(uniqueKeysWithValues: try fixture.projection().frameChanges.map { ($0.token, $0.frame) })
    }

    private func activeMember(ofColumnHolding token: WindowToken, in fixture: Fixture) -> WindowToken? {
        guard let node = fixture.base.niriNode(token),
              let column = fixture.base.niri.findColumn(containing: node, in: fixture.workspace)
        else { return nil }
        let members = column.windowNodes
        return members.indices.contains(column.activeTileIdx) ? members[column.activeTileIdx].token : nil
    }

    private func holdOverTarget(_ fixture: Fixture, at point: CGPoint) throws {
        fixture.handler.liveDragClock = { 0 }
        move(fixture, to: point)
        let delay = fixture.base.niri.liveCentreStackDelay
        fixture.handler.liveDragClock = { delay }
        try XCTUnwrap(fixture.handler.liveDragSession?.hoverTimer).fire()
    }

    func testTrackpadHoldOverTargetMakesRoomAboveOrBelowBeforeLift() throws {
        for above in [false, true] {
            let fixture = try makeMoveFixture(.horizontal, windows: 3)
            let (moved, target, other) = (fixture.moved, fixture.target, fixture.tokens[2])
            let frame = fixture.targetFrame
            let point = CGPoint(x: frame.midX, y: (frame.midY + (above ? frame.maxY : frame.minY)) / 2)
            let members = above ? [target, moved] : [moved, target]

            try holdOverTarget(fixture, at: point)
            XCTAssertEqual(fixture.order().first { $0.contains(target) }, members)
            XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)

            lift(fixture, at: point)
            XCTAssertEqual(fixture.order(), [members, [other]])
            let settled = try frames(fixture)
            let lower = try XCTUnwrap(settled[members[0]])
            let upper = try XCTUnwrap(settled[members[1]])
            XCTAssertLessThanOrEqual(lower.maxY, upper.minY)
            XCTAssertEqual(activeMember(ofColumnHolding: moved, in: fixture), moved)
            XCTAssertTrue(stepHistory(.undo, in: fixture))
            XCTAssertEqual(fixture.order(), [[moved], [target], [other]])
            XCTAssertFalse(stepHistory(.undo, in: fixture))
            XCTAssertTrue(stepHistory(.redo, in: fixture))
            XCTAssertEqual(fixture.order(), [members, [other]])
        }
    }

    func testCancellingAProvisionalTrackpadStackRestoresLayoutFramesAndHistory() throws {
        let fixture = try makeMoveFixture(.horizontal)
        try holdOverTarget(fixture, at: fixture.targetFrame.center)
        XCTAssertTrue(fixture.order().contains { $0.contains(fixture.moved) && $0.contains(fixture.target) })

        fixture.cancel()

        XCTAssertEqual(fixture.order(), [[fixture.moved], [fixture.target]])
        XCTAssertEqual(try frames(fixture), fixture.initialFrames)
        XCTAssertFalse(stepHistory(.undo, in: fixture))
        XCTAssertNil(fixture.base.niri.liveColumnMove)
    }

    func testATrackpadMoveOfTheShownTabCarriesTheOtherTabsWithIt() throws {
        let fixture = try makeMoveFixture(.horizontal, grouped: true) { base, tokens in
            base.manager.withEngineMutationScope(in: base.source) {
                guard let shown = base.niriNode(tokens[0]),
                      let column = base.niri.findColumn(containing: shown, in: base.source)
                else { return }
                column.displayMode = .tabbed
                base.niri.activateWindow(shown.id, in: base.source)
            }
        }
        let (moved, target, tab) = (fixture.moved, fixture.target, fixture.tokens[2])
        XCTAssertEqual(fixture.base.niriNode(tab)?.isHiddenInTabbedMode, true)

        let point = CGPoint(x: (fixture.targetFrame.midX + fixture.targetFrame.maxX) / 2, y: fixture.targetFrame.midY)
        move(fixture, to: point)
        XCTAssertEqual(fixture.base.niri.liveColumnMove?.isWholeColumn, true)
        lift(fixture, at: point)

        XCTAssertEqual(fixture.order(), [[target], [moved, tab]])
        XCTAssertEqual(fixture.base.niriNode(tab)?.isHiddenInTabbedMode, true)
        XCTAssertEqual(activeMember(ofColumnHolding: tab, in: fixture), moved)
    }

    func testTrackpadMovesOneMemberWithinAnOrdinaryStackBeforeLift() throws {
        let fixture = try makeMoveFixture(.horizontal, grouped: true)
        let (moved, target, sibling) = (fixture.moved, fixture.target, fixture.tokens[2])
        let siblingFrame = try XCTUnwrap(fixture.initialFrames[sibling])
        let expected = [[sibling, moved], [target]]

        move(fixture, to: siblingFrame.center)
        XCTAssertEqual(fixture.order(), expected)
        lift(fixture, at: siblingFrame.center)

        XCTAssertEqual(fixture.order(), expected)
        XCTAssertEqual(activeMember(ofColumnHolding: sibling, in: fixture), moved)
    }

    func testTrackpadStackLandingOnAPortraitStripResetsTheWindowsOwnWidth() throws {
        let fixture = try makeMoveFixture(.vertical, windows: 3) { base, tokens in
            base.niriNode(tokens[0])?.windowWidth = Self.ownShare
        }
        let point = CGPoint(x: (fixture.targetFrame.midX + fixture.targetFrame.maxX) / 2, y: fixture.targetFrame.midY)
        XCTAssertEqual(fixture.base.niriNode(fixture.moved)?.windowWidth, Self.ownShare)
        try holdOverTarget(fixture, at: point)
        lift(fixture, at: point)

        XCTAssertEqual(fixture.order(), [[fixture.target, fixture.moved], [fixture.tokens[2]]])
        XCTAssertEqual(fixture.base.niriNode(fixture.moved)?.windowWidth, .default)
    }

    func testALoneWindowFloatsAndReturnsWithoutATrackpadHistoryStep() throws {
        for tabbed in [false, true] {
            let fixture = try makeMoveFixture(.horizontal, windows: 1) { base, tokens in
                if tabbed, let window = base.niriNode(tokens[0]) {
                    base.manager.withEngineMutationScope(in: base.source) {
                        base.niri.findColumn(containing: window, in: base.source)?.displayMode = .tabbed
                    }
                }
            }
            let frame = fixture.startFrame
            let point = CGPoint(x: frame.midX, y: (frame.midY + frame.maxY) / 2)
            let carried = frame.offsetBy(dx: 0, dy: point.y - frame.midY)
            move(fixture, to: point)
            XCTAssertEqual(try frames(fixture)[fixture.moved], carried)
            lift(fixture, at: point)
            XCTAssertEqual(try frames(fixture), fixture.initialFrames)
            XCTAssertEqual(fixture.order(), [[fixture.moved]])
            XCTAssertFalse(stepHistory(.undo, in: fixture))
        }
    }

    func testMovingWithinAStackSlotKeepsItsSizeAndHistoryAcrossAHiddenMember() throws {
        let host = CrossDisplayDragTests()
        func makeStack() throws -> Fixture {
            try makeMoveFixture(.horizontal, grouped: true) { base, tokens in
                base.niriNode(tokens[0])?.height = Self.ownShare
                let hidden = host.addWindow(tokens.count + 1, to: base.source, pid: Self.hiddenAppPid, base)
                try host.stack(hidden, onto: tokens[0], in: base.source, base)
                _ = base.manager.setAppHidden(true, pid: Self.hiddenAppPid, source: .ax)
            }
        }
        let untouched = try makeStack()
        let fixture = try makeStack()
        let original = fixture.order()
        let between = try XCTUnwrap(original.first).dropFirst().dropLast()
        XCTAssertEqual(between.map { fixture.base.niri.isExcludedFromProjection($0, in: fixture.workspace) }, [true])
        let point = CGPoint(x: fixture.startFrame.midX, y: (fixture.startFrame.midY + fixture.startFrame.maxY) / 2)
        move(fixture, to: point)
        lift(fixture, at: point)

        XCTAssertEqual(fixture.order(), original)
        XCTAssertEqual(fixture.base.niriNode(fixture.moved)?.height, Self.ownShare)
        XCTAssertEqual(try frames(fixture), fixture.initialFrames)
        XCTAssertEqual(stepHistory(.undo, in: fixture), stepHistory(.undo, in: untouched))
        XCTAssertEqual(fixture.order(), untouched.order())
    }

    private func heldAndSettledFrames(_ fixture: Fixture, movingTo point: CGPoint) throws -> [WindowToken: CGRect] {
        move(fixture, to: point)
        let held = try frames(fixture)
        let landing = fixture.base.dwindle.currentFrames(in: fixture.workspace)
        let scale = fixture.controller.layoutRefreshController.buildMonitorSnapshot(for: fixture.monitor).scale
        let projectedLanding = landing.mapValues { $0.roundedToPhysicalPixels(scale: scale) }
        let order = fixture.order()
        XCTAssertEqual(held[fixture.moved], fixture.expectedFloatingFrame(at: fixture.touch(at: point)))
        XCTAssertNotEqual(projectedLanding, fixture.initialFrames)
        XCTAssertEqual(held.filter { $0.key != fixture.moved }, projectedLanding.filter { $0.key != fixture.moved })
        lift(fixture, at: point)
        XCTAssertEqual(fixture.order(), order)
        XCTAssertEqual(try frames(fixture), projectedLanding)
        return projectedLanding
    }

    func testTrackpadMoveToTheTopOfADwindleTileLandsAboveItBeforeLift() throws {
        let fixture = try makeMoveFixture(.dwindle, windows: 3)
        let (moved, target) = (fixture.tokens[0], fixture.tokens[1])

        let point = part(.up, of: fixture.targetFrame)
        XCTAssertEqual(WindowMoveGeometry.insertionDirection(at: point, in: fixture.targetFrame), .up)
        let frames = try heldAndSettledFrames(fixture, movingTo: point)
        let movedFrame = try XCTUnwrap(frames[moved])
        let targetFrame = try XCTUnwrap(frames[target])
        XCTAssertGreaterThanOrEqual(movedFrame.minY, targetFrame.maxY)
        XCTAssertEqual(movedFrame.minX, targetFrame.minX)
        XCTAssertEqual(movedFrame.width, targetFrame.width)
    }

    func testTrackpadMoveToTheDwindleAreaEdgeMakesTheOuterTileBeforeLift() throws {
        let fixture = try makeMoveFixture(.dwindle, windows: 3)
        let moved = fixture.moved
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        XCTAssertLessThan(fixture.startFrame.midX, area.midX)
        let lastPointInside = CGPoint(x: area.maxX - 1, y: area.midY)
        XCTAssertEqual(
            fixture.base.dwindle.workspaceEdgeDirection(at: lastPointInside, in: area, from: fixture.startFrame.center),
            .right
        )

        let frames = try heldAndSettledFrames(fixture, movingTo: lastPointInside)
        let movedFrame = try XCTUnwrap(frames[moved])
        let tiled = frames.values.reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(movedFrame.maxX, tiled.maxX)
        XCTAssertEqual(movedFrame.minY, tiled.minY)
        XCTAssertEqual(movedFrame.maxY, tiled.maxY)
        for (token, frame) in frames where token != moved {
            XCTAssertLessThanOrEqual(frame.maxX, movedFrame.minX)
        }
    }

    func testTrackpadMoveOntoADwindleDividerLandsBetweenItsTilesBeforeLift() throws {
        let fixture = try makeMoveFixture(.dwindle, windows: 3)
        let (moved, left, right) = (fixture.tokens[0], fixture.tokens[1], fixture.tokens[2])
        let leftFrame = try XCTUnwrap(fixture.initialFrames[left])
        let rightFrame = try XCTUnwrap(fixture.initialFrames[right])
        XCTAssertLessThan(leftFrame.maxX, rightFrame.minX)
        let line = CGPoint(x: (leftFrame.maxX + rightFrame.minX) / 2, y: leftFrame.midY)
        XCTAssertNotNil(
            fixture.base.dwindle.splitBoundaryMoveHit(at: line, for: moved, in: fixture.workspace, time: 0)
        )

        let frames = try heldAndSettledFrames(fixture, movingTo: line)
        let movedFrame = try XCTUnwrap(frames[moved])
        XCTAssertGreaterThanOrEqual(movedFrame.minX, try XCTUnwrap(frames[left]).maxX)
        XCTAssertLessThanOrEqual(movedFrame.maxX, try XCTUnwrap(frames[right]).minX)
    }

    func testUndoAndRedoTakeBackAndRepeatADwindleTrackpadDrop() throws {
        for side in [Direction?.none, .up] {
            let fixture = try makeMoveFixture(.dwindle, windows: 3)
            let original = fixture.order()
            try drop(fixture, on: side, of: fixture.target)
            let dropped = fixture.order()
            XCTAssertNotEqual(dropped, original)

            XCTAssertTrue(stepHistory(.undo, in: fixture))
            XCTAssertEqual(fixture.order(), original)
            XCTAssertTrue(stepHistory(.redo, in: fixture))
            XCTAssertEqual(fixture.order(), dropped)
        }
    }

    private func stepHistory(_ direction: NiriLayoutHistoryDirection, in fixture: Fixture) -> Bool {
        if fixture.kind == .dwindle {
            return fixture.controller.dwindleLayoutHandler.stepLayoutHistory(
                direction == .undo ? .undo : .redo, in: fixture.workspace
            )
        }
        return fixture.controller.niriLayoutHandler.stepLayoutHistory(direction, in: fixture.workspace)
    }
}
