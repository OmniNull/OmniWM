// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ImageIO
import IOSurface
@testable import OmniWM
import UniformTypeIdentifiers
import XCTest

extension ShellImagePreparation {
    func usesMainThread() -> Bool {
        Thread.isMainThread
    }
}

extension ShellShaderPreparation {
    func usesMainThread() -> Bool {
        Thread.isMainThread
    }
}

@MainActor
final class ShellComponentAssetTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func png(_ url: URL, width: Int) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testQualifiedReferencesRejectTraversalAndUnknownPackages() throws {
        let packages = ["stock": try folder("stock")]
        for reference in [
            "@omni-asset:stock/../other/icon.png",
            "@omni-asset:stock//icon.png",
            "@omni-asset:stock/./icon.png",
            "@omni-asset:stock/~/icon.png",
            "@omni-asset:stock/",
            "@omni-asset:missing/icon.png"
        ] {
            XCTAssertThrowsError(try ShellAsset(reference, packages: packages), reference)
        }
        let library = ShellShaderLibrary()
        XCTAssertNotNil(library
            .program(source: "@omni-asset:stock/../secret.metal", directories: [], packages: packages).failure)
    }

    func testImagePreparationUsesPackageIdentityAndRejectsSymlinkEscape() async throws {
        let stock = try folder("stock")
        let custom = try folder("custom")
        try png(stock.appendingPathComponent("icon.png"), width: 2)
        try png(custom.appendingPathComponent("icon.png"), width: 3)
        try FileManager.default.createSymbolicLink(
            at: stock.appendingPathComponent("escape.png"),
            withDestinationURL: custom.appendingPathComponent("icon.png")
        )
        try FileManager.default.createSymbolicLink(
            at: stock.appendingPathComponent("alias.png"),
            withDestinationURL: stock.appendingPathComponent("icon.png")
        )
        let packages = ["stock": stock, "custom": custom]
        let preparation = ShellImagePreparation()
        let onMain = await preparation.usesMainThread()
        XCTAssertFalse(onMain)
        let first = try await preparation.prepare(ShellAsset("@omni-asset:stock/icon.png", packages: packages))
        let second = try await preparation.prepare(ShellAsset("@omni-asset:custom/icon.png", packages: packages))
        let alias = try await preparation.prepare(ShellAsset("@omni-asset:stock/alias.png", packages: packages))
        XCTAssertEqual(first.frames.frames.first?.width, 2)
        XCTAssertEqual(second.frames.frames.first?.width, 3)
        XCTAssertNotEqual(first.revision.url, second.revision.url)
        XCTAssertTrue(alias.frames === first.frames)
        do {
            _ = try await preparation.prepare(ShellAsset("@omni-asset:stock/escape.png", packages: packages))
            XCTFail("A component asset escaped its source package")
        } catch {
            XCTAssertTrue(String(describing: error).contains("inside their source package"))
        }
    }

    func testImageEditsRefreshOnlyAffectedNativeBindings() async throws {
        let stock = try folder("stock")
        let custom = try folder("custom")
        let stockImage = stock.appendingPathComponent("icon.png")
        try png(stockImage, width: 2)
        try png(custom.appendingPathComponent("icon.png"), width: 3)
        let widget = try ShellRenderedWidget(name: "asset-root", source: """
        function render(ctx)
            return ui.row{
                ui.image{ key = "stock", image = "@omni-asset:stock/icon.png", w = 10, h = 10 },
                ui.image{ key = "custom", image = "@omni-asset:custom/icon.png", w = 10, h = 10 },
            }
        end
        """)
        widget.surface.assetFolders = ["stock": stock, "custom": custom]
        let library = widget.resources.images
        let loaded = expectation(description: "Both component images prepared")
        loaded.expectedFulfillmentCount = 2
        library.onLoad = { loaded.fulfill() }
        library.onAssetChange = { [weak surface = widget.surface] url in surface?.refreshAssets(at: url) }
        widget.render(ShellBarData())
        await fulfillment(of: [loaded], timeout: 10)
        let before = try XCTUnwrap(widget.surface.assetImages.values.first { $0.source.contains(":custom/") }?.frames)
        XCTAssertEqual(before.frames.first?.width, 3)

        let refreshed = expectation(description: "Component image revisions checked")
        refreshed.expectedFulfillmentCount = 2
        var changed: [URL] = []
        library.onLoad = { refreshed.fulfill() }
        library.onAssetChange = { [weak surface = widget.surface] url in
            changed.append(url)
            surface?.refreshAssets(at: url)
        }
        try png(stockImage, width: 4)
        XCTAssertFalse(library.refresh())
        await fulfillment(of: [refreshed], timeout: 10)
        XCTAssertEqual(changed, [stockImage])
        XCTAssertEqual(
            widget.surface.assetImages.values.first { $0.source.contains(":stock/") }?.frames?.frames.first?.width,
            4
        )
        XCTAssertTrue(widget.surface.assetImages.values.first { $0.source.contains(":custom/") }?.frames === before)
        ShellLayerScene.engineQueue.sync {}
    }

    func testShaderPreparationCachesByResolvedFileAndRevisionOffMain() async throws {
        let preparation = ShellShaderPreparation()
        let onMain = await preparation.usesMainThread()
        XCTAssertFalse(onMain)
        guard ShellShaderGPU.device != nil else { throw XCTSkip("Metal is not available") }
        let stock = try folder("stock")
        let custom = try folder("custom")
        let stockShader = stock.appendingPathComponent("bars.metal")
        let body = "float4 shade(float2 uv, constant OmniShader& shader) { return float4(0, 0, 0, 1); }"
        try body.write(to: stockShader, atomically: true, encoding: .utf8)
        try body.replacingOccurrences(of: "0, 0, 0", with: "1, 0, 0")
            .write(to: custom.appendingPathComponent("bars.metal"), atomically: true, encoding: .utf8)
        let packages = ["stock": stock, "custom": custom]
        let first = try await preparation.prepare(ShellAsset("@omni-asset:stock/bars.metal", packages: packages))
        let second = try await preparation.prepare(ShellAsset("@omni-asset:custom/bars.metal", packages: packages))
        XCTAssertNotEqual(first.revision.url, second.revision.url)
        let cached = try await preparation.prepare(ShellAsset("@omni-asset:stock/bars.metal", packages: packages))
        XCTAssertTrue(first.pipeline === cached.pipeline)
        try body.replacingOccurrences(of: "0, 0, 0", with: "0, 1, 0")
            .write(to: stockShader, atomically: true, encoding: .utf8)
        let changed = try await preparation.prepare(ShellAsset("@omni-asset:stock/bars.metal", packages: packages))
        XCTAssertNotEqual(first.revision, changed.revision)
        XCTAssertFalse(first.pipeline === changed.pipeline)
        let untouched = try await preparation.prepare(ShellAsset("@omni-asset:custom/bars.metal", packages: packages))
        XCTAssertTrue(second.pipeline === untouched.pipeline)
    }

    func testShaderTexturesLoadAndReloadAtZeroFPSForBothPathForms() async throws {
        guard ShellShaderGPU.device != nil else { throw XCTSkip("Metal is not available") }
        for qualified in [false, true] {
            let stock = try folder(qualified ? "qualified-texture" : "plain-texture")
            let file = stock.appendingPathComponent("icon.png")
            try png(file, width: 2)
            try Data("""
            #define OMNI_TEXTURE
            float4 shade(float2 uv, constant OmniShader& shader, texture2d<float> image) {
                return float4(float(image.get_width()) / 8.0, 0, 0, 1);
            }
            """.utf8).write(to: stock.appendingPathComponent("width.metal"))
            let source = qualified ? "@omni-asset:stock/icon.png" : "icon.png"
            let widget = try ShellRenderedWidget(name: "texture", source: """
            function render(ctx)
                return ui.shader{ source = '@omni-asset:stock/width.metal', texture = '\(source)',
                    w = 8, h = 4, fps = 0 }
            end
            """, directories: [stock])
            widget.surface.assetFolders = ["stock": stock]
            widget.resources.images.onAssetChange = { [weak surface = widget.surface] url in
                surface?.refreshAssets(at: url)
            }
            widget.resources.shaders.onAssetChange = { [weak surface = widget.surface] url in
                surface?.refreshAssets(at: url)
            }
            widget.render(ShellBarData())
            let scene = widget.surface.scene
            let red = {
                ShellLayerScene.engineQueue.sync { () -> UInt8? in
                    guard let surface = scene.layers.values.first?.contents as? IOSurface else { return nil }
                    surface.lock(options: .readOnly, seed: nil)
                    defer { surface.unlock(options: .readOnly, seed: nil) }
                    return surface.baseAddress.load(fromByteOffset: 2, as: UInt8.self)
                }
            }
            await until { red() == 64 }
            try png(file, width: 4)
            XCTAssertEqual(widget.resources.images.refresh(), !qualified)
            await until { red() == 128 }
        }
    }
}
