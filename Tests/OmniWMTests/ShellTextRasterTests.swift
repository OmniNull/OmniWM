// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class ShellTextRasterTests: XCTestCase {
    func testReusedTextBitmapClearsPixelsAndPreservesEarlierImages() throws {
        for scale: CGFloat in [1, 2] {
            try ShellLayerScene.engineQueue.sync {
                let scene = ShellLayerScene(container: CALayer(), scale: scale)
                let opaque = CGColor(srgbRed: 0.8, green: 0.2, blue: 0.4, alpha: 1)
                let transparent = CGColor(srgbRed: 0.2, green: 0.6, blue: 1, alpha: 0)
                let translucent = CGColor(srgbRed: 0.2, green: 0.6, blue: 1, alpha: 0.3)
                let initial = try XCTUnwrap(scene.rasterize(
                    "88888888", style: 4, color: opaque, maxWidth: 0, lines: 1
                ))
                let context = try XCTUnwrap(scene.textContext)
                var retained = [(initial, try pixels(initial))]
                XCTAssertTrue(retained[0].1.contains { $0 != 0 })
                for (text, color) in [("        ", opaque), ("88888888", transparent), ("11111111", translucent)] {
                    let image = try XCTUnwrap(scene.rasterize(
                        text, style: 4, color: color, maxWidth: 0, lines: 1
                    ))
                    let fresh = ShellLayerScene(container: CALayer(), scale: scale)
                    let expected = try XCTUnwrap(fresh.rasterize(
                        text, style: 4, color: color, maxWidth: 0, lines: 1
                    ))
                    XCTAssertTrue(scene.textContext === context)
                    XCTAssertEqual(image.width, initial.width)
                    XCTAssertEqual(image.height, initial.height)
                    try assertImagesEqual(image, expected)
                    if color.alpha == 0 || text.allSatisfy(\.isWhitespace) {
                        XCTAssertTrue(try pixels(image).allSatisfy { $0 == 0 })
                    }
                    for (previous, bytes) in retained {
                        XCTAssertEqual(try pixels(previous), bytes)
                    }
                    retained.append((image, try pixels(image)))
                }
            }
        }
    }

    func testReusedTextRasterMatchesFreshScenesAcrossFontsScriptsAndWrapping() throws {
        let samples: [(text: String, style: UInt32, width: CGFloat, lines: Int)] = [
            ("0123456789 42%", 4, 0, 1),
            ("👩🏽‍💻 🌈 🇨🇦", 0, 0, 1),
            ("Ångström déjà vu e\u{301}", 1, 0, 1),
            ("مرحبا بالعالم · שלום", 0, 0, 1),
            ("An active window title that needs truncation", 0, 100, 1),
            ("Wrapped café text 👩🏽‍💻 with multiple lines and a truncated ending", 0, 90, 3)
        ]
        for scale: CGFloat in [1, 2] {
            try ShellLayerScene.engineQueue.sync {
                let scene = ShellLayerScene(container: CALayer(), scale: scale)
                for (index, sample) in (samples + samples.reversed()).enumerated() {
                    let color = CGColor(srgbRed: 0.3, green: 0.7, blue: 0.9, alpha: index.isMultiple(of: 2) ? 1 : 0.4)
                    let fresh = ShellLayerScene(container: CALayer(), scale: scale)
                    let expected = try XCTUnwrap(fresh.rasterize(
                        sample.text, style: sample.style, color: color, maxWidth: sample.width, lines: sample.lines
                    ))
                    let first = try XCTUnwrap(scene.rasterize(
                        sample.text, style: sample.style, color: color, maxWidth: sample.width, lines: sample.lines
                    ))
                    let context = try XCTUnwrap(scene.textContext)
                    let second = try XCTUnwrap(scene.rasterize(
                        sample.text, style: sample.style, color: color, maxWidth: sample.width, lines: sample.lines
                    ))
                    XCTAssertTrue(scene.textContext === context)
                    try assertImagesEqual(first, expected)
                    try assertImagesEqual(second, expected)
                }
            }
        }
    }

    func testBitmapContextMatchesDimensionsAndResetsUnsavedTextState() throws {
        try ShellLayerScene.engineQueue.sync {
            let scene = ShellLayerScene(container: CALayer(), scale: 2)
            let initial = try XCTUnwrap(scene.textBitmapContext(width: 32, height: 16))
            initial.textMatrix = CGAffineTransform(scaleX: 2, y: -1)
            initial.move(to: .zero)
            initial.addLine(to: CGPoint(x: 5, y: 5))
            let reused = try XCTUnwrap(scene.textBitmapContext(width: 32, height: 16))
            XCTAssertTrue(reused === initial)
            XCTAssertEqual(reused.textMatrix, .identity)
            XCTAssertTrue(reused.isPathEmpty)
            let taller = try XCTUnwrap(scene.textBitmapContext(width: 32, height: 17))
            XCTAssertFalse(taller === initial)
            XCTAssertEqual(taller.width, 32)
            XCTAssertEqual(taller.height, 17)
            let wider = try XCTUnwrap(scene.textBitmapContext(width: 33, height: 17))
            XCTAssertFalse(wider === taller)
            XCTAssertEqual(wider.width, 33)
            XCTAssertEqual(wider.height, 17)
            XCTAssertTrue(scene.textContext === wider)
            XCTAssertNil(scene.textBitmapContext(width: 0, height: 17))
            XCTAssertNil(scene.textBitmapContext(width: 33, height: 0))
            XCTAssertTrue(scene.textContext === wider)
        }
    }

    func testOversizedTextRendersWithoutReplacingBoundedContext() throws {
        try ShellLayerScene.engineQueue.sync {
            let scene = ShellLayerScene(container: CALayer(), scale: 2)
            let cached = try XCTUnwrap(scene.textBitmapContext(width: 512, height: 512))
            XCTAssertEqual(cached.bytesPerRow * cached.height, 1 << 20)
            XCTAssertTrue(scene.textContext === cached)
            let text = String(repeating: "W", count: 2048)
            let color = CGColor(srgbRed: 0.8, green: 0.3, blue: 0.1, alpha: 0.6)
            let image = try XCTUnwrap(scene.rasterize(text, style: 4, color: color, maxWidth: 0, lines: 1))
            XCTAssertGreaterThan(image.bytesPerRow * image.height, 1 << 20)
            XCTAssertTrue(scene.textContext === cached)
            let fresh = ShellLayerScene(container: CALayer(), scale: 2)
            let expected = try XCTUnwrap(fresh.rasterize(text, style: 4, color: color, maxWidth: 0, lines: 1))
            XCTAssertNil(fresh.textContext)
            try assertImagesEqual(image, expected)
            let bytes = try pixels(image)
            let smaller = try XCTUnwrap(scene.rasterize("42%", style: 4, color: color, maxWidth: 0, lines: 1))
            XCTAssertLessThanOrEqual(smaller.bytesPerRow * smaller.height, 1 << 20)
            XCTAssertFalse(scene.textContext === cached)
            XCTAssertEqual(try pixels(image), bytes)
        }
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        Array(try XCTUnwrap(image.dataProvider?.data) as Data)
    }

    private func assertImagesEqual(
        _ image: CGImage,
        _ expected: CGImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(image.width, expected.width, file: file, line: line)
        XCTAssertEqual(image.height, expected.height, file: file, line: line)
        XCTAssertEqual(image.bitsPerComponent, expected.bitsPerComponent, file: file, line: line)
        XCTAssertEqual(image.bitsPerPixel, expected.bitsPerPixel, file: file, line: line)
        XCTAssertEqual(image.bytesPerRow, expected.bytesPerRow, file: file, line: line)
        XCTAssertEqual(image.bitmapInfo, expected.bitmapInfo, file: file, line: line)
        XCTAssertEqual(image.renderingIntent, expected.renderingIntent, file: file, line: line)
        XCTAssertEqual(image.shouldInterpolate, expected.shouldInterpolate, file: file, line: line)
        let colorSpace = try XCTUnwrap(image.colorSpace, file: file, line: line)
        let expectedColorSpace = try XCTUnwrap(expected.colorSpace, file: file, line: line)
        XCTAssertTrue(CFEqual(colorSpace, expectedColorSpace), file: file, line: line)
        XCTAssertEqual(try pixels(image), try pixels(expected), file: file, line: line)
    }
}
