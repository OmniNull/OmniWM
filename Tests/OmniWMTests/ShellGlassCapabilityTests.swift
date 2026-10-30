// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class ShellGlassCapabilityTests: XCTestCase {
    func testCompleteContractHasNoMissingCapability() {
        XCTAssertNil(ShellGlassCapability.firstMissing(
            classAvailable: { _ in true },
            setterAvailable: { _, _ in true }
        ))
    }

    func testEveryMissingClassSelectsFallbackBeforeAnySetter() {
        for missing in ShellGlassCapability.classNames {
            var checkedSetter = false
            let result = ShellGlassCapability.firstMissing(classAvailable: { $0 != missing }, setterAvailable: { _, _ in
                checkedSetter = true
                return true
            })
            XCTAssertEqual(result, "\(missing).class")
            XCTAssertFalse(checkedSetter)
        }
    }

    func testEveryAppliedEffectKeyIsRequired() {
        for effect in ShellGlassCapability.Effect.allCases {
            for missing in effect.keys.map(\.rawValue) {
                let result = ShellGlassCapability.firstMissing(
                    classAvailable: { _ in true },
                    setterAvailable: { name, key in
                        name != effect.rawValue || key != missing
                    }
                )
                XCTAssertEqual(result, "\(effect.rawValue).\(missing)")
            }
        }
    }

    func testEveryAppliedLayerKeyIsRequired() {
        let requirements = [
            ("CABackdropLayer", ShellGlassCapability.BackdropProperty.allCases.map(\.rawValue)),
            ("CASDFLayer", ShellGlassCapability.BodyProperty.allCases.map(\.rawValue)),
            ("CASDFElementLayer", ShellGlassCapability.ElementProperty.allCases.map(\.rawValue))
        ]
        for (name, keys) in requirements {
            for missing in keys {
                let result = ShellGlassCapability.firstMissing(
                    classAvailable: { _ in true },
                    setterAvailable: { candidate, key in
                        candidate != name || key != missing
                    }
                )
                XCTAssertEqual(result, "\(name).\(missing)")
            }
        }
    }

    func testFlatRequirementSkipsOnlyBackdropClassesAndKeys() {
        XCTAssertNil(ShellGlassCapability.firstMissing(
            classAvailable: { $0 != "CABackdropLayer" },
            setterAvailable: { name, _ in name != "CABackdropLayer" },
            backdrop: false
        ))
        XCTAssertTrue(ShellGlassCapability.sdfClassNames.contains("CAFilter"))
        for missing in ShellGlassCapability.sdfClassNames {
            let result = ShellGlassCapability.firstMissing(
                classAvailable: { $0 != missing },
                setterAvailable: { _, _ in true },
                backdrop: false
            )
            XCTAssertEqual(result, "\(missing).class")
        }
        let key = "CASDFKeyFillHighlightEffect.keyAmount"
        XCTAssertEqual(ShellGlassCapability.firstMissing(
            classAvailable: { _ in true },
            setterAvailable: { "\($0).\($1)" != key },
            backdrop: false
        ), key)
    }

    func testMissingBackdropFallsBackOnlyForBackdropBodies() throws {
        guard ShellGlassCapability.shared.available
        else { throw XCTSkip("Native glass contract unavailable on this runtime") }
        let missing = "CABackdropLayer.windowServerAware"
        let capability = ShellGlassCapability(denying: missing)
        XCTAssertEqual(capability.missing, missing)
        XCTAssertNil(capability.flatMissing)
        let gradient = [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)]
        for (recipe, colors, native) in [
            ("glass:26:-1:0:0:1", nil, false),
            ("glass:26:-1:0:0:1|optics:0.4:1:90", nil, true),
            ("glass:26:-1:0:0:1|optics:0.1:0:0", gradient, true)
        ] {
            let state = try apply(recipe, gradient: colors, capability: capability)
            XCTAssertEqual(state.native, native, recipe)
            XCTAssertEqual(state.failure, native ? nil : missing, recipe)
            XCTAssertEqual(state.tinted, !native, recipe)
            XCTAssertTrue(state.effects, recipe)
        }
    }

    func testMissingBandCapabilityFallsBackToPlainFillAndReports() throws {
        guard ShellGlassCapability.shared.available
        else { throw XCTSkip("Native glass contract unavailable on this runtime") }
        XCTAssertNotNil(ShellGlassCapability(denying: "CABackdropLayer.windowServerAware").compositing(.add))
        let missing = "CASDFGradientEffect.distances"
        let capability = ShellGlassCapability(denying: missing)
        XCTAssertEqual(capability.flatMissing, missing)
        XCTAssertNil(capability.compositing(.add))
        XCTAssertNil(capability.effect(.band, values: [.colors: [CGColor](), .distances: [CGFloat]()]))
        for (source, flat) in [
            ("glass:26:-1:0:0:1|optics:0.4:1:90", true),
            ("glass:26:-1:0:0:1|optics:0.4:0:90", false)
        ] {
            let state = try apply(source, gradient: nil, capability: capability)
            XCTAssertFalse(state.native, source)
            XCTAssertEqual(state.failure, missing, source)
            XCTAssertTrue(state.tinted, source)
            XCTAssertEqual(state.layers.count, flat ? 1 : 2, source)
            XCTAssertEqual(state.layers.last, "CALayer", source)
        }
    }

    func testMissingSDFCapabilityFallsBackToPlainFillAndReports() throws {
        guard ShellGlassCapability.shared.available
        else { throw XCTSkip("Native glass contract unavailable on this runtime") }
        let missing = "CASDFKeyFillHighlightEffect.keyAmount"
        let capability = ShellGlassCapability(denying: missing)
        XCTAssertEqual(capability.flatMissing, missing)
        let flat = try apply("glass:26:-1:0:0:1|optics:0.4:1:90", gradient: nil, capability: capability)
        XCTAssertFalse(flat.native)
        XCTAssertEqual(flat.failure, missing)
        XCTAssertTrue(flat.tinted)
        XCTAssertEqual(flat.layers, ["CALayer"])
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)]
        let painted = try apply("glass:26:-1:0:0:1|optics:0.4:1:90", gradient: colors, capability: capability)
        XCTAssertFalse(painted.native)
        XCTAssertEqual(painted.failure, missing)
        XCTAssertFalse(painted.tinted)
        XCTAssertEqual(painted.layers, ["CAGradientLayer"])
    }

    private struct BodyState: Sendable {
        let native: Bool
        let failure: String?
        let tinted: Bool
        let layers: [String]
        let effects: Bool
    }

    private func apply(_ source: String, gradient: [CGColor]?, capability: ShellGlassCapability) throws -> BodyState {
        let recipe = try XCTUnwrap(ShellGlassRecipe(source))
        return ShellLayerScene.engineQueue.sync {
            let body = ShellGlassBody(capability: capability)
            var paint = ShellLayerPaint(
                fill: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1),
                border: nil,
                borderWidth: 0,
                radius: 0,
                opacity: 1,
                scale: 1,
                shadow: nil,
                shadowRadius: 6
            )
            paint.gradient = gradient
            body.apply(size: CGSize(width: 80, height: 80), shapes: [
                ShellGlassShape(
                    slot: 1,
                    kind: 0,
                    rect: CGRect(x: 8, y: 8, width: 64, height: 64),
                    radius: 12,
                    thickness: 0
                )
            ], recipe: recipe, paint: paint, animation: nil)
            let visible = (body.layer.sublayers ?? []).filter { !$0.isHidden }
            let tint = visible.last.map { $0.backgroundColor?.alpha == 1 && $0.mask != nil } ?? false
            return BodyState(
                native: body.nativeAvailable,
                failure: body.failure,
                tinted: tint,
                layers: visible.map { String(describing: type(of: $0)) },
                effects: body.sdfLayers.count == 4 && body.sdfLayers.allSatisfy {
                    $0.value(forKey: ShellGlassCapability.BodyProperty.effect.rawValue) != nil
                }
            )
        }
    }

    func testDeniedEffectKeySelectsActualBodyFallback() throws {
        guard ShellGlassCapability.shared.available
        else { throw XCTSkip("Native glass contract unavailable on this runtime") }
        let missing = "CASDFKeyFillHighlightEffect.diffuseHeightScale"
        let state = try ShellLayerScene.engineQueue.sync {
            let capability = ShellGlassCapability(denying: missing)
            XCTAssertFalse(capability.available)
            XCTAssertEqual(capability.missing, missing)
            let body = ShellGlassBody(capability: capability)
            let recipe = try XCTUnwrap(ShellGlassRecipe("glass:26:-1:0:0:1"))
            let paint = ShellLayerPaint(
                fill: nil,
                border: nil,
                borderWidth: 0,
                radius: 0,
                opacity: 1,
                scale: 1,
                shadow: nil,
                shadowRadius: 6,
                blurRadius: 6,
                saturation: 1
            )
            body.apply(size: CGSize(width: 80, height: 80), shapes: [
                ShellGlassShape(
                    slot: 1,
                    kind: 0,
                    rect: CGRect(x: 8, y: 8, width: 64, height: 64),
                    radius: 12,
                    thickness: 0
                )
            ], recipe: recipe, paint: paint, animation: nil)
            return (body.nativeAvailable, body.sdfLayers.isEmpty, body.failure, body.maskElements.count)
        }
        XCTAssertFalse(state.0)
        XCTAssertTrue(state.1)
        XCTAssertEqual(state.2, missing)
        XCTAssertEqual(state.3, 1)
    }
}
