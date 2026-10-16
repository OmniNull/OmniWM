// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class ShellFrameEndpointTests: XCTestCase {
    func testSegmentedFrameCurveEndsAtNewModelGeometry() throws {
        let scene = ShellLayerScene(container: CALayer(), scale: 2)
        let initial = CGRect(x: 10, y: 20, width: 40, height: 30)
        let target = CGRect(x: 90, y: 50, width: 120, height: 80)
        scene.submit([
            .insert(slot: 0, parent: -1, kind: .image, after: -1),
            .frame(slot: 0, rect: initial, animation: nil)
        ], animated: false)
        let animation = ShellAnimation(motion: .ease, speed: 1, curve: ShellCurve(wire: 9, custom: nil))
        let result = ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            scene.applyFrame(0, target, preset: animation, animated: true)
            let layer = scene.layers[0]
            let position = layer?.animation(forKey: "position") as? CAKeyframeAnimation
            let bounds = layer?.animation(forKey: "bounds") as? CAKeyframeAnimation
            return (
                (position?.values?.last as? NSValue)?.pointValue,
                (bounds?.values?.last as? NSValue)?.rectValue,
                layer?.frame
            )
        }
        XCTAssertEqual(result.0, target.origin)
        XCTAssertEqual(result.1?.size, target.size)
        XCTAssertEqual(result.2, target)
    }

    func testSegmentedPaintCurveEndsAtNewValues() throws {
        let scene = ShellLayerScene(container: CALayer(), scale: 2)
        let base = ShellLayerPaint(
            fill: nil,
            border: nil,
            borderWidth: 1,
            radius: 0,
            opacity: 1,
            scale: 1,
            shadow: nil,
            shadowRadius: 0
        )
        let target = ShellLayerPaint(
            fill: nil,
            border: nil,
            borderWidth: 4,
            radius: 8,
            opacity: 0.3,
            scale: 1.2,
            shadow: nil,
            shadowRadius: 0
        )
        scene.submit([
            .insert(slot: 0, parent: -1, kind: .image, after: -1),
            .paint(slot: 0, base, animation: nil),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 40, height: 30), animation: nil)
        ], animated: false)
        let values = ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            scene.applyPaint(
                0,
                target,
                preset: ShellAnimation(motion: .ease, speed: 1, curve: ShellCurve(wire: 9, custom: nil)),
                animated: true
            )
            let layer = scene.layers[0]
            return ["borderWidth", "cornerRadius", "opacity"].map {
                ((layer?.animation(forKey: $0) as? CAKeyframeAnimation)?.values?.last as? NSNumber)?.doubleValue
            }
        }
        XCTAssertEqual(values[0], 4)
        XCTAssertEqual(values[1], 8)
        XCTAssertEqual(try XCTUnwrap(values[2]), Double(Float(0.3)), accuracy: 0.000001)
    }

    func testScaleEndpointUsesFinalSizeInSameTransaction() throws {
        let scene = ShellLayerScene(container: CALayer(), scale: 2)
        scene.submit([
            .insert(slot: 0, parent: -1, kind: .image, after: -1),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 20, height: 30), animation: nil)
        ], animated: false)
        let result = try ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            let animation = ShellAnimation(motion: .ease, speed: 1, curve: ShellCurve(wire: 9, custom: nil))
            let paint = ShellLayerPaint(
                fill: nil,
                border: nil,
                borderWidth: 0,
                radius: 0,
                opacity: 1,
                scale: 0.8,
                shadow: nil,
                shadowRadius: 0,
                frameSize: CGSize(width: 100, height: 30)
            )
            scene.applyPaint(0, paint, preset: animation, animated: true)
            scene.applyFrame(0, CGRect(x: 0, y: 0, width: 100, height: 30), preset: animation, animated: true)
            let layer = try XCTUnwrap(scene.layers[0])
            let transform = try XCTUnwrap((layer.animation(forKey: "transform") as? CAKeyframeAnimation)?.values?
                .last as? NSValue).caTransform3DValue
            return (transform.m41, layer.transform.m41)
        }
        XCTAssertEqual(result.0, 10, accuracy: 0.000001)
        XCTAssertEqual(result.0, result.1, accuracy: 0.000001)
    }

    func testPathAndMaskMorphsEndAtNewPath() throws {
        let scene = ShellLayerScene(container: CALayer(), scale: 2)
        let old = ShellLayerPath(path: ShellPath.parse("M0 0 H20 V20 H0 Z"), viewBox: nil, evenOdd: false)
        let new = ShellLayerPath(path: ShellPath.parse("M0 0 H40 V30 H0 Z"), viewBox: nil, evenOdd: false)
        scene.submit([
            .insert(slot: 0, parent: -1, kind: .path, after: -1),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 40, height: 30), animation: nil),
            .path(slot: 0, old, animation: nil)
        ], animated: false)
        let result = try ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            let layer = try XCTUnwrap(scene.layers[0])
            scene.setMask(true, slot: 0, layer: layer)
            scene.applyPath(0, new, animation: ShellAnimation(motion: .ease, speed: 1))
            let target = try XCTUnwrap(new.fitted(to: layer.bounds.size))
            let shape = try XCTUnwrap((layer.animation(forKey: "path") as? CABasicAnimation)?.toValue)
            let mask = try XCTUnwrap((scene.masks[0]?.layer.animation(forKey: "path") as? CABasicAnimation)?.toValue)
            return (CFEqual(shape as CFTypeRef, target), CFEqual(mask as CFTypeRef, target))
        }
        XCTAssertTrue(result.0)
        XCTAssertTrue(result.1)
    }
}
