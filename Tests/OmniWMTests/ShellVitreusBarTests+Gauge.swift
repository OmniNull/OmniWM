// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

private let unit = 1.35

private struct BandCase {
    let name: String
    let opacity: Double
    let alpha: String
    let rim: Double
    let background: String
    let share: Double
}

private struct PieceImage {
    let bytes: [UInt8]
    let crop: CGRect
    let scale: Int

    var width: Int {
        Int(crop.width) * scale
    }

    func pixel(_ x: CGFloat, _ y: CGFloat) -> [Int] {
        device(Int((x - crop.minX) * CGFloat(scale)), Int((y - crop.minY) * CGFloat(scale)))
    }

    func device(_ column: Int, _ row: Int) -> [Int] {
        let index = (row * width + column) * 4
        return bytes[index ..< index + 4].map(Int.init)
    }

    func brightest(in rect: CGRect) -> [Int] {
        var best = [0, 0, 0, 0]
        for y in stride(from: rect.minY, to: rect.maxY, by: 1 / CGFloat(scale)) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 1 / CGFloat(scale)) {
                let value = pixel(x, y)
                if value[0 ..< 3].max() ?? 0 > best[0 ..< 3].max() ?? 0 { best = value }
            }
        }
        return best
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
    func pieceGauge(_ shell: URL, _ level: Double, charging: Bool = false, animations: Bool = false) throws
        -> ShellRenderedWidget
    {
        try pieceWidget(shell, animations: animations) { widget in
            widget.set("battery") { $0.number(level) }
            widget.set("charging") { $0.bool(charging) }
        }
    }

    func pieceOpacities(_ widget: ShellRenderedWidget) throws -> [Double] {
        try ["battery-track", "battery-fill", "battery-nub"].map { try Double(piecePaint(widget, $0).opacity) }
    }

    func testBatteryGaugeShowsWhileTheBarIsHoveredOrLowWithTrackFillAndNubBodies() throws {
        let shell = try shell()
        let calm = try pieceGauge(shell, 50)
        XCTAssertEqual(try pieceOpacities(calm), [0, 0, 0])
        let pill = try VitreusFixture.frame(calm, key: "shell")
        let x = pill.minX + 7 * unit
        let full = pill.width - 14 * unit - 6.6 * unit
        let tall = pill.height - 14 * unit
        XCTAssertEqual(try VitreusFixture.frame(calm, key: "battery-track-shape").height, 0.7 * tall, accuracy: 0.001)
        try pieceHover(calm, "title-region", .began)
        for (value, target) in zip(try pieceOpacities(calm), [0.1, 0.19, 0.19]) {
            XCTAssertEqual(value, target, accuracy: 1e-6)
        }
        Self.assertRect(try VitreusFixture.frame(calm, key: "battery-track-shape"), CGRect(
            x: x, y: pill.midY - tall / 2, width: full, height: tall
        ))
        let nub = try VitreusFixture.frame(calm, key: "battery-track-nub")
        XCTAssertEqual(nub.midX, x + full + 3.1 * unit, accuracy: 0.001)
        XCTAssertEqual(nub.width, 7 * unit, accuracy: 0.001)
        XCTAssertEqual(nub.height, 0.56 * tall, accuracy: 0.001)
        Self.assertRect(try VitreusFixture.frame(calm, key: "battery-fill-shape"), CGRect(
            x: x, y: pill.midY - tall / 2, width: full / 2, height: tall
        ))
        let fillBody = try VitreusFixture.frame(calm, key: "battery-fill")
        XCTAssertEqual(fillBody.minX, x - full / 2 * 0.28 / 0.72, accuracy: 0.001)
        XCTAssertEqual(fillBody.maxX, x + full / 2, accuracy: 0.001)
        Self.assertRect(try VitreusFixture.frame(calm, key: "battery-nub-shape"), CGRect(
            x: x + full, y: pill.midY - 0.28 * tall, width: 6.6 * unit, height: 0.56 * tall
        ))
        let recipes = try ["battery-track", "battery-fill", "battery-nub"].map { try pieceRecipe(calm, $0) }
        XCTAssertEqual(recipes.map(\.flat), [true, true, true])
        XCTAssertEqual(recipes.map(\.rim), [0.1, 0.18, 0])
        XCTAssertEqual(recipes.map(\.blend), [0, 0, 0])
        XCTAssertEqual(recipes[1].gradientAngle, 0)
        let fill = try piecePaint(calm, "battery-fill")
        XCTAssertTrue(fill.gradientSpecified)
        XCTAssertEqual(fill.gradientFrom.role & 0xFF, UInt16(ShellRole.secondaryContainer.rawValue + 1))
        XCTAssertEqual(fill.gradientTo.role & 0xFF, UInt16(ShellRole.accent.rawValue + 1))
        XCTAssertEqual(try piecePaint(calm, "battery-track").shadow.alpha, 0)
        XCTAssertFalse(Self.has(calm, "battery-glint"))
        let low = try pieceGauge(shell, 15)
        for (value, target) in zip(try pieceOpacities(low), [0.1, 0.28, 0.28]) {
            XCTAssertEqual(value, target, accuracy: 1e-6)
        }
        let red = try piecePaint(low, "battery-fill").gradientTo
        XCTAssertEqual([red.red, red.green, red.blue].map { ($0 * 255).rounded() }, [224, 101, 90])
        XCTAssertFalse(Self.has(try pieceWidget(shell), "battery-track"))
    }

    func testBatteryGaugeAlsoShowsOverTheWorkspaceMarksAndLetsClicksThrough() throws {
        let shell = try shell()
        var data = VitreusFixture.bar()
        data.workspaces = [ShellBarWorkspace(id: "1", name: "One", focused: true, windows: [])]
        let widget = try pieceWidget(shell, pieces: .strings(["workspaces", "title", "gear"])) { widget in
            widget.set("battery") { $0.number(50) }
        }
        VitreusFixture.show(widget, bar: data)
        XCTAssertEqual(try pieceOpacities(widget), [0, 0, 0])
        try pieceHover(widget, "workspace-hit-1", .began, bar: data)
        for (value, target) in zip(try pieceOpacities(widget), [0.1, 0.19, 0.19]) {
            XCTAssertEqual(value, target, accuracy: 1e-6)
        }
        let gear = try VitreusFixture.frame(widget, key: "bar-gear")
        let point = CGPoint(x: gear.midX, y: gear.midY)
        XCTAssertTrue(try VitreusFixture.frame(widget, key: "battery-track-shape").contains(point))
        XCTAssertEqual(widget.surface.command(at: point), "shell menu")
        try pieceHover(widget, "workspace-hit-1", .ended, bar: data)
        XCTAssertEqual(try pieceOpacities(widget), [0, 0, 0])
    }

    func testChargingGlintLoopsOnlyWithMotionAndStopsWhenFull() throws {
        let shell = try shell()
        for animations in [false, true] {
            let widget = try pieceGauge(shell, 15, charging: true, animations: animations)
            for (value, target) in zip(try pieceOpacities(widget), [0.1, 0.19, 0.19]) {
                XCTAssertEqual(value, target, accuracy: 1e-6)
            }
            let pill = try VitreusFixture.frame(widget, key: "shell")
            Self.assertRect(try VitreusFixture.frame(widget, key: "battery-glint"), pill)
            let band = try VitreusFixture.element(widget, key: "battery-glint-band")
            let paint = widget.surface.layout.core.paint(of: band)
            let loop = try XCTUnwrap(ShellLoop(widget.text.string(paint.loop)))
            XCTAssertEqual(loop.channels.map(\.name), ["dx"])
            XCTAssertEqual(Double(loop.channels[0].to), (pill.width + 130 * unit) * 5 / 0.6, accuracy: 0.01)
            XCTAssertEqual(loop.channels[0].duration, 5)
            XCTAssertEqual(try VitreusFixture.frame(widget, key: "battery-glint-band").maxX, pill.minX, accuracy: 0.001)
            let running = ShellLayerScene.engineQueue.sync { widget.surface.scene.loops[band.slot] != nil }
            XCTAssertEqual(running, animations)
        }
        XCTAssertFalse(Self.has(try pieceGauge(shell, 99, charging: true), "battery-glint"))
        XCTAssertTrue(Self.has(try pieceGauge(shell, 97, charging: true), "battery-glint"))
    }
}

