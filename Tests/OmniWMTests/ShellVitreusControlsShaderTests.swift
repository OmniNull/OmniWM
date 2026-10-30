// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Metal
@testable import OmniWM
import XCTest

@MainActor
final class ShellVitreusControlsShaderTests: XCTestCase {
    private func pipeline() throws -> any MTLRenderPipelineState {
        _ = try XCTUnwrap(ShellShaderGPU.device, "The shatter proof requires Metal")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent(
            "Sources/OmniWM/ShellStyles/vitreus/shaders/vitreus-shatter.metal"
        )
        return try ShellShaderLibrary.pipeline(Data(contentsOf: file), name: file.lastPathComponent)
    }

    private func uniforms(time: Double, scale: Int, rate: Int = 60) -> ShellShaderUniforms {
        var colors = ShellShaderInput.Colors(repeating: .zero)
        colors[ShellRole.accent.rawValue] = SIMD4(0.35, 0.8, 0.65, 1)
        colors[ShellRole.secondaryContainerForeground.rawValue] = SIMD4(0.8, 1, 0.9, 1)
        return ShellShaderInput(values: SIMD4(1, 3, 0, 0), rate: rate, colors: colors).uniforms(
            size: CGSize(width: 312, height: 260), scale: CGFloat(scale), elapsed: time, now: time,
            transition: .settled
        )
    }

    func testShatterCompilesMovesAndEndsWithoutRepeatingOrInvalidPixels() throws {
        let program = try pipeline()
        for scale in [1, 2] {
            var moving: [[UInt8]] = []
            for time in [0.0, 0.12, 0.5, 0.95, 1.5] {
                let pixels = try ShellShaderTests.pixels(
                    program, uniforms(time: time, scale: scale), width: 312 * scale, height: 260 * scale
                )
                if time == 0 || time >= 0.95 {
                    XCTAssertTrue(pixels.allSatisfy { $0 == 0 }, "t=\(time), scale=\(scale)")
                } else {
                    XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 })
                    let invalid = stride(from: 0, to: pixels.count, by: 4).count { index in
                        pixels[index] > pixels[index + 3] || pixels[index + 1] > pixels[index + 3]
                            || pixels[index + 2] > pixels[index + 3]
                    }
                    XCTAssertEqual(invalid, 0, "t=\(time), scale=\(scale)")
                    moving.append(pixels)
                    try save(pixels, scale: scale, time: time)
                }
            }
            XCTAssertEqual(moving.count, 2)
            XCTAssertNotEqual(moving.first, moving.last)
        }
    }

    func testReducedMotionKeepsTheOneShotTransparentWithoutAdvancingItsClock() throws {
        let program = try pipeline()
        for time in [0.12, 0.5, 1.5] {
            let sample = uniforms(time: time, scale: 1, rate: 0)
            XCTAssertEqual(sample.time, 0)
            let pixels = try ShellShaderTests.pixels(program, sample, width: 312, height: 260)
            XCTAssertTrue(pixels.allSatisfy { $0 == 0 })
        }
    }

    private func save(_ bytes: [UInt8], scale: Int, time: Double) throws {
        guard let output = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] else { return }
        let width = 312 * scale, height = 260 * scale
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little
                .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "vitreus-shatter-\(Int(time * 1000))ms-\(scale)x.png"
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent(name))
    }
}
