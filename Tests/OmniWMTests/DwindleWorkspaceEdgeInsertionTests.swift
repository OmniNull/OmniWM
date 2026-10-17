// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class DwindleWorkspaceEdgeInsertionTests: XCTestCase {
    private let screen = CGRect(x: -1200, y: 100, width: 1000, height: 800)
    private let directions: [Direction] = [.left, .right, .up, .down]

    private struct Fixture {
        let engine: DwindleLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]
    }

    private indirect enum Tree: Equatable {
        case tile([WindowToken])
        case split(DwindleOrientation, CGFloat, Tree, Tree)
    }

    func testHoverPreviewsWorkspaceHalfWithoutChangingTheLayout() throws {
        for direction in directions {
            let fixture = makeFixture(count: 4)
            let root = try XCTUnwrap(fixture.engine.root(for: fixture.workspaceId))
            let before = tree(root)
            let frames = fixture.engine.currentFrames(in: fixture.workspaceId)

            try hover(fixture.tokens[0], at: direction, fixture: fixture)

            XCTAssertEqual(fixture.engine.interactiveMove?.target, .workspaceEdge(direction, frame: screen))
            XCTAssertNil(fixture.engine.interactiveMove?.targetToken)
            XCTAssertEqual(fixture.engine.interactiveMoveTargetFrame(at: 0), half(direction, of: screen))
            XCTAssertEqual(tree(root), before)
            XCTAssertEqual(fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen), frames)
            fixture.engine.interactiveMoveCancel()
            XCTAssertNil(fixture.engine.interactiveMoveTargetFrame(at: 0))
            XCTAssertEqual(tree(root), before)
        }
    }

    func testEverySourceCanMoveToEachWorkspaceEdgeWithoutLosingTiles() throws {
        for count in [2, 3, 5] {
            for sourceIndex in 0 ..< count {
                for direction in directions {
                    let fixture = makeFixture(count: count)
                    let source = fixture.tokens[sourceIndex]
                    let node = try XCTUnwrap(fixture.engine.findNode(for: source, in: fixture.workspaceId))
                    fixture.engine.settings.defaultSplitRatio = 1.4
                    try hover(source, at: direction, fixture: fixture)

                    XCTAssertEqual(fixture.engine.interactiveMoveEnd(), source)

                    let root = try XCTUnwrap(fixture.engine.root(for: fixture.workspaceId))
                    XCTAssertTrue(node.parent === root)
                    XCTAssertEqual(root.splitOrientation, direction.dwindleOrientation)
                    XCTAssertEqual(root.splitRatio, 1)
                    let frames = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
                    XCTAssertEqual(frames[source], half(direction, of: screen))
                    let remainder = half(opposite(direction), of: screen)
                    for token in fixture.tokens where token != source {
                        XCTAssertTrue(remainder.contains(try XCTUnwrap(frames[token])))
                    }
                    try assertTree(fixture)
                }
            }
        }
    }

    func testRemainderKeepsItsInternalRatiosAndPreselection() throws {
        let fixture = makeFixture(count: 5)
        fixture.engine.settings.defaultSplitRatio = 1.4
        let root = try XCTUnwrap(fixture.engine.root(for: fixture.workspaceId))
        let remainder = try XCTUnwrap(root.secondChild())
        remainder.kind = .split(orientation: .vertical, ratio: 0.6)
        remainder.secondChild()?.kind = .split(orientation: .horizontal, ratio: 1.4)
        _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        let expected = tree(remainder)
        XCTAssertTrue(fixture.engine.setPreselection(.up, in: fixture.workspaceId))

        try hover(fixture.tokens[0], at: .right, fixture: fixture)
        XCTAssertEqual(fixture.engine.interactiveMoveEnd(), fixture.tokens[0])

        XCTAssertEqual(tree(try XCTUnwrap(root.firstChild())), expected)
        XCTAssertEqual(root.splitRatio, 1)
        XCTAssertEqual(fixture.engine.existingState(for: fixture.workspaceId)?.preselection, .up)
        try assertTree(fixture)
    }

    func testTabGroupKeepsMembersSelectionConstraintsAndExistingSeeds() throws {
        let fixture = makeFixture(count: 4)
        let engine = fixture.engine
        let ws = fixture.workspaceId
        let inactive = fixture.tokens[0]
        let source = fixture.tokens[2]
        XCTAssertTrue(engine.groupWindow(source, into: inactive, in: ws))
        let tile = try XCTUnwrap(engine.findNode(for: source, in: ws)?.tile)
        let members = tile.members
        let activeIndex = tile.activeIndex
        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 150, height: 100),
            maxSize: .zero,
            isFixed: false
        )
        engine.updateWindowConstraints(for: source, constraints: constraints)
        engine.setExcludedTokens([inactive], in: ws)
        _ = engine.calculateLayout(for: ws, screen: screen)
        let state = try XCTUnwrap(engine.existingState(for: ws))
        let seed = CGRect(x: -100, y: 10, width: 200, height: 300)
        state.pendingMovementFrameSeeds[source] = seed

        try hover(source, at: .up, fixture: fixture)
        XCTAssertEqual(engine.interactiveMoveEnd(), source)

        let node = try XCTUnwrap(engine.findNode(for: source, in: ws))
        XCTAssertTrue(node.tile === tile)
        XCTAssertTrue(engine.findNode(for: inactive, in: ws) === node)
        XCTAssertEqual(tile.members, members)
        XCTAssertEqual(tile.activeIndex, activeIndex)
        XCTAssertTrue(engine.selectedNode(in: ws) === node)
        XCTAssertEqual(engine.constraints(for: source).minSize, constraints.minSize)
        XCTAssertEqual(engine.excludedTokens(in: ws), [inactive])
        XCTAssertEqual(state.pendingMovementFrameSeeds[source], seed)
        XCTAssertEqual(engine.tileCount(in: ws), 3)
        try assertTree(fixture)
    }

    func testMinimumSizesStillApplyToTheNewRootSplit() throws {
        for direction in directions {
            let fixture = makeFixture(count: 2)
            let engine = fixture.engine
            let horizontal = direction.dwindleOrientation == .horizontal
            engine.settings.innerGap = 8
            engine.updateWindowConstraints(for: fixture.tokens[0], constraints: WindowSizeConstraints(
                minSize: CGSize(width: horizontal ? 650 : 1, height: horizontal ? 1 : 500),
                maxSize: .zero, isFixed: false
            ))
            engine.updateWindowConstraints(for: fixture.tokens[1], constraints: WindowSizeConstraints(
                minSize: CGSize(width: horizontal ? 250 : 1, height: horizontal ? 1 : 200),
                maxSize: .zero, isFixed: false
            ))
            _ = engine.calculateLayout(for: fixture.workspaceId, screen: screen)
            try hover(fixture.tokens[0], at: direction, fixture: fixture)
            XCTAssertEqual(engine.interactiveMoveEnd(), fixture.tokens[0])

            let frames = engine.calculateLayout(for: fixture.workspaceId, screen: screen)
            let source = try XCTUnwrap(frames[fixture.tokens[0]])
            let peer = try XCTUnwrap(frames[fixture.tokens[1]])
            XCTAssertGreaterThanOrEqual(horizontal ? source.width : source.height, horizontal ? 650 : 500)
            XCTAssertGreaterThanOrEqual(horizontal ? peer.width : peer.height, horizontal ? 250 : 200)
            XCTAssertEqual(
                horizontal ? source.width + peer.width : source.height + peer.height,
                (horizontal ? screen.width : screen.height) - 8, accuracy: 0.001
            )
            try assertTree(fixture)
        }
    }

    func testEdgeAndTileTargetsCanBeChangedBeforeDropping() throws {
        let fixture = makeFixture(count: 3)
        let engine = fixture.engine
        let before = engine.currentFrames(in: fixture.workspaceId)
        try hover(fixture.tokens[0], at: .left, fixture: fixture)
        let targetFrame = try XCTUnwrap(before[fixture.tokens[1]])
        let point = CGPoint(x: targetFrame.midX, y: targetFrame.midY + targetFrame.height / 4)
        XCTAssertEqual(
            engine.interactiveMoveUpdate(currentLocation: point, at: 0, workspaceFrame: screen),
            fixture.tokens[1]
        )
        XCTAssertEqual(engine.interactiveMove?.target, .tile(fixture.tokens[1], direction: .up))
        XCTAssertEqual(engine.interactiveMoveTargetFrame(at: 0), half(.up, of: targetFrame))

        _ = engine.interactiveMoveUpdate(currentLocation: edgePoint(.down), at: 0, workspaceFrame: screen)
        XCTAssertEqual(engine.interactiveMove?.target, .workspaceEdge(.down, frame: screen))
        _ = engine.interactiveMoveUpdate(
            currentLocation: CGPoint(x: screen.maxX + 1, y: screen.midY),
            at: 0,
            workspaceFrame: screen
        )
        XCTAssertNil(engine.interactiveMove?.target)
        XCTAssertNil(engine.interactiveMoveTargetFrame(at: 0))
        XCTAssertNil(engine.interactiveMoveEnd())
        XCTAssertEqual(engine.calculateLayout(for: fixture.workspaceId, screen: screen), before)
    }

    func testCornersSelectTheNearestEdgeAndTheBandStaysNarrow() throws {
        let fixture = makeFixture(count: 3)
        let engine = fixture.engine
        XCTAssertTrue(engine.interactiveMoveBegin(
            token: fixture.tokens[2],
            startLocation: .zero,
            allowsInsertion: true,
            in: fixture.workspaceId
        ))
        let points: [(CGPoint, Direction)] = [
            (CGPoint(x: screen.minX + 2, y: screen.maxY - 10), .left),
            (CGPoint(x: screen.minX + 10, y: screen.maxY - 2), .up),
            (CGPoint(x: screen.maxX - 2, y: screen.minY + 10), .right),
            (CGPoint(x: screen.maxX - 10, y: screen.minY + 2), .down)
        ]
        for (point, direction) in points {
            _ = engine.interactiveMoveUpdate(currentLocation: point, at: 0, workspaceFrame: screen)
            XCTAssertEqual(engine.interactiveMove?.target, .workspaceEdge(direction, frame: screen))
        }
        let tilePoint = CGPoint(x: screen.minX + 25, y: screen.midY)
        XCTAssertEqual(
            engine.interactiveMoveUpdate(currentLocation: tilePoint, at: 0, workspaceFrame: screen),
            fixture.tokens[0]
        )
        XCTAssertEqual(engine.interactiveMove?.targetToken, fixture.tokens[0])
    }

    func testWorkspaceBoundsExcludeReservedAreasEvenWithOldWindowFrames() throws {
        let fixture = makeFixture(count: 2)
        let engine = fixture.engine
        let workingFrame = screen.insetBy(dx: 60, dy: 40)
        XCTAssertTrue(engine.interactiveMoveBegin(
            token: fixture.tokens[1],
            startLocation: .zero,
            allowsInsertion: true,
            in: fixture.workspaceId
        ))
        let point = CGPoint(x: workingFrame.minX + 1, y: workingFrame.midY)
        _ = engine.interactiveMoveUpdate(currentLocation: point, at: 0, workspaceFrame: workingFrame)
        XCTAssertEqual(engine.interactiveMoveTargetFrame(at: 0), half(.left, of: workingFrame))
        for point in [
            CGPoint(x: screen.minX + 1, y: screen.midY),
            CGPoint(x: screen.midX, y: screen.maxY - 1),
            CGPoint(x: screen.maxX + 1, y: screen.midY)
        ] {
            XCTAssertNil(engine.interactiveMoveUpdate(currentLocation: point, at: 0, workspaceFrame: workingFrame))
            XCTAssertNil(engine.interactiveMove?.target)
        }
        XCTAssertNil(engine.interactiveMoveEnd())
    }

    func testSwapModeStillUsesTileTargetsAtTheWorkspaceEdge() throws {
        let fixture = makeFixture(count: 3)
        let engine = fixture.engine
        let target = try XCTUnwrap(engine.presentedFrame(for: fixture.tokens[0], in: fixture.workspaceId, at: 0))
        XCTAssertTrue(engine.interactiveMoveBegin(
            token: fixture.tokens[2],
            startLocation: .zero,
            in: fixture.workspaceId
        ))
        XCTAssertEqual(
            engine.interactiveMoveUpdate(currentLocation: edgePoint(.left), at: 0, workspaceFrame: screen),
            fixture.tokens[0]
        )
        XCTAssertEqual(engine.interactiveMove?.target, .tile(fixture.tokens[0], direction: nil))
        XCTAssertEqual(engine.interactiveMoveTargetFrame(at: 0), target)
    }

    func testSingleVisibleTileDoesNotOfferAnEdgeTarget() throws {
        let fixture = makeFixture(count: 2)
        let engine = fixture.engine
        engine.setExcludedTokens([fixture.tokens[1]], in: fixture.workspaceId)
        _ = engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        let before = engine.currentFrames(in: fixture.workspaceId)
        XCTAssertTrue(engine.interactiveMoveBegin(
            token: fixture.tokens[0],
            startLocation: .zero,
            allowsInsertion: true,
            in: fixture.workspaceId
        ))
        _ = engine.interactiveMoveUpdate(currentLocation: edgePoint(.up), at: 0, workspaceFrame: screen)
        XCTAssertNil(engine.interactiveMove?.target)
        XCTAssertNil(engine.interactiveMoveEnd())
        XCTAssertEqual(engine.calculateLayout(for: fixture.workspaceId, screen: screen), before)
    }

    func testExclusionAndFullscreenInvalidateThePendingEdgeInsertion() throws {
        for tokenIndex in 0 ..< 2 {
            for fullscreen in [false, true] {
                for updateFirst in [false, true] {
                    let fixture = makeFixture(count: 2)
                    let engine = fixture.engine
                    try hover(fixture.tokens[0], at: .up, fixture: fixture)
                    if fullscreen {
                        engine.setSelectedNode(
                            engine.findNode(for: fixture.tokens[tokenIndex], in: fixture.workspaceId),
                            in: fixture.workspaceId
                        )
                        XCTAssertEqual(engine.toggleFullscreen(in: fixture.workspaceId), fixture.tokens[tokenIndex])
                    } else {
                        engine.setExcludedTokens([fixture.tokens[tokenIndex]], in: fixture.workspaceId)
                    }
                    let before = tree(try XCTUnwrap(engine.root(for: fixture.workspaceId)))
                    if updateFirst {
                        _ = engine.interactiveMoveUpdate(
                            currentLocation: edgePoint(.right),
                            at: 0,
                            workspaceFrame: screen
                        )
                        XCTAssertNil(engine.interactiveMove)
                    }
                    XCTAssertNil(engine.interactiveMoveEnd())
                    XCTAssertEqual(tree(try XCTUnwrap(engine.root(for: fixture.workspaceId))), before)
                }
            }
        }
    }

    func testRemovingSourceOrRemainderWindowsCancelsTheGesture() throws {
        for removedIndex in 0 ..< 3 {
            let fixture = makeFixture(count: 3)
            try hover(fixture.tokens[0], at: .right, fixture: fixture)
            fixture.engine.removeWindow(token: fixture.tokens[removedIndex], from: fixture.workspaceId)
            XCTAssertNil(fixture.engine.interactiveMove)
            XCTAssertNil(fixture.engine.interactiveMoveEnd())
            XCTAssertEqual(fixture.engine.windowCount(in: fixture.workspaceId), 2)
        }
    }

    func testAnotherWorkspaceDoesNotInvalidateTheEdgeTarget() throws {
        let fixture = makeFixture(count: 3)
        let otherWorkspace = WorkspaceDescriptor.ID()
        let otherToken = WindowToken(pid: 99, windowId: 99)
        _ = fixture.engine.addWindow(token: otherToken, to: otherWorkspace, activeWindowFrame: nil)
        try hover(fixture.tokens[0], at: .down, fixture: fixture)
        fixture.engine.removeWindow(token: otherToken, from: otherWorkspace)
        XCTAssertNotNil(fixture.engine.interactiveMove)
        XCTAssertEqual(fixture.engine.interactiveMoveEnd(), fixture.tokens[0])
        try assertTree(fixture)
    }

    func testAllAffectedTilesAnimateFromTheirPreviousFrames() throws {
        for count in [2, 4] {
            let fixture = makeFixture(count: count)
            let engine = fixture.engine
            let ws = fixture.workspaceId
            let source = fixture.tokens[count - 1]
            let before = engine.presentedFrames(in: ws, at: 100)
            try hover(source, at: .up, fixture: fixture)
            XCTAssertEqual(engine.interactiveMoveEnd(), source)

            var previousTargets = engine.currentFrames(in: ws)
            var oldFrames = engine.presentedFrames(in: ws, at: 100)
            engine.consumePendingMovementFrameSeeds(
                in: ws,
                oldFrames: &oldFrames,
                previousTargetFrames: &previousTargets
            )
            let newFrames = engine.calculateLayout(for: ws, screen: screen)
            engine.animateWindowMovements(
                .init(oldFrames: oldFrames, previousTargetFrames: previousTargets, newFrames: newFrames),
                in: ws, startTime: 100, motion: .enabled
            )
            XCTAssertNotEqual(newFrames, before)
            XCTAssertEqual(engine.calculateAnimatedFrames(baseFrames: newFrames, in: ws, at: 100), before)
        }
    }

    private func makeFixture(count: Int) -> Fixture {
        let engine = DwindleLayoutEngine()
        engine.settings.innerGap = 0
        let workspaceId = WorkspaceDescriptor.ID()
        let tokens = (0 ..< count).map { WindowToken(pid: pid_t($0 + 1), windowId: $0 + 1) }
        for token in tokens {
            _ = engine.setPreselection(.right, in: workspaceId)
            _ = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
        }
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        return Fixture(engine: engine, workspaceId: workspaceId, tokens: tokens)
    }

    private func hover(_ source: WindowToken, at direction: Direction, fixture: Fixture) throws {
        XCTAssertTrue(fixture.engine.interactiveMoveBegin(
            token: source,
            startLocation: .zero,
            allowsInsertion: true,
            in: fixture.workspaceId
        ))
        _ = fixture.engine.interactiveMoveUpdate(currentLocation: edgePoint(direction), at: 0, workspaceFrame: screen)
        XCTAssertEqual(fixture.engine.interactiveMove?.target, .workspaceEdge(direction, frame: screen))
    }

    private func edgePoint(_ direction: Direction) -> CGPoint {
        switch direction {
        case .left: CGPoint(x: screen.minX + 1, y: screen.midY)
        case .right: CGPoint(x: screen.maxX - 1, y: screen.midY)
        case .up: CGPoint(x: screen.midX, y: screen.maxY - 1)
        case .down: CGPoint(x: screen.midX, y: screen.minY + 1)
        }
    }

    private func half(_ direction: Direction, of frame: CGRect) -> CGRect {
        switch direction {
        case .left: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .up: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        case .down: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        }
    }

    private func opposite(_ direction: Direction) -> Direction {
        switch direction {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }

    private func tree(_ node: DwindleNode) -> Tree {
        guard let orientation = node.splitOrientation, let ratio = node.splitRatio,
              let first = node.firstChild(), let second = node.secondChild()
        else { return .tile(node.tile?.members.map(\.token) ?? []) }
        return .split(orientation, ratio, tree(first), tree(second))
    }

    private func assertTree(_ fixture: Fixture) throws {
        let root = try XCTUnwrap(fixture.engine.root(for: fixture.workspaceId))
        XCTAssertNil(root.parent)
        let leaves = root.collectAllLeaves()
        let tokens = leaves.flatMap { $0.tile?.members.map(\.token) ?? [] }
        XCTAssertEqual(tokens.count, fixture.tokens.count)
        XCTAssertEqual(Set(tokens), Set(fixture.tokens))
        XCTAssertEqual(fixture.engine.tileCount(in: fixture.workspaceId), leaves.count)
        for leaf in leaves {
            for token in leaf.tile?.members.map(\.token) ?? [] {
                XCTAssertTrue(fixture.engine.findNode(for: token, in: fixture.workspaceId) === leaf)
            }
            var node = leaf
            while let parent = node.parent {
                XCTAssertEqual(parent.children.count, 2)
                XCTAssertTrue(parent.children.contains(where: { $0 === node }))
                node = parent
            }
            XCTAssertTrue(node === root)
        }
    }
}
