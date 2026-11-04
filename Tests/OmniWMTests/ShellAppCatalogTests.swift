// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import XCTest

@MainActor
final class ShellAppCatalogTests: XCTestCase {
    func testNestedModuleChangesAreObservedAndInvalidateItsDeclaredView() async throws {
        let fixture = ShellAppAuthoringFixture()
        defer { try? fixture.remove() }
        let module = "lib/nested/view.luau"
        let source = fixture.source.replacingOccurrences(
            of: "function(ctx) return ui.text{text=label} end", with: "require('@self/lib/nested/view')"
        )
        try fixture.write(source: source)
        try fixture.writeFile("return function(ctx) return ui.text{text='Nested view'} end", path: module)
        let catalog = ShellAppCatalog(configDirectory: fixture.config)
        let discovered = expectation(description: "Startup publishes the app with its nested module")
        withObservationTracking { _ = catalog.definitions } onChange: { discovered.fulfill() }
        catalog.startObserving()
        defer { catalog.stopObserving() }
        let observationFailureDeadline: TimeInterval = 5
        await fulfillment(of: [discovered], timeout: observationFailureDeadline)
        XCTAssertNotNil(catalog.definitions[fixture.id])
        let invalidated = expectation(description: "Nested source change publishes the missing-view failure")
        withObservationTracking { _ = catalog.problems } onChange: { invalidated.fulfill() }
        try fixture.writeFile("return 'not a view'", path: module)
        await fulfillment(of: [invalidated], timeout: observationFailureDeadline)
        XCTAssertNil(catalog.definitions[fixture.id])
        XCTAssertTrue(catalog.problems.contains { $0.contains("missing declared view \(fixture.view)") })
    }

    func testStartupAndFilesystemObservationPublishTheEditedApp() async throws {
        let fixture = ShellAppAuthoringFixture()
        defer { try? fixture.remove() }
        try fixture.write()
        let catalog = ShellAppCatalog(configDirectory: fixture.config)
        defer { catalog.stopObserving() }
        let discovered = expectation(description: "Startup publishes the local app")
        withObservationTracking { _ = catalog.definitions } onChange: { discovered.fulfill() }
        catalog.startObserving()
        let observationFailureDeadline: TimeInterval = 5
        await fulfillment(of: [discovered], timeout: observationFailureDeadline)
        XCTAssertEqual(catalog.definitions[fixture.id]?.title, fixture.title)

        let edited = expectation(description: "Native directory observation publishes the edited title")
        withObservationTracking { _ = catalog.definitions } onChange: { edited.fulfill() }
        let newTitle = "Observed authoring change"
        try fixture.writeFile(
            fixture.manifest.replacingOccurrences(of: fixture.title, with: newTitle), path: "component.toml"
        )
        await fulfillment(of: [edited], timeout: observationFailureDeadline)
        XCTAssertEqual(catalog.definitions[fixture.id]?.title, newTitle)
        XCTAssertTrue(catalog.problems.isEmpty)
    }

    func testDiscoveryValidatesActualExportsWithoutInitializingComponentsOrProviders() async throws {
        let fixture = ShellAppAuthoringFixture()
        defer { try? fixture.remove() }
        let source = fixture.source.replacingOccurrences(
            of: "return {views=", with: "return {init=function() error('discovery must not initialize') end, views="
        )
        try fixture.write(source: source)
        let catalog = ShellAppCatalog(configDirectory: fixture.config)

        await catalog.refresh()

        XCTAssertTrue(catalog.problems.isEmpty, catalog.problems.joined(separator: "\n"))
        let app = try XCTUnwrap(catalog.definitions[fixture.id])
        XCTAssertEqual(app.title, fixture.title)
        XCTAssertEqual(app.view, fixture.view)
        XCTAssertEqual(app.folder.resolvingSymlinksInPath(), fixture.folder.resolvingSymlinksInPath())
        XCTAssertNotNil(catalog.definitions[ShellAppWindowManager.exampleID])
    }

