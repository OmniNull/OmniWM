// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import UniformTypeIdentifiers
import XCTest

struct VitreusRaster {
    let bytes: [UInt8]
    let width: Int
    let scale: CGFloat

    func rgba(_ x: CGFloat, _ y: CGFloat) -> [Int] {
        let index = (Int(y * scale) * width + Int(x * scale)) * 4
        return bytes[index ..< index + 4].map(Int.init)
    }

    func empty(_ rect: CGRect) -> Bool {
        stride(from: rect.minY, to: rect.maxY, by: 1 / scale).allSatisfy { row in
            stride(from: rect.minX, to: rect.maxX, by: 1 / scale).allSatisfy { rgba($0, row)[3] == 0 }
        }
    }

    func varies(_ rect: CGRect, from base: [Int]) -> Bool {
        stride(from: rect.minY, to: rect.maxY, by: 1 / scale).contains { row in
            stride(from: rect.minX, to: rect.maxX, by: 1 / scale).contains { column in
                let pixel = rgba(column, row)
                return (0 ..< 4).contains { abs(pixel[$0] - base[$0]) > 60 }
            }
        }
    }
}

@MainActor
extension ShellVitreusDeskTests {
    static func envelope(width: CGFloat, height: CGFloat) -> (rect: CGRect, du: CGFloat) {
        let du = 1.5525 * min(max(height / 1350, 0.55), 1)
        return (CGRect(x: width - 7.5 * du - 353 * du, y: height / 2 - 230 * du, width: 353 * du, height: 460 * du), du)
    }

    private func raster(_ widget: ShellRenderedWidget, scale: CGFloat) throws -> VitreusRaster {
        let layer = try XCTUnwrap(widget.surface.view.layer)
        let width = Int(ceil(widget.surface.size.width * scale))
        let height = Int(ceil(widget.surface.size.height * scale))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        ShellLayerScene.engineQueue.sync { layer.render(in: context) }
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return VitreusRaster(
            bytes: Array(UnsafeBufferPointer(start: data, count: width * height * 4)),
            width: width,
            scale: scale
        )
    }

