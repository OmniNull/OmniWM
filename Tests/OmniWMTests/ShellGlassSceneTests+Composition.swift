// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

struct ShellGlassCompositionCase {
    let name: String
    let fill: CGColor
    var gradient: [CGColor]?
}

struct ShellGlassCompositionErrors {
    let profile: Double
    let whole: Double
    let alpha: Int
    let interiorAlpha: Int
    let invalid: Int
    let unclipped: Double
    let maximumRequiredClip: Double
}

extension ShellGlassSceneTests {
    nonisolated static var fullSweep: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["OMNIWM_GLASS_EVIDENCE"] != nil || environment["OMNI_F1_FRAME_PROBE_OUT"] != nil
    }

    nonisolated static func sweeps(_ caseIndex: Int, opacity: Double, scale: Int) -> Bool {
        fullSweep || (opacity == 1 ? 0 : 2) + scale - 1 == caseIndex % 4
    }

    nonisolated static var sweptCompositionCells: Int {
        compositionCases.count * (fullSweep ? 4 : 1)
    }

    nonisolated static var sweptRims: [Double] {
        fullSweep ? [0.1, 0.3, 0.4, 0.55] : [0.1, 0.55]
    }

    nonisolated static var premultipliedRims: [Double] {
        fullSweep ? [0.1, 0.4, 0.55, 0.7, 1.0] : [0.4, 1.0]
    }

    nonisolated static var compositionCases: [ShellGlassCompositionCase] {
        let tints = [0.36, 0.5, 1.0].flatMap { alpha in
            [
                ShellGlassCompositionCase(
                    name: "dark-\(alpha)",
                    fill: CGColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: alpha)
                ),
                ShellGlassCompositionCase(
                    name: "bright-\(alpha)",
                    fill: CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: alpha)
                )
            ]
        }
        return tints + [(1.0, 1.0), (0.5, 0.5), (0.25, 0.75)].map { from, to in
            ShellGlassCompositionCase(
                name: "gradient-\(from)-\(to)",
                fill: ShellLayerScene.clear,
                gradient: [
                    CGColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: from),
                    CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: to)
                ]
            )
        }
    }

    nonisolated static func compositionBody(
        _ style: ShellGlassCompositionCase, opacity: Double, rim: Double,
        shapes: [ShellGlassShape] = [rimShape]
    ) throws -> ShellGlassBody {
        let body = try rimBody("\(rim):1:90", fill: style.fill, gradient: style.gradient, shapes: shapes)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.sdfLayers[0].isHidden = true
        body.layer.opacity = Float(opacity)
        CATransaction.commit()
        return body
    }

    nonisolated static func compositionBaseline(
        _ style: ShellGlassCompositionCase, opacity: Double, shape: ShellGlassShape = rimShape
    ) throws -> CALayer {
        let capability = ShellGlassCapability.shared
        XCTAssertNil(capability.flatMissing)
        let mask: CALayer
        let element: CALayer
        let material: CALayer
        if let colors = style.gradient {
            mask = CALayer()
            mask.masksToBounds = true
            element = CALayer()
            element.backgroundColor = CGColor(gray: 1, alpha: 1)
            element.cornerCurve = .circular
            let gradient = CAGradientLayer()
            gradient.colors = colors
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            material = gradient
        } else {
            mask = try XCTUnwrap(capability.bodyClass).init()
            element = try XCTUnwrap(capability.elementClass).init()
            mask.setValue(52, forKey: ShellGlassCapability.BodyProperty.smoothness.rawValue)
            mask.setValue(
                capability.effect(.fill, values: [.color: CGColor(gray: 1, alpha: 1)]),
                forKey: ShellGlassCapability.BodyProperty.effect.rawValue
            )
            element.setValue("bounds", forKey: ShellGlassCapability.ElementProperty.mode.rawValue)
            element.setValue("union", forKey: ShellGlassCapability.ElementProperty.operation.rawValue)
            material = CALayer()
            material.backgroundColor = style.fill
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [material, mask, element] { layer.anchorPoint = .zero }
        for layer in [material, mask] { layer.bounds = CGRect(x: 0, y: 0, width: 96, height: 96) }
        element.position = shape.rect.origin
        element.bounds = CGRect(origin: .zero, size: shape.rect.size)
        element.cornerRadius = shape.radius
        mask.addSublayer(element)
        material.mask = mask
        let owner = CALayer()
        owner.anchorPoint = .zero
        owner.bounds = CGRect(x: 0, y: 0, width: 96, height: 96)
        owner.opacity = Float(opacity)
        owner.addSublayer(material)
        CATransaction.commit()
        return owner
    }

    private nonisolated static func compositionDistance(_ x: Int, _ y: Int, scale: Int) -> Double {
        let px = (Double(x) + 0.5) / Double(scale) - 48
        let py = (Double(y) + 0.5) / Double(scale) - 48
        let qx = abs(px) - 20, qy = abs(py) - 20
        return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - 12
    }

    nonisolated static func compositionErrors(
        _ pixels: [UInt8], baseline: [UInt8], rim: Double, scale: Int
    ) -> ShellGlassCompositionErrors {
        let width = 96 * scale
        var profile = 0.0, whole = 0.0, unclipped = 0.0, maximumRequiredClip = 0.0
        var alphaError = 0, interiorAlphaError = 0, invalid = 0
        for y in 0 ..< width {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                let alpha = Double(baseline[index + 3])
                alphaError = max(alphaError, abs(Int(pixels[index + 3]) - Int(baseline[index + 3])))
                if max(pixels[index], pixels[index + 1], pixels[index + 2]) > pixels[index + 3] { invalid += 1 }
                let distance = compositionDistance(x, y, scale: scale)
                if distance <= -2.2 {
                    interiorAlphaError = max(interiorAlphaError, abs(Int(pixels[index + 3]) - Int(baseline[index + 3])))
                }
                let light = 255 * rim * smoothstep(-2.2, -0.4, distance)
                for channel in 0 ..< 3 {
                    let exact = min(255, Double(baseline[index + channel]) + light * alpha / 255)
                    let clipped = min(alpha, exact)
                    maximumRequiredClip = max(maximumRequiredClip, max(0, exact - alpha))
                    let error = abs(Double(pixels[index + channel]) - clipped)
                    whole = max(whole, error)
                    unclipped = max(unclipped, abs(Double(pixels[index + channel]) - exact))
                    if [30 * scale, 48 * scale, 66 * scale].contains(y),
                       x >= 16 * scale, x < 22 * scale { profile = max(profile, error) }
                }
            }
        }
        return ShellGlassCompositionErrors(
            profile: profile, whole: whole, alpha: alphaError, interiorAlpha: interiorAlphaError,
            invalid: invalid, unclipped: unclipped, maximumRequiredClip: maximumRequiredClip
        )
    }

    nonisolated static func saveCompositionMetrics(
        _ rows: [[String: Any]], name: String = "composition-metrics.json"
    ) throws {
        guard let folder = ProcessInfo.processInfo.environment["OMNIWM_GLASS_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: directory.appendingPathComponent(name))
    }

    func testCompositionPreservesTheOriginalAuthoredTintAndGradientWithoutABand() throws {
        try ShellLayerScene.engineQueue.sync {
            for (index, style) in Self.compositionCases.enumerated() {
                for opacity in [1.0, 0.55] {
                    for scale in [1, 2] where Self.sweeps(index, opacity: opacity, scale: scale) {
                        let width = 96 * scale
                        let reference = try Self.pixels(
                            Self.compositionBaseline(style, opacity: opacity), width: width, height: width, scale: scale
                        )
                        let body = try Self.compositionBody(style, opacity: opacity, rim: 0)
                        let actual = try Self.pixels(body.layer, width: width, height: width, scale: scale)
                        let errors = Self.compositionErrors(actual, baseline: reference, rim: 0, scale: scale)
                        let label = "\(style.name), opacity \(opacity), \(scale)x"
                        XCTAssertLessThanOrEqual(max(errors.whole, Double(errors.alpha)), 3, label)
                        XCTAssertLessThanOrEqual(errors.interiorAlpha, 1, label)
                        XCTAssertEqual(errors.invalid, 0, label)
                    }
                }
            }
        }
    }

    func testClippedCompositionMatchesIndependentTintAndGradientReferenceAndPreservesAlpha() throws {
        try ShellLayerScene.engineQueue.sync {
            var rows: [[String: Any]] = []
            for (index, style) in Self.compositionCases.enumerated() {
                for opacity in [1.0, 0.55] {
                    for scale in [1, 2] where Self.sweeps(index, opacity: opacity, scale: scale) {
                        let width = 96 * scale
                        let reference = try Self.pixels(
                            Self.compositionBaseline(style, opacity: opacity), width: width, height: width, scale: scale
                        )
                        let ownBaseline = try Self.pixels(
                            Self.compositionBody(style, opacity: opacity, rim: 0).layer,
                            width: width, height: width, scale: scale
                        )
                        for rim in Self.sweptRims {
                            let body = try Self.compositionBody(style, opacity: opacity, rim: rim)
                            let pixels = try Self.pixels(body.layer, width: width, height: width, scale: scale)
                            let error = Self.compositionErrors(pixels, baseline: reference, rim: rim, scale: scale)
                            let ownAlphaError = stride(from: 3, to: pixels.count, by: 4).reduce(0) {
                                max($0, abs(Int(pixels[$1]) - Int(ownBaseline[$1])))
                            }
                            let label = "\(style.name), opacity \(opacity), \(scale)x, rim \(rim)"
                            XCTAssertLessThanOrEqual(error.profile, 3, label)
                            XCTAssertLessThanOrEqual(error.whole, 3, label)
                            XCTAssertLessThanOrEqual(error.alpha, 1, label)
                            XCTAssertLessThanOrEqual(ownAlphaError, 1, label)
                            XCTAssertEqual(error.invalid, 0, label)
                            if style.name == "bright-0.5", opacity == 0.55, scale == 2, rim == 0.4 {
                                try Self.save(pixels, width: width, name: "composition-translucent-tint-2x.png")
                            }
                            if style.name == "gradient-0.25-0.75", opacity == 1, scale == 2, rim == 0.55 {
                                try Self.save(pixels, width: width, name: "composition-translucent-gradient-2x.png")
                            }
                            rows.append([
                                "name": style.name, "opacity": opacity, "scale": scale, "rim": rim,
                                "profileError": error.profile, "wholeRasterError": error.whole,
                                "maximumAlphaChange": error.alpha, "maximumOwnAlphaChange": ownAlphaError,
                                "invalidPixels": error.invalid,
                                "maximumUnclippedError": error.unclipped,
                                "maximumRequiredClip": error.maximumRequiredClip
                            ])
                        }
                    }
                }
            }
            XCTAssertEqual(rows.count, Self.sweptCompositionCells * Self.sweptRims.count)
            XCTAssertEqual(Set(rows.map { "\($0["opacity"] ?? "") \($0["scale"] ?? "")" }).count, 4)
            try Self.saveCompositionMetrics(rows)
        }
    }

    func testTransparentFlatAndLowAlphaGlassKeepPremultiplicationValid() throws {
        try ShellLayerScene.engineQueue.sync {
            for scale in [1, 2] {
                let width = 96 * scale
                let transparent = ShellGlassCompositionCase(name: "transparent", fill: ShellLayerScene.clear)
                let flat = try Self.compositionBody(transparent, opacity: 1, rim: 1)
                let empty = try Self.pixels(flat.layer, width: width, height: width, scale: scale)
                XCTAssertTrue(empty.allSatisfy { $0 == 0 })
                for alpha in [0.0, 0.1] {
                    let fill = try XCTUnwrap(Self.rimTint.copy(alpha: alpha))
                    for rim in [0.3, 1.0] {
                        let glass = try Self.rimBody("\(rim):0:90", fill: fill)
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        glass.sdfLayers[0].isHidden = true
                        CATransaction.commit()
                        let pixels = try Self.pixels(glass.layer, width: width, height: width, scale: scale)
                        let invalid = stride(from: 0, to: pixels.count, by: 4).count {
                            max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) > pixels[$0 + 3]
                        }
                        XCTAssertEqual(invalid, 0, "alpha \(alpha), rim \(rim), \(scale)x")
                    }
                }
            }
        }
    }
}

