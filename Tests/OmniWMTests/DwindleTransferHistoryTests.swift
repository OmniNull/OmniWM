// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class DwindleTransferHistoryTests: XCTestCase {
    func testReturningAGroupMemberPreservesThePeersLaterSplitRatioAndSelection() throws {
        let fixture = try Fixture()
        let sourceBefore = fixture.engine.layoutSnapshot(in: fixture.source)
        let targetBefore = fixture.engine.layoutSnapshot(in: fixture.target)
        let moved = try XCTUnwrap(fixture.engine.detachForTransfer(
            token: fixture.returning, wholeTile: false, from: fixture.source
        ))
        fixture.engine.attachTransferredTile(moved, placement: .beside(fixture.resident, .right), in: fixture.target)
        fixture.engine.recordLayoutTransfer(
            from: fixture.source,
            to: fixture.target,
            sourceBefore: sourceBefore,
            targetBefore: targetBefore
        )
        XCTAssertFalse(fixture.engine.containsWindow(fixture.returning, in: fixture.source))
        XCTAssertTrue(fixture.engine.containsWindow(fixture.returning, in: fixture.target))
        XCTAssertEqual(fixture.engine.layoutHistoryCounts(in: fixture.target).undo, 1)

        let laterSourceChange = fixture.engine.layoutSnapshot(in: fixture.source)
        XCTAssertTrue(fixture.engine.resizeSelected(by: 1 / 4, orientation: .horizontal, in: fixture.source))
        fixture.engine.recordLayoutChange(in: fixture.source, since: laterSourceChange)
        fixture.engine.setSelectedNode(
            fixture.engine.findNode(for: fixture.neighbor, in: fixture.source),
            in: fixture.source
        )
        _ = fixture.engine.calculateLayout(for: fixture.source, screen: fixture.screen)
        let inverseSnapshot = try XCTUnwrap(fixture.engine.layoutSnapshot(in: fixture.target))
        let entry = try XCTUnwrap(fixture.engine.takeLayoutTransferHistory(.undo, in: fixture.target))
        let transfer = try XCTUnwrap(entry.transfer)
        XCTAssertTrue(transfer.departed.isEmpty)
        XCTAssertEqual(transfer.away.count, 1)
        let away = try XCTUnwrap(transfer.away.first)
        XCTAssertEqual(away.workspaceId, fixture.source)
        XCTAssertEqual(away.tokens, [fixture.returning])
        let arrival = try XCTUnwrap(fixture.engine.detachForHistoryTransfer(
            token: fixture.returning, wholeTile: false, from: fixture.target
        ))
        fixture.engine.restoreLayoutAway(away, arrivals: [arrival])
        XCTAssertNotNil(fixture.engine.commitTransferredLayoutHistoryStep(
            .undo, in: fixture.target, entry: entry,
            inverse: DwindleLayoutHistoryEntry(snapshot: inverseSnapshot, departed: [fixture.returning])
        ))

        try fixture.assertReturnedPeer(ratio: 1 + 1 / 4)
        XCTAssertEqual(fixture.engine.layoutHistoryCounts(in: fixture.source).undo, 2)
        XCTAssertEqual(fixture.engine.layoutHistoryCounts(in: fixture.target).undo, 0)
        XCTAssertEqual(fixture.engine.layoutHistoryCounts(in: fixture.target).redo, 1)
        XCTAssertEqual(fixture.engine.root(for: fixture.target)?.windowToken, fixture.resident)
        XCTAssertTrue(try XCTUnwrap(fixture.engine.root(for: fixture.target)).children.isEmpty)
        XCTAssertEqual(fixture.engine.windowCount(in: fixture.target), 1)
        XCTAssertFalse(fixture.engine.containsWindow(fixture.returning, in: fixture.target))
        XCTAssertEqual(
            fixture.engine.calculateLayout(for: fixture.target, screen: fixture.screen),
            [fixture.resident: fixture.screen]
        )
    }

    func testMissingTileWrapsThePromotedRootWithoutRevertingItsCurrentSubtree() throws {
        let peer = PeerFixture()
        peer.add(peer.first)
        peer.add(peer.second, beside: peer.first, direction: .right)
        peer.add(peer.third, beside: peer.second, direction: .up)
        let root = try XCTUnwrap(peer.engine.root(for: peer.workspace))
        let discardedSiblingId = try XCTUnwrap(root.secondChild()).id
        let away = try peer.away([peer.first])
        let arrival = try peer.detach(peer.first)
        XCTAssertEqual(root.splitOrientation, .vertical)
        XCTAssertNotEqual(root.id, discardedSiblingId)
        peer.engine.setSelectedNode(peer.engine.findNode(for: peer.second, in: peer.workspace), in: peer.workspace)
        XCTAssertTrue(peer.engine.resizeSelected(by: 1 / 2, orientation: .vertical, in: peer.workspace))
        peer.add(peer.fourth, beside: peer.third, direction: .right)
        XCTAssertTrue(peer.engine.groupWindow(peer.fourth, into: peer.third, in: peer.workspace))
        XCTAssertEqual(peer.engine.activateWindowOutcome(peer.third, in: peer.workspace), .activated)
        XCTAssertTrue(peer.engine.toggleFullscreen(for: peer.third, in: peer.workspace))
        let group = try XCTUnwrap(peer.engine.tile(containing: peer.third, in: peer.workspace))

        peer.engine.restoreLayoutAway(away, arrivals: [arrival])

        XCTAssertTrue(peer.engine.root(for: peer.workspace) === root)
        XCTAssertEqual(root.splitOrientation, .horizontal)
        XCTAssertEqual(root.splitRatio, 1)
        XCTAssertEqual(root.firstChild()?.windowToken, peer.first)
        let remainder = try XCTUnwrap(root.secondChild())
        XCTAssertEqual(remainder.splitOrientation, .vertical)
        XCTAssertEqual(remainder.splitRatio, 1 + 1 / 2)
        XCTAssertEqual(remainder.firstChild()?.windowToken, peer.second)
        XCTAssertTrue(remainder.secondChild()?.tile === group)
        XCTAssertEqual(group.members.map(\.token), [peer.third, peer.fourth])
        XCTAssertEqual(group.activeToken, peer.third)
        XCTAssertTrue(peer.engine.isWindowFullscreen(peer.third, in: peer.workspace))
        XCTAssertEqual(peer.engine.activeToken(in: peer.workspace), peer.third)
        assertParentLinks(root, parent: nil)
        let outer = peer.split(peer.screen, .horizontal, 1)
        let inner = peer.split(outer.1, .vertical, 1 + 1 / 2)
        XCTAssertEqual(peer.layout(), [
            peer.first: peer.gapped(outer.0),
            peer.second: peer.gapped(inner.0),
            peer.third: peer.screen
        ])
    }

    func testWholeGroupReturnRestoresSavedOrderActiveFullscreenConstraintsAndExclusions() throws {
        let fixture = try Fixture()
        XCTAssertEqual(fixture.engine.activateWindowOutcome(fixture.returning, in: fixture.source), .activated)
        XCTAssertTrue(fixture.engine.toggleFullscreen(for: fixture.returning, in: fixture.source))
        XCTAssertEqual(fixture.engine.activateWindowOutcome(fixture.first, in: fixture.source), .activated)
        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: fixture.screen.width / 16, height: fixture.screen.height / 16),
            maxSize: .zero, isFixed: false
        )
        fixture.engine.updateWindowConstraints(for: fixture.returning, constraints: constraints)
        fixture.engine.setExcludedTokens([fixture.returning], in: fixture.source)
        let away = DwindleLayoutAway(
            workspaceId: fixture.source,
            tokens: [fixture.first, fixture.returning],
            snapshot: try XCTUnwrap(fixture.engine.layoutSnapshot(in: fixture.source))
        )
        let arrival = try XCTUnwrap(fixture.engine.detachForTransfer(
            token: fixture.first, wholeTile: true, from: fixture.source
        ))
        XCTAssertEqual(fixture.sourceRoot.windowToken, fixture.neighbor)

        fixture.engine.restoreLayoutAway(away, arrivals: [.tile(arrival)])

        XCTAssertTrue(fixture.engine.root(for: fixture.source) === fixture.sourceRoot)
        XCTAssertEqual(fixture.sourceRoot.splitRatio, 1)
        let group = try XCTUnwrap(fixture.engine.tile(containing: fixture.first, in: fixture.source))
        XCTAssertTrue(group === fixture.sourceGroup)
        XCTAssertEqual(group.members, [
            DwindleTileMember(token: fixture.first, isFullscreen: false),
            DwindleTileMember(token: fixture.returning, isFullscreen: true)
        ])
        XCTAssertEqual(group.activeToken, fixture.first)
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.source), fixture.neighbor)
        XCTAssertEqual(fixture.engine.excludedTokens(in: fixture.source), [fixture.returning])
        XCTAssertEqual(fixture.engine.constraints(for: fixture.returning).minSize, constraints.minSize)
        XCTAssertEqual(fixture.engine.tileCount(in: fixture.source), 2)
        XCTAssertEqual(fixture.engine.windowCount(in: fixture.source), 3)
        assertParentLinks(fixture.sourceRoot, parent: nil)
    }

    func testEmptyPeerReceivesTheGroupWithoutChangingRootIdentityOrLeavingSelectionEmpty() throws {
        let fixture = try Fixture()
        let away = DwindleLayoutAway(
            workspaceId: fixture.source,
            tokens: [fixture.first, fixture.returning],
            snapshot: try XCTUnwrap(fixture.engine.layoutSnapshot(in: fixture.source))
        )
        let arrival = try XCTUnwrap(fixture.engine.detachForTransfer(
            token: fixture.first, wholeTile: true, from: fixture.source
        ))
        fixture.engine.removeWindow(token: fixture.neighbor, from: fixture.source)
        XCTAssertEqual(fixture.engine.windowCount(in: fixture.source), 0)

        fixture.engine.restoreLayoutAway(away, arrivals: [.tile(arrival)])

        XCTAssertTrue(fixture.engine.root(for: fixture.source) === fixture.sourceRoot)
        XCTAssertTrue(fixture.sourceRoot.children.isEmpty)
        XCTAssertNil(fixture.sourceRoot.parent)
        XCTAssertTrue(fixture.sourceRoot.tile === fixture.sourceGroup)
        XCTAssertEqual(fixture.sourceGroup.members.map(\.token), [fixture.first, fixture.returning])
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.source), fixture.first)
        XCTAssertEqual(fixture.engine.projectedActiveToken(in: fixture.source), fixture.first)
        XCTAssertTrue(fixture.engine.selectedNode(in: fixture.source) === fixture.sourceRoot)
        XCTAssertEqual(fixture.engine.tileCount(in: fixture.source), 1)
        XCTAssertEqual(fixture.engine.windowCount(in: fixture.source), 2)
        let rail = fixture.engine.tabRailWidth
        XCTAssertEqual(
            fixture.engine.calculateLayout(for: fixture.source, screen: fixture.screen),
            [fixture.first: CGRect(
                x: fixture.screen.minX + rail,
                y: fixture.screen.minY,
                width: fixture.screen.width - rail,
                height: fixture.screen.height
            )]
        )
    }

    func testMultipleReturningLeavesRecoverTheirMissingSavedAncestry() throws {
        let peer = PeerFixture()
        peer.add(peer.first)
        peer.add(peer.second, beside: peer.first, direction: .right)
        peer.add(peer.third, beside: peer.second, direction: .up)
        peer.engine.setSelectedNode(peer.engine.findNode(for: peer.first, in: peer.workspace), in: peer.workspace)
        XCTAssertTrue(peer.engine.resizeSelected(by: 1 / 4, orientation: .horizontal, in: peer.workspace))
        peer.engine.setSelectedNode(peer.engine.findNode(for: peer.second, in: peer.workspace), in: peer.workspace)
        XCTAssertTrue(peer.engine.resizeSelected(by: 1 / 2, orientation: .vertical, in: peer.workspace))
        let root = try XCTUnwrap(peer.engine.root(for: peer.workspace))
        let away = try peer.away([peer.first, peer.second])
        let firstArrival = try peer.detach(peer.first)
        let secondArrival = try peer.detach(peer.second)
        XCTAssertEqual(root.windowToken, peer.third)

        peer.engine.restoreLayoutAway(away, arrivals: [secondArrival, firstArrival])

        XCTAssertTrue(peer.engine.root(for: peer.workspace) === root)
        XCTAssertEqual(root.splitOrientation, .horizontal)
        XCTAssertEqual(root.splitRatio, 1 + 1 / 4)
        XCTAssertEqual(root.firstChild()?.windowToken, peer.first)
        let inner = try XCTUnwrap(root.secondChild())
        XCTAssertEqual(inner.splitOrientation, .vertical)
        XCTAssertEqual(inner.splitRatio, 1 + 1 / 2)
        XCTAssertEqual(inner.firstChild()?.windowToken, peer.second)
        XCTAssertEqual(inner.secondChild()?.windowToken, peer.third)
        XCTAssertEqual(peer.engine.tileCount(in: peer.workspace), 3)
        XCTAssertEqual(peer.engine.windowCount(in: peer.workspace), 3)
        assertParentLinks(root, parent: nil)
        let outerFrames = peer.split(peer.screen, .horizontal, 1 + 1 / 4)
        let innerFrames = peer.split(outerFrames.1, .vertical, 1 + 1 / 2)
        XCTAssertEqual(peer.layout(), [
            peer.first: peer.gapped(outerFrames.0),
            peer.second: peer.gapped(innerFrames.0),
            peer.third: peer.gapped(innerFrames.1)
        ])
    }

    func testPartialGroupReturnOmitsClosedMembersAndKeepsLaterMembersActiveAndFullscreen() throws {
        let peer = PeerFixture()
        peer.add(peer.first)
        peer.add(peer.second, beside: peer.first, direction: .right)
        XCTAssertTrue(peer.engine.groupWindow(peer.second, into: peer.first, in: peer.workspace))
        peer.add(peer.third, beside: peer.first, direction: .right)
        XCTAssertTrue(peer.engine.groupWindow(peer.third, into: peer.first, in: peer.workspace))
        peer.add(peer.fourth, beside: peer.first, direction: .right)
        let root = try XCTUnwrap(peer.engine.root(for: peer.workspace))
        let group = try XCTUnwrap(peer.engine.tile(containing: peer.first, in: peer.workspace))
        let away = try peer.away([peer.second])
        let arrival = try peer.detach(peer.second, whole: false)
        peer.engine.removeWindow(token: peer.first, from: peer.workspace)
        peer.add(peer.fifth, beside: peer.third, direction: .right)
        XCTAssertTrue(peer.engine.groupWindow(peer.fifth, into: peer.third, in: peer.workspace))
        XCTAssertTrue(peer.engine.toggleFullscreen(for: peer.fifth, in: peer.workspace))

        peer.engine.restoreLayoutAway(away, arrivals: [arrival])

        XCTAssertTrue(peer.engine.root(for: peer.workspace) === root)
        XCTAssertTrue(peer.engine.tile(containing: peer.second, in: peer.workspace) === group)
        XCTAssertFalse(peer.engine.containsWindow(peer.first, in: peer.workspace))
        XCTAssertEqual(group.members, [
            DwindleTileMember(token: peer.second, isFullscreen: false),
            DwindleTileMember(token: peer.third, isFullscreen: false),
            DwindleTileMember(token: peer.fifth, isFullscreen: true)
        ])
        XCTAssertEqual(group.activeToken, peer.fifth)
        XCTAssertEqual(peer.engine.activeToken(in: peer.workspace), peer.fifth)
        XCTAssertEqual(root.secondChild()?.windowToken, peer.fourth)
        XCTAssertEqual(root.splitRatio, 1)
        XCTAssertEqual(peer.engine.windowCount(in: peer.workspace), 4)
        XCTAssertEqual(peer.engine.tileCount(in: peer.workspace), 2)
        assertParentLinks(root, parent: nil)
    }

    func testSelectiveReturnSeedsTheSurvivingTilesExactPresentedOrigin() throws {
        let peer = PeerFixture()
        peer.add(peer.first)
        peer.add(peer.second, beside: peer.first, direction: .right)
        let away = try peer.away([peer.first])
        let arrival = try peer.detach(peer.first)
        var oldFrames: [WindowToken: CGRect] = [:]
        var previousTargets: [WindowToken: CGRect] = [:]
        peer.engine.consumePendingMovementFrameSeeds(
            in: peer.workspace,
            oldFrames: &oldFrames,
            previousTargetFrames: &previousTargets
        )
        oldFrames.removeAll()
        previousTargets.removeAll()
        let survivor = try XCTUnwrap(peer.engine.findNode(for: peer.second, in: peer.workspace))
        let target = peer.screen
        let origin = target.offsetBy(dx: -target.width / 8, dy: target.height / 8)
        let config = peer.engine.windowMovementAnimationConfig
        let sample = config.duration / 2
        survivor.animateFrom(oldFrame: origin, newFrame: target, startTime: 0, config: config, animated: true)
        let progress = CGFloat(config.value(at: sample / config.duration))
        let presented = CGRect(
            x: origin.minX + (target.minX - origin.minX) * progress,
            y: origin.minY + (target.minY - origin.minY) * progress,
            width: target.width,
            height: target.height
        )
        XCTAssertEqual(survivor.presentedFrame(at: sample), presented)

        peer.engine.restoreLayoutAway(away, arrivals: [arrival], at: sample)

        let state = try XCTUnwrap(peer.engine.existingState(for: peer.workspace))
        XCTAssertEqual(state.pendingMovementFrameSeeds, [peer.second: presented])
        peer.engine.consumePendingMovementFrameSeeds(
            in: peer.workspace,
            oldFrames: &oldFrames,
            previousTargetFrames: &previousTargets
        )
        XCTAssertEqual(oldFrames, [peer.second: presented])
        XCTAssertEqual(previousTargets, oldFrames)
        XCTAssertTrue(state.pendingMovementFrameSeeds.isEmpty)
        let frames = peer.layout()
        peer.engine.animateWindowMovements(
            .init(
                oldFrames: oldFrames,
                previousTargetFrames: previousTargets,
                newFrames: frames
            ),
            in: peer.workspace,
            startTime: sample,
            motion: .enabled
        )
        XCTAssertEqual(peer.engine.calculateAnimatedFrames(
            baseFrames: frames,
            in: peer.workspace,
            at: sample
        )[peer.second], presented)
        XCTAssertEqual(peer.engine.calculateAnimatedFrames(
            baseFrames: frames,
            in: peer.workspace,
            at: sample + config.duration
        ), frames)
    }

    private func assertParentLinks(_ node: DwindleNode, parent: DwindleNode?) {
        XCTAssertTrue(node.parent === parent)
        for child in node.children { assertParentLinks(child, parent: node) }
    }

    private struct PeerFixture {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        let third = WindowToken(pid: 3, windowId: 3)
        let fourth = WindowToken(pid: 4, windowId: 4)
        let fifth = WindowToken(pid: 5, windowId: 5)
        let screen = CGRect(x: 160, y: 96, width: 2048, height: 1536)

        func add(_ token: WindowToken, beside: WindowToken? = nil, direction: Direction = .right) {
            if let beside { engine.setSelectedNode(engine.findNode(for: beside, in: workspace), in: workspace) }
            engine.setPreselection(direction, in: workspace)
            engine.addWindow(token: token, to: workspace, activeWindowFrame: nil)
            _ = layout()
        }

        func away(_ tokens: [WindowToken]) throws -> DwindleLayoutAway {
            DwindleLayoutAway(
                workspaceId: workspace,
                tokens: tokens,
                snapshot: try XCTUnwrap(engine.layoutSnapshot(in: workspace))
            )
        }

        func detach(_ token: WindowToken, whole: Bool = true) throws -> DwindleHistoryArrival {
            let result = try XCTUnwrap(engine.detachForHistoryTransfer(token: token, wholeTile: whole, from: workspace))
            _ = layout()
            return result
        }

        func split(_ frame: CGRect, _ orientation: DwindleOrientation, _ ratio: CGFloat) -> (CGRect, CGRect) {
            engine.splitRect(frame, orientation: orientation, ratio: ratio, minimums: (first: .zero, second: .zero))
        }

        func gapped(_ frame: CGRect) -> CGRect {
            DwindleGapCalculator.applyGaps(nodeRect: frame, tilingArea: screen, settings: engine.settings)
        }

        func layout() -> [WindowToken: CGRect] {
            engine.calculateLayout(for: workspace, screen: screen)
        }
    }

    private struct Fixture {
        let engine = DwindleLayoutEngine()
        let source = WorkspaceDescriptor.ID()
        let target = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let returning = WindowToken(pid: 2, windowId: 2)
        let neighbor = WindowToken(pid: 3, windowId: 3)
        let resident = WindowToken(pid: 4, windowId: 4)
        let screen = CGRect(x: 160, y: 96, width: 2048, height: 1536)
        let sourceRoot: DwindleNode
        let sourceGroup: DwindleTile
        let sourceGroupNode: DwindleNode
        let sourceNeighborNode: DwindleNode

        init() throws {
            engine.settings.defaultSplitRatio = 1
            engine.addWindow(token: first, to: source, activeWindowFrame: nil)
            engine.setPreselection(.right, in: source)
            engine.addWindow(token: returning, to: source, activeWindowFrame: nil)
            XCTAssertTrue(engine.groupWindow(returning, into: first, in: source))
            XCTAssertEqual(engine.activateWindowOutcome(first, in: source), .activated)
            engine.setPreselection(.right, in: source)
            engine.addWindow(token: neighbor, to: source, activeWindowFrame: nil)
            sourceRoot = try XCTUnwrap(engine.root(for: source))
            sourceGroupNode = try XCTUnwrap(engine.findNode(for: first, in: source))
            sourceNeighborNode = try XCTUnwrap(engine.findNode(for: neighbor, in: source))
            sourceGroup = try XCTUnwrap(sourceGroupNode.tile)
            engine.setSelectedNode(sourceGroupNode, in: source)
            engine.addWindow(token: resident, to: target, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: source, screen: screen)
            _ = engine.calculateLayout(for: target, screen: screen)
            XCTAssertEqual(sourceRoot.splitOrientation, .horizontal)
            XCTAssertEqual(sourceRoot.splitRatio, 1)
            XCTAssertEqual(sourceGroup.members.map(\.token), [first, returning])
            XCTAssertEqual(sourceGroup.activeToken, first)
        }

        func assertReturnedPeer(ratio: CGFloat) throws {
            XCTAssertTrue(engine.root(for: source) === sourceRoot)
            XCTAssertNil(sourceRoot.parent)
            XCTAssertEqual(sourceRoot.children.count, 2)
            XCTAssertEqual(sourceRoot.splitOrientation, .horizontal)
            XCTAssertEqual(sourceRoot.splitRatio, ratio)
            XCTAssertTrue(sourceRoot.firstChild() === sourceGroupNode)
            XCTAssertTrue(sourceRoot.secondChild() === sourceNeighborNode)
            XCTAssertTrue(sourceGroupNode.parent === sourceRoot)
            XCTAssertTrue(sourceNeighborNode.parent === sourceRoot)
            XCTAssertTrue(sourceGroupNode.tile === sourceGroup)
            XCTAssertTrue(engine.findNode(for: returning, in: source) === sourceGroupNode)
            XCTAssertEqual(sourceGroup.members, [
                DwindleTileMember(token: first, isFullscreen: false),
                DwindleTileMember(token: returning, isFullscreen: false)
            ])
            XCTAssertEqual(sourceGroup.activeToken, first)
            XCTAssertEqual(engine.activeToken(in: source), neighbor)
            XCTAssertEqual(engine.tileCount(in: source), 2)
            XCTAssertEqual(engine.windowCount(in: source), 3)
            let raw = engine.splitRect(
                screen,
                orientation: .horizontal,
                ratio: ratio,
                minimums: (first: .zero, second: .zero)
            )
            var groupFrame = DwindleGapCalculator.applyGaps(
                nodeRect: raw.0,
                tilingArea: screen,
                settings: engine.settings
            )
            groupFrame.origin.x += engine.tabRailWidth
            groupFrame.size.width -= engine.tabRailWidth
            let neighborFrame = DwindleGapCalculator.applyGaps(
                nodeRect: raw.1,
                tilingArea: screen,
                settings: engine.settings
            )
            XCTAssertEqual(
                engine.calculateLayout(for: source, screen: screen),
                [first: groupFrame, neighbor: neighborFrame]
            )
        }
    }
}
