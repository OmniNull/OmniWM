// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics
import Foundation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class EventTapTeardownTests: XCTestCase {
    private struct Fixture {
        let tap: CFMachPort
        let source: CFRunLoopSource
    }

    func testTeardownOrdersOperationsAndClearsReferences() throws {
        var tap: CFMachPort? = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
        var source: CFRunLoopSource? = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        var operations: [String] = []

        for _ in 0 ..< 2 {
            EventTapTeardown.tearDown(
                tap: &tap,
                runLoopSource: &source,
                operations: EventTapTeardownOperations(
                    disableTap: { _ in operations.append("disable") },
                    removeRunLoopSource: { _, _, _ in operations.append("remove") },
                    invalidateTap: { _ in operations.append("invalidate") }
                )
            )
        }

        XCTAssertEqual(operations, ["disable", "remove", "invalidate"])
        XCTAssertNil(tap)
        XCTAssertNil(source)
    }

    func testLiveTeardownInvalidatesAndUnschedules() throws {
        let fixture = try makeFixture()
        var tap: CFMachPort? = fixture.tap
        var source: CFRunLoopSource? = fixture.source

        EventTapTeardown.tearDown(tap: &tap, runLoopSource: &source)

        XCTAssertFalse(CFMachPortIsValid(fixture.tap))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.source, .commonModes))
        XCTAssertNil(tap)
        XCTAssertNil(source)
    }

    func testMouseCleanupInvalidatesBothTaps() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "EventTapTeardownMouse")
        let handler = controller.mouseEventHandler
        let move = try makeFixture()
        let session = try makeFixture()
        handler.state.moveTap = move.tap
        handler.state.moveTapRunLoopSource = move.source
        handler.state.eventTap = session.tap
        handler.state.runLoopSource = session.source

        handler.cleanup()

        XCTAssertFalse(CFMachPortIsValid(move.tap))
        XCTAssertFalse(CFMachPortIsValid(session.tap))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), move.source, .commonModes))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), session.source, .commonModes))
    }

    func testHotkeyStopInvalidatesTap() throws {
        let fixture = try makeFixture()
        let hotkeys = HotkeyCenter()
        hotkeys.hyperTriggerTap = fixture.tap
        hotkeys.hyperTriggerRunLoopSource = fixture.source

        hotkeys.stopHyperTriggerTap()

        XCTAssertFalse(CFMachPortIsValid(fixture.tap))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.source, .commonModes))
        XCTAssertNil(hotkeys.hyperTriggerTap)
        XCTAssertNil(hotkeys.hyperTriggerRunLoopSource)
    }

    func testExternalSwitcherUsesATailTapAndKeepsItUntilItsLastKeyUp() async throws {
        let hotkeys = HotkeyCenter()
        let shortcut = try makeFixture()
        hotkeys.hyperTriggerTap = shortcut.tap
        hotkeys.hyperTriggerRunLoopSource = shortcut.source
        let externalTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
        var callback: CGEventTapCallBack?
        var context: UnsafeMutableRawPointer?
        let generation = try XCTUnwrap(hotkeys.beginExternalWindowSwitcherSession(holding: .maskAlternate) {
            location, placement, options, mask, handler, userInfo in
            XCTAssertEqual(location, .cgSessionEventTap)
            XCTAssertEqual(placement, .tailAppendEventTap)
            XCTAssertEqual(options, .defaultTap)
            XCTAssertNotEqual(mask & (1 << CGEventType.flagsChanged.rawValue), 0)
            callback = handler
            context = userInfo
            return externalTap
        })
        let handle = try XCTUnwrap(callback)
        let proxy = OpaquePointer(Unmanaged.passUnretained(externalTap).toOpaque())
        var actions: [WindowSwitcherAction] = []
        hotkeys.onWindowSwitcherAction = { action, _ in actions.append(action) }
        let press = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_W), keyDown: true))
        press.flags = .maskAlternate

        XCTAssertNotNil(hotkeys.handleHyperTriggerEvent(type: .keyDown, event: press))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertNil(handle(proxy, .keyDown, press, context))
        XCTAssertEqual(actions, [.close])
        hotkeys.cancelWindowSwitcherSession(generation: generation)
        XCTAssertTrue(CFMachPortIsValid(externalTap))
        XCTAssertNotNil(hotkeys.handleHyperTriggerEvent(type: .keyUp, event: press))
        XCTAssertNil(handle(proxy, .keyUp, press, context))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertFalse(CFMachPortIsValid(externalTap))
        XCTAssertNil(hotkeys.externalWindowSwitcherTap)
        XCTAssertTrue(CFMachPortIsValid(shortcut.tap))
    }

    func testExternalSwitcherCommitsWhenHyperConsumesTheModifierRelease() throws {
        let hotkeys = HotkeyCenter()
        hotkeys.start()
        defer { hotkeys.stop() }
        hotkeys.hyperTrigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_Control)), capsLockRemapped: false)
        hotkeys.windowSwitcherInput.beginExternalSession(holding: .maskControl)
        var actions: [WindowSwitcherAction] = []
        hotkeys.onWindowSwitcherAction = { action, _ in actions.append(action) }
        let release = try XCTUnwrap(CGEvent(source: nil))
        release.type = .flagsChanged
        release.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Control))
        release.flags = []

        XCTAssertNil(hotkeys.handleHyperTriggerEvent(type: .flagsChanged, event: release))
        XCTAssertEqual(actions, [.commit])
        XCTAssertFalse(hotkeys.windowSwitcherInput.isActive)
    }

    func testUnstartedHotkeyDestructionOnMainActorCleansUpImmediately() throws {
        let fixture = try makeFixture()
        let destruction = HotkeyDestructionRecord()
        let owner = makeHotkeyOwner(fixture: fixture, destruction: destruction)

        owner.withLock { $0 = nil }

        XCTAssertTrue(destruction.wasOnMainThread.withLock { $0 })
        XCTAssertFalse(CFMachPortIsValid(fixture.tap))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.source, .commonModes))
    }

    func testUnstartedHotkeyDestructionAfterDetachedFinalReleaseCleansUpOnMainActor() async throws {
        let fixture = try makeFixture()
        let destruction = HotkeyDestructionRecord()
        let owner = makeHotkeyOwner(fixture: fixture, destruction: destruction)

        let releasedOnMainThread = await Task.detached {
            owner.withLock { center in
                center = nil
                return Thread.isMainThread
            }
        }.value
        await fulfillment(of: [destruction.completed], timeout: failureBound)

        XCTAssertFalse(releasedOnMainThread)
        XCTAssertTrue(destruction.wasOnMainThread.withLock { $0 })
        XCTAssertFalse(CFMachPortIsValid(fixture.tap))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.source, .commonModes))
    }

    func testRepeatedHotkeyStopBeforeDetachedDestructionKeepsResourcesReleased() async throws {
        let fixture = try makeFixture()
        let destruction = HotkeyDestructionRecord()
        let owner = makeHotkeyOwner(fixture: fixture, destruction: destruction, start: true)
        owner.withLock { center in
            center?.stop()
            center?.stop()
            XCTAssertNil(center?.hyperTriggerTap)
            XCTAssertNil(center?.hyperTriggerRunLoopSource)
        }
        XCTAssertFalse(CFMachPortIsValid(fixture.tap))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.source, .commonModes))

        let releasedOnMainThread = await Task.detached {
            owner.withLock { center in
                center = nil
                return Thread.isMainThread
            }
        }.value
        await fulfillment(of: [destruction.completed], timeout: failureBound)

        XCTAssertFalse(releasedOnMainThread)
        XCTAssertTrue(destruction.wasOnMainThread.withLock { $0 })
        XCTAssertFalse(CFMachPortIsValid(fixture.tap))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.source, .commonModes))
    }

    private func makeHotkeyOwner(
        fixture: Fixture,
        destruction: HotkeyDestructionRecord,
        start: Bool = false
    ) -> Mutex<HotkeyCenter?> {
        let center = HotkeyCenter()
        center.updateBindings([], systemHyperTrigger: .none)
        if start {
            center.start()
        }
        center.hyperTriggerTap = fixture.tap
        center.hyperTriggerRunLoopSource = fixture.source
        let witness = HotkeyDestructionWitness(record: destruction)
        center.onCommand = { [witness] _ in
            withExtendedLifetime(witness) {}
        }
        return Mutex(center)
    }

    private func makeFixture() throws -> Fixture {
        let tap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
        let source = try XCTUnwrap(CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0))
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return Fixture(tap: tap, source: source)
    }
}

private final class HotkeyDestructionRecord: Sendable {
    let completed = XCTestExpectation(description: "HotkeyCenter stored properties destroyed")
    let wasOnMainThread = Mutex(false)
}

private final class HotkeyDestructionWitness: Sendable {
    private let record: HotkeyDestructionRecord

    init(record: HotkeyDestructionRecord) {
        self.record = record
    }

    deinit {
        record.wasOnMainThread.withLock { $0 = Thread.isMainThread }
        record.completed.fulfill()
    }
}
