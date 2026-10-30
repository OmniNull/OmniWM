// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class ShellShapeContourTests: XCTestCase {
    private func shape(_ rect: CGRect, radius: CGFloat, rotation: CGFloat = 0) -> ShellGlassShape {
        ShellGlassShape(slot: 1, kind: 0, rect: rect, radius: radius, thickness: 0, rotation: rotation)
    }

    func testRoundedCageRetainsTheAuthoredPathAtRestAndKeepsTheSampledCornerRadius() throws {
        let path = try XCTUnwrap(ShellPath.parse("M 6 0 Q 0 0 0 6 L 0 14 Q 0 20 6 20 L 34 20 Q 40 20 40 14"))
            .path(fitting: nil, into: .zero)
        let base = shape(CGRect(x: 0, y: 0, width: 40, height: 20), radius: 6)
        let contour = ShellShapeContour(path: path, base: base, toBody: .identity)
        XCTAssertEqual(contour.path(at: base), path)
        let stretched = shape(CGRect(x: 20, y: 2, width: 60, height: 16), radius: 4.8)
        let actual = points(contour.path(at: stretched))
        let expected = [
            CGPoint(x: 24.8, y: 2), CGPoint(x: 20, y: 2), CGPoint(x: 20, y: 6.8),
            CGPoint(x: 20, y: 13.2), CGPoint(x: 20, y: 18), CGPoint(x: 24.8, y: 18),
            CGPoint(x: 75.2, y: 18), CGPoint(x: 80, y: 18), CGPoint(x: 80, y: 13.2)
        ]
        XCTAssertEqual(actual.count, expected.count)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9)
        }
    }

    func testContourConvertsPathAndBodySpacesAndComposesShapeRotation() throws {
        let path = try XCTUnwrap(ShellPath.parse("M 16 10 L 24 10"))
            .path(fitting: nil, into: .zero)
        let base = shape(CGRect(x: 20, y: 20, width: 40, height: 20), radius: 6)
        let contour = ShellShapeContour(path: path, base: base, toBody: CGAffineTransform(scaleX: 2, y: 2))
        let target = shape(CGRect(x: 40, y: 20, width: 40, height: 20), radius: 6, rotation: .pi / 2)
        let actual = points(contour.path(at: target))
        XCTAssertEqual(actual[0].x, 35, accuracy: 1e-9)
        XCTAssertEqual(actual[0].y, 11, accuracy: 1e-9)
        XCTAssertEqual(actual[1].x, 35, accuracy: 1e-9)
        XCTAssertEqual(actual[1].y, 19, accuracy: 1e-9)
    }

    private func points(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock {
            let element = $0.pointee
            let count = switch element.type {
            case .moveToPoint,
                 .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            case .closeSubpath: 0
            @unknown default: 0
            }
            points += (0 ..< count).map { element.points[$0] }
        }
        return points
    }
}