@MainActor
extension ShellVitreusBarTests {
    fileprivate func pieceBand(_ entry: BandCase, rim: Double, scale: Int) throws -> [Int]? {
        let widget = try ShellRenderedWidget(name: "band", source: """
        function render(ctx)
            return ui.stack{ w = 96, h = 64,
                ui.box{ w = 96, h = 64, fill = "\(entry.background)" },
                ui.glass{ key = "band", w = 96, h = 64, backdrop = false, fill = "#5a7a6c\(entry.alpha)", rim = \(rim),
                    opacity = \(entry.opacity), blend = 0, shadow = 0,
                    ui.shape{ align = "topLeading", dx = 16, dy = 16, w = 64, h = 32, radius = 12 } } }
        end
        """, scale: CGFloat(scale))
        widget.render(ShellBarData())
        widget.surface.view.frame = CGRect(origin: .zero, size: widget.surface.size)
        let body = try VitreusFixture.body(widget, key: "band")
        guard ShellLayerScene.engineQueue.sync(execute: { body.nativeAvailable }) else { return nil }
        let crop = CGRect(x: 0, y: 0, width: 96, height: 64)
        let image = try PieceImage(
            bytes: VitreusFixture.pixels(widget, crop: crop, scale: scale),
            crop: crop,
            scale: scale
        )
        return (0 ..< 3 * scale).map { image.device(16 * scale + $0, 32 * scale)[1] }
    }

