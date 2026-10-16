// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

final class ShellCurveTests: XCTestCase {
    private func points(_ timing: CAMediaTimingFunction) -> [Float] {
        (0 ..< 4).map { index in
            var point: [Float] = [0, 0]
            timing.getControlPoint(at: index, values: &point)
            return point
        }.flatMap(\.self)
    }

    private func assertPoints(
        _ timing: CAMediaTimingFunction,
        _ expected: [Float],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (value, target) in zip(points(timing), [0, 0] + expected + [1, 1]) {
            XCTAssertEqual(value, target, accuracy: 0.0001, file: file, line: line)
        }
    }

    func testTwoSegmentCurvesBecomeKeyframesAndReverse() throws {
        let emphasized = try XCTUnwrap(ShellCurve(wire: 9, custom: nil))
        let frames = try XCTUnwrap(emphasized.keyframes)
        XCTAssertEqual(frames.times.map(\.doubleValue), [0, 1.0 / 6.0, 1], accuracy: 0.0001)
        XCTAssertEqual(frames.progress, [0, 0.4, 1])
        assertPoints(frames.timings[0], [0.3, 0, 0.8, 0.15])
        assertPoints(frames.timings[1], [0.05, 0.7, 0.1, 1])

        let reversed = try XCTUnwrap(emphasized.reversed.keyframes)
        XCTAssertEqual(reversed.times.map(\.doubleValue), [0, 5.0 / 6.0, 1], accuracy: 0.0001)
        XCTAssertEqual(reversed.progress.map { Double($0) }, [0, 0.6, 1], accuracy: 0.0001)

        let spatial = try XCTUnwrap(ShellCurve(wire: 13, custom: nil))
        XCTAssertNil(spatial.keyframes)
        assertPoints(spatial.timing(), [0.38, 1.21, 0.22, 1])
        assertPoints(spatial.reversed.timing(), [0.78, 0, 0.62, -0.21])
        assertPoints(
            try XCTUnwrap(ShellCurve(wire: UInt8(OMNI_CURVE_CUSTOM), custom: "0.1,0.2,0.3,0.4")).timing(),
            [0.1, 0.2, 0.3, 0.4]
        )
        XCTAssertNil(ShellCurve(wire: 0, custom: nil))
        XCTAssertNil(ShellCurve(wire: 18, custom: nil))
    }

