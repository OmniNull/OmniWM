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

    private func touch(for point: CGPoint, in fixture: Fixture) -> CGPoint {
        let monitor = fixture.monitor.frame
        return CGPoint(
            x: fixture.startTouch.x + (point.x - fixture.startFrame.midX) / monitor.width,
            y: fixture.startTouch.y + (point.y - fixture.startFrame.midY) / monitor.height
        )
    }

    private func move(_ fixture: Fixture, to point: CGPoint) {
        fixture.begin()
        fixture.send(fixture.event(at: touch(for: point, in: fixture)))
        XCTAssertTrue(fixture.handler.state.isMoving)
    }

    private func lift(_ fixture: Fixture, at point: CGPoint) {
        fixture.send(fixture.event(at: touch(for: point, in: fixture), phase: .ended, sample: 3))
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

    func testTrackpadDropBesideAFarColumnGivesTheWindowItsOwnColumnOnThatSide() throws {
        for side in [Direction.left, .right] {
            let fixture = try makeMoveFixture(.horizontal, windows: 3)
            let (moved, middle, far) = (fixture.tokens[0], fixture.tokens[1], fixture.tokens[2])
            XCTAssertEqual(fixture.order(), [[moved], [middle], [far]])

            try drop(fixture, on: side, of: far)

            XCTAssertEqual(
                fixture.order(),
                side == .left ? [[middle], [moved], [far]] : [[middle], [far], [moved]],
                "\(side)"
            )
        }
    }

    func testTrackpadDropOnTheTopOrBottomOfAWindowStacksItThereAsTheActiveMember() throws {
        for side in [Direction.up, .down] {
            let fixture = try makeMoveFixture(.horizontal, windows: 3)
            let (moved, target, other) = (fixture.tokens[0], fixture.tokens[1], fixture.tokens[2])

            try drop(fixture, on: side, of: target)

            XCTAssertEqual(
                fixture.order(),
                side == .up ? [[target, moved], [other]] : [[moved, target], [other]],
                "\(side)"
            )
            let frames = try frames(fixture)
            let movedFrame = try XCTUnwrap(frames[moved])
            let targetFrame = try XCTUnwrap(frames[target])
            if side == .up {
                XCTAssertGreaterThanOrEqual(movedFrame.minY, targetFrame.maxY)
            } else {
                XCTAssertLessThanOrEqual(movedFrame.maxY, targetFrame.minY)
            }
            XCTAssertEqual(activeMember(ofColumnHolding: moved, in: fixture), moved, "\(side)")
        }
    }

    private enum UnchangedDrop: CaseIterable {
        case loneWindowOnTheNearSideOfItsNeighbour
        case stackedWindowOnTheSideItAlreadyOccupies
        case stackedWindowNextToItsNeighbourAcrossAHiddenWindow
    }

    private func makeUnchangedDrop(
        _ scenario: UnchangedDrop
    ) throws -> (fixture: Fixture, side: Direction, target: WindowToken) {
        switch scenario {
        case .loneWindowOnTheNearSideOfItsNeighbour:
            let fixture = try makeMoveFixture(.horizontal, windows: 3)
            return (fixture, .left, fixture.target)
        case .stackedWindowOnTheSideItAlreadyOccupies:
            let fixture = try makeMoveFixture(.horizontal, grouped: true) { base, tokens in
                base.niriNode(tokens[0])?.height = Self.ownShare
            }
            return (fixture, .down, fixture.tokens[2])
        case .stackedWindowNextToItsNeighbourAcrossAHiddenWindow:
            let host = CrossDisplayDragTests()
            let fixture = try makeMoveFixture(.horizontal, grouped: true) { base, tokens in
                base.niriNode(tokens[0])?.height = Self.ownShare
                let hidden = host.addWindow(tokens.count + 1, to: base.source, pid: Self.hiddenAppPid, base)
                try host.stack(hidden, onto: tokens[0], in: base.source, base)
                _ = base.manager.setAppHidden(true, pid: Self.hiddenAppPid, source: .ax)
            }
            let column = try XCTUnwrap(fixture.order().first)
            XCTAssertEqual([column.first, column.last], [fixture.moved, fixture.tokens[2]])
            let hiddenBetween = column.dropFirst().dropLast().map {
                fixture.base.niri.isExcludedFromProjection($0, in: fixture.workspace)
            }
            XCTAssertEqual(hiddenBetween, [true])
            return (fixture, .down, fixture.tokens[2])
        }
    }

    func testATrackpadDropThatWouldChangeNothingPutsTheWindowBackAsItWas() throws {
        for scenario in UnchangedDrop.allCases {
            let (fixture, side, target) = try makeUnchangedDrop(scenario)
            let original = fixture.order()
            let height = fixture.base.niriNode(fixture.moved)?.height
            if scenario != .loneWindowOnTheNearSideOfItsNeighbour {
                XCTAssertEqual(height, Self.ownShare, "\(scenario)")
            }

            try drop(fixture, on: side, of: target)

            XCTAssertEqual(fixture.order(), original, "\(scenario)")
            XCTAssertEqual(fixture.base.niriNode(fixture.moved)?.height, height, "\(scenario)")
            XCTAssertEqual(try frames(fixture), fixture.initialFrames, "\(scenario)")
        }
    }

    func testTrackpadDropOfTheShownTabIntoAnotherStackShowsTheTabLeftBehind() throws {
        let fixture = try makeMoveFixture(.horizontal, grouped: true) { base, tokens in
            base.manager.withEngineMutationScope(in: base.source) {
                guard let shown = base.niriNode(tokens[0]),
                      let column = base.niri.findColumn(containing: shown, in: base.source)
                else { return }
                column.displayMode = .tabbed
                base.niri.activateWindow(shown.id, in: base.source)
            }
        }
        let (moved, target, leftBehind) = (fixture.tokens[0], fixture.tokens[1], fixture.tokens[2])
        XCTAssertEqual(fixture.base.niriNode(leftBehind)?.isHiddenInTabbedMode, true)

        try drop(fixture, on: .up, of: target)

        XCTAssertEqual(fixture.order(), [[leftBehind], [target, moved]])
        XCTAssertEqual(fixture.base.niriNode(leftBehind)?.isHiddenInTabbedMode, false)
        XCTAssertEqual(activeMember(ofColumnHolding: leftBehind, in: fixture), leftBehind)
    }

    func testTrackpadStackDropOnAPortraitStripResetsTheWindowsOwnWidth() throws {
        let fixture = try makeMoveFixture(.vertical, grouped: true) { base, tokens in
            base.niriNode(tokens[0])?.windowWidth = Self.ownShare
        }
        let (moved, target, sibling) = (fixture.tokens[0], fixture.tokens[1], fixture.tokens[2])

        try drop(fixture, on: .right, of: target)

        XCTAssertEqual(fixture.order(), [[sibling], [target, moved]])
        XCTAssertEqual(fixture.base.niriNode(moved)?.windowWidth, .default)
    }

    func testTrackpadDropOnTheTopOfADwindleTileLandsAboveIt() throws {
        let fixture = try makeMoveFixture(.dwindle, windows: 3)
        let (moved, target) = (fixture.tokens[0], fixture.tokens[1])

        try drop(fixture, on: .up, of: target)

        let frames = try frames(fixture)
        let movedFrame = try XCTUnwrap(frames[moved])
        let targetFrame = try XCTUnwrap(frames[target])
        XCTAssertGreaterThanOrEqual(movedFrame.minY, targetFrame.maxY)
        XCTAssertEqual(movedFrame.minX, targetFrame.minX)
        XCTAssertEqual(movedFrame.width, targetFrame.width)
    }

    func testTrackpadDropAtTheEdgeOfTheDwindleAreaMakesTheWindowTheTileAlongThatEdge() throws {
        let fixture = try makeMoveFixture(.dwindle, windows: 3)
        let moved = fixture.moved
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        XCTAssertLessThan(fixture.startFrame.midX, area.midX)
        let lastPointInside = CGPoint(x: area.maxX - 1, y: area.midY)
        XCTAssertEqual(
            fixture.base.dwindle.workspaceEdgeDirection(at: lastPointInside, in: area, from: fixture.startFrame.center),
            .right
        )

        move(fixture, to: lastPointInside)
        lift(fixture, at: lastPointInside)

        let frames = try frames(fixture)
        let movedFrame = try XCTUnwrap(frames[moved])
        let tiled = frames.values.reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(movedFrame.maxX, tiled.maxX)
        XCTAssertEqual(movedFrame.minY, tiled.minY)
        XCTAssertEqual(movedFrame.maxY, tiled.maxY)
        for (token, frame) in frames where token != moved {
            XCTAssertLessThanOrEqual(frame.maxX, movedFrame.minX)
        }
    }

    func testTrackpadDropOnTheLineBetweenTwoDwindleTilesLandsBetweenThemOnlyAtTheLift() throws {
        let fixture = try makeMoveFixture(.dwindle, windows: 3)
        let (moved, left, right) = (fixture.tokens[0], fixture.tokens[1], fixture.tokens[2])
        let leftFrame = try XCTUnwrap(fixture.initialFrames[left])
        let rightFrame = try XCTUnwrap(fixture.initialFrames[right])
        XCTAssertLessThan(leftFrame.maxX, rightFrame.minX)
        let line = CGPoint(x: (leftFrame.maxX + rightFrame.minX) / 2, y: leftFrame.midY)
        XCTAssertNotNil(
            fixture.base.dwindle.splitBoundaryMoveHit(at: line, for: moved, in: fixture.workspace, time: 0)
        )

        move(fixture, to: line)
        XCTAssertEqual(fixture.base.dwindle.interactiveMove?.isInsertion, false)
        lift(fixture, at: line)

        let frames = try frames(fixture)
        let movedFrame = try XCTUnwrap(frames[moved])
        XCTAssertGreaterThanOrEqual(movedFrame.minX, try XCTUnwrap(frames[left]).maxX)
        XCTAssertLessThanOrEqual(movedFrame.maxX, try XCTUnwrap(frames[right]).minX)
    }
}
