// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

extension CrossDisplayDragTests {
    func testDwindleEdgeDoubleClickArmsExpandsBelowFivePercentAndRestoresAtItsNewEdge() throws {
        try assertDwindleEdgeTapCycle(horizontal: true)
    }

    func testDwindleVerticalEdgeDoubleClickArmsExpandsBelowFivePercentAndRestoresAtItsNewEdge() throws {
        try assertDwindleEdgeTapCycle(horizontal: false)
    }

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

    func testDwindleTitleBarArmsTheFirstClickButBodyCornersAndModifiersPassThrough() throws {
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
            CGPoint(x: frame.minX + inset, y: frame.minY + inset),
            CGPoint(x: frame.minX + inset, y: frame.maxY - inset),
            CGPoint(x: frame.maxX - inset, y: frame.minY + inset),
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
            XCTAssertFalse(fixture.handler.state.isMoving)
            XCTAssertNil(fixture.handler.tapInputs.capturedInteractionButton)
            XCTAssertNil(fixture.dwindle.interactiveMove)
            XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
            XCTAssertFalse(fixture.handler.dispatchAuthoritativeTap(
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
            let points = [
                try dwindleTitleBar(token, fixture),
                dwindleEdgePoint(try XCTUnwrap(fixture.frame(token)), horizontal: true)
            ]
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

            for point in points {
                XCTAssertFalse(fixture.handler.handleFusionDoubleClick(at: point, modifiers: []))
            }

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
            let points = [
                try dwindleTitleBar(token, fixture),
                dwindleEdgePoint(try XCTUnwrap(fixture.frame(token)), horizontal: true)
            ]
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

            for point in points {
                XCTAssertFalse(fixture.handler.handleFusionDoubleClick(at: point, modifiers: []))
            }

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

    func testDwindleEdgeDoubleClickRejectsUnknownAndCoveringWindowsWithoutTitleBarQueries() throws {
        let fixture = try makeNativeFixture([.dwindle])
        let token = addWindow(1, to: fixture.source, fixture)
        let other = addWindow(2, to: fixture.source, fixture)
        let blocker = prepareDwindleDoubleClicks(fixture)
        defer { finishDwindleDoubleClicks(fixture, blocker: blocker) }
        fixture.layout()
        let point = dwindleEdgePoint(try XCTUnwrap(fixture.frame(token)), horizontal: true)
        let frames = fixture.dwindle.currentFrames(in: fixture.source)
        let root = try XCTUnwrap(fixture.dwindle.root(for: fixture.source))
        let ratio = root.splitRatio
        let userActions = fixture.controller.userActionCount
        var titleBarQueries = 0
        fixture.handler.titleBarHitProvider = { _, _ in
            titleBarQueries += 1
            return nil
        }
        let topmostCases: [Int?] = [nil, other.windowId]
        for topmost in topmostCases {
            fixture.handler.topmostWindowIdProvider = { _ in topmost }
            let actionsBeforeDecline = fixture.controller.userActionCount
            XCTAssertFalse(fixture.handler.handleFusionDoubleClick(at: point, modifiers: []))
            XCTAssertEqual(fixture.controller.userActionCount, actionsBeforeDecline)
            XCTAssertFalse(dwindleDoubleClick(at: point, fixture))
        }
        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), frames)
        XCTAssertEqual(root.splitRatio, ratio)
        XCTAssertNil(root.edgeExpansion)
        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
        XCTAssertEqual(fixture.controller.userActionCount, userActions + UInt64(topmostCases.count))
        XCTAssertEqual(titleBarQueries, 0)
    }

    func testDwindleEdgeDoubleClickArmsSingleEdgesButPreservesOuterEdgesAndModifiers() throws {
        let fixture = try makeNativeFixture([.dwindle])
        let token = addWindow(1, to: fixture.source, fixture)
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            _ = fixture.dwindle.setPreselection(.right, in: fixture.source)
        }
        _ = addWindow(2, to: fixture.source, fixture)
        let blocker = prepareDwindleDoubleClicks(fixture)
        defer { finishDwindleDoubleClicks(fixture, blocker: blocker) }
        fixture.layout()
        fixture.handler.topmostWindowIdProvider = { _ in token.windowId }
        let frame = try XCTUnwrap(fixture.frame(token))
        let inset = NiriLayoutEngine.doubleClickEdgeInset / 2
        let inner = dwindleEdgePoint(frame, horizontal: true)
        let outer = [
            CGPoint(x: frame.minX + inset, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.minY + inset),
            CGPoint(x: frame.midX, y: frame.maxY - inset)
        ]
        let frames = fixture.dwindle.currentFrames(in: fixture.source)
        let root = try XCTUnwrap(fixture.dwindle.root(for: fixture.source))
        let ratio = root.splitRatio
        let userActions = fixture.controller.userActionCount
        let singleEdges = outer + [inner]
        let passthroughModifiers: [CGEventFlags] = [.maskCommand, .maskShift, .maskAlternate]
        for point in singleEdges {
            fixture.handler.receiveTapMouseDown(at: point, modifiers: [], clickCount: 1)
            XCTAssertEqual(fixture.handler.inputTapThread.filterSnapshot.fusionDoubleClickArmedAt, point)
            fixture.handler.receiveTapMouseUp(at: point)
        }
        for point in outer {
            let actionsBeforeDecline = fixture.controller.userActionCount
            XCTAssertFalse(fixture.handler.handleFusionDoubleClick(at: point, modifiers: []))
            XCTAssertEqual(fixture.controller.userActionCount, actionsBeforeDecline)
            XCTAssertFalse(dwindleDoubleClick(at: point, fixture))
        }
        for modifiers in passthroughModifiers {
            let actionsBeforeDecline = fixture.controller.userActionCount
            XCTAssertFalse(fixture.handler.handleFusionDoubleClick(at: inner, modifiers: modifiers))
            XCTAssertEqual(fixture.controller.userActionCount, actionsBeforeDecline)
            fixture.handler.receiveTapMouseDown(at: inner, modifiers: modifiers, clickCount: 1)
            XCTAssertNil(fixture.handler.inputTapThread.filterSnapshot.fusionDoubleClickArmedAt)
            fixture.handler.receiveTapMouseUp(at: inner)
            XCTAssertFalse(dwindleDoubleClick(at: inner, modifiers: modifiers, fixture))
        }
        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), frames)
        XCTAssertEqual(root.splitRatio, ratio)
        XCTAssertNil(root.edgeExpansion)
        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
        let firstPresses = singleEdges.count + passthroughModifiers.count
        let secondPresses = outer.count + passthroughModifiers.count
        XCTAssertEqual(fixture.controller.userActionCount, userActions + UInt64(firstPresses + secondPresses))
    }

    func testDwindleEdgePassesModifiedClicksThroughAndKeepsExistingCapture() throws {
        let fixture = try makeNativeFixture([.dwindle])
        let token = addWindow(1, to: fixture.source, fixture)
        _ = addWindow(2, to: fixture.source, fixture)
        let blocker = prepareDwindleDoubleClicks(fixture)
        defer { finishDwindleDoubleClicks(fixture, blocker: blocker) }
        fixture.layout()
        fixture.handler.topmostWindowIdProvider = { _ in token.windowId }
        let point = dwindleEdgePoint(try XCTUnwrap(fixture.frame(token)), horizontal: true)
        let root = try XCTUnwrap(fixture.dwindle.root(for: fixture.source))
        let ratio = root.splitRatio
        fixture.handler.tapInputs.capturedInteractionButton = .right
        XCTAssertFalse(fixture.handler.handleFusionDoubleClick(at: point, modifiers: []))
        XCTAssertEqual(fixture.handler.tapInputs.capturedInteractionButton, .right)
        fixture.handler.tapInputs.capturedInteractionButton = nil
        for clickCount: Int64 in [1, 2] {
            XCTAssertFalse(fixture.handler.dispatchAuthoritativeTap(
                type: .leftMouseDown, location: point, modifiers: .maskControl,
                buttonNumber: 0, scrollPayload: nil, clickCount: clickCount
            ))
            XCTAssertNil(fixture.handler.inputTapThread.filterSnapshot.fusionDoubleClickArmedAt)
            XCTAssertFalse(fixture.handler.state.isMoving)
            XCTAssertNil(fixture.handler.tapInputs.capturedInteractionButton)
            XCTAssertNil(fixture.dwindle.interactiveMove)
            XCTAssertFalse(fixture.handler.dispatchAuthoritativeTap(
                type: .leftMouseUp, location: point, modifiers: .maskControl,
                buttonNumber: 0, scrollPayload: nil
            ))
            XCTAssertFalse(fixture.handler.state.isMoving)
            XCTAssertNil(fixture.handler.tapInputs.capturedInteractionButton)
            fixture.layout()
        }
        XCTAssertEqual(root.splitRatio, ratio)
        XCTAssertNil(root.edgeExpansion)
        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
    }

    func testDwindleFullscreenEdgeCannotExpandOrCreateARestore() throws {
        let fixture = try makeNativeFixture([.dwindle])
        let token = addWindow(1, to: fixture.source, fixture)
        _ = addWindow(2, to: fixture.source, fixture)
        let blocker = prepareDwindleDoubleClicks(fixture)
        defer { finishDwindleDoubleClicks(fixture, blocker: blocker) }
        fixture.layout()
        fixture.handler.topmostWindowIdProvider = { _ in token.windowId }
        let original = fixture.dwindle.currentFrames(in: fixture.source)
        let root = try XCTUnwrap(fixture.dwindle.root(for: fixture.source))
        let ratio = root.splitRatio
        XCTAssertTrue(dwindleDoubleClick(at: try dwindleTitleBar(token, fixture), fixture))
        let fullscreen = fixture.dwindle.currentFrames(in: fixture.source)
        let point = dwindleEdgePoint(try XCTUnwrap(fixture.frame(token)), horizontal: true)
        let userActions = fixture.controller.userActionCount

        XCTAssertFalse(fixture.handler.handleFusionDoubleClick(at: point, modifiers: []))
        XCTAssertEqual(fixture.controller.userActionCount, userActions)
        XCTAssertFalse(dwindleDoubleClick(at: point, fixture))

        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), fullscreen)
        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [token])
        XCTAssertEqual(root.splitRatio, ratio)
        XCTAssertNil(root.edgeExpansion)
        XCTAssertEqual(fixture.controller.userActionCount, userActions + 1)
        XCTAssertTrue(dwindleDoubleClick(at: try dwindleTitleBar(token, fixture), fixture))
        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), original)
        XCTAssertEqual(root.splitRatio, ratio)
        XCTAssertNil(root.edgeExpansion)
    }

    private func assertDwindleEdgeTapCycle(horizontal: Bool) throws {
        let fixture = try makeNativeFixture(
            [.dwindle], orientations: [horizontal ? .horizontal : .vertical],
            frames: [CGRect(x: 137, y: -241, width: horizontal ? 1512 : 912, height: horizontal ? 912 : 1512)]
        )
        let clicked = addWindow(1, to: fixture.source, fixture)
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            _ = fixture.dwindle.setPreselection(horizontal ? .right : .up, in: fixture.source)
        }
        let neighbor = addWindow(2, to: fixture.source, fixture)
        let blocker = prepareDwindleDoubleClicks(fixture)
        defer { finishDwindleDoubleClicks(fixture, blocker: blocker) }
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitors[0])
        let settings = fixture.dwindle.settings
        let span = horizontal ? area.width : area.height
        let minimumRawSpan = span / 64
        let minimumContentSpan = minimumRawSpan - settings.innerGap / 2
        constrainDwindleEdgeNeighbor(neighbor, horizontal: horizontal, minimumContentSpan: minimumContentSpan, fixture)
        fixture.layout()
        let root = try XCTUnwrap(fixture.dwindle.root(for: fixture.source))
        let originalRatio = settings.defaultSplitRatio
        let original = dwindleEdgeFrames(
            fixture, clicked: clicked, neighbor: neighbor, horizontal: horizontal,
            cut: span * settings.ratioToFraction(originalRatio)
        )
        let expanded = dwindleEdgeFrames(
            fixture, clicked: clicked, neighbor: neighbor, horizontal: horizontal, cut: span - minimumRawSpan
        )
        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), original)
        XCTAssertEqual(root.splitRatio, originalRatio)
        fixture.handler.topmostWindowIdProvider = { _ in clicked.windowId }
        var titleBarQueries = 0
        fixture.handler.titleBarHitProvider = { _, _ in
            titleBarQueries += 1
            return nil
        }
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        MouseEventHandler._instance = fixture.handler
        fixture.handler.syncTapFilterSnapshot()
        let intake = fixture.controller.eventIntake
        intake.open(sink: fixture.controller.eventInterpreter)
        defer { intake.close() }
        let start = try XCTUnwrap(original[clicked])
        let firstPoint = dwindleEdgePoint(start, horizontal: horizontal)
        try dwindleTapDoubleClick(at: firstPoint, frames: original, fixture)

        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), expanded)
        XCTAssertEqual(root.splitRatio, 2 * (span - minimumRawSpan) / span)
        XCTAssertNotNil(root.edgeExpansion)
        let neighborFrame = try XCTUnwrap(fixture.frame(neighbor))
        XCTAssertEqual(horizontal ? neighborFrame.width : neighborFrame.height, minimumContentSpan)
        XCTAssertEqual(fixture.frame(clicked)?.minX, start.minX)
        XCTAssertEqual(fixture.frame(clicked)?.minY, start.minY)
        XCTAssertEqual(
            horizontal ? fixture.frame(clicked)?.height : fixture.frame(clicked)?.width,
            horizontal ? start.height : start.width
        )
        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
        let grown = try XCTUnwrap(expanded[clicked])
        let restoredPoint = dwindleEdgePoint(grown, horizontal: horizontal)
        XCTAssertNotEqual(restoredPoint, firstPoint)
        try dwindleTapDoubleClick(at: restoredPoint, frames: expanded, fixture)

        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), original)
        XCTAssertEqual(root.splitRatio, originalRatio)
        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
        XCTAssertNil(root.edgeExpansion)
        XCTAssertEqual(titleBarQueries, 0)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
    }

    private func constrainDwindleEdgeNeighbor(
        _ token: WindowToken, horizontal: Bool, minimumContentSpan: CGFloat, _ fixture: Fixture
    ) {
        fixture.manager.setCachedConstraints(
            WindowSizeConstraints(
                minSize: CGSize(
                    width: horizontal ? minimumContentSpan : 1, height: horizontal ? 1 : minimumContentSpan
                ),
                maxSize: .zero, isFixed: false
            ), for: token
        )
        fixture.controller.dwindleLayoutHandler.refreshEngineConstraints(
            workspaceId: fixture.source, monitor: fixture.monitors[0]
        )
    }

    private func dwindleTapDoubleClick(at point: CGPoint, frames: [WindowToken: CGRect], _ fixture: Fixture) throws {
        for (token, frame) in frames {
            fixture.controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
        }
        let tap = fixture.handler.inputTapThread
        tap.evaluateLeftMouseDown(at: point, modifiers: [], timestamp: 0, snapshot: tap.filterSnapshot) {
            frames.mapValues { ScreenCoordinateSpace.toWindowServer(rect: $0) }
        }
        fixture.controller.eventIntake.drainNow()
        XCTAssertEqual(tap.filterSnapshot.fusionDoubleClickArmedAt, point)
        let release = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: ScreenCoordinateSpace.toWindowServer(point: point), mouseButton: .left
        ))
        release.flags = []
        XCTAssertNotNil(tap.evaluateTap(type: .leftMouseUp, event: release))
        fixture.controller.eventIntake.drainNow()
        let secondPress = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: ScreenCoordinateSpace.toWindowServer(point: point), mouseButton: .left
        ))
        secondPress.flags = []
        secondPress.setIntegerValueField(.mouseEventClickState, value: 2)
        XCTAssertNil(tap.evaluateTap(type: .leftMouseDown, event: secondPress))
        XCTAssertEqual(fixture.handler.tapInputs.capturedInteractionButton, .left)
        XCTAssertEqual(tap.filterSnapshot.activeCapture, .left)
        XCTAssertNil(tap.evaluateTap(type: .leftMouseUp, event: release))
        XCTAssertNil(fixture.handler.tapInputs.capturedInteractionButton)
        XCTAssertNil(tap.filterSnapshot.activeCapture)
        fixture.layout()
    }

    private func dwindleEdgePoint(_ frame: CGRect, horizontal: Bool) -> CGPoint {
        let inset = NiriLayoutEngine.doubleClickEdgeInset / 2
        return CGPoint(x: horizontal ? frame.maxX - inset : frame.midX, y: horizontal ? frame.midY : frame.maxY - inset)
    }

    private func dwindleEdgeFrames(
        _ fixture: Fixture, clicked: WindowToken, neighbor: WindowToken, horizontal: Bool, cut: CGFloat
    ) -> [WindowToken: CGRect] {
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitors[0])
        let rectangles = [
            (clicked, CGRect(
                x: area.minX, y: area.minY, width: horizontal ? cut : area.width,
                height: horizontal ? area.height : cut
            )),
            (neighbor, CGRect(
                x: horizontal ? area.minX + cut : area.minX, y: horizontal ? area.minY : area.minY + cut,
                width: horizontal ? area.width - cut : area.width, height: horizontal ? area.height : area.height - cut
            ))
        ]
        return Dictionary(uniqueKeysWithValues: rectangles.map { token, rectangle in
            (token, DwindleGapCalculator.applyGaps(
                nodeRect: rectangle, tilingArea: area, settings: fixture.dwindle.settings
            ))
        })
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
