// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class ShellGestureBoxTests: XCTestCase {
    func testRawScrollAccumulatesButUsesLatestSequenceAndModifiers() throws {
        let box = ShellGestureBox()
        var first = gesture(kind: .scroll, dx: 2, dy: 3)
        let pending = try XCTUnwrap(box.post(first))
        first.sequence = 3
        first.event.shift = true
        XCTAssertNil(box.post(first))
        let taken = try XCTUnwrap(pending.take())
        XCTAssertEqual(taken.event.dx, 4)
        XCTAssertEqual(taken.event.dy, 6)
        XCTAssertTrue(taken.event.shift)
        XCTAssertEqual(taken.sequence, 3)
        XCTAssertNil(pending.take())
    }

    func testGestureTranslationsAndSliderValuesKeepLatestRatherThanSum() throws {
        for kind in [ShellEvent.Kind.gesture, .slider] {
            let box = ShellGestureBox()
            var sample = gesture(kind: kind, dx: 10, dy: 4)
            sample.event.value = 0.25
            let pending = try XCTUnwrap(box.post(sample))
            sample.event.dx = 12
            sample.event.dy = 5
            sample.event.value = 0.75
            sample.event.vx = 14
            XCTAssertNil(box.post(sample))
            let taken = try XCTUnwrap(pending.take())
            XCTAssertEqual(taken.event.dx, 12)
            XCTAssertEqual(taken.event.dy, 5)
            XCTAssertEqual(taken.event.vx, 14)
            XCTAssertEqual(taken.event.value, 0.75)
        }
    }

    func testTerminalBoundaryKeepsOlderWakeFromTakingNextGesture() throws {
        let box = ShellGestureBox()
        let earlier = try XCTUnwrap(box.post(gesture(kind: .gesture, dx: 10, dy: 0)))
        box.seal()
        let later = try XCTUnwrap(box.post(gesture(kind: .gesture, dx: 30, dy: 0)))
        XCTAssertEqual(earlier.take()?.event.dx, 10)
        XCTAssertEqual(later.take()?.event.dx, 30)
    }

    func testDifferentTargetAndMomentumKeepSeparateOrderedWakes() throws {
        let box = ShellGestureBox()
        var sample = gesture(kind: .scroll, dx: 1, dy: 2)
        let first = try XCTUnwrap(box.post(sample))
        sample = ShellGestureBox.Gesture(
            bar: sample.bar,
            view: sample.view,
            action: 9,
            sequence: 2,
            event: sample.event
        )
        let second = try XCTUnwrap(box.post(sample))
        sample.event.momentum = .changed
        let momentum = try XCTUnwrap(box.post(sample))
        XCTAssertEqual(first.take()?.action, 7)
        XCTAssertEqual(second.take()?.event.momentum, ShellEvent.Momentum.none)
        XCTAssertEqual(momentum.take()?.event.momentum, .changed)
    }

    func testOnlyContinuousSamplesAreCoalescible() {
        for kind in [ShellEvent.Kind.scroll, .gesture, .slider] {
            var event = gesture(kind: kind, dx: 1, dy: 1).event
            XCTAssertTrue(event.isGesture)
            for phase in [ShellEvent.Phase.began, .ended, .cancelled] {
                event.phase = phase
                XCTAssertFalse(event.isGesture)
            }
        }
        for kind in [ShellEvent.Kind.click, .key, .hover, .press, .outsidePress] {
            XCTAssertFalse(gesture(kind: kind, dx: 0, dy: 0).event.isGesture)
        }
    }

    private func gesture(kind: ShellEvent.Kind, dx: Double, dy: Double) -> ShellGestureBox.Gesture {
        var event = ShellEvent(button: .none, dx: dx, dy: dy, phase: .changed)
        event.kind = kind
        return ShellGestureBox.Gesture(
            bar: ShellBarKey(monitor: Monitor.ID(displayId: 1)),
            view: .bar,
            action: 7,
            sequence: 1,
            event: event
        )
    }
}
