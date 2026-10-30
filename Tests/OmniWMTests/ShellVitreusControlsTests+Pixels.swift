// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

extension ShellVitreusControlsTests {
    func testControlsHaveNativePixelsAtBothScalesAndExpandedWindowsStayInsideTheDrawer() throws {
        let widget = try fixture()
        try snapshot(widget, "controls", scales: [1, 2])
        widget.set("audioApps") {
            ShellAudioApps(access: .granted, apps: [
                .init(id: "test.music", name: "Music Player", playing: true, volume: 50, muted: false),
                .init(id: "test.browser", name: "Web Browser", playing: true, volume: 84, muted: false)
            ]).write(into: &$0)
        }
        _ = try invoke(widget, "controls-mixer-toggle")
        try snapshot(widget, "controls-mixer", scales: [2])
        for name in ["wifi", "bluetooth", "caffeine", "notifications", "capture", "power"] {
            _ = try invoke(widget, "controls-tile-" + name)
            let panel = try VitreusFixture.frame(widget, key: "drawer-content-controls")
            for key in ["controls-back", "controls-window-title"] {
                let frame = try VitreusFixture.frame(widget, key: key)
                XCTAssertTrue(panel.insetBy(dx: -0.1, dy: -0.1).contains(frame), key)
            }
            try snapshot(widget, "controls-" + name, scales: [2])
            _ = try invoke(widget, "controls-back")
        }
    }

    func snapshot(_ widget: ShellRenderedWidget, _ name: String, scales: [Int]) throws {
        let frame = try VitreusFixture.frame(widget, key: "drawer-content-controls")
        let crop = frame.insetBy(dx: -10, dy: -10).integral
        for scale in scales {
            let bytes = try VitreusFixture.pixels(widget, crop: crop, scale: scale)
            let width = Int(crop.width) * scale, height = Int(crop.height) * scale
            let x = Int((frame.midX - crop.minX) * Double(scale))
            let y = Int((frame.minY + 4 * cu - crop.minY) * Double(scale))
            XCTAssertGreaterThan(bytes[(y * width + x) * 4 + 3], 40)
            guard let output = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] else { continue }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let image = try XCTUnwrap(CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo.byteOrder32Little
                    .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            ))
            let folder = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("vitreus-\(name)-\(scale)x.png"))
        }
    }
}