    func testMissingActualViewSyntaxErrorAndInvalidManifestNeverRegister() async throws {
        let fixture = ShellAppAuthoringFixture()
        defer { try? fixture.remove() }
        let catalog = ShellAppCatalog(configDirectory: fixture.config)
        for (source, expected) in [
            (
                fixture.source.replacingOccurrences(of: "preferences = function", with: "other = function"),
                "preferences"
            ),
            ("return {views={}}", fixture.view),
            ("local =", "component.luau"),
            ("return {}", "views")
        ] {
            try fixture.write(source: source)
            await catalog.refresh()
            XCTAssertNil(catalog.definitions[fixture.id])
            XCTAssertTrue(
                catalog.problems.contains { $0.contains(fixture.id) && $0.contains(expected) },
                "\(catalog.problems)"
            )
        }
        try fixture.write(manifest: fixture.manifest + "\nunknown = true")
        await catalog.refresh()
        XCTAssertNil(catalog.definitions[fixture.id])
        XCTAssertTrue(catalog.problems.contains { $0.contains("unknown") })
        try fixture.write()
        await catalog.refresh()
        XCTAssertNotNil(catalog.definitions[fixture.id])
        XCTAssertTrue(catalog.problems.isEmpty)
    }

    func testBundledAndDuplicateFolderCollisionsKeepTheDeterministicFirstOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ShellAppAuthoringFixture(config: root.appendingPathComponent("a"))
        let second = ShellAppAuthoringFixture(config: root.appendingPathComponent("b"))
        let collision = ShellAppAuthoringFixture(config: first.config, id: ShellAppWindowManager.exampleID)
        try first.write()
        try second.write()
        try collision.write()
        let bundled = try XCTUnwrap(ShellAppDefinition.example)
        let loader = ShellAppCatalogLoader()
        let snapshot = try await loader.load(directories: [second.directory, first.directory], bundled: bundled.folder)

        XCTAssertEqual(
            snapshot.definitions[first.id]?.folder.resolvingSymlinksInPath(),
            first.folder.resolvingSymlinksInPath()
        )
        XCTAssertEqual(snapshot.definitions[bundled.id]?.folder, bundled.folder)
        XCTAssertTrue(snapshot.problems.contains { $0.contains(second.folder.path) && $0.contains(first.folder.path) })
        XCTAssertTrue(snapshot.problems
            .contains { $0.contains(collision.folder.path) && $0.contains(bundled.folder.path) })
        XCTAssertEqual(snapshot.problems.count, [second.folder, collision.folder].count)
    }

    func testReloadAddsEditsAndRemovesAppsIndependentlyOfShellProfiles() async throws {
        let fixture = ShellAppAuthoringFixture()
        defer { try? fixture.remove() }
        let catalog = ShellAppCatalog(configDirectory: fixture.config)
        await catalog.refresh()
        XCTAssertNil(catalog.definitions[fixture.id])
        try fixture.write()
        await catalog.refresh()
        XCTAssertEqual(catalog.definitions[fixture.id]?.title, fixture.title)
        let newTitle = "Edited app title"
        try fixture.write(manifest: fixture.manifest.replacingOccurrences(of: fixture.title, with: newTitle))
        let shell = fixture.config.appendingPathComponent("shell/style-that-is-not-an-app")
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
        try Data(fixture.source.utf8).write(to: shell.appendingPathComponent("init.luau"))
        await catalog.refresh()
        XCTAssertEqual(catalog.definitions[fixture.id]?.title, newTitle)
        XCTAssertNil(catalog.definitions[shell.lastPathComponent])
        try FileManager.default.removeItem(at: fixture.folder)
        await catalog.refresh()
        XCTAssertNil(catalog.definitions[fixture.id])
        XCTAssertNotNil(catalog.definitions[ShellAppWindowManager.exampleID])
    }

    func testAppErrorsUseTheExistingShellAuthoringBanner() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let authoring = ShellAppAuthoringFixture(
            config: fixture.controller.settings.settingsFileURL.deletingLastPathComponent()
        )
        defer { try? FileManager.default.removeItem(at: authoring.directory) }
        try authoring.write(manifest: "views = ['main']")
        let catalog = fixture.controller.shellAppCatalog
        await catalog.refresh()
        let editor = ShellDesktopEditor(
            configuration: fixture.controller.workspaceBarManager.shellConfiguration,
            settings: fixture.controller.settings, controller: fixture.controller
        )
        XCTAssertNil(catalog.definitions[authoring.id])
        XCTAssertEqual(editor.metadataProblem, catalog.problems.joined(separator: "\n"))
        XCTAssertTrue(try XCTUnwrap(editor.metadataProblem).contains("[window]"))
        try authoring.write()
        await catalog.refresh()
        XCTAssertNil(editor.metadataProblem)
    }
}
