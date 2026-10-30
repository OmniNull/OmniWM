// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import Metal
@testable import OmniWM
import XCTest

@MainActor
final class ShellVitreusFramePieceTests: XCTestCase {
    func testClockGradientUsesTheNativeTextAlphaAndReachesTheMintStop() throws {
        let device = try XCTUnwrap(ShellShaderGPU.device)
        let shader = try ShellStyleFixture.source("vitreus")
            .appendingPathComponent("shaders/vitreus-clock-gradient.metal")
        let pipeline = try ShellShaderLibrary.pipeline(Data(contentsOf: shader), name: shader.lastPathComponent)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 200, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let white = [UInt8](repeating: 128, count: 800)
        source.replace(region: MTLRegionMake2D(0, 0, 1, 200), mipmapLevel: 0, withBytes: white, bytesPerRow: 4)
        var colors = ShellShaderInput.Colors(repeating: .zero)
        colors[ShellRole.secondaryContainerForeground.rawValue] = SIMD4(1, 0, 0, 1)
        colors[ShellRole.accent.rawValue] = SIMD4(0, 1, 0, 1)
        let input = ShellShaderInput(values: SIMD4(0.85, 0.55, 0, 0), rate: 0, colors: colors)
        let uniforms = input.uniforms(
            size: CGSize(width: 1, height: 200),
            scale: 1,
            elapsed: 0,
            now: 0,
            transition: .settled
        )
        let image = try ShellShaderTests.pixels(pipeline, uniforms, width: 1, height: 200, source: source)
        var mint = 0
        var high = false
        for row in 0 ..< 200 {
            let pixel = Array(image[(row * 4) ..< (row * 4 + 4)])
            XCTAssertEqual(pixel[3], 128)
            XCTAssertTrue(pixel.prefix(3).allSatisfy { $0 <= pixel[3] })
            XCTAssertEqual(pixel[0], 0)
            if pixel[1] == 128, pixel[2] == 0 { mint += 1 }
            if pixel[2] >= 125, pixel[1] <= 3 { high = true }
        }
        XCTAssertTrue(high)
        XCTAssertGreaterThanOrEqual(mint, 105)
        XCTAssertLessThanOrEqual(mint, 108)
    }
}
