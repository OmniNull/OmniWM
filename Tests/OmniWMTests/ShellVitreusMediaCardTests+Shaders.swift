// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Metal
@testable import OmniWM
import XCTest

@MainActor
extension ShellVitreusMediaCardTests {
    private func pipeline(_ name: String) throws -> any MTLRenderPipelineState {
        _ = try XCTUnwrap(ShellShaderGPU.device, "The media card shaders need Metal")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Sources/OmniWM/ShellStyles/vitreus/shaders/" + name)
        return try ShellShaderLibrary.pipeline(Data(contentsOf: file), name: name)
    }

    private func uniforms(_ values: SIMD4<Float>, size: CGSize, time: Double) -> ShellShaderUniforms {
        var colors = ShellShaderInput.Colors(repeating: .zero)
        colors[ShellRole.accent.rawValue] = SIMD4(0.35, 0.8, 0.65, 1)
        colors[ShellRole.foreground.rawValue] = SIMD4(1, 1, 1, 1)
        return ShellShaderInput(values: values, rate: 60, colors: colors).uniforms(
            size: size, scale: 1, elapsed: time, now: time, transition: .settled
        )
    }

    private static func chance(_ seed: UInt32, _ index: UInt32, _ salt: UInt32) -> Double {
        func pcg(_ value: UInt32) -> UInt32 {
            let state = value &* 747_796_405 &+ 2_891_336_453
            let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277_803_737
            return (word >> 22) ^ word
        }
        return Double(pcg(seed ^ pcg(index ^ pcg(salt)))) / 4_294_967_295
    }

    func testTheSeekWaveRunsOnlyAlongThePlayedLengthMovesWithTimeAndBreathesForStreams() throws {
        let program = try pipeline("vitreus-seek.metal")
        let size = CGSize(width: 200, height: 20)
        func pixels(_ values: SIMD4<Float>, _ time: Double) throws -> [UInt8] {
            try ShellShaderTests.pixels(program, uniforms(values, size: size, time: time), width: 200, height: 20)
        }
        func drawn(_ bytes: [UInt8], column: Int) -> Bool {
            (0 ..< 20).contains { bytes[($0 * 200 + column) * 4 + 3] > 0 }
        }
        let early = try pixels(SIMD4(1, 96, 0, 0), 0)
        XCTAssertTrue((8 ..< 98).allSatisfy { drawn(early, column: $0) })
        XCTAssertFalse((106 ..< 200).contains { drawn(early, column: $0) })
        XCTAssertNotEqual(early, try pixels(SIMD4(1, 96, 0, 0), 0.75))
        XCTAssertTrue(try pixels(SIMD4(1, 0, 0, 0), 0.4).allSatisfy { $0 == 0 })
        let total = { (bytes: [UInt8]) in stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) } }
        let crest = try total(pixels(SIMD4(1, 192, 0, 1), 0.75))
        let trough = try total(pixels(SIMD4(1, 192, 0, 1), 2.25))
        XCTAssertGreaterThan(Double(crest), Double(trough) * 1.3)
    }

    func testThirtySixSparksBurstFromTheCoverAndAreAllGoneByTheirLongestLife() throws {
        let program = try pipeline("vitreus-sparks.metal")
        let side = 260
        for time in [0.0, 0.25, 0.6, 1.07] {
            let bytes = try ShellShaderTests.pixels(
                program, uniforms(SIMD4(1, 3, 0, 0), size: CGSize(width: side, height: side), time: time),
                width: side, height: side
            )
            let invalid = stride(from: 0, to: bytes.count, by: 4).count {
                bytes[$0] > bytes[$0 + 3] || bytes[$0 + 1] > bytes[$0 + 3] || bytes[$0 + 2] > bytes[$0 + 3]
            }
            XCTAssertEqual(invalid, 0, "t=\(time)")
            var alive = 0
            for index in UInt32(0) ..< 36 {
                let age = time - Self.chance(3, index, 7) * 0.06
                guard age > 0, age < (0.5 + 0.5 * Self.chance(3, index, 1)) * 0.95 else { continue }
                let angle = (Self.chance(3, index, 4) - 0.5) * 2 * .pi
                let speed = 70 + 100 * Self.chance(3, index, 5)
                let carried = (1 - exp(-1.2 * age)) / 1.2
                let x = cos(angle) * speed * carried, y = sin(angle) * speed * carried + 40 * (age - carried) / 1.2
                alive += 1
                let pixel = (Int(Double(side) / 2 + y) * side + Int(Double(side) / 2 + x)) * 4 + 3
                XCTAssertGreaterThan(bytes[pixel], 0, "spark \(index) at t=\(time)")
            }
            XCTAssertEqual(alive > 0, stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }, "t=\(time)")
            if time == 0.25 { XCTAssertEqual(alive, 36) }
        }
    }

    func testTheCoverEffectBloomsItsOwnColoursUnderTheArtAndDesaturatesWhilePaused() throws {
        let program = try pipeline("vitreus-cover.metal")
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 60, height: 60, bitsPerComponent: 8, bytesPerRow: 240, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 15, y: 15, width: 30, height: 30))
        let texture = try XCTUnwrap(ShellShaderTexture.make(XCTUnwrap(context.makeImage())))
        func pixels(_ values: SIMD4<Float>) throws -> [UInt8] {
            try ShellShaderTests.pixels(
                program, uniforms(values, size: CGSize(width: 60, height: 60), time: 0), width: 60, height: 60,
                source: texture
            )
        }
        func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
            Array(bytes[(y * 60 + x) * 4 ..< (y * 60 + x) * 4 + 4])
        }
        let lit = try pixels(SIMD4(1, 10, 0.6, 0))
        let plain = try pixels(SIMD4(1, 0, 0, 0))
        let grey = try pixels(SIMD4(0.3, 10, 0.6, 0))
        XCTAssertEqual(pixel(lit, 30, 30), pixel(plain, 30, 30))
        XCTAssertGreaterThan(pixel(lit, 30, 30)[2], 240)
        XCTAssertLessThan(pixel(lit, 30, 30)[1], 40)
        let luma = 0.2126 + 0.7874 * 26 / 255
        XCTAssertEqual(Double(pixel(grey, 30, 30)[2]), (luma + 0.3 * (1 - luma)) * 255, accuracy: 3)
        XCTAssertEqual(Double(pixel(grey, 30, 30)[1]), (luma + 0.3 * (26 / 255 - luma)) * 255, accuracy: 3)
        XCTAssertGreaterThan(pixel(lit, 11, 30)[3], 0)
        XCTAssertEqual(pixel(plain, 11, 30)[3], 0)
        XCTAssertGreaterThan(pixel(lit, 11, 30)[2], pixel(lit, 11, 30)[1])
        XCTAssertEqual(pixel(lit, 1, 1)[3], 0)
    }
}