    func testBatteryRimBandsFollowTheirBodyOpacityLikePleamarOverAnyBackground() throws {
        let dark = "#1B2127", grey = "#808080"
        let cases = [
            BandCase(name: "opaque", opacity: 1, alpha: "ff", rim: 0.1, background: dark, share: 1),
            BandCase(name: "track", opacity: 0.1, alpha: "ff", rim: 0.1, background: dark, share: 0.1),
            BandCase(name: "track-grey", opacity: 0.1, alpha: "ff", rim: 0.1, background: grey, share: 0.1),
            BandCase(name: "fill", opacity: 0.19, alpha: "ff", rim: 0.18, background: dark, share: 0.19),
            BandCase(name: "fill-low", opacity: 0.28, alpha: "ff", rim: 0.18, background: grey, share: 0.28),
            BandCase(name: "fill-alpha", opacity: 1, alpha: "1a", rim: 0.1, background: dark, share: 0x1A / 255),
            BandCase(name: "fill-alpha-grey", opacity: 1, alpha: "1a", rim: 0.1, background: grey, share: 0x1A / 255)
        ]
        for scale in [1, 2] {
            for entry in cases {
                guard let lit = try pieceBand(entry, rim: entry.rim, scale: scale),
                      let unlit = try pieceBand(entry, rim: 0, scale: scale)
                else { throw XCTSkip("Native glass is unavailable") }
                let band = zip(lit, unlit).map { $0 - $1 }
                let pleamar = (0 ..< band.count).map { depth -> Double in
                    let ramp = min(max((-(Double(depth) + 0.5) / Double(scale) + 2.2) / 1.8, 0), 1)
                    return entry.share * entry.rim * 253 * ramp * ramp * (3 - 2 * ramp)
                }
                let label = "\(entry.name) \(scale)x"
                let reference = pleamar.map { ($0 * 10).rounded() / 10 }
                print("vitreus-battery-band \(label) measured \(band) pleamar \(reference)")
                XCTAssertTrue(band.allSatisfy { $0 >= 0 }, "\(label) \(band)")
                guard entry.alpha == "ff" else { continue }
                let tolerance = max(1.5, 0.1 * (pleamar.first ?? 0))
                for (value, target) in zip(band, pleamar) {
                    XCTAssertEqual(Double(value), target, accuracy: tolerance, "\(label) \(band)")
                }
            }
        }
    }

    func pieceSnapshotWidget(_ shell: URL, scale: Int) throws -> ShellRenderedWidget {
        let widget = try pieceWidget(shell, scale: CGFloat(scale)) { widget in
            widget.set("clock") { $0.string("9:41\u{202F}AM") }
            widget.set("date") { $0.string("Tue 28 Oct") }
            widget.set("app") { $0.string("Safari") }
            widget.set("title") { $0.string("Apple – Start Page") }
            widget.set("media") { ShellMedia(title: "Song", app: "Music", playing: true).write(into: &$0) }
            widget.set("privacy") { ShellPrivacy(microphone: true, camera: false).write(into: &$0) }
            widget.set("battery") { $0.number(64) }
        }
        let body = try VitreusFixture.body(widget, key: "bar")
        guard ShellLayerScene.engineQueue.sync(execute: { body.nativeAvailable }) else {
            throw XCTSkip("Native glass is unavailable")
        }
        return widget
    }

