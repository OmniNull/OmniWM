// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

private struct ShellGlassRepeatTrial {
    let name: String
    let opacity: Double
    let scale: Int
    let rim: Double
    let geometry: Int

    var label: String {
        "\(name), opacity \(opacity), \(scale)x, rim \(rim), geometry \(geometry)"
    }

    var checksReference: Bool {
        geometry == 0 && [0.1, 0.4, 0.55].contains(rim)
    }
}

extension ShellGlassSceneTests {
    private nonisolated static func compositionRepeat(
        _ renderer: ShellOffscreenRenderer, trial: ShellGlassRepeatTrial,
        baselines: (independent: [UInt8], own: [UInt8])
    ) throws -> [String: Any] {
        var first: [UInt8]?
        var delta = 0, invalidTotal = 0, alphaError = 0, ownAlphaError = 0
        var colourError = 0.0, requiredClip = 0.0
        for _ in 0 ..< 3 {
            let pixels = try renderer.render()
            let invalid = stride(from: 0, to: pixels.count, by: 4).count {
                max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) > pixels[$0 + 3]
            }
            XCTAssertEqual(invalid, 0, trial.label)
            invalidTotal += invalid
            if let first {
                delta = max(delta, zip(pixels, first).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) })
            } else { first = pixels }
            if trial.checksReference {
                let independent = compositionErrors(
                    pixels, baseline: baselines.independent, rim: trial.rim, scale: trial.scale
                )
                let own = compositionErrors(pixels, baseline: baselines.own, rim: trial.rim, scale: trial.scale)
                XCTAssertLessThanOrEqual(independent.whole, 3, trial.label)
                XCTAssertLessThanOrEqual(independent.alpha, 1, trial.label)
                XCTAssertLessThanOrEqual(own.alpha, 1, trial.label)
                colourError = max(colourError, independent.whole)
                requiredClip = max(requiredClip, independent.maximumRequiredClip)
                alphaError = max(alphaError, independent.alpha)
                ownAlphaError = max(ownAlphaError, own.alpha)
            }
        }
        return [
            "name": trial.name, "opacity": trial.opacity, "scale": trial.scale, "rim": trial.rim,
            "geometry": ["canonical", "fractional", "union"][trial.geometry], "frames": 3,
            "semanticFrames": trial.checksReference ? 3 : 0, "referenceChecked": trial.checksReference,
            "maximumRepeatByteDelta": delta,
            "maximumReferenceColourError": colourError, "maximumReferenceAlphaChange": alphaError,
            "maximumRequiredClip": requiredClip,
            "maximumOwnAlphaChange": ownAlphaError, "invalidPixels": invalidTotal
        ]
    }

    private nonisolated static var compositionRepeatShapes: [[ShellGlassShape]] {
        let fractional = ShellGlassShape(
            slot: 1, kind: 0, rect: CGRect(x: 16.3, y: 15.6, width: 63.5, height: 40.2), radius: 9.7, thickness: 0
        )
        return [[rimShape], [fractional], [rimShape, ShellGlassShape(
            slot: 2, kind: 0, rect: CGRect(x: 62, y: 40, width: 22, height: 36), radius: 8, thickness: 0
        )]]
    }

    func testClippedCompositionKeepsValidPremultiplicationAcrossRepeatedFullRimRenders() throws {
        let geometries = Self.compositionRepeatShapes
        try ShellLayerScene.engineQueue.sync {
            var rows: [[String: Any]] = []
            var count = 0
            for style in Self.compositionCases {
                for opacity in [1.0, 0.55] {
                    for scale in [1, 2] {
                        let width = 96 * scale
                        let independent = try Self.pixels(
                            Self.compositionBaseline(style, opacity: opacity),
                            width: width,
                            height: width,
                            scale: scale
                        )
                        let own = try Self.pixels(
                            Self.compositionBody(style, opacity: opacity, rim: 0).layer,
                            width: width,
                            height: width,
                            scale: scale
                        )
                        for rim in [0.1, 0.4, 0.55, 0.7, 1.0] {
                            for (geometry, shapes) in geometries.enumerated() {
                                let body = try Self.compositionBody(style, opacity: opacity, rim: rim, shapes: shapes)
                                let renderer = try Self.compositionRenderer(body.layer, scale: scale)
                                let trial = ShellGlassRepeatTrial(
                                    name: style.name,
                                    opacity: opacity,
                                    scale: scale,
                                    rim: rim,
                                    geometry: geometry
                                )
                                rows.append(try Self.compositionRepeat(
                                    renderer,
                                    trial: trial,
                                    baselines: (independent, own)
                                ))
                                count += 3
                            }
                        }
                    }
                }
            }
            XCTAssertEqual(count, 1620)
            XCTAssertEqual(rows.count, 540)
            XCTAssertEqual(rows.compactMap { $0["semanticFrames"] as? Int }.reduce(0, +), 324)
            try Self.saveCompositionMetrics(rows, name: "composition-repeat-metrics.json")
        }
    }
}
