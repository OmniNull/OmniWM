// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class DwindleInsertionTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let directions: [Direction] = [.left, .right, .up, .down]

    private struct Fixture {
        let engine: DwindleLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]
    }

    func testSiblingInsertionUsesEqualSplitInEveryDirection() throws {
        for direction in directions {
            for sourceIndex in 0 ..< 2 {
                let fixture = makeFixture(count: 2)
                fixture.engine.settings.defaultSplitRatio = 1.4
                let source = fixture.tokens[sourceIndex]
                let target = fixture.tokens[1 - sourceIndex]
                try hover(source, over: target, direction: direction, fixture: fixture)
                XCTAssertEqual(fixture.engine.interactiveMoveEnd(), target)
                let frames = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
                let sourceFrame = try XCTUnwrap(frames[source])
                let targetFrame = try XCTUnwrap(frames[target])
                XCTAssertEqual(sourceFrame.size, targetFrame.size)
                assertPosition(sourceFrame, beside: targetFrame, direction: direction)
                try assertTree(fixture)
            }
        }
    }

    func testNestedInsertionsKeepEveryWindowAndCanonicalParent() throws {
        for sourceIndex in 0 ..< 5 {
            for targetIndex in 0 ..< 5 where targetIndex != sourceIndex {
                for direction in directions {
                    let fixture = makeFixture(count: 5)
                    let source = fixture.tokens[sourceIndex]
                    let target = fixture.tokens[targetIndex]
                    try hover(source, over: target, direction: direction, fixture: fixture)
                    XCTAssertEqual(fixture.engine.interactiveMoveEnd(), target)
                    _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
                    let sourceNode = try XCTUnwrap(fixture.engine.findNode(for: source, in: fixture.workspaceId))
                    let targetNode = try XCTUnwrap(fixture.engine.findNode(for: target, in: fixture.workspaceId))
                    XCTAssertTrue(sourceNode.parent === targetNode.parent)
                    XCTAssertEqual(sourceNode.parent?.splitOrientation, direction.dwindleOrientation)
                    XCTAssertEqual(sourceNode.parent?.splitRatio, 1)
                    assertPosition(
                        try XCTUnwrap(sourceNode.cachedFrame), beside: try XCTUnwrap(targetNode.cachedFrame),
                        direction: direction
                    )
                    try assertTree(fixture)
                }
            }
        }
    }

    func testSiblingInsertionAnimatesBothTilesFromTheirPresentedFrames() throws {
        try assertInsertionAnimationContinuity(windowCount: 2, sourceIndex: 0, targetIndex: 1)
    }

    func testInsertionAnimatesTargetAndPromotedSiblingFromTheirPresentedFrames() throws {
        try assertInsertionAnimationContinuity(windowCount: 3, sourceIndex: 1, targetIndex: 0)
    }

    func testUnrelatedSubtreeAndPreselectionArePreserved() throws {
        let fixture = makeFixture(count: 4)
        let engine = fixture.engine
        let root = try XCTUnwrap(engine.root(for: fixture.workspaceId))
        let untouched = try XCTUnwrap(root.secondChild()?.secondChild())
        let children = untouched.children.map(\.id)
        untouched.kind = .split(orientation: .vertical, ratio: 0.7)
        _ = engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        XCTAssertTrue(engine.setPreselection(.up, in: fixture.workspaceId))

        try hover(fixture.tokens[0], over: fixture.tokens[1], direction: .down, fixture: fixture)
        XCTAssertEqual(engine.interactiveMoveEnd(), fixture.tokens[1])

        XCTAssertTrue(engine.findNodeById(untouched.id, in: root) === untouched)
        XCTAssertEqual(untouched.children.map(\.id), children)
        XCTAssertEqual(untouched.splitOrientation, .vertical)
        XCTAssertEqual(untouched.splitRatio, 0.7)
        XCTAssertEqual(engine.existingState(for: fixture.workspaceId)?.preselection, .up)
        try assertTree(fixture)
    }

    func testBothTabGroupsKeepMembershipSelectionConstraintsAndSeeds() throws {
        let fixture = makeFixture(count: 5)
        let engine = fixture.engine
        let ws = fixture.workspaceId
        let source = fixture.tokens[0]
        let sourceTab = fixture.tokens[2]
        let target = fixture.tokens[1]
        let targetTab = fixture.tokens[3]
        XCTAssertTrue(engine.groupWindow(sourceTab, into: source, in: ws))
        XCTAssertTrue(engine.groupWindow(targetTab, into: target, in: ws))
        let sourceTile = try XCTUnwrap(engine.findNode(for: source, in: ws)?.tile)
        let targetTile = try XCTUnwrap(engine.findNode(for: target, in: ws)?.tile)
        let sourceMembers = sourceTile.members
        let targetMembers = targetTile.members
        let sourceIndex = sourceTile.activeIndex
        let targetIndex = targetTile.activeIndex
        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 250, height: 180),
            maxSize: .zero,
            isFixed: false
        )
        engine.updateWindowConstraints(for: source, constraints: constraints)
        engine.setExcludedTokens([source], in: ws)
        let before = engine.calculateLayout(for: ws, screen: screen)
        let sourceFrame = try XCTUnwrap(before[sourceTab])
        let movementSeed = engine.existingState(for: ws)?.pendingMovementFrameSeeds[sourceTab] ?? sourceFrame

        try hover(sourceTab, over: targetTab, direction: .up, fixture: fixture)
        XCTAssertEqual(engine.interactiveMoveEnd(), targetTab)

        XCTAssertTrue(engine.findNode(for: sourceTab, in: ws)?.tile === sourceTile)
        XCTAssertTrue(engine.findNode(for: targetTab, in: ws)?.tile === targetTile)
        XCTAssertEqual(sourceTile.members, sourceMembers)
        XCTAssertEqual(targetTile.members, targetMembers)
        XCTAssertEqual(sourceTile.activeIndex, sourceIndex)
        XCTAssertEqual(targetTile.activeIndex, targetIndex)
        XCTAssertEqual(engine.constraints(for: source).minSize, constraints.minSize)
        XCTAssertEqual(engine.excludedTokens(in: ws), [source])
        XCTAssertEqual(engine.existingState(for: ws)?.pendingMovementFrameSeeds[sourceTab], movementSeed)
        XCTAssertTrue(engine.selectedNode(in: ws) === engine.findNode(for: sourceTab, in: ws))
        XCTAssertEqual(engine.tileCount(in: ws), 3)
        try assertTree(fixture)
    }

    func testMinimumSizesOverrideEqualSplitWithAnExcludedAncestor() throws {
        for direction in directions {
            let fixture = makeFixture(count: 3)
            let engine = fixture.engine
            let ws = fixture.workspaceId
            let source = fixture.tokens[1]
            let target = fixture.tokens[2]
            let horizontal = direction.dwindleOrientation == .horizontal
            engine.settings.innerGap = 8
            engine.updateWindowConstraints(for: source, constraints: WindowSizeConstraints(
                minSize: CGSize(width: horizontal ? 650 : 1, height: horizontal ? 1 : 500),
                maxSize: .zero, isFixed: false
            ))
            engine.updateWindowConstraints(for: target, constraints: WindowSizeConstraints(
                minSize: CGSize(width: horizontal ? 250 : 1, height: horizontal ? 1 : 200),
                maxSize: .zero, isFixed: false
            ))
            engine.setExcludedTokens([fixture.tokens[0]], in: ws)
            _ = engine.calculateLayout(for: ws, screen: screen)

            try hover(source, over: target, direction: direction, fixture: fixture)
            XCTAssertEqual(engine.interactiveMoveEnd(), target)
            let frames = engine.calculateLayout(for: ws, screen: screen)
            let first = try XCTUnwrap(frames[source])
            let second = try XCTUnwrap(frames[target])
            XCTAssertNil(frames[fixture.tokens[0]])
            XCTAssertGreaterThanOrEqual(horizontal ? first.width : first.height, horizontal ? 650 : 500)
            XCTAssertGreaterThanOrEqual(horizontal ? second.width : second.height, horizontal ? 250 : 200)
            XCTAssertEqual(
                horizontal ? first.width + second.width : first.height + second.height,
                (horizontal ? screen.width : screen.height) - 8,
                accuracy: 0.001
            )
            assertPosition(first, beside: second, direction: direction)
            try assertTree(fixture)
        }
    }

    func testHoverPreviewsOnlyTheChosenHalfWithoutMutatingTheTree() throws {
        let fixture = makeFixture(count: 2)
        let engine = fixture.engine
        let source = fixture.tokens[0]
        let target = fixture.tokens[1]
        let before = engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        let frame = try XCTUnwrap(before[target])
        XCTAssertTrue(engine.interactiveMoveBegin(
            token: source,
            startLocation: .zero,
            isInsertMode: true,
            in: fixture.workspaceId
        ))
        for direction in directions {
            XCTAssertEqual(engine.interactiveMoveUpdate(currentLocation: point(direction, in: frame), at: 0), target)
            XCTAssertEqual(engine.interactiveMove?.targetDirection, direction)
            let preview = try XCTUnwrap(engine.interactiveMoveTargetFrame(at: 0))
            XCTAssertEqual(preview.width * preview.height, frame.width * frame.height / 2)
            XCTAssertTrue(frame.contains(preview))
            XCTAssertTrue(preview.contains(point(direction, in: frame)))
            XCTAssertEqual(engine.calculateLayout(for: fixture.workspaceId, screen: screen), before)
        }
        engine.interactiveMoveCancel()
        XCTAssertNil(engine.interactiveMoveTargetFrame(at: 0))
        XCTAssertEqual(engine.calculateLayout(for: fixture.workspaceId, screen: screen), before)
    }

    func testLeavingTheTargetClearsThePendingInsertion() throws {
        let fixture = makeFixture(count: 2)
        let engine = fixture.engine
        let before = engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        try hover(fixture.tokens[0], over: fixture.tokens[1], direction: .down, fixture: fixture)
        XCTAssertNil(engine.interactiveMoveUpdate(currentLocation: CGPoint(x: -100, y: -100), at: 0))
        XCTAssertNil(engine.interactiveMove?.targetDirection)
        XCTAssertNil(engine.interactiveMoveTargetFrame(at: 0))
        XCTAssertNil(engine.interactiveMoveEnd())
        XCTAssertEqual(engine.calculateLayout(for: fixture.workspaceId, screen: screen), before)
    }

    func testRemovingEitherWindowCancelsWithoutLosingTheSurvivor() throws {
        for removedIndex in 0 ..< 2 {
            let fixture = makeFixture(count: 2)
            let engine = fixture.engine
            try hover(fixture.tokens[0], over: fixture.tokens[1], direction: .down, fixture: fixture)
            engine.removeWindow(token: fixture.tokens[removedIndex], from: fixture.workspaceId)
            XCTAssertNil(engine.interactiveMove)
            XCTAssertNil(engine.interactiveMoveEnd())
            XCTAssertNil(engine.interactiveMove)
            XCTAssertEqual(engine.windowCount(in: fixture.workspaceId), 1)
            let frames = engine.calculateLayout(for: fixture.workspaceId, screen: screen)
            XCTAssertEqual(frames[fixture.tokens[1 - removedIndex]], screen)
        }
    }

    func testHiddenOrFullscreenWindowsCancelThePendingInsertion() throws {
        for tokenIndex in 0 ..< 2 {
            for fullscreen in [false, true] {
                let fixture = makeFixture(count: 2)
                let engine = fixture.engine
                try hover(fixture.tokens[0], over: fixture.tokens[1], direction: .up, fixture: fixture)
                if fullscreen {
                    engine.setSelectedNode(
                        engine.findNode(for: fixture.tokens[tokenIndex], in: fixture.workspaceId),
                        in: fixture.workspaceId
                    )
                    XCTAssertEqual(engine.toggleFullscreen(in: fixture.workspaceId), fixture.tokens[tokenIndex])
                } else {
                    engine.setExcludedTokens([fixture.tokens[tokenIndex]], in: fixture.workspaceId)
                }
                let before = engine.root(for: fixture.workspaceId)?.children.map(\.id)
                XCTAssertNil(engine.interactiveMoveEnd())
                XCTAssertEqual(engine.root(for: fixture.workspaceId)?.children.map(\.id), before)
                XCTAssertEqual(engine.windowCount(in: fixture.workspaceId), 2)
            }
        }
    }

    func testExcludedWindowsCancelInsteadOfRetargetingDuringTheDrag() throws {
        for tokenIndex in 0 ..< 2 {
            let fixture = makeFixture(count: 3)
            let engine = fixture.engine
            try hover(fixture.tokens[0], over: fixture.tokens[1], direction: .up, fixture: fixture)
            engine.setExcludedTokens([fixture.tokens[tokenIndex]], in: fixture.workspaceId)
            let frames = engine.calculateLayout(for: fixture.workspaceId, screen: screen)
            let nextTarget = try XCTUnwrap(frames[fixture.tokens[2]])
            XCTAssertNil(engine.interactiveMoveUpdate(currentLocation: nextTarget.center, at: 0))
            XCTAssertNil(engine.interactiveMove)
            XCTAssertNil(engine.interactiveMoveEnd())
            XCTAssertEqual(engine.calculateLayout(for: fixture.workspaceId, screen: screen), frames)
        }
    }

    private func assertInsertionAnimationContinuity(windowCount: Int, sourceIndex: Int, targetIndex: Int) throws {
        let fixture = makeFixture(count: windowCount)
        let engine = fixture.engine
        let ws = fixture.workspaceId
        let before = engine.presentedFrames(in: ws, at: 100)
        let source = fixture.tokens[sourceIndex]
        let target = fixture.tokens[targetIndex]

        try hover(source, over: target, direction: .up, fixture: fixture)
        XCTAssertEqual(engine.interactiveMoveEnd(), target)

        var previousTargets = engine.currentFrames(in: ws)
        var oldFrames = engine.presentedFrames(in: ws, at: 100)
        engine.consumePendingMovementFrameSeeds(
            in: ws,
            oldFrames: &oldFrames,
            previousTargetFrames: &previousTargets
        )
        let newFrames = engine.calculateLayout(for: ws, screen: screen)
        for token in fixture.tokens {
            XCTAssertNotEqual(newFrames[token], before[token])
        }
        engine.animateWindowMovements(
            .init(oldFrames: oldFrames, previousTargetFrames: previousTargets, newFrames: newFrames),
            in: ws,
            startTime: 100,
            motion: .enabled
        )

        XCTAssertEqual(engine.calculateAnimatedFrames(baseFrames: newFrames, in: ws, at: 100), before)
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

    private func hover(_ source: WindowToken, over target: WindowToken, direction: Direction, fixture: Fixture) throws {
        let frame = try XCTUnwrap(fixture.engine.presentedFrame(for: target, in: fixture.workspaceId, at: 0))
        XCTAssertTrue(fixture.engine.interactiveMoveBegin(
            token: source, startLocation: .zero, isInsertMode: true, in: fixture.workspaceId
        ))
        XCTAssertEqual(
            fixture.engine.interactiveMoveUpdate(currentLocation: point(direction, in: frame), at: 0),
            target
        )
        XCTAssertEqual(fixture.engine.interactiveMove?.targetDirection, direction)
    }

    private func point(_ direction: Direction, in frame: CGRect) -> CGPoint {
        switch direction {
        case .left: CGPoint(x: frame.minX + 1, y: frame.midY)
        case .right: CGPoint(x: frame.maxX - 1, y: frame.midY)
        case .up: CGPoint(x: frame.midX, y: frame.maxY - 1)
        case .down: CGPoint(x: frame.midX, y: frame.minY + 1)
        }
    }

    private func assertPosition(_ source: CGRect, beside target: CGRect, direction: Direction) {
        switch direction {
        case .left: XCTAssertLessThanOrEqual(source.maxX, target.minX)
        case .right: XCTAssertGreaterThanOrEqual(source.minX, target.maxX)
        case .up: XCTAssertGreaterThanOrEqual(source.minY, target.maxY)
        case .down: XCTAssertLessThanOrEqual(source.maxY, target.minY)
        }
    }

    private func assertTree(_ fixture: Fixture) throws {
        let engine = fixture.engine
        let ws = fixture.workspaceId
        let root = try XCTUnwrap(engine.root(for: ws))
        let leaves = root.collectAllLeaves()
        let tokens = leaves.flatMap { $0.tile?.members.map(\.token) ?? [] }
        XCTAssertNil(root.parent)
        XCTAssertEqual(tokens.count, fixture.tokens.count)
        XCTAssertEqual(Set(tokens), Set(fixture.tokens))
        XCTAssertEqual(engine.windowCount(in: ws), tokens.count)
        XCTAssertEqual(engine.tileCount(in: ws), leaves.count)
        for token in tokens {
            let leaf = try XCTUnwrap(engine.findNode(for: token, in: ws))
            XCTAssertTrue(engine.findNodeById(leaf.id, in: root) === leaf)
            XCTAssertTrue(leaf.tile?.members.contains(where: { $0.token == token }) == true)
        }
        for leaf in leaves {
            var node = leaf
            while let parent = node.parent {
                XCTAssertEqual(parent.children.count, 2)
                XCTAssertTrue(parent.isSplit)
                XCTAssertTrue(parent.children.contains(where: { $0 === node }))
                node = parent
            }
            XCTAssertTrue(node === root)
        }
    }
}
