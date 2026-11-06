// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class DwindleSplitInsertionTests: XCTestCase {
    private let screen = CGRect(x: -1200, y: 100, width: 1200, height: 900)
    private let orientations: [DwindleOrientation] = [.horizontal, .vertical]

    private struct Fixture {
        let engine: DwindleLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]
        let split: DwindleNode
    }

    private indirect enum Tree: Equatable {
        case tile([WindowToken])
        case split(DwindleOrientation, CGFloat, Tree, Tree)
    }

    func testHoverPreviewsTheFollowingSubtreeWithoutChangingTheLayout() throws {
        for orientation in orientations {
            let fixture = makeFixture(orientation: orientation)
            let engine = fixture.engine
            let root = try XCTUnwrap(engine.root(for: fixture.workspaceId))
            let before = tree(root)
            let frames = engine.currentFrames(in: fixture.workspaceId)
            let preview = previewFrame(fixture.split)

            try hover(fixture.tokens[0], fixture: fixture)

            XCTAssertEqual(engine.interactiveMove?.target, .splitBoundary(fixture.split.id, frame: preview))
            XCTAssertTrue(engine.interactiveMove?.isInsertion == true)
            XCTAssertNil(engine.interactiveMove?.targetToken)
            XCTAssertEqual(engine.interactiveMoveTargetFrame(at: 0), preview)
            XCTAssertEqual(tree(root), before)
            XCTAssertEqual(engine.calculateLayout(for: fixture.workspaceId, screen: screen), frames)
            engine.interactiveMoveCancel()
            XCTAssertNil(engine.interactiveMoveTargetFrame(at: 0))
            XCTAssertEqual(tree(root), before)
        }
    }

    func testSourceSiblingPromotionKeepsTheSplitAndBothSubtreesRatios() throws {
        for orientation in orientations {
            let fixture = makeFixture(orientation: orientation)
            let engine = fixture.engine
            let ws = fixture.workspaceId
            let first = try XCTUnwrap(fixture.split.firstChild())
            let second = try XCTUnwrap(fixture.split.secondChild())
            let beforeFirst = tree(first)
            let beforeSecond = tree(second)
            let source = try XCTUnwrap(engine.findNode(for: fixture.tokens[0], in: ws))
            engine.settings.defaultSplitRatio = 1.4
            XCTAssertTrue(engine.setPreselection(.up, in: ws))

            try hover(fixture.tokens[0], fixture: fixture)
            XCTAssertEqual(engine.interactiveMoveEnd(), fixture.tokens[0])

            let destination = try XCTUnwrap(engine.root(for: ws))
            XCTAssertEqual(destination.splitOrientation, orientation)
            XCTAssertEqual(destination.splitRatio, 0.8)
            XCTAssertTrue(destination.firstChild() === first)
            XCTAssertEqual(tree(first), beforeFirst)
            XCTAssertEqual(tree(second), beforeSecond)
            let inserted = try XCTUnwrap(destination.secondChild())
            XCTAssertEqual(inserted.splitOrientation, orientation)
            XCTAssertEqual(inserted.splitRatio, 1)
            XCTAssertTrue(inserted.firstChild() === source)
            XCTAssertTrue(inserted.secondChild() === second)
            XCTAssertTrue(engine.selectedNode(in: ws) === source)
            XCTAssertEqual(engine.existingState(for: ws)?.preselection, .up)
            engine.settings.innerGap = 0
            let frames = engine.calculateLayout(for: ws, screen: screen)
            let sourceFrame = try XCTUnwrap(frames[fixture.tokens[0]])
            let secondFrame = visibleFrame(second)
            XCTAssertEqual(
                orientation == .horizontal ? sourceFrame.width : sourceFrame.height,
                orientation == .horizontal ? secondFrame.width : secondFrame.height
            )
            try assertTree(fixture)
        }
    }

    func testNestedTargetKeepsItsAncestorsAndUnrelatedBranch() throws {
        let fixture = makeFixture(orientation: .horizontal, sourceIsSibling: false)
        let engine = fixture.engine
        let root = try XCTUnwrap(engine.root(for: fixture.workspaceId))
        let originalRatio = root.splitRatio
        let beforeFirst = tree(try XCTUnwrap(fixture.split.firstChild()))
        let beforeSecond = tree(try XCTUnwrap(fixture.split.secondChild()))

        try hover(fixture.tokens[0], fixture: fixture)
        XCTAssertEqual(engine.interactiveMoveEnd(), fixture.tokens[0])

        XCTAssertEqual(root.splitRatio, originalRatio)
        XCTAssertTrue(root.secondChild() === fixture.split)
        XCTAssertEqual(root.firstChild()?.windowToken, fixture.tokens[5])
        XCTAssertEqual(fixture.split.splitRatio, 0.8)
        XCTAssertEqual(tree(try XCTUnwrap(fixture.split.firstChild())), beforeFirst)
        XCTAssertEqual(tree(try XCTUnwrap(fixture.split.secondChild()?.secondChild())), beforeSecond)
        try assertTree(fixture)
    }

    func testSourcesInsideEitherBranchKeepTheOtherSubtreeIntact() throws {
        for orientation in orientations {
            for index in 1 ... 4 {
                let fixture = makeFixture(orientation: orientation)
                let source = fixture.tokens[index]
                let other = try XCTUnwrap(index < 3 ? fixture.split.secondChild() : fixture.split.firstChild())
                let before = tree(other)

                try hover(source, fixture: fixture)
                XCTAssertEqual(fixture.engine.interactiveMoveEnd(), source)

                XCTAssertEqual(tree(other), before)
                XCTAssertEqual(fixture.split.splitRatio, 0.8)
                try assertTree(fixture)
            }
        }
    }

    func testTheDeepestMatchingBoundaryWins() throws {
        let fixture = makeFixture(orientation: .horizontal)
        let first = try XCTUnwrap(fixture.split.firstChild())
        let point = CGPoint(x: visibleFrame(first).maxX - 1, y: boundaryPoint(first).y)
        XCTAssertTrue(fixture.engine.interactiveMoveBegin(
            token: fixture.tokens[0], startLocation: .zero, allowsInsertion: true, in: fixture.workspaceId
        ))
        _ = fixture.engine.interactiveMoveUpdate(currentLocation: point, at: 0, workspaceFrame: screen)
        XCTAssertEqual(fixture.engine.interactiveMove?.target, .splitBoundary(first.id, frame: previewFrame(first)))
    }

    func testWorkspaceEdgesAndBoundsTakePrecedenceOverInternalDividers() throws {
        let fixture = makeFixture(orientation: .horizontal)
        let engine = fixture.engine
        let point = CGPoint(x: boundaryPoint(fixture.split).x, y: screen.maxY - 1)
        XCTAssertNotNil(engine.splitBoundaryMoveTarget(
            at: point,
            for: fixture.tokens[0],
            in: fixture.workspaceId,
            time: 0
        ))
        XCTAssertTrue(engine.interactiveMoveBegin(
            token: fixture.tokens[0], startLocation: .zero, allowsInsertion: true, in: fixture.workspaceId
        ))
        _ = engine.interactiveMoveUpdate(currentLocation: point, at: 0, workspaceFrame: screen)
        XCTAssertEqual(engine.interactiveMove?.target, .workspaceEdge(.up, frame: screen))
        _ = engine.interactiveMoveUpdate(
            currentLocation: CGPoint(x: point.x, y: screen.maxY + 1), at: 0, workspaceFrame: screen
        )
        XCTAssertNil(engine.interactiveMove?.target)
        XCTAssertNil(engine.interactiveMoveEnd())
    }

    func testBoundaryBandIsNarrowAndDoesNotReplaceTileDropZones() throws {
        let fixture = makeFixture(orientation: .horizontal)
        let engine = fixture.engine
        let boundary = boundaryPoint(fixture.split)
        XCTAssertTrue(engine.interactiveMoveBegin(
            token: fixture.tokens[0], startLocation: .zero, allowsInsertion: true, in: fixture.workspaceId
        ))
        _ = engine.interactiveMoveUpdate(currentLocation: boundary, at: 0, workspaceFrame: screen)
        XCTAssertEqual(
            engine.interactiveMove?.target,
            .splitBoundary(fixture.split.id, frame: previewFrame(fixture.split))
        )
        _ = engine.interactiveMoveUpdate(
            currentLocation: CGPoint(x: boundary.x + 13, y: boundary.y), at: 0, workspaceFrame: screen
        )
        guard case .tile = engine.interactiveMove?.target
        else { return XCTFail("Expected a tile target outside the band") }
        let target = fixture.tokens[3]
        let frame = try XCTUnwrap(engine.presentedFrame(for: target, in: fixture.workspaceId, at: 0))
        _ = engine.interactiveMoveUpdate(currentLocation: frame.center, at: 0, workspaceFrame: screen)
        XCTAssertEqual(engine.interactiveMove?.target, .tile(target, direction: nil))
    }

    func testGesturesAndTinyMovementsDoNotOfferBoundaryInsertion() throws {
        for allowsInsertion in [false, true] {
            let fixture = makeFixture(orientation: .horizontal)
            let point = boundaryPoint(fixture.split)
            let before = tree(try XCTUnwrap(fixture.engine.root(for: fixture.workspaceId)))
            XCTAssertTrue(fixture.engine.interactiveMoveBegin(
                token: fixture.tokens[0],
                startLocation: allowsInsertion ? CGPoint(x: point.x - 9, y: point.y) : .zero,
                allowsInsertion: allowsInsertion, in: fixture.workspaceId
            ))
            _ = fixture.engine.interactiveMoveUpdate(currentLocation: point, at: 0, workspaceFrame: screen)
            XCTAssertNil(fixture.engine.interactiveMove?.target)
            XCTAssertNil(fixture.engine.interactiveMoveEnd())
            XCTAssertEqual(tree(try XCTUnwrap(fixture.engine.root(for: fixture.workspaceId))), before)
        }
    }

    func testBothBranchesNeedAVisibleTileOtherThanTheSource() throws {
        let fixture = makeFixture(orientation: .horizontal)
        let root = try XCTUnwrap(fixture.engine.root(for: fixture.workspaceId))
        XCTAssertFalse(fixture.engine.canInsertAtSplitBoundary(
            token: fixture.tokens[0], splitId: root.id, in: fixture.workspaceId
        ))
        fixture.engine.setExcludedTokens([fixture.tokens[1], fixture.tokens[2]], in: fixture.workspaceId)
        _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        XCTAssertFalse(fixture.engine.canInsertAtSplitBoundary(
            token: fixture.tokens[0], splitId: fixture.split.id, in: fixture.workspaceId
        ))
    }

    func testExclusionAndFullscreenCancelInsteadOfRetargeting() throws {
        for invalidation in 0 ..< 4 {
            for updateBeforeRelease in [false, true] {
                let fixture = makeFixture(orientation: .horizontal)
                let engine = fixture.engine
                let ws = fixture.workspaceId
                try hover(fixture.tokens[0], fixture: fixture)
                switch invalidation {
                case 0: engine.setExcludedTokens([fixture.tokens[0]], in: ws)
                case 1: engine.setExcludedTokens([fixture.tokens[1], fixture.tokens[2]], in: ws)
                case 2: engine.setExcludedTokens([fixture.tokens[3], fixture.tokens[4]], in: ws)
                default:
                    engine.setSelectedNode(engine.findNode(for: fixture.tokens[1], in: ws), in: ws)
                    XCTAssertEqual(engine.toggleFullscreen(in: ws), fixture.tokens[1])
                }
                let before = tree(try XCTUnwrap(engine.root(for: ws)))
                let frames = engine.calculateLayout(for: ws, screen: screen)
                if updateBeforeRelease {
                    _ = engine.interactiveMoveUpdate(currentLocation: screen.center, at: 0, workspaceFrame: screen)
                    XCTAssertNil(engine.interactiveMove)
                }
                XCTAssertNil(engine.interactiveMoveEnd())
                XCTAssertEqual(tree(try XCTUnwrap(engine.root(for: ws))), before)
                XCTAssertEqual(engine.calculateLayout(for: ws, screen: screen), frames)
            }
        }
    }

    func testRemovingAWindowCancelsOnlyMovesInThatWorkspace() throws {
        let fixture = makeFixture(orientation: .horizontal)
        let engine = fixture.engine
        try hover(fixture.tokens[0], fixture: fixture)
        let otherWorkspace = WorkspaceDescriptor.ID()
        let other = WindowToken(pid: 50, windowId: 50)
        _ = engine.addWindow(token: other, to: otherWorkspace, activeWindowFrame: nil)
        engine.removeWindow(token: other, from: otherWorkspace)
        XCTAssertNotNil(engine.interactiveMove)
        engine.removeWindow(token: fixture.tokens[2], from: fixture.workspaceId)
        XCTAssertNil(engine.interactiveMove)
        XCTAssertEqual(engine.windowCount(in: fixture.workspaceId), 4)
    }

    func testGroupingAwayTheDividerCancelsInsteadOfRetargeting() throws {
        let fixture = makeFixture(orientation: .horizontal)
        let engine = fixture.engine
        try hover(fixture.tokens[0], fixture: fixture)
        for index in 1 ... 3 {
            XCTAssertTrue(engine.groupWindow(fixture.tokens[index], into: fixture.tokens[4], in: fixture.workspaceId))
        }
        let before = tree(try XCTUnwrap(engine.root(for: fixture.workspaceId)))
        _ = engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        _ = engine.interactiveMoveUpdate(currentLocation: screen.center, at: 0, workspaceFrame: screen)
        XCTAssertNil(engine.interactiveMove)
        XCTAssertNil(engine.interactiveMoveEnd())
        XCTAssertEqual(tree(try XCTUnwrap(engine.root(for: fixture.workspaceId))), before)
        XCTAssertEqual(engine.windowCount(in: fixture.workspaceId), 5)
    }

    func testTabRailsCountAsPartOfTheirTileInTheBoundaryBand() throws {
        for railWidth in [CGFloat(10), 28] {
            let fixture = makeFixture(orientation: .horizontal)
            let engine = fixture.engine
            let ws = fixture.workspaceId
            engine.tabRailWidth = railWidth
            XCTAssertTrue(engine.groupWindow(fixture.tokens[4], into: fixture.tokens[3], in: ws))
            _ = engine.calculateLayout(for: ws, screen: screen)
            let first = tileFrame(try XCTUnwrap(fixture.split.firstChild()))
            let second = tileFrame(try XCTUnwrap(fixture.split.secondChild()))
            XCTAssertTrue(engine.interactiveMoveBegin(
                token: fixture.tokens[0], startLocation: .zero, allowsInsertion: true, in: ws
            ))

            _ = engine.interactiveMoveUpdate(
                currentLocation: CGPoint(x: (first.maxX + second.minX) / 2, y: first.midY),
                at: 0,
                workspaceFrame: screen
            )

            XCTAssertEqual(
                engine.interactiveMove?.target,
                .splitBoundary(fixture.split.id, frame: WindowMoveGeometry.targetFrame(in: second, direction: .left))
            )
            engine.interactiveMoveCancel()
        }
    }

    func testMinimumSizesAndWholeTabGroupsArePreserved() throws {
        for orientation in orientations {
            let fixture = makeFixture(orientation: orientation)
            let engine = fixture.engine
            let ws = fixture.workspaceId
            let source = fixture.tokens[0]
            let tab = WindowToken(pid: 20, windowId: 20)
            _ = engine.addWindow(token: tab, to: ws, activeWindowFrame: nil)
            XCTAssertTrue(engine.groupWindow(tab, into: source, in: ws))
            let tile = try XCTUnwrap(engine.findNode(for: source, in: ws)?.tile)
            let members = tile.members
            let activeIndex = tile.activeIndex
            let minimum = CGSize(
                width: orientation == .horizontal ? 700 : 1,
                height: orientation == .vertical ? 600 : 1
            )
            engine.updateWindowConstraints(
                for: tab,
                constraints: .init(minSize: minimum, maxSize: .zero, isFixed: false)
            )
            engine.setExcludedTokens([source], in: ws)
            _ = engine.calculateLayout(for: ws, screen: screen)
            let expectedFirst = tree(try XCTUnwrap(fixture.split.firstChild()))
            let existingSeed = CGRect(x: 30, y: 40, width: 200, height: 250)
            engine.existingState(for: ws)?.pendingMovementFrameSeeds[tab] = existingSeed

            try hover(tab, fixture: fixture)
            XCTAssertEqual(engine.interactiveMoveEnd(), tab)

            let frames = engine.calculateLayout(for: ws, screen: screen)
            let frame = try XCTUnwrap(frames[tab])
            XCTAssertGreaterThanOrEqual(frame.width, minimum.width)
            XCTAssertGreaterThanOrEqual(frame.height, minimum.height)
            XCTAssertEqual(tree(try XCTUnwrap(engine.root(for: ws)?.firstChild())), expectedFirst)
            XCTAssertTrue(engine.findNode(for: source, in: ws)?.tile === tile)
            XCTAssertTrue(engine.findNode(for: tab, in: ws)?.tile === tile)
            XCTAssertEqual(tile.members, members)
            XCTAssertEqual(tile.activeIndex, activeIndex)
            XCTAssertEqual(engine.constraints(for: tab).minSize, minimum)
            XCTAssertEqual(engine.existingState(for: ws)?.pendingMovementFrameSeeds[tab], existingSeed)
            XCTAssertEqual(engine.windowCount(in: ws), 6)
            XCTAssertEqual(engine.tileCount(in: ws), 5)
        }
    }

    func testInsertionSeedsAllAffectedTilesFromTheirPresentedFrames() throws {
        for sourceIndex in [0, 1, 4] {
            let fixture = makeFixture(orientation: .horizontal)
            let engine = fixture.engine
            let ws = fixture.workspaceId
            let before = engine.presentedFrames(in: ws, at: 100)
            try hover(fixture.tokens[sourceIndex], fixture: fixture)
            XCTAssertEqual(engine.interactiveMoveEnd(), fixture.tokens[sourceIndex])
            var previousTargets = engine.currentFrames(in: ws)
            var oldFrames = engine.presentedFrames(in: ws, at: 100)
            engine.consumePendingMovementFrameSeeds(
                in: ws,
                oldFrames: &oldFrames,
                previousTargetFrames: &previousTargets
            )
            let frames = engine.calculateLayout(for: ws, screen: screen)
            engine.animateWindowMovements(
                .init(oldFrames: oldFrames, previousTargetFrames: previousTargets, newFrames: frames),
                in: ws, startTime: 100, motion: .enabled
            )
            XCTAssertNotEqual(frames, before)
            XCTAssertEqual(engine.presentedFrames(in: ws, at: 100), before)
        }
    }

    private func makeFixture(orientation: DwindleOrientation, sourceIsSibling: Bool = true) -> Fixture {
        let engine = DwindleLayoutEngine()
        engine.settings.innerGap = 8
        let ws = WorkspaceDescriptor.ID()
        let tokens = (0 ..< (sourceIsSibling ? 5 : 6)).map { WindowToken(pid: pid_t($0 + 1), windowId: $0 + 1) }
        for token in tokens { _ = engine.addWindow(token: token, to: ws, activeWindowFrame: nil) }
        let leaves = tokens.map { engine.findNode(for: $0, in: ws)! }
        for leaf in leaves { leaf.detach() }
        let first = DwindleNode(kind: .split(orientation: orientation.perpendicular, ratio: 0.6))
        first.replaceChildren(first: leaves[1], second: leaves[2])
        let second = DwindleNode(kind: .split(orientation: orientation.perpendicular, ratio: 1.4))
        second.replaceChildren(first: leaves[3], second: leaves[4])
        let split = DwindleNode(kind: .split(orientation: orientation, ratio: 0.8))
        split.replaceChildren(first: first, second: second)
        var sourceBranch = leaves[0]
        if !sourceIsSibling {
            sourceBranch = DwindleNode(kind: .split(orientation: orientation, ratio: 0.7))
            sourceBranch.replaceChildren(first: leaves[0], second: leaves[5])
        }
        let root = engine.root(for: ws)!
        root.kind = .split(orientation: orientation.perpendicular, ratio: 1.2)
        root.replaceChildren(first: sourceBranch, second: split)
        _ = engine.calculateLayout(for: ws, screen: screen)
        return Fixture(engine: engine, workspaceId: ws, tokens: tokens, split: split)
    }

    private func hover(_ source: WindowToken, fixture: Fixture) throws {
        XCTAssertTrue(fixture.engine.interactiveMoveBegin(
            token: source, startLocation: .zero, allowsInsertion: true, in: fixture.workspaceId
        ))
        _ = fixture.engine.interactiveMoveUpdate(
            currentLocation: boundaryPoint(fixture.split), at: 0, workspaceFrame: screen
        )
        XCTAssertEqual(
            fixture.engine.interactiveMove?.target,
            .splitBoundary(fixture.split.id, frame: previewFrame(fixture.split))
        )
    }

    private func boundaryPoint(_ split: DwindleNode) -> CGPoint {
        let first = visibleFrame(split.firstChild()!)
        let second = visibleFrame(split.secondChild()!)
        return split.splitOrientation == .horizontal
            ? CGPoint(
                x: (first.maxX + second.minX) / 2,
                y: max(first.minY, second.minY) + min(first.height, second.height) / 2
            )
            : CGPoint(
                x: max(first.minX, second.minX) + min(first.width, second.width) / 2,
                y: (first.maxY + second.minY) / 2
            )
    }

    private func previewFrame(_ split: DwindleNode) -> CGRect {
        WindowMoveGeometry.targetFrame(
            in: visibleFrame(split.secondChild()!),
            direction: split.splitOrientation == .horizontal ? .left : .down
        )
    }

    private func visibleFrame(_ node: DwindleNode) -> CGRect {
        node.collectAllLeaves().compactMap { $0.presentedFrame(at: 0) }.reduce(CGRect.null) { $0.union($1) }
    }

    private func tileFrame(_ node: DwindleNode) -> CGRect {
        node.collectAllLeaves().compactMap(\.cachedFrame).reduce(CGRect.null) { $0.union($1) }
    }

    private func tree(_ node: DwindleNode) -> Tree {
        guard let orientation = node.splitOrientation, let ratio = node.splitRatio,
              let first = node.firstChild(), let second = node.secondChild()
        else { return .tile(node.tile?.members.map(\.token) ?? []) }
        return .split(orientation, ratio, tree(first), tree(second))
    }

    private func assertTree(_ fixture: Fixture) throws {
        let root = try XCTUnwrap(fixture.engine.root(for: fixture.workspaceId))
        let leaves = root.collectAllLeaves()
        let tokens = leaves.flatMap { $0.tile?.members.map(\.token) ?? [] }
        XCTAssertNil(root.parent)
        XCTAssertEqual(tokens.count, fixture.tokens.count)
        XCTAssertEqual(Set(tokens), Set(fixture.tokens))
        XCTAssertEqual(fixture.engine.windowCount(in: fixture.workspaceId), tokens.count)
        XCTAssertEqual(fixture.engine.tileCount(in: fixture.workspaceId), leaves.count)
        for leaf in leaves {
            for token in leaf.tile?.members.map(\.token) ?? [] {
                XCTAssertTrue(fixture.engine.findNode(for: token, in: fixture.workspaceId) === leaf)
            }
            var node = leaf
            while let parent = node.parent {
                XCTAssertEqual(parent.children.count, 2)
                XCTAssertTrue(parent.children.contains { $0 === node })
                node = parent
            }
            XCTAssertTrue(node === root)
        }
    }
}
