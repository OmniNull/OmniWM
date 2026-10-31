// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import Synchronization
import XCTest

private final class PointRecorder: Sendable {
    let points = Mutex<[CGPoint]>([])

    var all: [CGPoint] {
        points.withLock { $0 }
    }

    func record(_ point: CGPoint) {
        points.withLock { $0.append(point) }
    }
}

@MainActor
final class PointerEdgeBarrierTests: XCTestCase {
    private let main = monitor(1, CGRect(x: 0, y: 0, width: 2560, height: 1440))
    private let staircase = monitor(2, CGRect(x: 2560, y: 1440, width: 1920, height: 1080))
    private let adjoining = monitor(3, CGRect(x: 2560, y: 0, width: 1920, height: 1440))
    private let above = monitor(4, CGRect(x: 0, y: 1440, width: 2560, height: 1440))
    private let bottom = monitor(5, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let top = monitor(6, CGRect(x: 0, y: 1080, width: 1920, height: 1080))
    private var clock: UInt64 = 1_000_000_000

    private static func monitor(_ id: CGDirectDisplayID, _ frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: id),
            displayId: id,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "M\(id)"
        )
    }

    private func topology(_ other: Monitor, margin: CGFloat = 1, fin: Bool = true) -> PointerEdgeTopology {
        var topology = PointerEdgeTopology()
        topology.isEnabled = true
        topology.margin = margin
        topology.flipY = 1440
        topology.monitors = [main, other]
        topology.edges[.init(monitorId: main.id, direction: .right)] = .init(
            target: other,
            finSpan: fin ? CGRect(x: 2559, y: 0, width: 1, height: 1440) : nil
        )
        return topology
    }

    private func stackedButRoutedSideBySide() -> PointerEdgeTopology {
        var topology = PointerEdgeTopology()
        topology.isEnabled = true
        topology.flipY = 1080
        topology.monitors = [bottom, top]
        topology.containment = MouseContainment(
            layout: [
                MonitorRoutingSettings(monitorName: "M5", monitorDisplayId: 5, gridColumn: 0, gridRow: 0),
                MonitorRoutingSettings(monitorName: "M6", monitorDisplayId: 6, gridColumn: 1, gridRow: 0)
            ],
            monitors: [bottom, top]
        )
        return topology
    }

    private func move(
        _ recognizer: inout PointerEdgeRecognizer,
        _ x: CGFloat,
        _ y: CGFloat,
        dx: CGFloat,
        dy: CGFloat = 0,
        after nanoseconds: UInt64 = 8_000_000,
        _ topology: PointerEdgeTopology
    ) -> PointerEdgeRecognizer.Decision {
        clock += nanoseconds
        return recognizer.handle(
            location: CGPoint(x: x, y: y),
            motion: CGVector(dx: dx, dy: dy),
            timestamp: clock,
            topology: topology
        )
    }

    private func moveEvent(_ cgPoint: CGPoint) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cgPoint, mouseButton: .left
        ))
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return event
    }

    func testTheTapTakesLeftDragsOnlyForNaturalWindowDrag() {
        let moved: CGEventMask = 1 << CGEventType.mouseMoved.rawValue
        let dragged: CGEventMask = 1 << CGEventType.leftMouseDragged.rawValue
        XCTAssertEqual(PointerEdgeBarrier.eventsOfInterest(tracksLiveDrags: false), moved)
        XCTAssertEqual(PointerEdgeBarrier.eventsOfInterest(tracksLiveDrags: true), moved | dragged)
    }

    func testPinnedEdgeExcludesArrivalAndCrossesOnceAtNetPressure() throws {
        let topology = topology(staircase)
        var recognizer = PointerEdgeRecognizer()
        XCTAssertEqual(move(&recognizer, 2500, 700, dx: 10, topology), .pass)
        XCTAssertEqual(move(&recognizer, 2559.5, 700, dx: 80, topology), .pass)
        XCTAssertEqual(recognizer.hold?.pressure, 0)
        for _ in 0 ..< 9 {
            XCTAssertEqual(move(&recognizer, 2559.5, 700, dx: 10, topology), .pass)
        }
        guard case let .cross(crossing) = move(&recognizer, 2559.5, 700, dx: 10, topology) else {
            return XCTFail("expected crossing at threshold")
        }
        XCTAssertEqual(crossing.source, main.id)
        XCTAssertEqual(crossing.target.id, staircase.id)
        XCTAssertTrue(crossing.pushed)
        recognizer.noteCursorMoved(to: crossing.destination, monitor: crossing.target.id, at: clock)
        XCTAssertNil(recognizer.hold)
    }

    func testAdjoiningEdgeClampsNativeCrossingAndCountsPushedDistance() {
        let topology = topology(adjoining)
        var recognizer = PointerEdgeRecognizer()
        XCTAssertEqual(move(&recognizer, 2555, 700, dx: 5, topology), .pass)
        XCTAssertEqual(move(&recognizer, 2565, 700, dx: 10, topology), .clamp(CGPoint(x: 2559.5, y: 700)))
        XCTAssertEqual(move(&recognizer, 2609.5, 700, dx: 50, topology), .clamp(CGPoint(x: 2559.5, y: 700)))
        XCTAssertEqual(recognizer.hold?.pressure, 50)
        guard case .cross = move(&recognizer, 2609.5, 700, dx: 50, topology) else {
            return XCTFail("expected crossing at threshold")
        }
    }

    func testWideMarginAdjustmentAddsNothingAndInwardMovementSubtracts() {
        let topology = topology(staircase, margin: 10)
        var recognizer = PointerEdgeRecognizer()
        _ = move(&recognizer, 2551, 700, dx: 1, topology)
        for (x, dx) in [(2555.0, 4.0), (2551, -4), (2555, 4), (2551, -4), (2559.5, 8.5)] {
            XCTAssertEqual(move(&recognizer, x, 700, dx: dx, topology), .pass)
        }
        XCTAssertEqual(recognizer.hold?.pressure, 0)
        _ = move(&recognizer, 2559.5, 700, dx: 40, topology)
        XCTAssertEqual(recognizer.hold?.pressure, 40)
        _ = move(&recognizer, 2554.5, 700, dx: -5, topology)
        XCTAssertEqual(recognizer.hold?.pressure, 35)
    }

    func testRetreatMissingFinStickyHoldAndJump() {
        let offered = topology(staircase)
        let withdrawn = topology(staircase, fin: false)
        var recognizer = PointerEdgeRecognizer()
        _ = move(&recognizer, 2559.5, 700, dx: 5, offered)
        XCTAssertNotNil(recognizer.hold)
        _ = move(&recognizer, 2540, 700, dx: -19.5, offered)
        XCTAssertNil(recognizer.hold)

        _ = move(&recognizer, 2559.5, 700, dx: 19.5, offered)
        _ = move(&recognizer, 2559.5, 1200, dx: 0, dy: 500, withdrawn)
        XCTAssertNotNil(recognizer.hold)
        _ = move(&recognizer, 1000, 300, dx: 1, offered)
        XCTAssertNil(recognizer.hold)
    }

    func testVerticalHoldAtCornerEntersTargetThroughItsBottomEdge() {
        var topology = PointerEdgeTopology()
        topology.isEnabled = true
        topology.flipY = 1440
        topology.monitors = [main, above]
        topology.edges[.init(monitorId: main.id, direction: .up)] = .init(
            target: above,
            finSpan: CGRect(x: 0, y: 1439, width: 2560, height: 1)
        )
        var recognizer = PointerEdgeRecognizer()
        XCTAssertEqual(move(&recognizer, 20, 1439.5, dx: 0, dy: 1, topology), .pass)
        guard case let .cross(crossing) = move(&recognizer, 0, 1539.5, dx: -20, dy: 100, topology) else {
            return XCTFail("expected crossing at threshold")
        }
        XCTAssertEqual(crossing.target.id, above.id)
        XCTAssertEqual(crossing.destination, CGPoint(x: 16, y: 1442))
    }

    func testEdgeWithoutFinCrossesImmediatelyThenCoolsDown() {
        let topology = topology(staircase, fin: false)
        var recognizer = PointerEdgeRecognizer()
        _ = move(&recognizer, 2500, 700, dx: 10, topology)
        guard case let .cross(crossing) = move(&recognizer, 2559.5, 700, dx: 59.5, topology) else {
            return XCTFail("expected immediate crossing")
        }
        let zone = MouseWarpGeometry.crossing(location: CGPoint(x: 2559.5, y: 700), frame: main.frame, margin: 1)
        XCTAssertFalse(crossing.pushed)
        XCTAssertEqual(crossing.destination, MouseWarpGeometry.destinationPoint(
            on: staircase.frame, entryEdge: zone?.entryEdge ?? .left, ratio: zone?.ratio ?? 0, margin: 1
        ))
        recognizer.noteCursorMoved(to: crossing.destination, monitor: staircase.id, at: clock)
        XCTAssertEqual(move(&recognizer, 2559.5, 700, dx: 0, after: 10_000_000, topology), .pass)
        guard case .cross = move(&recognizer, 2559.5, 700, dx: 0, after: 60_000_000, topology) else {
            return XCTFail("expected crossing after the cooldown")
        }
    }

    func testContainmentWallClampsFreshNativeCrossingAndStaleBaselineAdopts() {
        let topology = stackedButRoutedSideBySide()
        var recognizer = PointerEdgeRecognizer()
        _ = move(&recognizer, 960, 1075, dx: 0, dy: 5, topology)
        XCTAssertEqual(
            move(&recognizer, 960, 1085, dx: 0, dy: 10, topology),
            .wall(CGPoint(x: 960, y: 1078), source: bottom.id, blocked: top.id)
        )

        var stale = PointerEdgeRecognizer()
        _ = move(&stale, 960, 1075, dx: 0, dy: 5, topology)
        XCTAssertEqual(move(&stale, 960, 1085, dx: 0, dy: 10, after: 2_000_000_000, topology), .pass)
        XCTAssertEqual(move(&stale, 960, 1095, dx: 0, dy: 10, topology), .pass)
    }

    func testContainmentWallsDuringCrossingCooldownAndKeepsItsBaseline() {
        let topology = stackedButRoutedSideBySide()
        var recognizer = PointerEdgeRecognizer()
        recognizer.noteCursorMoved(to: CGPoint(x: 2, y: 1096), monitor: top.id, at: clock)
        let wall = PointerEdgeRecognizer.Decision.wall(CGPoint(x: 2, y: 1082), source: top.id, blocked: bottom.id)
        XCTAssertEqual(move(&recognizer, 2, 1079, dx: 0, dy: -17, after: 10_000_000, topology), wall)
        XCTAssertEqual(move(&recognizer, 2, 1079, dx: 0, dy: -3, after: 60_000_000, topology), wall)
    }

    func testProgrammaticMoveEndsHoldAndStartsCooldown() {
        let topology = topology(staircase)
        var recognizer = PointerEdgeRecognizer()
        _ = move(&recognizer, 2559.5, 700, dx: 5, topology)
        XCTAssertNotNil(recognizer.hold)
        recognizer.noteCursorMoved(to: CGPoint(x: 1280, y: 720), monitor: main.id, at: clock)
        XCTAssertNil(recognizer.hold)
        XCTAssertEqual(move(&recognizer, 2559.5, 700, dx: 5, after: 10_000_000, topology), .pass)
        XCTAssertNil(recognizer.hold)
    }

    private func dragEvent(_ cgPoint: CGPoint, dx: CGFloat) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: cgPoint, mouseButton: .left
        ))
        event.setDoubleValueField(.mouseEventDeltaX, value: dx)
        return event
    }

    private final class StepClock: Sendable {
        private let now = Mutex<UInt64>(1_000_000_000)

        func read() -> UInt64 {
            now.withLock { $0 }
        }

        func advance(_ nanoseconds: UInt64 = LiveDragHold.settleNs) {
            now.withLock { $0 += nanoseconds }
        }
    }

    private func liveDragBarrier(
        _ other: Monitor,
        holding directions: Set<Direction> = [.right],
        warps: PointRecorder,
        warpsPointer: Bool = true,
        clock: StepClock = StepClock()
    ) -> PointerEdgeBarrier {
        let barrier = PointerEdgeBarrier(
            installsTap: false,
            displayBounds: { _ in .infinite },
            warpCursor: { warps.record($0)
                return .success
            },
            postMove: { _ in },
            clock: { clock.read() }
        )
        var topology = topology(other, fin: false)
        topology.warpsPointer = warpsPointer
        barrier.publish(topology)
        barrier.publishLiveDragHold(.init(monitorId: main.id, heldDirections: directions))
        return barrier
    }

    private func drag(_ barrier: PointerEdgeBarrier, _ cgPoint: CGPoint, dx: CGFloat) throws -> CGPoint {
        let event = try dragEvent(cgPoint, dx: dx)
        XCTAssertNotNil(barrier.handleTapEvent(.leftMouseDragged, event))
        return event.location
    }

    func testALiveDragIsHeldAtASharedEdgeWhileTheStripCanScroll() throws {
        let warps = PointRecorder()
        let barrier = liveDragBarrier(adjoining, warps: warps)

        let held = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)

        XCTAssertEqual(held, CGPoint(x: 2558, y: 700))
        XCTAssertTrue(warps.all.isEmpty)
        let inside = try drag(barrier, CGPoint(x: 2400, y: 700), dx: -8)
        XCTAssertEqual(inside, CGPoint(x: 2400, y: 700))
    }

    func testPushingOnCrossesASharedEdgeOnceTheHoldHasSettled() throws {
        let warps = PointRecorder()
        let clock = StepClock()
        let barrier = liveDragBarrier(adjoining, warps: warps, clock: clock)

        for _ in 0 ..< 30 {
            _ = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)
        }
        XCTAssertTrue(warps.all.isEmpty)
        clock.advance()
        for _ in 0 ..< 11 {
            _ = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)
        }
        XCTAssertTrue(warps.all.isEmpty)
        let crossed = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)

        XCTAssertEqual(warps.all.count, 1)
        XCTAssertEqual(crossed, warps.all.first)
        XCTAssertGreaterThanOrEqual(crossed.x, adjoining.frame.minX)
    }

    func testAFastApproachIsHeldUnlessItIsAFlick() throws {
        let warps = PointRecorder()
        let barrier = liveDragBarrier(adjoining, warps: warps)

        let held = try drag(barrier, CGPoint(x: 2570, y: 700), dx: 30)
        _ = try drag(barrier, CGPoint(x: 2600, y: 700), dx: 60)

        XCTAssertEqual(held, CGPoint(x: 2558, y: 700))
        XCTAssertTrue(warps.all.isEmpty)
    }

    func testAQuickFlickCrossesASharedEdgeAtOnce() throws {
        let warps = PointRecorder()
        let barrier = liveDragBarrier(adjoining, warps: warps)

        let crossed = try drag(barrier, CGPoint(x: 2600, y: 700), dx: 120)

        XCTAssertEqual(warps.all.count, 1)
        XCTAssertGreaterThanOrEqual(crossed.x, adjoining.frame.minX)
    }

    func testAtTheStripsEndASharedEdgeLetsThePointerThrough() throws {
        let warps = PointRecorder()
        let barrier = liveDragBarrier(adjoining, holding: [.left], warps: warps)

        let point = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)

        XCTAssertEqual(point, CGPoint(x: 2562, y: 700))
        XCTAssertTrue(warps.all.isEmpty)
    }

    func testWithWarpOnTheWholeRoutedEdgeIsHeldWhereverMacOSPutsTheDisplay() throws {
        let warps = PointRecorder()
        let barrier = liveDragBarrier(staircase, warps: warps)

        let held = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)

        XCTAssertEqual(held, CGPoint(x: 2558, y: 700))
        XCTAssertTrue(warps.all.isEmpty)
    }

    func testWithWarpOffOutsideTheSpanMacOSSharesTheEdgeIsNotHeld() throws {
        let warps = PointRecorder()
        let barrier = liveDragBarrier(staircase, warps: warps, warpsPointer: false)

        let point = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)

        XCTAssertEqual(point, CGPoint(x: 2562, y: 700))
        XCTAssertTrue(warps.all.isEmpty)
    }

    func testWithWarpOffTheHoldStillWorksAndMacOSCrosses() throws {
        let warps = PointRecorder()
        let clock = StepClock()
        let barrier = liveDragBarrier(adjoining, warps: warps, warpsPointer: false, clock: clock)

        let held = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)
        XCTAssertEqual(held, CGPoint(x: 2558, y: 700))
        clock.advance()
        for _ in 0 ..< 11 {
            _ = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)
        }
        let through = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)

        XCTAssertEqual(through, CGPoint(x: 2562, y: 700))
        XCTAssertTrue(warps.all.isEmpty)
    }

    func testWithWarpOffAnEdgeMacOSDoesNotShareIsNotHeld() throws {
        let warps = PointRecorder()
        let apart = Self.monitor(7, CGRect(x: 3000, y: 0, width: 1920, height: 1440))
        let barrier = liveDragBarrier(apart, warps: warps, warpsPointer: false)

        let point = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)

        XCTAssertEqual(point, CGPoint(x: 2562, y: 700))
    }

    func testAfterCrossingTheOldDisplaysHoldNoLongerApplies() throws {
        let warps = PointRecorder()
        let clock = StepClock()
        let barrier = liveDragBarrier(adjoining, warps: warps, clock: clock)
        _ = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)
        clock.advance()
        for _ in 0 ..< 12 {
            _ = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)
        }
        XCTAssertEqual(warps.all.count, 1)
        XCTAssertNil(barrier.liveDragHold)

        let point = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)

        XCTAssertEqual(point, CGPoint(x: 2562, y: 700))
    }

    func testAPointerWarpedWellPastTheHeldEdgeIsNotPulledBack() throws {
        let warps = PointRecorder()
        let barrier = liveDragBarrier(adjoining, warps: warps)
        barrier.publishLiveDragHold(.init(monitorId: adjoining.id, heldDirections: [.left]))

        let point = try drag(barrier, CGPoint(x: 2540, y: 700), dx: -4)

        XCTAssertEqual(point, CGPoint(x: 2540, y: 700))
        XCTAssertTrue(warps.all.isEmpty)
    }

    func testDragsThatArentLiveAreNotHeld() throws {
        let warps = PointRecorder()
        let barrier = liveDragBarrier(adjoining, warps: warps)
        barrier.publishLiveDragHold(nil)

        let point = try drag(barrier, CGPoint(x: 2562, y: 700), dx: 8)

        XCTAssertEqual(point, CGPoint(x: 2562, y: 700))
        XCTAssertTrue(warps.all.isEmpty)
    }

    func testWithWarpOffPlainMouseMovesAreLeftAlone() throws {
        let warps = PointRecorder()
        let barrier = liveDragBarrier(staircase, warps: warps, warpsPointer: false)
        barrier.publishLiveDragHold(nil)

        let event = try moveEvent(CGPoint(x: 2559.5, y: 740))
        XCTAssertTrue(barrier.handleTapEvent(.mouseMoved, event) != nil)
        XCTAssertTrue(warps.all.isEmpty)
    }

    func testHostCrossingWarpsSuppressesTriggerAndPostsMove() throws {
        let warps = PointRecorder()
        let posts = PointRecorder()
        let barrier = PointerEdgeBarrier(
            installsTap: false,
            displayBounds: { _ in .infinite },
            warpCursor: { warps.record($0)
                return .success
            },
            postMove: { posts.record($0) }
        )
        barrier.publish(topology(staircase, fin: false))
        let trigger = try moveEvent(CGPoint(x: 2559.5, y: 740))
        XCTAssertTrue(barrier.handleTapEvent(.mouseMoved, trigger) == nil)
        XCTAssertEqual(warps.all.count, 1)
        XCTAssertEqual(posts.all, warps.all)
        let duringCooldown = try moveEvent(CGPoint(x: 2559.5, y: 740))
        XCTAssertTrue(barrier.handleTapEvent(.mouseMoved, duringCooldown) != nil)
        XCTAssertEqual(warps.all.count, 1)
    }

    func testHostTimesCooldownItselfBecauseHIDEventsCarryMachTicks() throws {
        let warps = PointRecorder()
        let time = Mutex<UInt64>(199_339_405_295_208)
        let barrier = PointerEdgeBarrier(
            installsTap: false,
            displayBounds: { _ in .infinite },
            warpCursor: { warps.record($0)
                return .success
            },
            postMove: { _ in },
            clock: { time.withLock { $0 } }
        )
        barrier.publish(topology(staircase, fin: false))
        let first = try moveEvent(CGPoint(x: 2559.5, y: 740))
        first.timestamp = 4_784_145_324_399
        XCTAssertTrue(barrier.handleTapEvent(.mouseMoved, first) == nil)
        time.withLock { $0 += 100_000_000 }
        let second = try moveEvent(CGPoint(x: 2559.5, y: 740))
        second.timestamp = 4_784_147_724_399
        XCTAssertTrue(barrier.handleTapEvent(.mouseMoved, second) == nil)
        XCTAssertEqual(warps.all.count, 2)
    }

    func testHostRejectsInvalidBoundsAndWarpErrorsWithoutPosting() throws {
        let posts = PointRecorder()
        for (bounds, result) in [(nil, CGError.success), (CGRect.infinite, .failure)] as [(CGRect?, CGError)] {
            let barrier = PointerEdgeBarrier(
                installsTap: false,
                displayBounds: { _ in bounds },
                warpCursor: { _ in result },
                postMove: { posts.record($0) }
            )
            barrier.publish(topology(staircase, fin: false))
            let event = try moveEvent(CGPoint(x: 2559.5, y: 740))
            XCTAssertTrue(barrier.handleTapEvent(.mouseMoved, event) != nil)
        }
        XCTAssertTrue(posts.all.isEmpty)
    }

    func testCrossingTraceRecordsRouteOnlyWhileCapturing() throws {
        let time = Mutex<UInt64>(1_000_000_000)
        let barrier = PointerEdgeBarrier(
            installsTap: false,
            displayBounds: { _ in .infinite },
            warpCursor: { _ in .success },
            postMove: { _ in },
            clock: { time.withLock { $0 } }
        )
        barrier.publish(topology(staircase, fin: false))
        MouseTrace.shared.beginCapture()
        MouseTrace.shared.endCapture()
        let untraced = try moveEvent(CGPoint(x: 2559.5, y: 740))
        XCTAssertTrue(barrier.handleTapEvent(.mouseMoved, untraced) == nil)
        XCTAssertFalse(MouseTrace.shared.dump().contains("edge-warp"))

        time.withLock { $0 += 100_000_000 }
        MouseTrace.shared.beginCapture()
        defer { MouseTrace.shared.endCapture() }
        let traced = try moveEvent(CGPoint(x: 2559.5, y: 740))
        XCTAssertTrue(barrier.handleTapEvent(.mouseMoved, traced) == nil)
        MouseTrace.shared.endCapture()
        let zone = try XCTUnwrap(
            MouseWarpGeometry.crossing(location: CGPoint(x: 2559.5, y: 700), frame: main.frame, margin: 1)
        )
        let destination = MouseWarpGeometry.destinationPoint(
            on: staircase.frame, entryEdge: zone.entryEdge, ratio: zone.ratio, margin: 1
        )
        let warp = CGPoint(x: destination.x, y: 1440 - destination.y)
        XCTAssertTrue(MouseTrace.shared.dump().contains(
            "edge-warp from=\(main.id) to=\(staircase.id) dir=right "
                + "dest=\(TraceFormat.point(destination)) warp=\(TraceFormat.point(warp)) callbackUs="
        ))
    }

    func testStopDisablesHoldsBeforeTheTapThreadExits() throws {
        let barrier = PointerEdgeBarrier(installsTap: false)
        barrier.publish(topology(adjoining))
        barrier.stop()
        let event = try moveEvent(CGPoint(x: 2565, y: 740))
        XCTAssertTrue(barrier.handleTapEvent(.mouseMoved, event) != nil)
        XCTAssertEqual(event.location, CGPoint(x: 2565, y: 740))
        XCTAssertFalse(barrier.ownsCrossings)
    }

    private func controllerWithFin() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMPointerEdge-\(UUID().uuidString)")
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        let controller = WMController(settings: settings)
        controller.workspaceManager.applyMonitorConfigurationChange([main, staircase])
        let fin = CGRect(x: 2530, y: 650, width: 30, height: 108)
        controller.ownedWindowRegistry.registerWindowNumber(
            surfaceId: "pointer-edge-latch-test",
            policy: SurfacePolicy(
                kind: .parkingEdgeMask, hitTestPolicy: .interactive, capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            ),
            windowNumber: 999_401, frameProvider: { fin }, visibilityProvider: { true }
        )
        return controller
    }

    func testFinPressLatchClearsWhenReleaseArrivesDuringInputSuppression() {
        let controller = controllerWithFin()
        defer { controller.ownedWindowRegistry.unregister(surfaceId: "pointer-edge-latch-test") }
        let mouse = controller.mouseEventHandler
        let point = CGPoint(x: 2545, y: 700)
        XCTAssertFalse(mouse.dispatchMouseDown(at: point, modifiers: []))
        XCTAssertEqual(mouse.state.parkingEdgePressButton, .left)
        controller.isLockScreenActive = true
        mouse.dispatchMouseUp(at: point)
        controller.isLockScreenActive = false
        XCTAssertNil(mouse.state.parkingEdgePressButton)
    }

    func testOtherButtonPressClearsFinPressLatchWhoseReleaseWasMissed() {
        let controller = controllerWithFin()
        defer { controller.ownedWindowRegistry.unregister(surfaceId: "pointer-edge-latch-test") }
        let mouse = controller.mouseEventHandler
        XCTAssertFalse(mouse.receiveTapMouseDown(at: CGPoint(x: 2545, y: 700), modifiers: []))
        XCTAssertEqual(mouse.state.parkingEdgePressButton, .left)
        mouse.pressedMouseButtonsProvider = { 0 }
        _ = mouse.receiveTapMouseDown(at: CGPoint(x: 1280, y: 720), modifiers: [], button: .right)
        XCTAssertNil(mouse.state.parkingEdgePressButton)
    }

    func testFinPressLatchSurvivesOtherButtonPressWhileStillHeld() {
        let controller = controllerWithFin()
        defer { controller.ownedWindowRegistry.unregister(surfaceId: "pointer-edge-latch-test") }
        let mouse = controller.mouseEventHandler
        XCTAssertFalse(mouse.receiveTapMouseDown(at: CGPoint(x: 2545, y: 700), modifiers: []))
        mouse.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        _ = mouse.receiveTapMouseDown(at: CGPoint(x: 1280, y: 720), modifiers: [], button: .right)
        XCTAssertEqual(mouse.state.parkingEdgePressButton, .left)
    }

    func testSameButtonPressClearsMissedFinReleaseBeforeDrainingItsDrags() {
        let controller = controllerWithFin()
        defer { controller.ownedWindowRegistry.unregister(surfaceId: "pointer-edge-latch-test") }
        controller.eventIntake.open(sink: controller.eventInterpreter)
        defer { controller.eventIntake.close() }
        let mouse = controller.mouseEventHandler
        XCTAssertFalse(mouse.receiveTapMouseDown(at: CGPoint(x: 2545, y: 700), modifiers: []))
        mouse.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        XCTAssertTrue(EventIntake.post(.mouseDragged(button: .left, location: CGPoint(x: 1280, y: 720))))
        XCTAssertNil(controller.mouseWarpHandler.state.lastSampleAt)
        _ = mouse.receiveTapMouseDown(at: CGPoint(x: 1280, y: 720), modifiers: [])
        XCTAssertNotNil(controller.mouseWarpHandler.state.lastSampleAt)
        XCTAssertNil(mouse.state.parkingEdgePressButton)
    }
}
