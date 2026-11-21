// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class InputTapThreadTests: XCTestCase {
    @MainActor
    private final class CapturedDragSink: EventIntakeSink {
        let interpreter: EventInterpreter
        let location: CGPoint
        let delivered: XCTestExpectation

        init(interpreter: EventInterpreter, location: CGPoint, delivered: XCTestExpectation) {
            self.interpreter = interpreter
            self.location = location
            self.delivered = delivered
        }

        func handleIntakeEvent(_ stamped: StampedIntakeEvent) {
            interpreter.handleIntakeEvent(stamped)
            if case let .mouseDragged(button, received) = stamped.event {
                XCTAssertEqual(button, .left)
                XCTAssertEqual(received, location)
                delivered.fulfill()
            }
        }
    }

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
    func testNativeResizeCapturesUnmodifiedAndOptionClicks() {
        let controller = makeController()
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

        XCTAssertTrue(tap.filterSnapshot.capturesNativeResizeBaseline)
        let before = captures
        let excludedModifiers: [CGEventFlags] = [
            .maskCommand,
            .maskShift,
            [.maskAlternate, .maskCommand],
            [.maskAlternate, .maskShift]
        ]
        for modifiers in excludedModifiers {
            click(modifiers: modifiers)
            XCTAssertEqual(captures, before)
        }
        let nativeModifiers: [CGEventFlags] = [[], .maskAlternate]
        for (index, modifiers) in nativeModifiers.enumerated() {
            click(modifiers: modifiers)
            XCTAssertEqual(captures, before + index + 1)
        }
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

        handler.tapInputs.capturedInteractionButton = .left
        XCTAssertEqual(handler.inputTapThread.filterSnapshot.activeCapture, .left)
        XCTAssertTrue(MouseEventHandler.processTapCallback(type: .leftMouseDragged, event: drag))

        let upEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        ))
        XCTAssertTrue(MouseEventHandler.processTapCallback(type: .leftMouseUp, event: upEvent))
        XCTAssertNil(handler.tapInputs.capturedInteractionButton)
        XCTAssertNil(handler.inputTapThread.filterSnapshot.activeCapture)
    }

    @MainActor
    func testCapturedDragOffMainDoesNotWaitForMainThread() async throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        handler.setup()
        handler.beginPerformanceCapture()
        let location = CGPoint(x: 100, y: 100)
        let delivered = expectation(description: "Captured left drag handled by the intake owner")
        let sink = CapturedDragSink(interpreter: controller.eventInterpreter, location: location, delivered: delivered)
        controller.eventIntake.open(sink: sink)
        defer {
            controller.eventIntake.close()
            _ = handler.endPerformanceCapture()
            handler.cleanup()
        }
        handler.tapInputs.capturedInteractionButton = .left
        let windowServerLocation = ScreenCoordinateSpace.toWindowServer(point: location)
        let suppressed = Mutex(false)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { done.signal() }
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: windowServerLocation,
                mouseButton: .left
            ) else { return }
            let result = MouseEventHandler.processTapCallback(type: .leftMouseDragged, event: event)
            suppressed.withLock { $0 = result }
        }
        XCTAssertEqual(done.wait(timeout: .now() + failureBound), .success)
        XCTAssertTrue(suppressed.withLock { $0 })
        XCTAssertEqual(handler.performanceSnapshot()?.cgEvents, 0)

        let delivery = await XCTWaiter.fulfillment(of: [delivered], timeout: failureBound)
        XCTAssertEqual(delivery, .completed)
        withExtendedLifetime(sink) {}
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

        handler.tapInputs.gesturePhase = .committed
        XCTAssertTrue(handler.inputTapThread.filterSnapshot.gestureActiveOrLatched)
        XCTAssertTrue(MouseEventHandler.processTapCallback(type: .scrollWheel, event: scrollEvent))

        handler.tapInputs.gesturePhase = .idle
        handler.tapInputs.consumeTrackpadScrollUntilAllTouchesLift = true
        XCTAssertTrue(handler.inputTapThread.filterSnapshot.gestureActiveOrLatched)
        XCTAssertTrue(MouseEventHandler.processTapCallback(type: .scrollWheel, event: scrollEvent))

        handler.tapInputs.consumeTrackpadScrollUntilAllTouchesLift = false
        handler.inputTapThread.touchCountProvider = { 3 }
        XCTAssertFalse(handler.inputTapThread.filterSnapshot.gestureActiveOrLatched)
        XCTAssertFalse(MouseEventHandler.processTapCallback(type: .scrollWheel, event: scrollEvent))
    }

    @MainActor
    func testTheTapFilterIsPublishedWhenOneOfItsFiveInputsChangesAndOnlyThen() throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        handler.setup()
        defer { handler.cleanup() }
        let tap = handler.inputTapThread
        let published = tap.filterSnapshot.isInputSuppressed
        let unclaimed = try XCTUnwrap(MouseButtonBinding.supportedButtons.first {
            tap.filterSnapshot.claimedOtherButtonMask & (UInt32(1) << $0) == 0
        })
        let changes: [(String, (MouseEventHandler) -> Void)] = [
            ("the captured button", { $0.tapInputs.capturedInteractionButton = .right }),
            ("the captured other button", { $0.tapInputs.capturedOtherMouseButton = unclaimed }),
            ("the gesture phase", { $0.tapInputs.gesturePhase = .armed }),
            ("scroll consumed until lift", { $0.tapInputs.consumeTrackpadScrollUntilAllTouchesLift = true }),
            ("momentum scroll suppressed", { $0.tapInputs.suppressTrackpadMomentumScroll = true })
        ]
        for (name, change) in changes {
            tap.updateFilterSnapshot { $0.isInputSuppressed.toggle() }
            handler.state.leftPressLocation = .zero
            XCTAssertNotEqual(tap.filterSnapshot.isInputSuppressed, published, "other mouse state, before \(name)")

            change(handler)
            XCTAssertEqual(tap.filterSnapshot.isInputSuppressed, published, name)

            tap.updateFilterSnapshot { $0.isInputSuppressed.toggle() }
            change(handler)
            XCTAssertNotEqual(tap.filterSnapshot.isInputSuppressed, published, "\(name) written again unchanged")
            tap.updateFilterSnapshot { $0.isInputSuppressed.toggle() }
        }
        XCTAssertEqual(tap.filterSnapshot.activeCapture, .right)
        XCTAssertNotEqual(tap.filterSnapshot.claimedOtherButtonMask & (UInt32(1) << unclaimed), 0)
        XCTAssertTrue(tap.filterSnapshot.gestureActiveOrLatched)

        handler.tapInputs = TapFilterInputs()
        XCTAssertNil(tap.filterSnapshot.activeCapture)
        XCTAssertEqual(tap.filterSnapshot.claimedOtherButtonMask & (UInt32(1) << unclaimed), 0)
        XCTAssertFalse(tap.filterSnapshot.gestureActiveOrLatched)
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
