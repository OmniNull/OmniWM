// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

extension ShellGlassSceneTests {
    func testClippedCompositionKeepsValidPremultiplicationOnFractionalAndUnionShapes() throws {
        let fractional = ShellGlassShape(
            slot: 1, kind: 0, rect: CGRect(x: 16.3, y: 15.6, width: 63.5, height: 40.2), radius: 9.7, thickness: 0
        )
        let geometries = [[fractional], [Self.rimShape, ShellGlassShape(
            slot: 2, kind: 0, rect: CGRect(x: 62, y: 40, width: 22, height: 36), radius: 8, thickness: 0
        )]]
        try ShellLayerScene.engineQueue.sync {
            var count = 0
            for (index, style) in Self.compositionCases.enumerated() {
                for opacity in [1.0, 0.55] {
                    for scale in [1, 2] where Self.sweeps(index, opacity: opacity, scale: scale) {
                        let width = 96 * scale
                        for rim in Self.premultipliedRims {
                            for shapes in geometries {
                                let body = try Self.compositionBody(style, opacity: opacity, rim: rim, shapes: shapes)
                                let pixels = try Self.pixels(body.layer, width: width, height: width, scale: scale)
                                let invalid = stride(from: 0, to: pixels.count, by: 4).count {
                                    max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) > pixels[$0 + 3]
                                }
                                XCTAssertEqual(
                                    invalid, 0,
                                    "\(style.name), opacity \(opacity), \(scale)x, rim \(rim), \(shapes.count) shapes"
                                )
                                count += 1
                            }
                        }
                    }
                }
            }
            XCTAssertEqual(count, Self.sweptCompositionCells * geometries.count * Self.premultipliedRims.count)
        }
    }
}