extension ShellGlassSceneTests {
    private nonisolated static func isolatedGlassTintPlane(
        _ style: ShellGlassCompositionCase, rim: Double
    ) throws -> ShellGlassBody {
        let body = try rimBody("\(rim):0:90", fill: style.fill)
        let type = try XCTUnwrap(ShellGlassCapability.shared.backdropClass)
        let backdrop = try XCTUnwrap(body.canvasLayers.first { $0.isKind(of: type) })
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in [0, 2, 3] { body.sdfLayers[index].isHidden = true }
        backdrop.isHidden = true
        CATransaction.commit()
        return body
    }

    private nonisolated static func glassTintProfiles(
        _ style: ShellGlassCompositionCase, scale: Int
    ) throws -> [[String: Any]] {
        let width = 96 * scale
        let reference = try pixels(
            compositionBaseline(style, opacity: 1),
            width: width,
            height: width,
            scale: scale
        )
        let original = try pixels(
            isolatedGlassTintPlane(style, rim: 0.1).layer,
            width: width,
            height: width,
            scale: scale
        )
        var rows: [[String: Any]] = []
        for rim in sweptRims {
            let body = try isolatedGlassTintPlane(style, rim: rim)
            let actual = try pixels(body.layer, width: width, height: width, scale: scale)
            let recipe = try XCTUnwrap(ShellGlassRecipe("glass:26:-1:0:0:1|optics:\(rim):0:90"))
            let error = compositionErrors(
                actual,
                baseline: reference,
                rim: Double(recipe.band / style.fill.alpha),
                scale: scale
            )
            let ownAlpha = stride(from: 3, to: actual.count, by: 4).reduce(0) {
                max($0, abs(Int(actual[$1]) - Int(original[$1])))
            }
            let label = "\(style.name), \(scale)x, rim \(rim)"
            XCTAssertLessThanOrEqual(error.whole, 3, label)
            XCTAssertLessThanOrEqual(error.alpha, 1, label)
            XCTAssertLessThanOrEqual(ownAlpha, 1, label)
            XCTAssertEqual(error.invalid, 0, label)
            rows.append([
                "name": style.name,
                "scale": scale,
                "rim": rim,
                "profileError": error.profile,
                "wholeRasterError": error.whole,
                "maximumAlphaChange": error.alpha,
                "maximumOwnAlphaChange": ownAlpha,
                "invalidPixels": error.invalid,
                "maximumUnclippedError": error.unclipped, "maximumRequiredClip": error.maximumRequiredClip
            ])
        }
        return rows
    }

    func testGlassTintPlaneSharesTheBandOnceAndClipsAtItsOwnAlpha() throws {
        let tints = Self.fullSweep
            ? [(0.1, false), (0.1, true), (0.36, false), (0.36, true)]
            : [(0.1, true), (0.36, false)]
        try ShellLayerScene.engineQueue.sync {
            var rows: [[String: Any]] = []
            for (alpha, bright) in tints {
                let style = ShellGlassCompositionCase(
                    name: "glass-\(bright ? "bright" : "dark")-\(alpha)",
                    fill: CGColor(
                        srgbRed: bright ? 0.8 : 0.2,
                        green: bright ? 0.8 : 0.3,
                        blue: bright ? 0.8 : 0.4,
                        alpha: alpha
                    )
                )
                for scale in [1, 2] { rows += try Self.glassTintProfiles(style, scale: scale) }
            }
            XCTAssertEqual(rows.count, tints.count * 2 * Self.sweptRims.count)
            try Self.saveCompositionMetrics(rows, name: "glass-tint-plane-metrics.json")
        }
    }
}
