// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO
@testable import OmniWM
import OmniWMShellCore
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ShellSettingsPreviewTests: XCTestCase {
    func testSamplePercentagesUseTheLiveDataContract() throws {
        let values = ShellSettingsPreviewSamples.values(style: .init(), islandSize: nil, dark: false, scale: 2)
        for (key, expected) in ["cpu": 18.0, "memory": 42, "gpu": 12, "disk": 34, "battery": 76, "volume": 45] {
            let bytes = try XCTUnwrap(values[key])
            XCTAssertEqual(try ShellServiceValue.decode(bytes).number, expected, key)
        }
        let timestamp = try ShellServiceValue.decode(XCTUnwrap(values["seconds"]))
        XCTAssertEqual(
            timestamp.number.map { Date(timeIntervalSince1970: $0) },
            ISO8601DateFormatter().date(from: "2026-10-13T20:42:00Z")
        )
    }

    func testAllInstalledStylesRenderTheirRealBarSourcesWithoutChangingConfiguration() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: directory.appendingPathComponent("shell.toml"))
        let settings = WorkspaceBarSettings()
        for profile in ShellProfiles.names(in: directory) {
            let config = try config(profile, in: directory)
            XCTAssertTrue(config.leading.contains("apple-menu"), profile)
            XCTAssertTrue(config.leading.contains("app-menu"), profile)
            let request = ShellSettingsPreview.Request(
                config: config, surface: .bar, style: ShellSettingsPreview.style(settings: settings, config: config),
                scale: 2, dark: false, fullWidth: config.barOverride?.settings.fullWidth ?? settings.fullWidth,
                revision: 0
            )
            let image = try await ShellSettingsPreview.render(request)
            try inspect(image, name: "settings-\(profile)-bar")
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("shell.toml")), original)
        }
    }

    func testIslandCompactAndExpandedSamplesRenderAtBothScalesAndAppearances() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for profile in ["system", "lake"] {
            let config = try config(profile, in: directory)
            XCTAssertEqual(config.island?.root, profile == "system" ? "focus-ribbon" : "lake")
            if profile == "lake" {
                let island = try XCTUnwrap(config.island)
                XCTAssertEqual(island.components.count, 6)
                let input = ShellWidgetSourceLoader.Input(
                    name: island.root, shellDirectory: directory, sourceURL: try XCTUnwrap(config.widget(island.root)),
                    directories: config.directories, profile: config.profile, components: island.components
                )
                for expanded in [false, true] {
                    let trees = try await ShellSettingsPreviewRenderer.shared.render(
                        inputs: [input], values: ShellSettingsPreviewSamples.values(
                            style: .init(), islandSize: island.size, dark: false, scale: 1
                        ), settings: config.widgetSettings, expanded: expanded
                    )
                    let tree = try XCTUnwrap(trees.first)
                    let text = ShellTextStore()
                    text.ingest(tree.strings, count: tree.stringCount)
                    XCTAssertFalse(text.strings.contains("Customize island"))
                    if expanded { XCTAssertTrue(text.strings.contains("Golden Hour")) }
                }
            }
            for scale: CGFloat in [1, 2] {
                for dark in [false, true] {
                    for expanded in [false, true] {
                        let request = ShellSettingsPreview.Request(
                            config: config, surface: .island(expanded: expanded), style: .init(),
                            scale: scale, dark: dark, fullWidth: false, revision: 0
                        )
                        let image = try await ShellSettingsPreview.render(request)
                        let island = try XCTUnwrap(config.island)
                        XCTAssertEqual(image.width, Int(ceil(island.width * scale)))
                        XCTAssertEqual(image.height, Int(ceil(island.height * scale)))
                        try inspect(
                            image,
                            name: "settings-\(profile)-\(expanded ? "expanded" : "compact")-\(dark ? "dark" : "light")-\(Int(scale))x"
                        )
                    }
                }
            }
        }
    }

    func testBarOrientationAndBackingScaleAreExplicitPreviewInputs() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try config("system", in: directory)
        for vertical in [false, true] {
            for scale: CGFloat in [1, 2] {
                var style = ShellSettingsPreview.style(settings: WorkspaceBarSettings(), config: config)
                style.vertical = vertical
                style.position = vertical ? "left" : "belowMenuBar"
                style.height = 40
                let request = ShellSettingsPreview.Request(
                    config: config, surface: .bar, style: style, scale: scale, dark: true, fullWidth: true, revision: 0
                )
                let image = try await ShellSettingsPreview.render(request)
                XCTAssertEqual(vertical ? image.width : image.height, Int(style.height * scale))
                XCTAssertGreaterThan(vertical ? image.height : image.width, 800 * Int(scale))
                try inspect(image, name: "settings-system-\(vertical ? "vertical" : "horizontal")-\(Int(scale))x")
            }
        }
    }

    func testOversizedIslandRetainsNativeGeometryAndSelectionWithinBitmapAndCacheBudgets() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = try config("system", in: directory)
        config.island?.width = 8192
        config.island?.height = 8192
        let island = try XCTUnwrap(config.island)
        let source = try XCTUnwrap(config.widget(island.root))
        let values = ShellSettingsPreviewSamples.values(style: .init(), islandSize: island.size, dark: true, scale: 2)
        let input = ShellWidgetSourceLoader.Input(
            name: island.root, shellDirectory: directory, sourceURL: source, directories: config.directories,
            profile: config.profile, components: island.components
        )
        let trees = try await ShellSettingsPreviewRenderer.shared.render(
            inputs: [input], values: values, settings: config.widgetSettings, expanded: true
        )
        let tree = try XCTUnwrap(trees.first)
        let text = ShellTextStore()
        text.ingest(tree.strings, count: tree.stringCount)
        let layout = ShellWidgetLayout()
        layout.setRootLimit(Size2(width: 8192, height: 8192))
        XCTAssertTrue(layout.apply(tree.wire, text: text))
        XCTAssertEqual(layout.size, island.size)
        XCTAssertTrue(text.strings.contains("Safari"))
        XCTAssertTrue(text.strings.contains("1 · 1/3"))
        XCTAssertTrue(text.strings.contains("A quiet afternoon"))
        let sampleIsland = try ShellServiceValue.decode(XCTUnwrap(values["island"]))
        XCTAssertEqual(sampleIsland.fields?["scale"]?.number, 2)
        XCTAssertEqual(sampleIsland.fields?["navigation"]?.fields?["focused"]?.string, "sample-safari")
        let request = ShellSettingsPreview.Request(
            config: config, surface: .island(expanded: true), style: .init(), scale: 2,
            dark: true, fullWidth: false, revision: 0
        )
        let image = try await ShellSettingsPreview.render(request)
        XCTAssertLessThanOrEqual(image.width, ShellSettingsPreviewResolution.maximumDimension)
        XCTAssertLessThanOrEqual(image.height, ShellSettingsPreviewResolution.maximumDimension)
        XCTAssertLessThanOrEqual(image.width * image.height, ShellSettingsPreviewResolution.maximumPixels)
        XCTAssertEqual(image.width, 2048)
        XCTAssertEqual(image.height, 2048)
        try inspect(image, name: "settings-system-oversized-island")
        let cache = ShellSettingsPreviewCache()
        for revision: UInt64 in 0 ..< 3 {
            cache.insert(image, for: .init(
                config: config,
                surface: request.surface,
                style: request.style,
                scale: request.scale,
                dark: request.dark,
                fullWidth: request.fullWidth,
                revision: revision
            ))
        }
        XCTAssertEqual(cache.count, 2)
        XCTAssertLessThanOrEqual(cache.retainedBytes, ShellSettingsPreviewCache.maximumBytes)
    }

    func testSolidBlackBarRemainsOpaqueAtZeroBackgroundOpacity() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try config("system", in: directory)
        var style = ShellSettingsPreview.style(settings: WorkspaceBarSettings(), config: config)
        style.solidBlack = true
        style.transparent = true
        style.opacity = 0
        let image = try await ShellSettingsPreview.render(.init(
            config: config, surface: .bar, style: style, scale: 1, dark: false, fullWidth: true, revision: 0
        ))
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertEqual(Array(bytes.prefix(4)), [0, 0, 0, 255])
    }

    func testPreviewVMNeverDispatchesScriptRequestsOrExecutesServices() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("widgets/sample")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = folder.appendingPathComponent("init.luau")
        try """
        local dispatched = false
        local function execute()
            dispatched = true
            omniwm.run("switch-workspace 2")
        end
        assert(omniwm.store.set("preview", true))
        assert(omniwm.after(0.01, execute))
        assert(omniwm.http({ url = "https://example.test/preview" }, execute))
        function trigger() execute() end
        function render(ctx)
            return ui.text{ text = if dispatched then "Dispatched" else ctx.data.clock, onClick = execute }
        end
        """.write(to: entry, atomically: true, encoding: .utf8)
        let input = ShellWidgetSourceLoader.Input(
            name: "sample", shellDirectory: directory, sourceURL: entry, directories: [directory], profile: "default"
        )
        let trees = try await ShellSettingsPreviewRenderer.shared.render(
            inputs: [input], values: ShellSettingsPreviewSamples.values(
                style: .init(),
                islandSize: nil,
                dark: false,
                scale: 1
            ),
            settings: [:], expanded: nil
        )
        XCTAssertEqual(trees.count, 1)
        let tree = try XCTUnwrap(trees.first)
        let text = ShellTextStore()
        text.ingest(tree.strings, count: tree.stringCount)
        XCTAssertTrue(text.strings.contains("16:42"))
        XCTAssertFalse(text.strings.contains("Dispatched"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("store").path))
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = ShellDefaults.sync(into: directory)
        try "profile = \"system\"\n".write(
            to: directory.appendingPathComponent("shell.toml"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    private func config(_ profile: String, in directory: URL) throws -> ShellConfig {
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(profile: profile, shellDirectory: directory, problems: &problems))
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "; "))
        return config
    }

    private func inspect(_ image: CGImage, name: String) throws {
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertTrue(data.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 }, name)
        guard let path = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            directory.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
