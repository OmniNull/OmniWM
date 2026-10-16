// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import OmniWMShellCore
import XCTest

final class ShellGestureTests: XCTestCase {
    private let outer = ElementHandle(slot: 0, generation: 1)
    private let inner = ElementHandle(slot: 1, generation: 1)

    private func candidate(
        _ handle: ElementHandle,
        axis: ShellGestureConfig.Axis,
        all: Bool = false
    ) -> ShellPointerGesture.Candidate {
        var configuration = ShellGestureConfig()
        configuration.axis = axis
        configuration.eventsAll = all
        return ShellPointerGesture.Candidate(handle: handle, configuration: configuration)
    }

    func testThresholdAndDominanceSelectInnermostMatchingAncestor() {
        let candidates = [candidate(outer, axis: .y), candidate(inner, axis: .x)]
        var horizontal = ShellPointerGesture(candidates: candidates, origin: .zero, source: .pointer, timestamp: 0)
        XCTAssertNil(horizontal.update(at: CGPoint(x: 3.9, y: 0), timestamp: 0.01))
        XCTAssertEqual(horizontal.update(at: CGPoint(x: 4, y: 0), timestamp: 0.02)?.handle, inner)
        var vertical = ShellPointerGesture(candidates: candidates, origin: .zero, source: .pointer, timestamp: 0)
        XCTAssertNil(vertical.update(at: CGPoint(x: 4, y: 4), timestamp: 0.01))
        XCTAssertEqual(vertical.update(at: CGPoint(x: 4, y: 5), timestamp: 0.02)?.handle, outer)
        var free = ShellPointerGesture(
            candidates: [candidate(outer, axis: .y), candidate(inner, axis: .free)],
            origin: .zero,
            source: .pointer,
            timestamp: 0
        )
        XCTAssertEqual(free.update(at: CGPoint(x: 3, y: 3), timestamp: 0.01)?.handle, inner)
    }

    func testAxisLocksBeforeGestureThresholdAndCaptureSurvivesOutsideBounds() {
        var gesture = ShellPointerGesture(
            candidates: [candidate(outer, axis: .y), candidate(inner, axis: .x)],
            origin: .zero,
            source: .pointer,
            timestamp: 0
        )
        XCTAssertNil(gesture.update(at: CGPoint(x: 2, y: 0), timestamp: 0.01))
        XCTAssertNil(gesture.update(at: CGPoint(x: 2, y: 8), timestamp: 0.02))
        XCTAssertEqual(gesture.update(at: CGPoint(x: 5, y: 9), timestamp: 0.03)?.handle, inner)
        let end = gesture.end(at: CGPoint(x: 2000, y: -3000), timestamp: 1)
        XCTAssertEqual(end?.handle, inner)
        XCTAssertEqual(end?.translation, CGPoint(x: 2000, y: -3000))
        XCTAssertEqual(end?.phase, .ended)
    }

    func testChangedIsOptInAndTranslationRemainsCumulative() {
        for all in [false, true] {
            var gesture = ShellPointerGesture(
                candidates: [candidate(inner, axis: .x, all: all)],
                origin: CGPoint(x: 10, y: 20),
                source: .pointer,
                timestamp: 0
            )
            XCTAssertEqual(gesture.update(at: CGPoint(x: 14, y: 20), timestamp: 0.01)?.phase, .began)
            let changed = gesture.update(at: CGPoint(x: 19, y: 20), timestamp: 0.02)
            XCTAssertEqual(changed?.phase, all ? .changed : nil)
            if all { XCTAssertEqual(changed?.translation, CGPoint(x: 9, y: 0)) }
            XCTAssertEqual(gesture.end(at: CGPoint(x: 25, y: 20), timestamp: 0.03)?.translation, CGPoint(x: 15, y: 0))
        }
    }

    func testCommitUsesEnabledDirectionalDistanceOrReleaseVelocity() {
        var configuration = ShellGestureConfig()
        configuration.axis = .y
        configuration.direction = .up
        configuration.commitDistance = 50
        configuration.commitVelocity = 150
        let candidate = ShellPointerGesture.Candidate(handle: inner, configuration: configuration)
        var gesture = ShellPointerGesture(candidates: [candidate], origin: .zero, source: .pointer, timestamp: 0)
        XCTAssertNil(gesture.update(at: CGPoint(x: 0, y: -3), timestamp: 0.01))
        XCTAssertEqual(gesture.update(at: CGPoint(x: 0, y: -5), timestamp: 0.02)?.phase, .began)
        XCTAssertEqual(gesture.end(at: CGPoint(x: 0, y: -6), timestamp: 0.025)?.committed, true)
        XCTAssertEqual(gesture.end(at: CGPoint(x: 0, y: -6), timestamp: 1)?.committed, false)
        XCTAssertEqual(gesture.end(at: CGPoint(x: 0, y: -60), timestamp: 1)?.committed, true)
        XCTAssertEqual(gesture.end(at: CGPoint(x: 0, y: 60), timestamp: 1)?.committed, false)
        let cancel = gesture.end(at: CGPoint(x: 0, y: -60), timestamp: 1, cancelled: true)
        XCTAssertEqual(cancel?.phase, .cancelled)
        XCTAssertEqual(cancel?.committed, false)
    }

    func testEachCandidateHonorsItsOwnAxisLockDeclaration() {
        var configuration = ShellGestureConfig()
        configuration.axis = .x
        configuration.lockDistance = 100
        var gesture = ShellPointerGesture(
            candidates: [
                candidate(outer, axis: .y),
                ShellPointerGesture.Candidate(handle: inner, configuration: configuration)
            ],
            origin: .zero, source: .pointer, timestamp: 0
        )
        XCTAssertNil(gesture.update(at: CGPoint(x: 4, y: 0), timestamp: 0.01))
        XCTAssertTrue(gesture.canClaim)
        XCTAssertEqual(gesture.update(at: CGPoint(x: 101, y: 0), timestamp: 0.02)?.handle, inner)
        configuration.lockDistance = 1
        configuration.dominance = 2
        gesture = ShellPointerGesture(
            candidates: [
                candidate(outer, axis: .y),
                ShellPointerGesture.Candidate(handle: inner, configuration: configuration)
            ],
            origin: .zero, source: .pointer, timestamp: 0
        )
        XCTAssertNil(gesture.update(at: CGPoint(x: 6, y: 4), timestamp: 0.01))
        XCTAssertEqual(gesture.update(at: CGPoint(x: 9, y: 4), timestamp: 0.02)?.handle, inner)
    }
}
