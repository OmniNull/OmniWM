// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class ParkingEdgeRepeatTests: XCTestCase {
    private typealias Fixture = ParkingEdgeInteractionTests.Fixture

    @MainActor private final class Interval {
        var value = 0.25
        var reads = 0

        func read() -> TimeInterval {
            reads += 1
            return value
        }
    }

    private func arm(_ fixture: Fixture, action: () -> Void) async throws -> Task<Void, Never> {
        let started = expectation(description: "Navigation interval armed")
        fixture.dwell.onStart = { started.fulfill() }
        action()
        let task = try XCTUnwrap(try fixture.window().dwellTask)
        await fulfillment(of: [started], timeout: failureBound)
        fixture.dwell.onStart = nil
        return task
    }

    private func progressAnimation(_ fixture: Fixture) throws -> CAAnimation? {
        try fixture.fin().contentView?.layer?.sublayers?.compactMap {
            $0.animation(forKey: "parkingEdge.dwell")
        }.first
    }

    private func click(_ window: ParkingEdgeMaskWindow) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 0.5, y: 400), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        window.contentView?.mouseDown(with: event)
    }

    func testRepeatsSampleCurrentIntervalOnceAndAnimateForTheSameDuration() async throws {
        let fixture = try Fixture.make(hover: true)
        defer { fixture.destroy() }
        let window = try fixture.window()
        let interval = Interval()
        fixture.manager.navigationInterval = { interval.read() }
        for (index, value) in [0.25, 0.75, 2.0].enumerated() {
            interval.value = value
            let mask = fixture.mask(hover: true, target: index + 1)
            let task = try await arm(fixture) {
                if index == 0 {
                    window.updateHover()
                } else {
                    fixture.manager.apply([mask])
                }
            }
            fixture.manager.apply([mask])
            window.updateHover()
            XCTAssertEqual(interval.reads, index + 1)
            XCTAssertEqual(fixture.dwell.durations.last, .seconds(value))
            XCTAssertEqual(try XCTUnwrap(progressAnimation(fixture)).duration, value)
            XCTAssertEqual(fixture.activations, index)
            fixture.dwell.complete()
            await task.value
            XCTAssertEqual(fixture.activations, index + 1)
            XCTAssertNil(window.dwellTask)
            XCTAssertNil(try progressAnimation(fixture))
        }
        XCTAssertEqual(fixture.dwell.durations.count, 3)
    }

    func testClickCancelsPendingDwellAndFreshTargetStartsAFullInterval() async throws {
        let fixture = try Fixture.make(hover: true)
        defer { fixture.destroy() }
        let window = try fixture.window()
        fixture.manager.navigationInterval = { 0.5 }
        let oldTask = try await arm(fixture) { window.updateHover() }
        try click(window)
        XCTAssertEqual(fixture.activations, 1)
        XCTAssertNil(window.dwellTask)
        let newTask = try await arm(fixture) {
            fixture.manager.apply([fixture.mask(hover: true, target: 2)])
        }
        XCTAssertEqual(fixture.dwell.durations, [.milliseconds(500), .milliseconds(500)])
        XCTAssertEqual(try XCTUnwrap(progressAnimation(fixture)).duration, 0.5)
        fixture.dwell.complete()
        await oldTask.value
        XCTAssertEqual(fixture.activations, 1)
        XCTAssertNotNil(window.dwellTask)
        fixture.dwell.complete()
        await newTask.value
        XCTAssertEqual(fixture.activations, 2)
    }

    func testHiddenFinClickDoesNotStartRepeatUntilPointerReenters() async throws {
        for revealFirst in [false, true] {
            let fixture = try Fixture.make(hover: true)
            defer { fixture.destroy() }
            let window = try fixture.window()
            if revealFirst {
                fixture.manager.apply([fixture.mask(hover: false)])
                window.updateHover()
                XCTAssertTrue(try fixture.fin().isVisible)
            }
            var endpoint = fixture.mask(hover: true)
            endpoint.navigation = nil
            fixture.manager.apply([endpoint])
            window.updateHover()
            fixture.manager.apply([fixture.mask(hover: true)])
            try click(window)
            XCTAssertEqual(fixture.activations, 1)
            fixture.manager.apply([fixture.mask(hover: true, target: 2)])
            XCTAssertNil(window.dwellTask)
            if let unexpected = window.dwellTask {
                let started = expectation(description: "Unexpected hidden dwell armed")
                fixture.dwell.onStart = { started.fulfill() }
                await fulfillment(of: [started], timeout: failureBound)
                fixture.dwell.onStart = nil
                fixture.dwell.complete()
                await unexpected.value
            }
            XCTAssertEqual(fixture.activations, 1)
            XCTAssertTrue(fixture.dwell.durations.isEmpty)
            XCTAssertFalse(SurfaceCoordinator.shared.visibleSurfaceIDs(kind: .parkingEdgeMask).contains(
                "parking-edge-fin-989001-left"
            ))
            fixture.pointer.x -= 40
            window.updateHover()
            fixture.pointer.x += 40
            let resumed = try await arm(fixture) { window.updateHover() }
            XCTAssertTrue(try fixture.fin().isVisible)
            XCTAssertEqual(try XCTUnwrap(progressAnimation(fixture)).duration, 1.5)
            fixture.dwell.complete()
            await resumed.value
            XCTAssertEqual(fixture.activations, 2)
        }
    }

    func testPolicySuspensionCancelsAndResumeStartsAFreshIntervalWithoutDuplicatingTasks() async throws {
        let fixture = try Fixture.make(hover: true)
        defer { fixture.destroy() }
        let window = try fixture.window()
        let mask = fixture.mask(hover: true)
        let oldTask = try await arm(fixture) { window.updateHover() }
        fixture.allowed = false
        fixture.manager.apply([mask])
        XCTAssertNil(window.dwellTask)
        XCTAssertNil(try progressAnimation(fixture))
        fixture.allowed = true
        let newTask = try await arm(fixture) { fixture.manager.apply([mask]) }
        fixture.manager.apply([mask])
        XCTAssertEqual(fixture.dwell.durations, [.milliseconds(1500), .milliseconds(1500)])
        fixture.dwell.complete()
        await oldTask.value
        XCTAssertEqual(fixture.activations, 0)
        XCTAssertNotNil(window.dwellTask)
        XCTAssertEqual(try XCTUnwrap(progressAnimation(fixture)).duration, 1.5)
        fixture.dwell.complete()
        await newTask.value
        XCTAssertEqual(fixture.activations, 1)
    }

    func testRejectedActivationDoesNotPollOrRepeatWhilePointerRemainsInside() async throws {
        let fixture = try Fixture.make(hover: true)
        defer { fixture.destroy() }
        let window = try fixture.window()
        fixture.manager.onActivate = { [weak fixture] _, _ in
            fixture?.activations += 1
            return false
        }
        let task = try await arm(fixture) { window.updateHover() }
        fixture.dwell.complete()
        await task.value
        fixture.manager.apply([fixture.mask(hover: true, target: 2)])
        window.updateHover()
        XCTAssertEqual(fixture.activations, 1)
        XCTAssertNil(window.dwellTask)
        XCTAssertEqual(fixture.dwell.durations.count, 1)
        fixture.pointer.x -= 40
        window.updateHover()
        fixture.pointer.x += 40
        let reentered = try await arm(fixture) { window.updateHover() }
        fixture.dwell.complete()
        await reentered.value
        XCTAssertEqual(fixture.activations, 2)
    }

    func testWorkspaceEndFrameChangeOrRemovalCancelsPendingRepeat() async throws {
        for change in 0 ..< 4 {
            let fixture = try Fixture.make(hover: true)
            defer { fixture.destroy() }
            let window = try fixture.window()
            let first = try await arm(fixture) { window.updateHover() }
            fixture.dwell.complete()
            await first.value
            let second = try await arm(fixture) {
                fixture.manager.apply([fixture.mask(hover: true, target: 2)])
            }
            var mask = fixture.mask(hover: true, target: 2)
            switch change {
            case 0:
                mask.navigation = .init(
                    workspaceId: .init(), target: .init(pid: 989_001, windowId: 3), hoverEnabled: true
                )
            case 1:
                mask.navigation = nil
            case 2:
                mask = .init(key: mask.key, frame: mask.frame.offsetBy(dx: 2, dy: 0), navigation: mask.navigation)
            default:
                fixture.manager.removeAll()
            }
            if change < 3 {
                fixture.manager.apply([mask])
            }
            XCTAssertNil(window.dwellTask)
            fixture.dwell.complete()
            await second.value
            XCTAssertEqual(fixture.activations, 1)
            XCTAssertEqual(fixture.dwell.durations.count, 2)
            XCTAssertNil(window.dwellTask)
        }
    }

    func testSynchronousTargetAcknowledgementStartsNextInterval() async throws {
        let fixture = try Fixture.make(hover: true)
        defer { fixture.destroy() }
        let window = try fixture.window()
        fixture.manager.onActivate = { [weak fixture] _, _ in
            guard let fixture else { return false }
            fixture.activations += 1
            var mask = fixture.mask(hover: true, target: 2)
            if fixture.activations == 2 {
                mask.navigation = nil
            }
            fixture.manager.apply([mask])
            return true
        }
        let first = try await arm(fixture) { window.updateHover() }
        let repeated = expectation(description: "Synchronous target armed")
        fixture.dwell.onStart = { repeated.fulfill() }
        fixture.dwell.complete()
        await first.value
        let second = try XCTUnwrap(window.dwellTask)
        await fulfillment(of: [repeated], timeout: failureBound)
        fixture.dwell.onStart = nil
        XCTAssertEqual(fixture.activations, 1)
        XCTAssertEqual(fixture.dwell.durations, [.milliseconds(1500), .milliseconds(1500)])
        fixture.dwell.complete()
        await second.value
        XCTAssertEqual(fixture.activations, 2)
        XCTAssertNil(window.dwellTask)
    }

    func testActivationCallbackCanSynchronouslyRemoveMask() async throws {
        let fixture = try Fixture.make(hover: true)
        defer { fixture.destroy() }
        let window = try fixture.window()
        fixture.manager.onActivate = { [weak fixture] _, _ in
            fixture?.activations += 1
            fixture?.manager.removeAll()
            return true
        }
        let task = try await arm(fixture) { window.updateHover() }
        fixture.dwell.complete()
        await task.value
        XCTAssertEqual(fixture.activations, 1)
        XCTAssertNil(window.dwellTask)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(SurfaceCoordinator.shared.visibleSurfaceIDs(kind: .parkingEdgeMask).contains(
            "parking-edge-fin-989001-left"
        ))
    }
}