    fileprivate func pieceImage(_ widget: ShellRenderedWidget, scale: Int) throws -> PieceImage {
        let crop = CGRect(x: 0, y: 0, width: 1920, height: 120)
        return try PieceImage(bytes: VitreusFixture.pixels(widget, crop: crop, scale: scale), crop: crop, scale: scale)
    }

    func testPieceSnapshotsShowTheIslandBarWithItsDataAtOneAndTwoX() throws {
        let shell = try shell()
        for scale in [1, 2] {
            let widget = try pieceSnapshotWidget(shell, scale: scale)
            let pill = try VitreusFixture.frame(widget, key: "shell")
            let probe = CGPoint(x: pill.minX + 7 * unit + 2, y: pill.midY + 12)
            let rest = try pieceImage(widget, scale: scale)
            try pieceHover(widget, "title-region", .began)
            let shown = try pieceImage(widget, scale: scale)
            let label = "vitreus-bar-pieces-1920x1080-\(scale)x"
            XCTAssertGreaterThan(shown.pixel(probe.x, probe.y)[1], rest.pixel(probe.x, probe.y)[1] + 2, label)
            for key in ["clock-hour", "clock-tail", "title-text", "title-app"] {
                let best = shown.brightest(in: try VitreusFixture.frame(widget, key: key))
                XCTAssertGreaterThan(best[0 ..< 3].max() ?? 0, 120, "\(label) \(key)")
            }
            XCTAssertGreaterThan(
                shown.brightest(in: try VitreusFixture.frame(widget, key: "tray-microphone"))[2],
                120,
                label
            )
            for point in [CGPoint(x: pill.minX - 30, y: pill.midY), CGPoint(x: pill.midX, y: pill.maxY + 30)] {
                XCTAssertEqual(shown.pixel(point.x, point.y)[3], 0, "\(label) \(point)")
            }
            for key in ["clock-hour", "title-text"] {
                let frame = try VitreusFixture.frame(widget, key: key)
                let before = rest.brightest(in: frame), after = shown.brightest(in: frame)
                print("vitreus-gauge-over-text \(label) \(key) rest \(before) shown \(after)")
                XCTAssertEqual(after, before, "\(label) \(key)")
            }
            try ShellVitreusDeskTests.write(XCTUnwrap(shown.image()), name: label)
        }
    }

    func testTitleTabMeltsOutBelowThePillAsFarAsTheVitreusTab() throws {
        let shell = try shell()
        let blend = 6.0, depth = 3.5
        let vitreus = CGFloat((depth + (blend - depth) * (blend - depth) / (4 * blend)) * unit)
        for scale in [1, 2] {
            let widget = try pieceSnapshotWidget(shell, scale: scale)
            let pill = try VitreusFixture.frame(widget, key: "shell")
            try pieceHover(widget, "title-region", .began)
            let flat = try pieceImage(widget, scale: scale)
            try pieceHover(widget, "title-button", .began)
            let tabbed = try pieceImage(widget, scale: scale)
            let column = try VitreusFixture.frame(widget, key: "title-tab").midX
            func reach(_ image: PieceImage) -> CGFloat {
                var y = pill.maxY - 3
                while y < 119, image.pixel(column, y)[3] >= 46 { y += 1 / CGFloat(scale) }
                return y - pill.maxY
            }
            let label = "vitreus-bar-pieces-1920x1080-\(scale)x-title-tab"
            print("vitreus-title-tab-reach \(label) without \(reach(flat)) with \(reach(tabbed)) vitreus \(vitreus)")
            XCTAssertEqual(reach(flat), 0, accuracy: 1, label)
            XCTAssertEqual(reach(tabbed), vitreus, accuracy: 1, label)
            try ShellVitreusDeskTests.write(XCTUnwrap(tabbed.image()), name: label)
        }
    }
}
