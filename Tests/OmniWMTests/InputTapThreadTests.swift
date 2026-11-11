// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import Synchronization
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
        let incoherentSnapshots = Mutex(0)
        thread.updateFilterSnapshot {
            $0.activeCapture = .left
            $0.gestureActiveOrLatched = true
        }
        let initial = thread.filterSnapshot
        XCTAssertEqual(initial.activeCapture, .left)
        XCTAssertTrue(initial.gestureActiveOrLatched)

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
                    let snapshot = thread.filterSnapshot
                    if !((snapshot.activeCapture == .left && snapshot.gestureActiveOrLatched)
                        || (snapshot.activeCapture == nil && !snapshot.gestureActiveOrLatched))
                    {
                        incoherentSnapshots.withLock { $0 += 1 }
                    }
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(incoherentSnapshots.withLock { $0 }, 0)
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
    func testNativeResizeCapturesWindowFramesOnlyForEnabledUnmodifiedClicks() {
        let controller = makeController()
        controller.settings.gestures.mouseMoveModifierKey = .option
        let handler = controller.mouseEventHandler
        handler.setup()
        defer { handler.cleanup() }
        let tap = handler.inputTapThread
        let location = CGPoint(x: 100, y: 100)
        var captures = 0

        func click(modifiers: CGEventFlags = []) {
            tap.evaluateLeftMouseDown(at: location, modifiers: modifiers, timestamp: 0, snapshot: tap.filterSnapshot) {
                captures += 1
                return [:]
            }
        }

        click()
        XCTAssertEqual(captures, 0)

        controller.settings.gestures.adoptNativeResize = true
        click(modifiers: .maskCommand)
        XCTAssertEqual(captures, 0)

        click()
        XCTAssertEqual(captures, 1)

        controller.settings.gestures.adoptNativeResize = false
        click()
        XCTAssertEqual(captures, 1)
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
    func testCapturedDragOffMainDoesNotWaitForMainThread() throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        handler.setup()
        handler.beginPerformanceCapture()
        defer {
            _ = handler.endPerformanceCapture()
            handler.cleanup()
        }
        handler.state.capturedInteractionButton = .right

        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let drag = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .rightMouseDragged,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .right
        ))
        let suppressed = Mutex(false)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let event = drag
        Thread.detachNewThread {
            let result = MouseEventHandler.processTapCallback(type: .rightMouseDragged, event: event)
            suppressed.withLock { $0 = result }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(suppressed.withLock { $0 })

        let drained = expectation(description: "main drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: failureBound)
        XCTAssertEqual(handler.performanceSnapshot()?.cgEvents, 1)
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
        handler.beginPerformanceCapture()
        defer {
            _ = handler.endPerformanceCapture()
            handler.cleanup()
        }

        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .otherMouseDown,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .center
        ))
        event.setIntegerValueField(.mouseEventButtonNumber, value: 5)

        XCTAssertFalse(MouseEventHandler.processTapCallback(type: .otherMouseDown, event: event))
        XCTAssertEqual(handler.performanceSnapshot()?.cgEvents, 0)

        handler.inputTapThread.updateFilterSnapshot { $0.claimedOtherButtonMask = UInt32(1) << 5 }
        XCTAssertFalse(MouseEventHandler.processTapCallback(type: .otherMouseDown, event: event))
        XCTAssertEqual(handler.performanceSnapshot()?.cgEvents, 1)
    }

    @MainActor
    func testOtherMouseButtonNumbersOutsideSupportedRangePassThrough() throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        handler.setup()
        handler.beginPerformanceCapture()
        defer {
            _ = handler.endPerformanceCapture()
            handler.cleanup()
        }

        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .otherMouseDown,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .center
        ))
        handler.inputTapThread.updateFilterSnapshot { $0.claimedOtherButtonMask = .max }
        for button in [Int64.min, -1, 0, 1, 32, 33, Int64.max] {
            event.setIntegerValueField(.mouseEventButtonNumber, value: button)
            XCTAssertFalse(MouseEventHandler.processTapCallback(type: .otherMouseDown, event: event))
        }
        XCTAssertEqual(handler.performanceSnapshot()?.cgEvents, 0)
    }

    func testSessionTapPublicationIsClearedByStop() throws {
        let thread = InputTapThread()
        _ = thread.startAndGetRunLoop()
        let port = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil))
        thread.sessionTap = port
        XCTAssertTrue(thread.sessionTap === port)
        thread.stop()
        XCTAssertNil(thread.sessionTap)
    }

    @MainActor
    func testSessionTapIsPublishedToTheInputThreadUntilCleanup() {
        let handler = makeController().mouseEventHandler
        handler.setup()
        XCTAssertTrue(handler.inputTapThread.sessionTap === handler.state.eventTap)
        handler.cleanup()
        XCTAssertNil(handler.inputTapThread.sessionTap)
    }

    func testSessionTapCallbackReturnsEventsOffTheMainThread() {
        let returned = Mutex<[Bool]>([])
        let done = expectation(description: "Session tap callback returned off the main thread")
        Thread.detachNewThread {
            for type in [CGEventType.tapDisabledByUserInput, .tapDisabledByTimeout, .null] {
                guard let event = CGEvent(source: nil) else { continue }
                let result = MouseEventHandler.sessionTapCallback(OpaquePointer(bitPattern: 1)!, type, event, nil)
                returned.withLock { $0.append(result?.takeUnretainedValue() === event) }
            }
            done.fulfill()
        }
        wait(for: [done], timeout: failureBound)
        XCTAssertEqual(returned.withLock { $0 }, [true, true, true])
    }

    @MainActor
    private func makeController() -> WMController {
        InputControllerTestSupport.controller(for: self)
    }
}
