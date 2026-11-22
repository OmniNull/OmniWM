// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class DwindleGroupVisibilityTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testAnimationOmitsAMemberMissingFromItsTargetFrames() {
        let fixture = makeGroupedFixture()
        let frames = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        let time = TimeInterval.zero
        let member = fixture.second
        XCTAssertNotNil(frames[member])
        XCTAssertNotNil(fixture.engine.presentedFrame(for: member, in: fixture.workspaceId, at: time))
        let diff = fixture.handler.layoutDiff(
            windows: [snapshot(member)], frames: [:],
            context: .init(
                engine: fixture.engine, workspaceId: fixture.workspaceId,
                preferredHideSide: .left, canRestoreHiddenWorkspaceWindows: true, scale: 1,
                reassertHidden: false, pendingParkWindowIds: [], animationTime: time
            )
        )
        XCTAssertTrue(diff.frameChanges.isEmpty)
    }

    func testLayoutDiffParksInactiveMemberAndFramesOnlyActiveMember() {
        let fixture = makeGroupedFixture()
        let frames = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        let diff = fixture.handler.layoutDiff(
            windows: [snapshot(fixture.first), snapshot(fixture.second)],
            frames: frames,
            context: .init(
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                preferredHideSide: .left,
                canRestoreHiddenWorkspaceWindows: true,
                scale: 1,
                reassertHidden: false,
                pendingParkWindowIds: [],
                animationTime: nil
            )
        )

        XCTAssertEqual(diff.frameChanges.map(\.token), [fixture.second])
        XCTAssertEqual(diff.visibilityChanges.count, 1)
        guard case let .hide(token, side) = diff.visibilityChanges[0] else {
            return XCTFail("expected inactive grouped member to be parked")
        }
        XCTAssertEqual(token, fixture.first)
        XCTAssertEqual(side, .left)
    }

    func testLayoutDiffDefersPreviousMemberParkUntilRevealCompletes() {
        let fixture = makeGroupedFixture()
        XCTAssertEqual(
            fixture.engine.activateWindowOutcome(fixture.first, in: fixture.workspaceId),
            .activated
        )
        let frames = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        let diff = fixture.handler.layoutDiff(
            windows: [
                snapshot(fixture.first, hiddenSide: .left),
                snapshot(fixture.second)
            ],
            frames: frames,
            context: .init(
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                preferredHideSide: .right,
                canRestoreHiddenWorkspaceWindows: true,
                scale: 1,
                reassertHidden: false,
                pendingParkWindowIds: [],
                animationTime: nil
            )
        )

        XCTAssertEqual(diff.frameChanges.map(\.token), [fixture.first])
        XCTAssertEqual(diff.visibilityChanges.count, 1)
        guard case let .show(shown) = diff.visibilityChanges[0] else {
            return XCTFail("expected the new active member to be revealed")
        }
        XCTAssertEqual(shown, fixture.first)
        XCTAssertEqual(diff.deferredHides.count, 1)
        XCTAssertEqual(diff.deferredHides[0].token, fixture.second)
        XCTAssertEqual(diff.deferredHides[0].side, .right)
        XCTAssertEqual(diff.deferredHides[0].revealToken, fixture.first)
    }

    func testLayoutDiffReassertsOnlyPendingOrSettlingParks() {
        let fixture = makeGroupedFixture()
        let windows = [
            snapshot(fixture.first, hiddenSide: .left),
            snapshot(fixture.second)
        ]
        let frames = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)

        let steady = fixture.handler.layoutDiff(
            windows: windows,
            frames: frames,
            context: .init(
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                preferredHideSide: .right,
                canRestoreHiddenWorkspaceWindows: true,
                scale: 1,
                reassertHidden: false,
                pendingParkWindowIds: [],
                animationTime: nil
            )
        )
        XCTAssertTrue(steady.visibilityChanges.isEmpty)

        let pending = fixture.handler.layoutDiff(
            windows: windows,
            frames: frames,
            context: .init(
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                preferredHideSide: .right,
                canRestoreHiddenWorkspaceWindows: true,
                scale: 1,
                reassertHidden: false,
                pendingParkWindowIds: [fixture.first.windowId],
                animationTime: nil
            )
        )
        XCTAssertEqual(pending.visibilityChanges.count, 1)
        guard let pendingChange = pending.visibilityChanges.first,
              case let .hide(pendingToken, pendingSide) = pendingChange
        else {
            return XCTFail("expected pending inactive group member to be parked")
        }
        XCTAssertEqual(pendingToken, fixture.first)
        XCTAssertEqual(pendingSide, .left)

        let settling = fixture.handler.layoutDiff(
            windows: windows,
            frames: frames,
            context: .init(
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                preferredHideSide: .right,
                canRestoreHiddenWorkspaceWindows: true,
                scale: 1,
                reassertHidden: true,
                pendingParkWindowIds: [],
                animationTime: nil
            )
        )
        XCTAssertEqual(settling.visibilityChanges.count, 1)
        guard let settlingChange = settling.visibilityChanges.first,
              case let .hide(settlingToken, settlingSide) = settlingChange
        else {
            return XCTFail("expected settling inactive group member to be parked")
        }
        XCTAssertEqual(settlingToken, fixture.first)
        XCTAssertEqual(settlingSide, .left)

        let unrelated = fixture.handler.layoutDiff(
            windows: windows,
            frames: frames,
            context: .init(
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                preferredHideSide: .right,
                canRestoreHiddenWorkspaceWindows: true,
                scale: 1,
                reassertHidden: false,
                pendingParkWindowIds: [fixture.second.windowId],
                animationTime: nil
            )
        )
        XCTAssertTrue(unrelated.visibilityChanges.isEmpty)
    }

    func testLayoutDiffProjectsOnlyActiveSuspendedGroupMemberAsVisible() throws {
        let fixture = makeGroupedFixture()
        let firstOriginalToken = WindowToken(pid: 101, windowId: 201)
        let secondOriginalToken = WindowToken(pid: 102, windowId: 202)
        let activeFrame = CGRect(x: 0.26, y: 0.26, width: 999.74, height: 799.74)
        let diff = fixture.handler.layoutDiff(
            windows: [
                snapshot(
                    fixture.first,
                    layoutReason: .nativeFullscreen,
                    originalToken: firstOriginalToken
                ),
                snapshot(
                    fixture.second,
                    layoutReason: .nativeFullscreen,
                    originalToken: secondOriginalToken
                )
            ],
            frames: [fixture.second: activeFrame],
            context: .init(
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                preferredHideSide: .left,
                canRestoreHiddenWorkspaceWindows: true,
                scale: 2,
                reassertHidden: false,
                pendingParkWindowIds: [],
                animationTime: nil
            )
        )

        XCTAssertTrue(diff.frameChanges.isEmpty)
        XCTAssertEqual(diff.nativeFullscreenSlots.count, 2)
        let inactive = try XCTUnwrap(diff.nativeFullscreenSlots[firstOriginalToken])
        XCTAssertEqual(inactive.frame, .zero)
        XCTAssertFalse(inactive.visible)
        let active = try XCTUnwrap(diff.nativeFullscreenSlots[secondOriginalToken])
        XCTAssertEqual(active.currentToken, fixture.second)
        XCTAssertEqual(active.frame, activeFrame.roundedToPhysicalPixels(scale: 2))
        XCTAssertTrue(active.visible)
    }

    private func makeGroupedFixture() -> (
        handler: DwindleLayoutHandler,
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        first: WindowToken,
        second: WindowToken
    ) {
        let handler = DwindleLayoutHandler(controller: nil)
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        XCTAssertTrue(engine.groupWindow(direction: .left, in: workspaceId))
        return (handler, engine, workspaceId, first, second)
    }

    private func snapshot(
        _ token: WindowToken,
        hiddenSide: HideSide? = nil,
        layoutReason: LayoutReason = .standard,
        originalToken: WindowToken? = nil
    ) -> LayoutWindowSnapshot {
        LayoutWindowSnapshot(
            token: token,
            constraints: WindowSizeConstraints(minSize: .zero, maxSize: .zero, isFixed: false),
            hiddenState: hiddenSide.map {
                HiddenState(
                    proportionalPosition: .zero,
                    referenceMonitorId: nil,
                    reason: .layoutTransient($0)
                )
            },
            layoutReason: layoutReason,
            nativeFullscreenOriginalToken: originalToken
        )
    }
}
