// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

private struct VitreusBarImage {
    let bytes: [UInt8]
    let crop: CGRect
    let scale: Int

    var width: Int {
        Int(crop.width) * scale
    }

    func pixel(_ x: CGFloat, _ y: CGFloat) -> [Int] {
        let row = Int((y - crop.minY) * CGFloat(scale))
        let index = (row * width + Int((x - crop.minX) * CGFloat(scale))) * 4
        return bytes[index ..< index + 4].map(Int.init)
    }

    func image() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width, height: Int(crop.height) * scale, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Little
                .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

@MainActor
extension ShellVitreusBarTests {
    private func snapshot(width: CGFloat, height: CGFloat, scale: Int) throws {
        let monitor = VitreusFixture.monitor(width: width, height: height)
        let widget = try island(shell(), monitor: monitor, scale: CGFloat(scale))
        let label = "vitreus-bar-\(Int(width))x\(Int(height))-\(scale)x"
        let pill = try VitreusFixture.frame(widget, key: "shell")
        XCTAssertEqual(pill.midX, width / 2, accuracy: 0.001, label)
        XCTAssertEqual(pill.size, CGSize(width: 607.5, height: 54), label)
        let crop = CGRect(x: 0, y: 0, width: width, height: 120)
        let body = try VitreusFixture.body(widget, key: "bar")
        guard ShellLayerScene.engineQueue.sync(execute: { body.nativeAvailable }) else {
            throw XCTSkip("Native glass is unavailable")
        }
        let full = try VitreusBarImage(
            bytes: VitreusFixture.pixels(widget, crop: crop, scale: scale), crop: crop, scale: scale
        )
        let bare = try VitreusBarImage(
            bytes: VitreusFixture.pixels(widget, crop: crop, scale: scale, shadowless: true), crop: crop, scale: scale
        )
        let tint = full.pixel(pill.midX, pill.midY)
        XCTAssertGreaterThan(tint[3], 60, label)
        XCTAssertGreaterThan(tint[0], tint[1], label)
        XCTAssertGreaterThan(tint[1], tint[2], label)
        for x in [pill.minX + 2, pill.maxX - 2, pill.midX - 250, pill.midX + 250] {
            XCTAssertGreaterThan(bare.pixel(x, pill.midY)[3], 40, "\(label) \(x)")
        }
        let corner = 18.9 - (18.9 + 2) / 2.squareRoot()
        for point in [
            CGPoint(x: pill.minX + corner, y: pill.minY + corner), CGPoint(
                x: pill.maxX - corner,
                y: pill.minY + corner
            ),
            CGPoint(x: pill.minX - 3, y: pill.midY), CGPoint(x: pill.maxX + 3, y: pill.midY),
            CGPoint(x: pill.midX, y: pill.minY - 3), CGPoint(x: pill.midX, y: pill.maxY + 3)
        ] {
            XCTAssertEqual(bare.pixel(point.x, point.y)[3], 0, "\(label) \(point)")
        }
        XCTAssertGreaterThan(full.pixel(pill.midX, pill.maxY + 3)[3], 0, label)
        for point in [CGPoint(x: pill.minX - 30, y: pill.midY), CGPoint(x: pill.midX, y: pill.maxY + 30)] {
            XCTAssertEqual(full.pixel(point.x, point.y)[3], 0, "\(label) \(point)")
        }
        let left = (1 ... 4).map { bare.pixel(pill.minX + CGFloat($0), pill.midY)[2] }.max() ?? 0
        let right = (1 ... 4).map { bare.pixel(pill.maxX - CGFloat($0), pill.midY)[2] }.max() ?? 0
        XCTAssertGreaterThan(left, right, label)
        let opener = try VitreusFixture.frame(widget, key: "desk-opener")
        XCTAssertGreaterThan(full.pixel(opener.midX, opener.midY + 12)[3], 0, label)
        XCTAssertEqual(full.pixel(opener.minX - 6, opener.midY)[3], 0, label)
        try ShellVitreusDeskTests.write(XCTUnwrap(full.image()), name: label)
    }

    func testEmptyBarPillSnapshotsKeepTheVitreusSilhouetteOnEveryDisplay() throws {
        try snapshot(width: 1920, height: 1080, scale: 1)
        try snapshot(width: 1920, height: 1080, scale: 2)
        try snapshot(width: 1440, height: 900, scale: 2)
        try snapshot(width: 1512, height: 982, scale: 2)
    }
}
