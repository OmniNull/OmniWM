// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class SpatialCameraViewportTests: XCTestCase {
    func testInitialIdentityTransform() {
        let viewport = SpatialCameraViewport()
        let transform = viewport.current
        XCTAssertEqual(transform.scale, 1.0)
        XCTAssertEqual(transform.translation, .zero)

        let point = CGPoint(x: 200, y: 150)
        XCTAssertEqual(transform.project(point: point), point)
        XCTAssertEqual(transform.unproject(point: point), point)

        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(transform.project(rect: rect), rect)
    }

    func testAnchorPointRemainsInvariantDuringScale() {
        let viewport = SpatialCameraViewport()
        let anchor = CGPoint(x: 500, y: 400)
        viewport.beginGesture(anchor: anchor)
        viewport.updateMagnify(delta: -0.5)

        let projectedAnchor = viewport.current.project(point: anchor)
        XCTAssertEqual(projectedAnchor.x, anchor.x)
        XCTAssertEqual(projectedAnchor.y, anchor.y)
    }

    func testPanTranslatesProjectedPoints() {
        let viewport = SpatialCameraViewport()
        viewport.beginGesture(anchor: CGPoint(x: 0, y: 0))
        viewport.updatePan(delta: CGPoint(x: 50, y: -30))

        let point = CGPoint(x: 100, y: 100)
        let projected = viewport.current.project(point: point)
        XCTAssertEqual(projected.x, 150)
        XCTAssertEqual(projected.y, 70)
    }

    func testUnprojectInvertsProjectedPoint() {
        let viewport = SpatialCameraViewport()
        viewport.beginGesture(anchor: CGPoint(x: 300, y: 300))
        viewport.updateMagnify(delta: -0.4)
        viewport.updatePan(delta: CGPoint(x: 80, y: -40))

        let original = CGPoint(x: 640, y: 480)
        let projected = viewport.current.project(point: original)
        let unprojected = viewport.current.unproject(point: projected)

        XCTAssertEqual(unprojected.x, original.x)
        XCTAssertEqual(unprojected.y, original.y, accuracy: CGFloat.rounding(operations: 8, at: original.x))
    }

    func testTouchSpanRatioDrivesScale() {
        let viewport = SpatialCameraViewport()
        viewport.beginGesture(anchor: CGPoint(x: 200, y: 200))
        viewport.updateTouchSpan(distance: 200, center: CGPoint(x: 200, y: 200))
        viewport.updateTouchSpan(distance: 100, center: CGPoint(x: 200, y: 200))

        XCTAssertEqual(viewport.current.scale, 0.5)
    }

    func testRubberBandingBelowMinScale() {
        let viewport = SpatialCameraViewport(config: SpatialCameraConfig(minScale: 0.2, maxScale: 1.0))
        viewport.beginGesture(anchor: .zero)
        viewport.updateMagnify(delta: -0.95)
        XCTAssertLessThan(viewport.current.scale, 0.20)
        XCTAssertGreaterThan(viewport.current.scale, 0.10)
    }

    func testEndGestureSettlesToOverviewWhenZoomedOut() {
        let viewport = SpatialCameraViewport()
        viewport.beginGesture(anchor: .zero)
        viewport.updateMagnify(delta: -0.6)

        let settlement = viewport.endGesture(velocity: 0)
        XCTAssertEqual(settlement, .overviewGrid)

        viewport.settle(at: settlement)
        XCTAssertEqual(viewport.current.scale, viewport.config.overviewScale)
        XCTAssertEqual(viewport.current.translation, .zero)
    }

    func testEndGestureSettlesToFocusedWindowWhenNearFullScale() {
        let viewport = SpatialCameraViewport()
        viewport.beginGesture(anchor: .zero)
        viewport.updateMagnify(delta: -0.15)

        let settlement = viewport.endGesture(velocity: 0)
        XCTAssertEqual(settlement, .focusedWindow)

        viewport.settle(at: settlement)
        XCTAssertEqual(viewport.current.scale, viewport.config.maxScale)
        XCTAssertEqual(viewport.current.translation, .zero)
    }

    func testVelocityOverridesPositionThreshold() {
        let viewport = SpatialCameraViewport()
        viewport.beginGesture(anchor: .zero)
        viewport.updateMagnify(delta: -0.7)
        let settlement = viewport.endGesture(velocity: 1.2)
        XCTAssertEqual(settlement, .focusedWindow)
    }

    func testAnchorChangeKeepsProjection() {
        let viewport = SpatialCameraViewport()
        viewport.beginGesture(anchor: .zero)
        viewport.updateMagnify(delta: -0.5)
        let point = CGPoint(x: 640, y: 480)
        let before = viewport.current.project(point: point)

        viewport.updateMagnify(delta: 0, anchor: CGPoint(x: 400, y: 300))
        let afterMagnify = viewport.current.project(point: point)
        XCTAssertEqual(afterMagnify.x, before.x)
        XCTAssertEqual(afterMagnify.y, before.y)

        viewport.updateTouchSpan(distance: 120, center: CGPoint(x: 900, y: 100))
        let afterSpan = viewport.current.project(point: point)
        XCTAssertEqual(afterSpan.x, before.x)
        XCTAssertEqual(afterSpan.y, before.y)
    }

    func testZeroMagnifyKeepsRubberBandedScale() {
        let viewport = SpatialCameraViewport()
        viewport.beginGesture(anchor: .zero)
        viewport.updateMagnify(delta: -0.95)
        let banded = viewport.current.scale

        viewport.updateMagnify(delta: 0)
        XCTAssertEqual(viewport.current.scale, banded)

        viewport.updateMagnify(delta: 19)
        let overflow = (1 + CGFloat(-0.95)) * (1 + 19) - viewport.config.maxScale
        XCTAssertEqual(
            viewport.current.scale,
            viewport.config.maxScale + overflow * viewport.config.rubberBandResistance / (1 + overflow)
        )
    }

    func testFullInwardMagnifyCanZoomBackIn() {
        let viewport = SpatialCameraViewport()
        viewport.beginGesture(anchor: .zero)
        viewport.updateMagnify(delta: -1)
        XCTAssertGreaterThan(viewport.current.scale, 0)

        viewport.updateMagnify(delta: .nan)
        XCTAssertTrue(viewport.current.scale.isFinite)

        viewport.updateMagnify(delta: 99)
        XCTAssertEqual(viewport.current.scale, 1.0)
    }

    func testNegativeTouchSpanKeepsScalePositive() {
        let viewport = SpatialCameraViewport()
        viewport.beginGesture(anchor: .zero)
        viewport.updateTouchSpan(distance: 100, center: .zero)
        viewport.updateTouchSpan(distance: -1000, center: .zero)
        XCTAssertGreaterThan(viewport.current.scale, 0)
    }

    func testOverflowingInputKeepsScaleFinite() {
        let viewport = SpatialCameraViewport()
        viewport.beginGesture(anchor: CGPoint(x: 100, y: 100))
        viewport.updateMagnify(delta: .greatestFiniteMagnitude)
        viewport.updateMagnify(delta: 1)
        XCTAssertTrue(viewport.current.scale.isFinite)
        XCTAssertTrue(viewport.current.project(point: CGPoint(x: 10, y: 10)).x.isFinite)

        let span = SpatialCameraViewport()
        span.beginGesture(anchor: .zero)
        span.updateTouchSpan(distance: .leastNonzeroMagnitude, center: .zero)
        span.updateTouchSpan(distance: .greatestFiniteMagnitude, center: .zero)
        XCTAssertTrue(span.current.scale.isFinite)
    }
}
