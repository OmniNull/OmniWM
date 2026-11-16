// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

extension CrossDisplayDragTests {
    func testDwindleTitleBarDoubleClickUsesCurrentFullscreenFrameAndRestoresLayout() throws {
        let fixture = try makeNativeFixture(
            [.dwindle],
            orientations: [.horizontal],
            frames: [CGRect(x: 137, y: -241, width: 1512, height: 912)]
        )
        let first = addWindow(1, to: fixture.source, fixture)
        let clicked = addWindow(2, to: fixture.source, fixture)
        let blocker = prepareDwindleDoubleClicks(fixture)
        defer { finishDwindleDoubleClicks(fixture, blocker: blocker) }
        fixture.layout()
        fixture.handler.topmostWindowIdProvider = { _ in clicked.windowId }
        let before = fixture.dwindle.currentFrames(in: fixture.source)
        let root = try XCTUnwrap(fixture.dwindle.root(for: fixture.source))
        let ratio = root.splitRatio
        let userActions = fixture.controller.userActionCount
        let firstPoint = try dwindleTitleBar(clicked, fixture)

        XCTAssertTrue(dwindleDoubleClick(at: firstPoint, fixture))

        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [clicked])
        XCTAssertFalse(fixture.dwindle.isWindowFullscreen(first, in: fixture.source))
        XCTAssertEqual(fixture.frame(clicked), fixture.controller.insetWorkingFrame(for: fixture.monitors[0]))
        XCTAssertEqual(fixture.controller.userActionCount, userActions + 1)
        XCTAssertEqual(root.splitRatio, ratio)
        let fullscreenPoint = try dwindleTitleBar(clicked, fixture)
        XCTAssertNotEqual(fullscreenPoint, firstPoint)

