// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellIconTests: XCTestCase {
    private var surface: ShellWidgetSurface?

    private func output(_ source: String) throws -> [UInt8] {
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 8 << 20))
        defer { _ = omni_vm_destroy(vm) }
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(omni_vm_load(vm, "=icon", source, source.utf8.count, 100_000_000, &error, error.count), OMNI_OK)
        let instance = try XCTUnwrap(omni_instance_create(vm))
        defer { omni_instance_destroy(instance) }
        var stats = omni_render_stats()
        XCTAssertEqual(omni_instance_render(instance, OMNI_VIEW_BAR, 8_000_000, &stats, &error, error.count), OMNI_OK)
        var size = 0
        let bytes = try XCTUnwrap(omni_instance_output(instance, OMNI_VIEW_BAR, &size))
        return Array(UnsafeBufferPointer(start: bytes, count: size))
    }

    func testDataDemandBitsMatchTheScriptHost() throws {
        let bytes = try output("function render(ctx) local _ = ctx.data.network return ui.box{ w = 1, h = 1 } end")
        let deps = bytes.withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
        XCTAssertNotEqual(deps & ShellDataKey.network.bit, 0)
        XCTAssertNotNil(SystemStatsSampler.networkBytes())
    }

    func testDataReadsRecordExactlyTheirOwnKeys() throws {
        let bytes = try output("""
        function render(ctx)
            local _ = ctx.data.time, ctx.data.load, ctx.data.swap, ctx.data.network
            return ui.box{ w = 1, h = 1 }
        end
        """)
        let deps = bytes.withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
        XCTAssertEqual(deps, ShellDataKey.network.bit)
    }

    func testDataKeysMatchTheAuthoringDefinitions() throws {
        let url = try XCTUnwrap(ShellWidgetHost.definitionsURL)
        let source = try String(contentsOf: url, encoding: .utf8)
        let body = try XCTUnwrap(source.components(separatedBy: "export type Data = {").last?
            .components(separatedBy: "\n}").first)
        let keys = body.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("    "), !line.hasPrefix("     "), line.contains(":") else { return nil }
            return line.split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        XCTAssertEqual(keys, ShellDataKey.allCases.map(\.rawValue))
    }

    func testVolumeDataIsDemandedAndReadsWithinRange() throws {
        let bytes = try output("function render(ctx) local _ = ctx.data.muted return ui.box{ w = 1, h = 1 } end")
        let deps = bytes.withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
        XCTAssertNotEqual(deps & ShellDataKey.muted.bit, 0)
        guard let device = ShellAudio.defaultOutput(), let volume = ShellAudio.volume(of: device) else {
            throw XCTSkip("no default output with a main volume")
        }
        XCTAssertTrue((0 ... 100).contains(volume))
    }

    func testScaleAndShadowReachTheWire() throws {
        let plain = try output("function render(ctx) return ui.icon{ app = \"com.apple.finder\" } end")
        let styled = try output("""
        function render(ctx)
            return ui.icon{ app = "com.apple.finder", scale = 1.1, shadow = "accent/0.5", shadowRadius = 4 }
        end
        """)
        let node = { (bytes: [UInt8]) in
            bytes.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: MemoryLayout<omni_wire_header>.stride, as: omni_wire_node.self)
            }
        }
        XCTAssertEqual(node(plain).scale, 1)
        XCTAssertEqual(node(plain).shadow_role, 0)
        XCTAssertEqual(node(styled).scale, 1.1, accuracy: 0.0001)
        XCTAssertEqual(node(styled).shadow_radius, 4)
        XCTAssertEqual(node(styled).shadow_role & 0xFF, UInt16(ShellRole.accent.rawValue + 1))
    }

    func testIconElementDrawsTheAppIcon() throws {
        let bytes = try output("function render(ctx) return ui.icon{ app = \"com.apple.finder\" } end")
        let node = bytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: MemoryLayout<omni_wire_header>.stride, as: omni_wire_node.self)
        }
        XCTAssertEqual(ElementKind(rawValue: node.kind), .image)

        let text = ShellTextStore()
        text.ingest(wire: bytes)
        XCTAssertEqual(text.string(node.text), "com.apple.finder")

        let surface = ShellWidgetSurface(
            scale: 2,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            directories: []
        )
        self.surface = surface
        XCTAssertTrue(surface.apply(bytes, text: text))
        XCTAssertEqual(
            surface.size,
            CGSize(width: CGFloat(ShellWireDecoder.iconSize), height: CGFloat(ShellWireDecoder.iconSize))
        )
        ShellLayerScene.engineQueue.sync {}
        let icon = try XCTUnwrap(surface.view.layer?.sublayers?.first?.sublayers?.first)
        XCTAssertNotNil(icon.contents)
    }

    func testIconsResolveFromWindowsAndProcesses() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        let resources = ShellResources(
            motion: MotionPolicy(animationsEnabled: false),
            windowIcon: { $0 == "ow_known" ? image : nil }
        )
        XCTAssertTrue(resources.icon(.window, "ow_known") === image)
        XCTAssertNil(resources.icon(.window, "ow_missing"))
        XCTAssertNotNil(resources.icon(.pid, String(NSRunningApplication.current.processIdentifier)))
        XCTAssertNil(resources.icon(.pid, "not-a-pid"))
    }

    func testMissingIconsDrawTheirPlaceholderAndTintsRecolorIcons() throws {
        let missing = try drawnImage("ui.icon{ window = \"ow_missing\", placeholder = \"app.dashed\" }")
        XCTAssertNotNil(missing)
        XCTAssertNil(try drawnImage("ui.icon{ window = \"ow_missing\" }"))
        let tinted = try XCTUnwrap(drawnImage("ui.icon{ app = \"com.apple.finder\", color = \"#FF0000\" }"))
        let center = try XCTUnwrap(pixel(of: tinted, x: tinted.width / 2, y: tinted.height / 2))
        XCTAssertGreaterThan(center.red, 200)
        XCTAssertLessThan(center.green, 40)
    }

    private func drawnImage(_ element: String) throws -> CGImage? {
        let bytes = try output("function render(ctx) return \(element) end")
        let text = ShellTextStore()
        text.ingest(wire: bytes)
        let surface = ShellWidgetSurface(
            scale: 2,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            directories: []
        )
        self.surface = surface
        XCTAssertTrue(surface.apply(bytes, text: text))
        ShellLayerScene.engineQueue.sync {}
        let contents = surface.view.layer?.sublayers?.first?.sublayers?.first?.contents as AnyObject?
        return contents.map { $0 as! CGImage }
    }

    private func pixel(of image: CGImage, x: Int, y: Int) -> (red: Int, green: Int)? {
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &data,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]))
    }

    func testImagesDrawHostBitmapsById() throws {
        let (surface, bitmap) = try renderedImages("ui.image{ image = \"glyph:1\", w = 10, h = 8 }")
        XCTAssertEqual(surface.size, CGSize(width: 10, height: 8))
        let layer = try XCTUnwrap(surface.view.layer?.sublayers?.first?.sublayers?.first)
        XCTAssertTrue((layer.contents as AnyObject?) === bitmap)
    }

    func testRoundedImagesClipToTheirCorners() throws {
        let (surface, _) = try renderedImages("""
        ui.row{ ui.image{ image = "glyph:1", w = 10, h = 10, radius = 5 },
            ui.image{ image = "glyph:1", w = 10, h = 10, shadow = "shadow" } }
        """)
        let images = try XCTUnwrap(surface.view.layer?.sublayers?.first?.sublayers?.first?.sublayers)
        XCTAssertEqual(images.map(\.masksToBounds), [true, false])
        XCTAssertEqual(images.map(\.cornerRadius), [5, 0])
    }

    private func renderedImages(_ view: String) throws -> (ShellWidgetSurface, CGImage) {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bitmap = try XCTUnwrap(context.makeImage())
        let bytes = try output("function render(ctx) return \(view) end")
        let text = ShellTextStore()
        text.ingest(wire: bytes)
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        resources.setBitmap(bitmap, for: "glyph:1")
        let surface = ShellWidgetSurface(scale: 2, resources: resources, directories: [])
        self.surface = surface
        XCTAssertTrue(surface.apply(bytes, text: text))
        ShellLayerScene.engineQueue.sync {}
        return (surface, bitmap)
    }

    func testResourcesResolveInstalledAppsAndRejectUnknownOnes() {
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        XCTAssertNotNil(resources.icon(for: "com.apple.finder"))
        XCTAssertNil(resources.icon(for: "com.omniwm.tests.missing-app"))
        let override = NSImage(size: NSSize(width: 4, height: 4))
        let overridden = ShellResources(motion: MotionPolicy(animationsEnabled: false), iconOverride: { _ in override })
        XCTAssertTrue(overridden.icon(for: "com.apple.finder") === override)
    }
}
