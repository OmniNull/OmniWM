// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellSettingsPreviewRasterFitTests: XCTestCase {
    func testDrawerRasterScaleFitsTheNativeStackAndItsComposedImage() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for heights: [CGFloat] in [[200, 300, 400], [10, 20, 30]] {
            let config = try sources(in: directory, heights: heights)
            for chrome in [false, true] {
                try await assertDrawerFit(config: config, heights: heights, chrome: chrome)
            }
        }
    }

    func testUnfittedBatchKeepsSequentialRasterPixelsAndMemberOrder() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try sources(in: directory, heights: [200, 300, 400])
        let trees = try await trees(config, popout: false)
        for limit in [nil, CGSize(width: 90, height: 250)] as [CGSize?] {
            let batch = try await ShellSettingsPreviewRaster.render(
                trees, theme: config.theme, dark: false, scale: 2, limit: limit
            )
            XCTAssertEqual(batch.map(\.name), ["first", "second", "third"])
            for (tree, image) in zip(trees, batch) {
                let single = try await ShellSettingsPreviewRaster.render(
                    [tree], theme: config.theme, dark: false, scale: 2, limit: limit
                )
                let sequential = try XCTUnwrap(single.first)
                XCTAssertEqual(image.name, sequential.name)
                XCTAssertEqual(image.size, sequential.size)
                XCTAssertEqual(image.scale, 2)
                XCTAssertEqual(image.image.width, sequential.image.width)
                XCTAssertEqual(image.image.height, sequential.image.height)
                XCTAssertEqual(try pixels(image.image), try pixels(sequential.image))
            }
        }
    }

    private func assertDrawerFit(config: ShellConfig, heights: [CGFloat], chrome: Bool) async throws {
        var config = config
        config.drawers[0].chrome = chrome
        let trees = try await trees(config, popout: true)
        let padding: CGFloat = chrome ? 12 : 0
        let height = heights.reduce(0, +) + 24 + padding * 2
        let expectedScale = min(2, 2 * ShellSettingsPreview.drawerHeight / height)
        let widths: [CGFloat] = [60, 80, 100]
        let images = try await ShellSettingsPreviewRaster.render(
            trees, theme: config.theme, dark: false, scale: 2, limit: nil, rootMaterial: false
        ) { sizes in
            XCTAssertEqual(sizes, zip(widths, heights).map { CGSize(width: $0.0, height: $0.1) })
            return expectedScale
        }
        XCTAssertEqual(images.count, 3)
        for (index, image) in images.enumerated() {
            XCTAssertEqual(image.scale, expectedScale)
            XCTAssertEqual(image.size, CGSize(width: widths[index], height: heights[index]))
            XCTAssertEqual(image.image.width, Int(floor(widths[index] * expectedScale)))
            XCTAssertEqual(image.image.height, Int(floor(heights[index] * expectedScale)))
        }
        let composed = try await ShellSettingsPreview.render(.init(
            config: config, surface: .drawer("tools"), style: .init(), scale: 2,
            dark: false, fullWidth: false, sourceGeneration: 0
        ))
        XCTAssertEqual(composed.width, Int(floor((100 + padding * 2) * expectedScale)))
        XCTAssertEqual(composed.height, Int(floor(height * expectedScale)))
        XCTAssertLessThanOrEqual(composed.height, Int(2 * ShellSettingsPreview.drawerHeight))
    }

    private func trees(_ config: ShellConfig, popout: Bool) async throws -> [ShellSettingsPreviewRenderer.Tree] {
        let inputs = try ["first", "second", "third"].map {
            try XCTUnwrap(ShellSettingsPreview.input($0, config: config))
        }
        return try await ShellSettingsPreviewRenderer.shared.render(
            inputs: inputs, values: [:], settings: [:], expanded: nil, popout: popout
        )
    }

    private func sources(in directory: URL, heights: [CGFloat]) throws -> ShellConfig {
        for (index, name) in ["first", "second", "third"].enumerated() {
            let folder = directory.appendingPathComponent("widgets/" + name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("""
            local function content()
                return ui.box{ w = \([60, 80, 100][index]), h = \(Int(heights[index])), fill = '#CE7044' }
            end
            function render(ctx) return content() end
            function popout(ctx) return content() end
            """.utf8).write(to: folder.appendingPathComponent("init.luau"))
        }
        var config = ShellConfig()
        config.directories = [directory]
        config.drawers = [.init(id: "tools", edge: .right, widgets: ["first", "second", "third"], hover: false)]
        return config
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func pixels(_ image: CGImage) throws -> Data {
        try XCTUnwrap(image.dataProvider?.data) as Data
    }
}