        XCTAssertTrue(dwindleDoubleClick(at: fullscreenPoint, fixture))

        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), before)
        XCTAssertEqual(root.splitRatio, ratio)
        XCTAssertEqual(fixture.dwindleTile(first), [first])
        XCTAssertEqual(fixture.dwindleTile(clicked), [clicked])
        XCTAssertEqual(fixture.controller.userActionCount, userActions + 2)
    }

    func testDwindleTitleBarArmsTheFirstClickButEdgesBodyAndModifiersPassThrough() throws {
        let fixture = try makeNativeFixture([.dwindle])
        let token = addWindow(1, to: fixture.source, fixture)
        _ = addWindow(2, to: fixture.source, fixture)
        let blocker = prepareDwindleDoubleClicks(fixture)
        defer { finishDwindleDoubleClicks(fixture, blocker: blocker) }
        fixture.layout()
        fixture.handler.topmostWindowIdProvider = { _ in token.windowId }
        let title = try dwindleTitleBar(token, fixture)
        let frame = try XCTUnwrap(fixture.frame(token))
        let inset = NiriLayoutEngine.doubleClickEdgeInset / 2
        let passthrough = [
            frame.center,
            CGPoint(x: frame.minX + inset, y: frame.midY),
            CGPoint(x: frame.maxX - inset, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.minY + inset),
            CGPoint(x: frame.midX, y: frame.maxY - inset),
            CGPoint(x: frame.maxX - inset, y: frame.maxY - inset)
        ]
        fixture.handler.receiveTapMouseDown(at: title, modifiers: [], clickCount: 1)
        XCTAssertEqual(fixture.handler.inputTapThread.filterSnapshot.fusionDoubleClickArmedAt, title)
        XCTAssertFalse(dwindleDoubleClick(at: title, clickCount: 1, fixture))
        for point in passthrough {
            fixture.handler.receiveTapMouseDown(at: point, modifiers: [], clickCount: 1)
            XCTAssertNil(fixture.handler.inputTapThread.filterSnapshot.fusionDoubleClickArmedAt)
            XCTAssertFalse(dwindleDoubleClick(at: point, fixture))
        }
        for modifiers: CGEventFlags in [.maskCommand, .maskShift, .maskAlternate] {
            fixture.handler.receiveTapMouseDown(at: title, modifiers: modifiers, clickCount: 1)
            XCTAssertNil(fixture.handler.inputTapThread.filterSnapshot.fusionDoubleClickArmedAt)
            XCTAssertFalse(dwindleDoubleClick(at: title, modifiers: modifiers, fixture))
        }
        for clickCount: Int64 in [1, 2] {
            XCTAssertFalse(fixture.handler.dispatchAuthoritativeTap(
                type: .leftMouseDown, location: title, modifiers: .maskControl,
                buttonNumber: 0, scrollPayload: nil, clickCount: clickCount
            ))
            XCTAssertNil(fixture.handler.inputTapThread.filterSnapshot.fusionDoubleClickArmedAt)
            XCTAssertTrue(fixture.handler.state.isMoving)
            XCTAssertEqual(fixture.handler.tapInputs.capturedInteractionButton, .left)
            XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
            XCTAssertTrue(fixture.handler.dispatchAuthoritativeTap(
                type: .leftMouseUp, location: title, modifiers: .maskControl,
                buttonNumber: 0, scrollPayload: nil
            ))
            XCTAssertFalse(fixture.handler.state.isMoving)
            XCTAssertNil(fixture.handler.tapInputs.capturedInteractionButton)
            fixture.layout()
        }
        XCTAssertFalse(dwindleDoubleClick(at: title, clickCount: 3, fixture))
        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
    }

    func testDwindleTitleBarControlsAndUnknownOrCoveringWindowsKeepTheirDoubleClick() throws {
        let fixture = try makeNativeFixture([.dwindle])
        let token = addWindow(1, to: fixture.source, fixture)
        let other = addWindow(2, to: fixture.source, fixture)
        let blocker = prepareDwindleDoubleClicks(fixture)
        defer { finishDwindleDoubleClicks(fixture, blocker: blocker) }
        fixture.layout()
        let point = try dwindleTitleBar(token, fixture)
        let frames = fixture.dwindle.currentFrames(in: fixture.source)
        fixture.handler.topmostWindowIdProvider = { _ in token.windowId }
        for hit: TitleBarHit? in [
            .init(role: "AXButton", placement: .insideBar(elementWithinBar: true)),
            .init(role: "AXTextField", placement: .insideBar(elementWithinBar: true)),
            .init(role: "AXWebArea"),
            nil
        ] {
            fixture.handler.titleBarHitProvider = { _, _ in hit }
            XCTAssertFalse(dwindleDoubleClick(at: point, fixture))
        }
        fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(role: "AXWindow") }
        for topmost: Int? in [nil, other.windowId] {
            fixture.handler.topmostWindowIdProvider = { _ in topmost }
            XCTAssertFalse(dwindleDoubleClick(at: point, fixture))
        }
        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), frames)
    }

    func testDwindleDoubleClickTargetsTheUnselectedWindowOnTheOtherDisplay() throws {
        let fixture = try makeNativeFixture(
            [.dwindle, .dwindle],
            orientations: [.horizontal, .vertical],
            frames: [
                CGRect(x: -1600, y: -120, width: 1512, height: 912),
                CGRect(x: 137, y: 89, width: 912, height: 1512)
            ]
        )
        let focused = addWindow(1, to: fixture.source, fixture)
        let selected = addWindow(2, to: fixture.target, fixture)
        let clicked = addWindow(3, to: fixture.target, fixture)
        let blocker = prepareDwindleDoubleClicks(fixture)
        defer { finishDwindleDoubleClicks(fixture, blocker: blocker) }
        fixture.manager.withEngineMutationScope {
            fixture.dwindle.setSelectedNode(
                fixture.dwindle.findNode(for: selected, in: fixture.target),
                in: fixture.target
            )
        }
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.source)
        fixture.layout()
        let original = fixture.dwindle.currentFrames(in: fixture.target)
        let sourceFrame = try XCTUnwrap(fixture.frame(focused))
        fixture.handler.topmostWindowIdProvider = { _ in clicked.windowId }

        XCTAssertTrue(dwindleDoubleClick(at: try dwindleTitleBar(clicked, fixture), fixture))

        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.target), [clicked])
        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
        XCTAssertFalse(fixture.dwindle.isWindowFullscreen(selected, in: fixture.target))
        XCTAssertEqual(fixture.frame(focused), sourceFrame)
        XCTAssertTrue(dwindleDoubleClick(at: try dwindleTitleBar(clicked, fixture), fixture))
        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.target), original)
        XCTAssertEqual(fixture.frame(focused), sourceFrame)
    }

    func testDwindleDoubleClickFullscreensOnlyTheVisibleGroupMemberAndPreservesItsGroup() throws {
        let fixture = try makeNativeFixture([.dwindle])
        let inactive = addWindow(1, to: fixture.source, fixture)
        let clicked = addWindow(2, to: fixture.source, fixture)
        let neighbor = addWindow(3, to: fixture.source, fixture)
        let blocker = prepareDwindleDoubleClicks(fixture)
        defer { finishDwindleDoubleClicks(fixture, blocker: blocker) }
        fixture.manager.withEngineMutationScope {
            XCTAssertTrue(fixture.dwindle.groupWindow(clicked, into: inactive, in: fixture.source))
            _ = fixture.dwindle.activateWindowOutcome(clicked, in: fixture.source)
        }
        fixture.layout()
        let group = try XCTUnwrap(fixture.dwindle.tile(containing: clicked, in: fixture.source))
        let before = fixture.dwindle.currentFrames(in: fixture.source)
        fixture.handler.topmostWindowIdProvider = { _ in clicked.windowId }

        XCTAssertTrue(dwindleDoubleClick(at: try dwindleTitleBar(clicked, fixture), fixture))

        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [clicked])
        XCTAssertFalse(fixture.dwindle.isWindowFullscreen(inactive, in: fixture.source))
        XCTAssertFalse(fixture.dwindle.isWindowFullscreen(neighbor, in: fixture.source))
        XCTAssertEqual(group.members.map(\.token), [inactive, clicked])
        XCTAssertTrue(dwindleDoubleClick(at: try dwindleTitleBar(clicked, fixture), fixture))
        XCTAssertTrue(fixture.dwindle.tile(containing: clicked, in: fixture.source) === group)
        XCTAssertEqual(group.members.map(\.token), [inactive, clicked])
        XCTAssertEqual(fixture.dwindle.projectedActiveToken(in: fixture.source), clicked)
        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), before)
    }

    func testDwindleDoubleClickRejectsHiddenExcludedAndNativeSuppressedWindows() throws {
        for refusal in [DwindleDoubleClickRefusal.hidden, .excluded, .nativeSuppressed] {
            let fixture = try makeNativeFixture([.dwindle])
            let token = addWindow(1, to: fixture.source, fixture)
            _ = addWindow(2, to: fixture.source, fixture)
            let blocker = prepareDwindleDoubleClicks(fixture)
            defer { finishDwindleDoubleClicks(fixture, blocker: blocker) }
            fixture.layout()
            let point = try dwindleTitleBar(token, fixture)
            fixture.handler.topmostWindowIdProvider = { _ in token.windowId }
            switch refusal {
            case .hidden:
                fixture.manager.setHiddenState(
                    HiddenState(
                        proportionalPosition: .zero,
                        referenceMonitorId: fixture.monitors[0].id,
                        reason: .workspaceInactive
                    ),
                    for: token
                )
            case .excluded:
                fixture.manager.withEngineMutationScope {
                    fixture.dwindle.setExcludedTokens([token], in: fixture.source)
                }
            case .nativeSuppressed:
                fixture.controller.axManager.setWindowNativeSuppressed(true, token: token)
            }
            let userActions = fixture.controller.userActionCount

            XCTAssertFalse(fixture.handler.handleFusionDoubleClick(at: point, modifiers: []))

            XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
            XCTAssertEqual(fixture.controller.userActionCount, userActions)
            XCTAssertNil(fixture.handler.tapInputs.capturedInteractionButton)
        }
    }

    func testDwindleDoubleClickRejectsNativeFullscreenTransitionsAndSpaces() throws {
        for pending in [false, true] {
            let fixture = try makeNativeFixture([.dwindle])
            let token = addWindow(1, to: fixture.source, fixture)
            _ = addWindow(2, to: fixture.source, fixture)
            let blocker = prepareDwindleDoubleClicks(fixture)
            defer { finishDwindleDoubleClicks(fixture, blocker: blocker) }
            fixture.layout()
            let point = try dwindleTitleBar(token, fixture)
            fixture.handler.topmostWindowIdProvider = { _ in token.windowId }
            if pending {
                XCTAssertTrue(fixture.manager.requestNativeFullscreenEnter(token, in: fixture.source))
            } else {
                XCTAssertTrue(fixture.manager.markNativeFullscreenSuspended(token, ownsNativeFocus: false))
            }
            let spaceId: UInt64 = 1
            fixture.manager.commitSpaceTopology(SpaceTopology(
                displays: [.init(
                    displayIdentifier: String(fixture.monitors[0].displayId),
                    spaceIds: [spaceId], currentSpaceId: spaceId
                )],
                activeSpaceId: spaceId,
                fullscreenSpaceIds: pending ? [] : [spaceId]
            ))
            let userActions = fixture.controller.userActionCount

            XCTAssertFalse(fixture.handler.handleFusionDoubleClick(at: point, modifiers: []))

            XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
            XCTAssertEqual(fixture.controller.userActionCount, userActions)
            XCTAssertNil(fixture.handler.tapInputs.capturedInteractionButton)
        }
    }

    func testDwindleDoubleClickPreservesAnExistingCaptureAndCapturesItsOwnRelease() throws {
        let fixture = try makeNativeFixture([.dwindle])
        let token = addWindow(1, to: fixture.source, fixture)
        _ = addWindow(2, to: fixture.source, fixture)
        let blocker = prepareDwindleDoubleClicks(fixture)
        defer { finishDwindleDoubleClicks(fixture, blocker: blocker) }
        fixture.layout()
        let point = try dwindleTitleBar(token, fixture)
        fixture.handler.topmostWindowIdProvider = { _ in token.windowId }
        fixture.handler.tapInputs.capturedInteractionButton = .right
        let userActions = fixture.controller.userActionCount

        XCTAssertFalse(fixture.handler.handleFusionDoubleClick(at: point, modifiers: []))

        XCTAssertEqual(fixture.handler.tapInputs.capturedInteractionButton, .right)
        XCTAssertEqual(fixture.controller.userActionCount, userActions)
        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
        fixture.handler.tapInputs.capturedInteractionButton = nil
        XCTAssertTrue(fixture.handler.dispatchAuthoritativeTap(
            type: .leftMouseDown, location: point, modifiers: [], buttonNumber: 0, scrollPayload: nil, clickCount: 2
        ))
        XCTAssertEqual(fixture.handler.tapInputs.capturedInteractionButton, .left)
        XCTAssertEqual(fixture.handler.inputTapThread.filterSnapshot.activeCapture, .left)
        XCTAssertTrue(fixture.handler.dispatchAuthoritativeTap(
            type: .leftMouseDragged, location: point, modifiers: [], buttonNumber: 0, scrollPayload: nil
        ))
        XCTAssertTrue(fixture.handler.dispatchAuthoritativeTap(
            type: .leftMouseUp, location: point, modifiers: [], buttonNumber: 0, scrollPayload: nil
        ))
        XCTAssertNil(fixture.handler.tapInputs.capturedInteractionButton)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertEqual(fixture.controller.userActionCount, userActions + 1)
    }

    private enum DwindleDoubleClickRefusal {
        case hidden
        case excluded
        case nativeSuppressed
    }

    private struct DwindleDoubleClickBlocker {
        let task: Task<Void, Never>
        let completion: AsyncStream<Void>.Continuation
    }

    private func prepareDwindleDoubleClicks(_ fixture: Fixture) -> DwindleDoubleClickBlocker {
        fixture.manager.withEngineMutationScope {
            fixture.controller.dwindleLayoutHandler.applyResolvedSettings(
                fixture.controller.resolvedDwindleSettings(for: fixture.monitors[0]),
                to: fixture.dwindle
            )
        }
        fixture.controller.motionPolicy.animationsEnabled = false
        fixture.controller.hasStartedServices = true
        fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(role: "AXWindow") }
        fixture.handler.topmostWindowIdProvider = { _ in nil }
        let (events, completion) = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            var iterator = events.makeAsyncIterator()
            _ = await iterator.next()
        }
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = task
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: Set(fixture.workspaces)
        )
        return DwindleDoubleClickBlocker(task: task, completion: completion)
    }

    private func finishDwindleDoubleClicks(_ fixture: Fixture, blocker: DwindleDoubleClickBlocker) {
        blocker.completion.finish()
        blocker.task.cancel()
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = nil
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = nil
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
    }

    private func dwindleTitleBar(_ token: WindowToken, _ fixture: Fixture) throws -> CGPoint {
        let frame = try XCTUnwrap(fixture.frame(token))
        let depth = (NiriLayoutEngine.doubleClickEdgeInset + NiriLayoutEngine.doubleClickTitleBarDepth) / 2
        return CGPoint(x: frame.midX, y: frame.maxY - depth)
    }

    @discardableResult
    private func dwindleDoubleClick(
        at point: CGPoint,
        modifiers: CGEventFlags = [],
        clickCount: Int64 = 2,
        _ fixture: Fixture
    ) -> Bool {
        let press = fixture.handler.dispatchAuthoritativeTap(
            type: .leftMouseDown, location: point, modifiers: modifiers,
            buttonNumber: 0, scrollPayload: nil, clickCount: clickCount
        )
        let release = fixture.handler.dispatchAuthoritativeTap(
            type: .leftMouseUp, location: point, modifiers: modifiers, buttonNumber: 0, scrollPayload: nil
        )
        XCTAssertEqual(press, release)
        XCTAssertNil(fixture.handler.tapInputs.capturedInteractionButton)
        fixture.layout()
        return press
    }
}
