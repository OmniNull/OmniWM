// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellEditorSnapshotIslandTests: XCTestCase {
    func testSuccessfulCatalogIsReusedAcrossConfigurationEditsWithoutMetadataChanges() async throws {
        let fixture = try fixture()
        let original = try await fixture.snapshot()
        XCTAssertEqual(original.island?.root, "first-root")
        XCTAssertEqual(original.descriptors["clock"]?.title, "Original Clock")
        try write(component("Changed Clock"), to: "widgets/clock/component.toml", in: fixture.directory)
        var config = fixture.config
        config.island?.components[0].enabled = false
        let reused = try await fixture.snapshot(config: config, generation: 2)
        XCTAssertFalse(try XCTUnwrap(reused.config.island?.components.first).enabled)
        XCTAssertEqual(reused.island, original.island)
        XCTAssertEqual(reused.descriptors["clock"]?.title, "Original Clock")
    }

    func testChangedMetadataRebuildsTheSelectedCatalog() async throws {
        let fixture = try fixture()
        let original = try await fixture.snapshot()
        let file = fixture.directory.appendingPathComponent("widgets/clock/component.toml")
        try write(component("Updated Clock"), to: "widgets/clock/component.toml", in: fixture.directory)
        let metadata = [file.path: try XCTUnwrap(SettingsFileAccess.currentFingerprint(at: file))]
        let updated = try await fixture.snapshot(metadata: metadata)
        XCTAssertNotEqual(updated.island, original.island)
        XCTAssertEqual(updated.descriptors["clock"]?.title, "Updated Clock")
        XCTAssertEqual(updated.componentTitles["instance"], "Updated Clock")
    }

    func testChangingOnlyTheIslandRootRebuildsItsCatalog() async throws {
        let fixture = try fixture()
        let original = try await fixture.snapshot()
        var config = fixture.config
        config.island?.root = "second-root"
        let updated = try await fixture.snapshot(config: config)
        XCTAssertEqual(updated.island?.root, "second-root")
        XCTAssertEqual(original.island?.settings?.options["width"]?.defaultValue, .number(400))
        XCTAssertEqual(updated.island?.settings?.options["width"]?.defaultValue, .number(600))
        XCTAssertEqual(updated.schemas, original.schemas)
    }

    func testChangingDirectoriesRebuildsTheCatalogAtTheNewLocation() async throws {
        let fixture = try fixture()
        _ = try await fixture.snapshot()
        let other = fixture.directory.appendingPathComponent("other")
        try write(component("Other Clock"), to: "widgets/clock/component.toml", in: other)
        try write("return {}", to: "widgets/clock/component.luau", in: other)
        try write(root(800), to: "widgets/first-root/settings.toml", in: other)
        var config = fixture.config
        config.directories = [other]
        let updated = try await fixture.snapshot(config: config)
        XCTAssertEqual(updated.descriptors["clock"]?.title, "Other Clock")
        XCTAssertEqual(updated.island?.settings?.options["width"]?.defaultValue, .number(800))
        XCTAssertEqual(updated.island?.directories, [other])
    }

    func testFailedCatalogLoadIsRetriedOnTheNextUnchangedSnapshot() async throws {
        let fixture = try fixture()
        try write("[options.width\n", to: "widgets/first-root/settings.toml", in: fixture.directory)
        let failed = try await fixture.snapshot()
        XCTAssertNotNil(failed.islandProblem)
        XCTAssertNil(failed.island)
        try write(root(400), to: "widgets/first-root/settings.toml", in: fixture.directory)
        let recovered = try await fixture.snapshot()
        XCTAssertNil(recovered.islandProblem)
        XCTAssertEqual(recovered.island?.root, "first-root")
        XCTAssertEqual(recovered.descriptors["clock"]?.title, "Original Clock")
    }

    func testActiveSnapshotUsesThePublishedCoordinatorCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        try ShellStyleFixture.install("lake", into: directory)
        let configuration = ShellConfigurationCoordinator(shellDirectory: directory)
        try await configuration.ensureLoaded()
        _ = try await configuration.selectProfile("lake")
        configuration.stopObserving()
        let published = try XCTUnwrap(configuration.catalog)
        let descriptor = try XCTUnwrap(published.descriptors["world-clock"])
        let file = descriptor.folder.appendingPathComponent("component.toml")
        let source = try String(contentsOf: file, encoding: .utf8)
        let changed = source.replacingOccurrences(of: "title = \"Clock\"", with: "title = \"Changed on disk\"")
        XCTAssertNotEqual(changed, source)
        try Data(changed.utf8).write(to: file)
        XCTAssertEqual(
            try ShellComponentCatalog.load("world-clock", directories: published.directories).title,
            "Changed on disk"
        )
        let snapshot = try await configuration.editorSnapshot(profile: "lake")
        XCTAssertEqual(snapshot.descriptors["world-clock"]?.title, descriptor.title)
        XCTAssertEqual(configuration.catalog, published)
        XCTAssertEqual(snapshot.island, published)
        XCTAssertEqual(snapshot.descriptors, configuration.catalog?.descriptors)
        XCTAssertEqual(snapshot.config, configuration.config)
        XCTAssertNil(snapshot.islandProblem)
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let config: ShellConfig
        let cache: ShellEditorSnapshotCache
        let writer: ShellIslandConfigWriter
        let loader: ShellConfigurationCatalogLoader

        func snapshot(
            config: ShellConfig? = nil, metadata: [String: SettingsFileAccess.Fingerprint] = [:], generation: UInt64 = 1
        ) async throws -> ShellEditorSnapshot {
            try await cache.snapshot(
                for: config ?? self.config, metadata: metadata, generation: generation, writer: writer, catalog: loader
            )
        }
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        try write(component("Original Clock"), to: "widgets/clock/component.toml", in: directory)
        try write("return {}", to: "widgets/clock/component.luau", in: directory)
        try write(root(400), to: "widgets/first-root/settings.toml", in: directory)
        try write(root(600), to: "widgets/second-root/settings.toml", in: directory)
        var config = ShellConfig()
        config.profile = "preview"
        config.directories = [directory]
        config.island = .init(root: "first-root", components: [.init(id: "instance", widget: "clock")])
        return Fixture(
            directory: directory, config: config, cache: ShellEditorSnapshotCache(),
            writer: ShellIslandConfigWriter(shellDirectory: directory, reloadReady: {}),
            loader: ShellConfigurationCatalogLoader()
        )
    }

    private func component(_ title: String) -> String {
        "title = '\(title)'\nicon = 'clock'\nviews = ['compact']\n"
    }

    private func root(_ width: Int) -> String {
        "[options.width]\ntype = 'number'\ndefault = \(width)\nmin = 1\nmax = 8192\n"
    }

    private func write(_ text: String, to path: String, in directory: URL) throws {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
}
