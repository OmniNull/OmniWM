// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import XCTest

extension ShellVitreusFrameTests {
    func testDisplaySizedFrameHasClearNativeHolePixelsAndSnapshotsOnEveryEdge() async throws {
        for edge in ["left", "right", "ftop", "fbottom"] {
            let fixture = try fixture(edge)
            if edge == "left" || edge == "right" { try await prepareClock(fixture) }
            for scale in [1, 2] {
                let pixels = try VitreusFixture.pixels(
                    fixture.widget,
                    crop: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    scale: scale
                )
                let width = 1920 * scale
                for y in stride(from: 160, through: 920, by: 80) {
                    for x in stride(from: 160, through: 1760, by: 80) {
                        XCTAssertEqual(
                            pixels[((y * scale) * width + x * scale) * 4 + 3],
                            0,
                            "\(edge), \(scale)×, point=\(x),\(y)"
                        )
                    }
                }
                if edge == "left" || edge == "right" {
                    let clock = try frame(fixture, "clock-numerals").insetBy(dx: 8, dy: 4)
                    let lit = stride(from: Int(clock.minY * Double(scale)), to: Int(clock.maxY * Double(scale)), by: 1)
                        .contains { y in
                            stride(from: Int(clock.minX * Double(scale)), to: Int(clock.maxX * Double(scale)), by: 1)
                                .contains { x in pixels[(y * width + x) * 4 + 2] > 150 }
                        }
                    XCTAssertTrue(lit, "The vertical clock numerals are visible on \(edge) at \(scale)×")
                }
                if scale == 1 { try save(pixels, width: width, height: 1080, name: "frame-" + edge) }
            }
            VitreusFixture.trigger(fixture.widget.instance, "drawer-controls", fixture.bar.monitorId)
            show(fixture)
            let panel = try frame(fixture, "drawer-content-controls")
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 1920, height: 1080).contains(panel), edge)
            if edge == "left" || edge == "ftop" {
                let pixels = try VitreusFixture.pixels(
                    fixture.widget,
                    crop: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    scale: 1
                )
                try save(pixels, width: 1920, height: 1080, name: "frame-" + edge + "-controls")
            }
        }
    }

    private func prepareClock(_ fixture: Fixture) async throws {
        let library = fixture.widget.resources.shaders
        let program = library.program(
            source: "vitreus-clock-gradient.metal",
            directories: fixture.widget.surface.shaderDirectories
        )
        if program.isCompiling {
            let previous = library.onChange
            await withCheckedContinuation { continuation in
                library.onChange = {
                    previous?()
                    if !program.isCompiling {
                        library.onChange = previous
                        continuation.resume()
                    }
                }
            }
        }
        XCTAssertNotNil(program.pipeline, program.failure ?? "Clock shader did not compile")
        fixture.widget.surface.refreshShaders()
        let slot = try VitreusFixture.element(fixture.widget, key: "clock-numerals").slot
        let output = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(fixture.widget.surface.scene.effects[slot]?.output)
        }
        let published = expectation(description: "The clock shader published its first image")
        published.assertForOverFulfill = false
        let observation = output.observe(\.contents, options: [.initial, .new]) { layer, _ in
            if layer.contents != nil { published.fulfill() }
        }
        await fulfillment(of: [published], timeout: 5)
        withExtendedLifetime(observation) {}
    }

    private func save(_ bytes: [UInt8], width: Int, height: Int, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] else { return }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Little
                .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst
                        .rawValue)),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent("vitreus-" + name + ".png"))
    }
}