    nonisolated static func write(_ image: CGImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            folder.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func export(_ raster: VitreusRaster, crop: CGRect, name: String) throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] != nil else { return }
        let width = Int(crop.width * raster.scale)
        let height = Int(crop.height * raster.scale)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let tile = Int(20 * raster.scale)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let source = raster.rgba(
                    crop.minX + CGFloat(column) / raster.scale,
                    crop.minY + CGFloat(row) / raster.scale
                )
                let checker = (column / tile + row / tile).isMultiple(of: 2) ? 51 : 71
                for channel in 0 ..< 3 {
                    pixels[(row * width + column) * 4 + channel] = UInt8(min(
                        255,
                        source[channel] + checker * (255 - source[3]) / 255
                    ))
                }
            }
        }
        try Self.write(XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData)), decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )), name: name)
    }

    private func assertFramePixels(
        _ image: VitreusRaster,
        _ widget: ShellRenderedWidget,
        rect: CGRect,
        du: CGFloat,
        scale: CGFloat = 1,
        label: String
    ) throws {
        let cx = rect.minX + 176.5 * du
        let grip = image.rgba(cx, rect.minY + 11 * du)
        for (channel, ink) in [0xF5, 0xF7, 0xF5].enumerated() {
            let composite = grip[channel] + 51 * (255 - grip[3]) / 255
            XCTAssertEqual(composite, Int((0.2 * Double(ink) + 0.8 * 51).rounded()), accuracy: 3, label)
        }
        XCTAssertEqual(grip[3], 51, accuracy: 3, label)
        XCTAssertEqual(image.rgba(cx + 143 * du, rect.minY + 49 * du)[3], 20, accuracy: 3, label)
        for tab in ["tab-pad", "tab-focus"] {
            let frame = try VitreusFixture.frame(widget, key: tab)
            let base = image.rgba(frame.midX, frame.minY + 3 * du)
            XCTAssertTrue(
                image.varies(frame.insetBy(dx: frame.width / 4, dy: frame.height / 4), from: base),
                "\(label) \(tab)"
            )
        }
        let corner = rect.minX + 2 * scale + (26 * du - 2 * scale) - (26 * du - 2 * scale + 1.5) / 2.squareRoot()
        let outside = [
            CGPoint(x: corner, y: corner - rect.minX + rect.minY), CGPoint(x: rect.minX + 1, y: rect.minY + 1),
            CGPoint(x: rect.maxX - 1, y: rect.minY + 1), CGPoint(x: rect.minX + 1, y: rect.maxY - 1),
            CGPoint(x: rect.maxX - 1, y: rect.maxY - 1), CGPoint(x: rect.minX - 4, y: rect.midY)
        ]
        for point in outside {
            XCTAssertEqual(image.rgba(point.x, point.y)[3], 0, "\(label) \(point)")
        }
        let toggles = CGRect(x: rect.minX + 6.5 * du, y: rect.minY + 411 * du, width: 340 * du, height: 20 * du)
        XCTAssertTrue(image.empty(toggles), label)
    }

    private func snapshot(_ page: String, size: CGSize, scale: CGFloat) throws {
        let monitor = VitreusFixture.monitor(width: size.width, height: size.height)
        let widget = try VitreusFixture.desk(shell(), monitor: monitor, scale: scale)
        if page == "pad" {
            try VitreusFixture.click(widget, key: "tab-pad", on: monitor)
            for text in ["Review the Desk", "Ship Vitreus"] {
                var event = ShellEvent()
                event.text = text
                widget.invoke(
                    try XCTUnwrap(widget.tree().first { $0.kind == .input }).content.inputCommitAction,
                    event: event
                )
                VitreusFixture.show(widget, on: monitor)
            }
        }
        let name = "vitreus-\(page)-\(Int(size.width))x\(Int(size.height))-\(Int(scale))x"
        let image = try raster(widget, scale: scale)
        let (rect, du) = Self.envelope(width: size.width, height: size.height)
        try assertFramePixels(image, widget, rect: rect, du: du, label: name)
        if page == "focus" {
            let ring = image.rgba(rect.minX + 176.5 * du, rect.minY + 118 * du)
            for (channel, value) in [0x9E, 0xD6, 0xBD, 0xFF].enumerated() {
                XCTAssertEqual(ring[channel], value, accuracy: 4, name)
            }
            for chip in ["chip-15", "chip-30"] {
                let frame = try VitreusFixture.frame(widget, key: chip)
                let base = image.rgba(frame.minX + 2, frame.midY)
                XCTAssertTrue(
                    image.varies(frame.insetBy(dx: frame.width / 4, dy: frame.height / 4), from: base),
                    "\(name) \(chip)"
                )
            }
        }
        try export(image, crop: rect.insetBy(dx: -24, dy: -24), name: name)
    }

    func testFocusSnapshotsKeepTheDeskInsideItsClip() throws {
        try snapshot("focus", size: CGSize(width: 1920, height: 1080), scale: 1)
        try snapshot("focus", size: CGSize(width: 1280, height: 720), scale: 2)
    }

    func testPadSnapshotsKeepTheDeskInsideItsClip() throws {
        try snapshot("pad", size: CGSize(width: 1920, height: 1080), scale: 1)
    }

    func testAHalfSizeDeskIsRelaidOutWithCrispTextAndTheScaledFramePixels() throws {
        let widget = try VitreusFixture.desk(shell(), scale: 2)
        let (home, du) = Self.envelope(width: 1920, height: 1080)
        let time = try VitreusFixture.frame(widget, key: "time")
        try VitreusFixture.drag(widget, key: "resize-sw", by: CGVector(dx: 200 * du, dy: -200 * du))
        let rect = try VitreusFixture.frame(widget, key: "desk")
        XCTAssertEqual(rect.width / home.width, 0.5, accuracy: 1e-6)
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "time").height, time.height / 2, accuracy: 1)
        let slots = try ["desk", "time"].map { try VitreusFixture.element(widget, key: $0).slot }
        let scene = widget.surface.scene
        let (wrapper, text) = ShellLayerScene.engineQueue.sync {
            (
                scene.gestureLayers[slots[0]]?.layer.transform ?? CATransform3DIdentity,
                scene.layers[slots[1]]?.contentsScale
            )
        }
        XCTAssertTrue(CATransform3DIsIdentity(wrapper))
        XCTAssertEqual(text, 2)
        let name = "vitreus-focus-half-1920x1080-2x"
        let image = try raster(widget, scale: 2)
        try assertFramePixels(image, widget, rect: rect, du: du / 2, scale: 0.5, label: name)
        try export(image, crop: rect.insetBy(dx: -24, dy: -24), name: name)
    }

    func testTheBarPreviewHasNoLaneWidgetsBecauseTheIslandDrawsTheBar() async throws {
        let config = try VitreusFixture.config(shell())
        XCTAssertEqual(config.leading + config.center + config.trailing, [])
        do {
            _ = try await ShellSettingsPreview.render(.init(
                config: config, surface: .bar,
                style: ShellSettingsPreview.style(settings: WorkspaceBarSettings(), config: config), scale: 1,
                dark: true, fullWidth: true, sourceGeneration: 0
            ))
            XCTFail("the Vitreus profile has no bar lane widgets to preview")
        } catch let failure as ShellScriptFailure {
            XCTAssertEqual(failure.message, "Add a widget to preview the bar.")
        }
    }

    func testSettingsIslandPreviewDrawsTheDeskAndNativeGlass() async throws {
        let shell = try shell()
        let config = try VitreusFixture.config(shell)
        let island = try XCTUnwrap(config.island)
        let request = ShellSettingsPreview.Request(
            config: config, surface: .island(expanded: true), style: .init(), scale: 1, dark: true, fullWidth: true,
            sourceGeneration: 0
        )
        let sample = ShellSettingsPreview.islandData(for: request, config: island)
        XCTAssertEqual(sample.size, CGSize(width: 1440, height: 900))
        let trees = try await ShellSettingsPreviewRenderer.shared.render(
            inputs: [ShellWidgetSourceLoader.Input(
                name: island.root, shellDirectory: shell, sourceURL: XCTUnwrap(config.widget(island.root)),
                directories: config.directories, profile: config.profile, components: island.components
            )],
            values: ShellSettingsPreviewSamples.values(
                style: .init(),
                islandSize: sample.size,
                dark: true,
                scale: 1,
                surface: sample
            ),
            settings: config.widgetSettings, expanded: true
        )
        let text = ShellTextStore()
        let tree = try XCTUnwrap(trees.first)
        text.ingest(tree.strings, count: tree.stringCount)
        for caption in ["Pad", "Focus", "READY", "30:00"] {
            XCTAssertTrue(text.strings.contains(caption), caption)
        }
        let expanded = try await ShellSettingsPreview.render(request)
        XCTAssertEqual(CGSize(width: expanded.width, height: expanded.height), sample.size)
        let bytes = try XCTUnwrap(expanded.dataProvider?.data) as Data
        func alpha(_ x: CGFloat, _ y: CGFloat) -> UInt8 {
            bytes[Int(y) * expanded.bytesPerRow + Int(x) * 4 + 3]
        }
        let (rect, du) = Self.envelope(width: 1440, height: 900)
        XCTAssertTrue((-20 ... 20).contains { alpha(rect.minX + 176.5 * du + CGFloat($0), rect.minY + 182 * du) > 0 })
        XCTAssertGreaterThan(alpha(rect.minX + 3 * du, rect.midY), 80)
        XCTAssertEqual(alpha(rect.minX - 40, rect.midY), 0)
        try Self.write(expanded, name: "settings-vitreus-expanded-dark-1x")
        let compact = try await ShellSettingsPreview.render(.init(
            config: config, surface: .island(expanded: false), style: .init(), scale: 1, dark: true, fullWidth: true,
            sourceGeneration: 0
        ))
        XCTAssertEqual(CGSize(width: compact.width, height: compact.height), sample.size)
        let pill = try XCTUnwrap(compact.dataProvider?.data) as Data
        XCTAssertGreaterThan(pill[35 * compact.bytesPerRow + 720 * 4 + 3], 80)
        XCTAssertEqual(pill[90 * compact.bytesPerRow + 720 * 4 + 3], 0)
        try Self.write(compact, name: "settings-vitreus-compact-dark-1x")
    }
}