    func testEnterPlansSampleEveryCurveSegmentAndMirrorWhenClosing() throws {
        let enter = try XCTUnwrap(ShellEnter(Enter(opacity: 0, dy: -10, curve: 9)))
        let size = CGSize(width: 10, height: 10)
        let opening = try XCTUnwrap(enter.plan(
            ShellShaderTransition(from: 0, to: 1, start: 0, duration: 1, forced: true),
            at: 0,
            opacity: 1,
            transform: CATransform3DIdentity,
            size: size
        ))
        let frames = try XCTUnwrap(opening.curve.keyframes)
        XCTAssertEqual(frames.progress, [0, 0.4, 1])
        XCTAssertEqual(opening.sample(0.4).opacity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(opening.sample(0.4).transform.m42, -6, accuracy: 0.0001)

        let closing = try XCTUnwrap(enter.plan(
            ShellShaderTransition(from: 1, to: 0, start: 0, duration: 1, forced: true),
            at: 0,
            opacity: 1,
            transform: CATransform3DIdentity,
            size: size
        ))
        XCTAssertEqual(closing.curve, try XCTUnwrap(ShellCurve(wire: 9, custom: nil)).reversed)
        XCTAssertEqual(closing.sample(0.6).opacity, 0.4, accuracy: 0.0001)

        let custom = try XCTUnwrap(ShellEnter(Enter(curve: UInt8(OMNI_CURVE_CUSTOM)), curve: "0.1,0.2,0.3,0.4"))
        XCTAssertEqual(custom.curve, ShellCurve(points: [0.1, 0.2, 0.3, 0.4]))
        XCTAssertNil(ShellEnter(Enter(curve: UInt8(OMNI_CURVE_CUSTOM))))
    }

    func testCurvesGiveTheirValueAtAnyTime() throws {
        let linear = try XCTUnwrap(ShellCurve(wire: 1, custom: nil))
        XCTAssertEqual(linear.value(at: 0.3), 0.3, accuracy: 0.0001)
        let spatial = try XCTUnwrap(ShellCurve(wire: 13, custom: nil))
        XCTAssertEqual(spatial.value(at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(spatial.value(at: 1), 1, accuracy: 0.0001)
        XCTAssertGreaterThan((0 ... 100).map { spatial.value(at: CGFloat($0) / 100) }.max() ?? 0, 1.01)
        let emphasized = try XCTUnwrap(ShellCurve(wire: 9, custom: nil))
        XCTAssertEqual(emphasized.value(at: 1.0 / 6.0), 0.4, accuracy: 0.0001)
        XCTAssertEqual(emphasized.reversed.value(at: 5.0 / 6.0), 0.6, accuracy: 0.0001)
    }

    func testFastMovesStretchAlongTheirDirectionAndSettle() {
        let still = ShellStretch.deforms(positions: Array(repeating: .zero, count: 30), amount: 0.1)
        XCTAssertTrue(still.allSatisfy { $0 == .identity })

        let steps = 120
        let moving = (0 ... steps).map { CGPoint(x: 0, y: CGFloat($0) * 2000 / ShellStretch.rate) }
        let deforms = ShellStretch.deforms(positions: moving, amount: 0.1)
        let peak = deforms.map(\.d).max() ?? 1
        XCTAssertEqual(peak, 1.02, accuracy: 0.004)
        XCTAssertEqual(deforms[steps / 2].a, 1 / deforms[steps / 2].d, accuracy: 0.004)
        XCTAssertEqual(deforms[steps / 2].b, 0, accuracy: 0.0001)
        XCTAssertEqual(deforms.last, .identity)

        let flung = (0 ... 30).map { CGPoint(x: CGFloat($0) * 100_000, y: 0) }
        XCTAssertLessThanOrEqual(ShellStretch.deforms(positions: flung, amount: 0.1).map(\.a).max() ?? 0, 1.35 * 1.2)
    }

    func testEntersWithStretchSampleTheirSlide() throws {
        let size = CGSize(width: 100, height: 100)
        let transition = ShellShaderTransition(from: 0, to: 1, start: 0, duration: 0.5, forced: true)
        let enter = try XCTUnwrap(ShellEnter(Enter(dy: -400, curve: 13, stretch: 0.1)))
        let plan = try XCTUnwrap(enter.plan(
            transition,
            at: 0,
            opacity: 1,
            transform: CATransform3DIdentity,
            size: size
        ))
        let animation = try XCTUnwrap(enter.stretched(plan, size: size))
        let values = try XCTUnwrap(animation.values as? [NSValue]).map(\.caTransform3DValue)
        XCTAssertEqual(values.count, 61)
        XCTAssertEqual(values.first?.m42, -400)
        XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(values.last)))
        XCTAssertGreaterThan(values.map(\.m22).max() ?? 0, 1.001)

        XCTAssertNil(try XCTUnwrap(ShellEnter(Enter(dy: -400, curve: 13))).stretched(plan, size: size))
        XCTAssertNil(try XCTUnwrap(ShellEnter(Enter(opacity: 0, curve: 13, stretch: 0.1))).stretched(plan, size: size))
    }

    func testTrailingElementsLeadWithTheirFrontEdge() throws {
        let animation = ShellAnimation(motion: .ease(seconds: 0.5), speed: 1, curve: ShellCurve(wire: 13, custom: nil))
        let old = CGRect(x: 0, y: 0, width: 20, height: 10)
        let new = CGRect(x: 100, y: 0, width: 20, height: 10)
        let trail = try XCTUnwrap(animation.trail(from: old, to: new))
        XCTAssertEqual(trail.position.duration, 0.75, accuracy: 0.0001)
        let sizes = try XCTUnwrap(trail.bounds.values as? [NSValue]).map(\.rectValue.size)
        let positions = try XCTUnwrap(trail.position.values as? [NSValue]).map(\.pointValue)
        XCTAssertEqual(positions.first, old.origin)
        XCTAssertEqual(positions.last?.x ?? 0, 100, accuracy: 0.0001)
        XCTAssertEqual(sizes.last?.width ?? 0, 20, accuracy: 0.0001)
        let atLead = sizes.count * 2 / 3
        XCTAssertGreaterThan(sizes.map(\.width).max() ?? 0, 40)
        XCTAssertEqual(positions[atLead].x + sizes[atLead].width, 120, accuracy: 2)

        let back = try XCTUnwrap(animation.trail(from: new, to: old))
        let backPositions = try XCTUnwrap(back.position.values as? [NSValue]).map(\.pointValue)
        XCTAssertEqual(backPositions[backPositions.count * 2 / 3].x, 0, accuracy: 2)

        XCTAssertNil(ShellAnimation(motion: .spring, speed: 1).trail(from: old, to: new))
        XCTAssertNil(animation.trail(from: old, to: old))
    }

    func testElementAnimationsFollowEveryCurveSegment() throws {
        let emphasized = ShellCurve(wire: 9, custom: nil)
        let animation = ShellAnimation(motion: .ease(seconds: 0.4), speed: 2, curve: emphasized)
        let layer = CALayer()
        layer.opacity = 10
        layer.bounds = CGRect(x: 10, y: 0, width: 20, height: 40)
        let opacity = try XCTUnwrap(animation.keyframes("opacity", from: Float(0), on: layer))
        XCTAssertEqual((opacity.values as? [NSNumber])?.map(\.doubleValue), [0, 4, 10])
        XCTAssertEqual(opacity.duration, 0.2)
        let bounds = try XCTUnwrap(animation.keyframes(
            "bounds",
            from: CGRect(x: 0, y: 0, width: 10, height: 20),
            on: layer
        ))
        XCTAssertEqual((bounds.values?[1] as? NSValue)?.rectValue, CGRect(x: 4, y: 0, width: 14, height: 28))
        let color = try XCTUnwrap(ShellCurve.mix(
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1),
            0.4
        ))
        XCTAssertEqual(
            unsafeDowncast(color as AnyObject, to: CGColor.self).components?.map { Double($0) } ?? [],
            [0.4, 0.2, 0, 1],
            accuracy: 0.0001
        )

        XCTAssertNil(ShellAnimation(motion: .spring, speed: 1, curve: emphasized).keyframes(
            "opacity",
            from: 0,
            on: layer
        ))
        XCTAssertNil(ShellAnimation(motion: .ease, speed: 1, curve: ShellCurve(wire: 13, custom: nil))
            .keyframes("opacity", from: 0, on: layer))
        XCTAssertNil(animation.keyframes("path", from: CGPath(rect: .zero, transform: nil), on: CAShapeLayer()))
        XCTAssertEqual(
            points(ShellAnimation(motion: .ease, speed: 1, curve: ShellCurve(wire: 13, custom: nil)).make("opacity")
                .timingFunction!),
            [0, 0, 0.38, 1.21, 0.22, 1, 1, 1]
        )
    }
}

private func XCTAssertEqual(
    _ values: [Double],
    _ expected: [Double],
    accuracy: Double,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(values.count, expected.count, file: file, line: line)
    for (value, target) in zip(values, expected) {
        XCTAssertEqual(value, target, accuracy: accuracy, file: file, line: line)
    }
}
