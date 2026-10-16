// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class InputTapThreadTests: XCTestCase {
    func testInputTapThreadLifecycleRestart() {
        let thread = InputTapThread()
        let loop1 = thread.startAndGetRunLoop()
        XCTAssertNotNil(loop1)
        thread.stop()

        let loop2 = thread.startAndGetRunLoop()
        XCTAssertNotNil(loop2)
        XCTAssertFalse(loop1 === loop2)
        thread.stop()
    }

    func testTapFilterSnapshotThreadSafety() {
        let thread = InputTapThread()
        let iterations = 1000
        let group = DispatchGroup()

        for i in 0 ..< 4 {
            group.enter()
            DispatchQueue.global().async {
                for j in 0 ..< iterations {
                    if (i + j) % 2 == 0 {
                        thread.updateFilterSnapshot {
                            $0.activeCapture = .left
                            $0.gestureActiveOrLatched = true
                        }
                    } else {
                        thread.updateFilterSnapshot {
                            $0.activeCapture = nil
                            $0.gestureActiveOrLatched = false
                        }
                    }
                    _ = thread.filterSnapshot
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    }

    @MainActor
    func testFastPathPassesUncapturedClicksAndDrags() throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        handler.setup()
        defer { handler.cleanup() }

        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let leftDown = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        ))
        XCTAssertFalse(MouseEventHandler.processTapCallback(type: .leftMouseDown, event: leftDown))

        let leftDrag = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: CGPoint(x: 110, y: 100),
            mouseButton: .left
        ))
        XCTAssertFalse(MouseEventHandler.processTapCallback(type: .leftMouseDragged, event: leftDrag))

        let rightDown = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .rightMouseDown,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .right
        ))
        XCTAssertFalse(MouseEventHandler.processTapCallback(type: .rightMouseDown, event: rightDown))
    }

    @MainActor
    func testFastPathPassesUnmodifiedScrollAndTwoFingerTrackpadScroll() throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        handler.setup()
        defer { handler.cleanup() }

        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let mouseWheel = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: -10,
            wheel2: 0,
            wheel3: 0
        ))
        XCTAssertFalse(MouseEventHandler.processTapCallback(type: .scrollWheel, event: mouseWheel))

        let trackpadScroll = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: -10,
            wheel2: 0,
            wheel3: 0
        ))
        trackpadScroll.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.changed.rawValue))

        handler.inputTapThread.touchCountProvider = { 2 }
        XCTAssertFalse(MouseEventHandler.processTapCallback(type: .scrollWheel, event: trackpadScroll))

        handler.inputTapThread.touchCountProvider = { 0 }
        trackpadScroll.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        trackpadScroll.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: Int64(CGScrollPhase.changed.rawValue)
        )
        XCTAssertFalse(MouseEventHandler.processTapCallback(type: .scrollWheel, event: trackpadScroll))
    }

    @MainActor
    func testAuthoritativePathSuppressesCapturedInteraction() throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        handler.setup()
        defer { handler.cleanup() }

        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let drag = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        ))

        XCTAssertFalse(MouseEventHandler.processTapCallback(type: .leftMouseDragged, event: drag))

        handler.state.capturedInteractionButton = .left
        XCTAssertEqual(handler.inputTapThread.filterSnapshot.activeCapture, .left)
        XCTAssertTrue(MouseEventHandler.processTapCallback(type: .leftMouseDragged, event: drag))

        let upEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        ))
        XCTAssertTrue(MouseEventHandler.processTapCallback(type: .leftMouseUp, event: upEvent))
        XCTAssertNil(handler.state.capturedInteractionButton)
        XCTAssertNil(handler.inputTapThread.filterSnapshot.activeCapture)
    }

    @MainActor
    func testAuthoritativePathSuppressesTrackpadWhenGestureActiveOrLatched() throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        handler.setup()
        defer { handler.cleanup() }

        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let scrollEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: -10,
            wheel2: 0,
            wheel3: 0
        ))
        scrollEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.changed.rawValue))

        handler.state.gesturePhase = .committed
        XCTAssertTrue(handler.inputTapThread.filterSnapshot.gestureActiveOrLatched)
        XCTAssertTrue(MouseEventHandler.processTapCallback(type: .scrollWheel, event: scrollEvent))

        handler.state.gesturePhase = .idle
        handler.state.consumeTrackpadScrollUntilAllTouchesLift = true
        XCTAssertTrue(handler.inputTapThread.filterSnapshot.gestureActiveOrLatched)
        XCTAssertTrue(MouseEventHandler.processTapCallback(type: .scrollWheel, event: scrollEvent))

        handler.state.consumeTrackpadScrollUntilAllTouchesLift = false
        handler.inputTapThread.touchCountProvider = { 3 }
        XCTAssertFalse(handler.inputTapThread.filterSnapshot.gestureActiveOrLatched)
        XCTAssertFalse(MouseEventHandler.processTapCallback(type: .scrollWheel, event: scrollEvent))
    }

    @MainActor
    func testOtherMouseButtonClaimedVsUnclaimed() throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        handler.setup()
        defer { handler.cleanup() }

        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .otherMouseDown,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .center
        ))
        event.setIntegerValueField(.mouseEventButtonNumber, value: 5)

        XCTAssertFalse(MouseEventHandler.processTapCallback(type: .otherMouseDown, event: event))

        handler.inputTapThread.updateFilterSnapshot { $0.claimedOtherButtons.insert(5) }
        XCTAssertFalse(MouseEventHandler.processTapCallback(type: .otherMouseDown, event: event))
    }

    @MainActor
    private func makeController() -> WMController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.animationsEnabled = false
        return WMController(settings: settings)
    }
}
