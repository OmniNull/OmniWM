// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import XCTest

@MainActor
final class ShellConfigurationInputsTests: XCTestCase {
    func testLinkedWidgetTracksLogicalNamesAndContentChanges() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        let target = root.appendingPathComponent("external")
        let widget = shell.appendingPathComponent("widgets/my-widget")
        let names = ["settings.toml", "init.luau", "component.toml", "component.luau", "nested/helper.luau"]
        for name in names { try write("before", to: name, in: target) }
        try FileManager.default.createSymbolicLink(at: widget, withDestinationURL: target)

        var previous = try scan(shell)
        XCTAssertEqual(previous.widgets, ["my-widget"])
        XCTAssertNil(previous.files[widget.path])
        XCTAssertTrue(previous.recursivePaths.contains { $0.path == widget.path })
        XCTAssertTrue(previous.paths.contains { $0.path == target.path })
        for name in names {
            let file = widget.appendingPathComponent(name)
            XCTAssertNotNil(previous.sources[file.path], name)
            XCTAssertTrue(previous.paths.contains { $0.path == file.path }, name)
            if !name.contains("/") { XCTAssertNotNil(previous.metadata[file.path], name) }
        }

        for atomic in [false, true] {
            try Data("updated-settings-\(atomic)".utf8).write(
                to: target.appendingPathComponent("settings.toml"), options: atomic ? .atomic : []
            )
            let settings = try scan(shell)
            XCTAssertNotEqual(previous.metadata, settings.metadata)
            XCTAssertNotEqual(previous.sources, settings.sources)
            try Data("updated-helper-\(atomic)".utf8).write(
                to: target.appendingPathComponent("nested/helper.luau"), options: atomic ? .atomic : []
            )
            let source = try scan(shell)
            XCTAssertEqual(settings.metadata, source.metadata)
            XCTAssertNotEqual(settings.sources, source.sources)
            previous = source
        }
    }

    func testLinkedWidgetCollectionAndNestedLinksPreserveEveryAlias() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        let collection = root.appendingPathComponent("collection")
        let target = root.appendingPathComponent("external")
        let modules = root.appendingPathComponent("modules")
        try write("settings", to: "settings.toml", in: target)
        try write("source", to: "helper.luau", in: modules)
        try write("hidden", to: ".hidden/ignored.luau", in: modules)
        try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("nested"),
            withDestinationURL: modules
        )
        try FileManager.default.createSymbolicLink(
            atPath: collection.appendingPathComponent("first").path, withDestinationPath: "../external"
        )
        try FileManager.default.createSymbolicLink(
            atPath: collection.appendingPathComponent("second").path, withDestinationPath: "first"
        )
        try FileManager.default.removeItem(at: shell.appendingPathComponent("widgets"))
        try FileManager.default.createSymbolicLink(
            at: shell.appendingPathComponent("widgets"),
            withDestinationURL: collection
        )

        let inputs = try scan(shell)
        XCTAssertEqual(inputs.widgets, ["first", "second"])
        for name in inputs.widgets {
            let widget = shell.appendingPathComponent("widgets/\(name)")
            XCTAssertNotNil(inputs.metadata[widget.appendingPathComponent("settings.toml").path])
            XCTAssertNotNil(inputs.sources[widget.appendingPathComponent("nested/helper.luau").path])
            XCTAssertTrue(inputs.recursivePaths.contains { $0.path == widget.appendingPathComponent("nested").path })
        }
        XCTAssertEqual(inputs.files.count, 4)
        XCTAssertFalse(inputs.files.keys.contains { $0.contains(".hidden") })
    }

    func testAncestorDirectoryLinksStopAtCycles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        let target = root.appendingPathComponent("external")
        let widget = shell.appendingPathComponent("widgets/my-widget")
        try write("source", to: "init.luau", in: target)
        try FileManager.default.createSymbolicLink(at: widget, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("self"),
            withDestinationURL: target
        )
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("shell"),
            withDestinationURL: shell
        )

        let inputs = try scan(shell)
        XCTAssertEqual(inputs.widgets, ["my-widget"])
        XCTAssertEqual(Set(inputs.files.keys), [widget.appendingPathComponent("init.luau").path])
        XCTAssertTrue(inputs.recursivePaths.contains { $0.path == widget.appendingPathComponent("self").path })
        XCTAssertTrue(inputs.recursivePaths.contains { $0.path == widget.appendingPathComponent("shell").path })
        XCTAssertLessThan(inputs.paths.count, 20)
    }

    func testDanglingAndCyclicLinksDoNotHideOtherWidgetsAndCanRecover() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        let widgets = shell.appendingPathComponent("widgets")
        let target = root.appendingPathComponent("missing")
        let dangling = widgets.appendingPathComponent("dangling")
        try write("source", to: "working/init.luau", in: widgets)
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: target)
        for (name, destination) in [("self", "self"), ("first", "second"), ("second", "first")] {
            try FileManager.default.createSymbolicLink(
                atPath: widgets.appendingPathComponent(name).path, withDestinationPath: destination
            )
        }

        let before = try scan(shell)
        XCTAssertEqual(before.widgets, ["working"])
        XCTAssertTrue(before.paths.contains { $0.path == dangling.path })
        XCTAssertTrue(before.paths.contains { $0.path == root.path })
        XCTAssertTrue(before.recursivePaths.contains { $0.path == dangling.path })
        try write("settings", to: "settings.toml", in: target)
        let after = try scan(shell)
        XCTAssertEqual(after.widgets, ["dangling", "working"])
        XCTAssertNotNil(after.metadata[dangling.appendingPathComponent("settings.toml").path])
    }

    func testRetargetedDirectoryLinkReplacesTrackedContent() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let widget = shell.appendingPathComponent("widgets/my-widget")
        try write("first", to: "settings.toml", in: first)
        try write("old", to: "old.luau", in: first)
        try write("second", to: "settings.toml", in: second)
        try write("new", to: "new.luau", in: second)
        try FileManager.default.createSymbolicLink(at: widget, withDestinationURL: first)
        let before = try scan(shell)

        try FileManager.default.removeItem(at: widget)
        try FileManager.default.createSymbolicLink(at: widget, withDestinationURL: second)
        let after = try scan(shell)
        XCTAssertEqual(after.widgets, ["my-widget"])
        XCTAssertNotEqual(before.metadata, after.metadata)
        XCTAssertNil(after.sources[widget.appendingPathComponent("old.luau").path])
        XCTAssertNotNil(after.sources[widget.appendingPathComponent("new.luau").path])
        XCTAssertTrue(after.paths.contains { $0.path == second.path })
        XCTAssertFalse(after.paths.contains { $0.path == first.path })
    }

    func testLinkedWidgetEditsRefreshCoordinatorMetadataAndSourceGeneration() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        let target = root.appendingPathComponent("external")
        let widget = shell.appendingPathComponent("widgets/my-widget")
        _ = ShellDefaults.sync(into: shell)
        _ = try ShellProfiles.select("lake", in: shell)
        try write("[options.value]\ntype = 'boolean'\ndefault = true", to: "settings.toml", in: target)
        try write("function render(ctx) return ui.box{} end", to: "init.luau", in: target)
        try FileManager.default.createSymbolicLink(at: widget, withDestinationURL: target)
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        XCTAssertEqual(coordinator.widgetSchemas["my-widget"]?.options["value"]?.kind, .boolean)
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        try await coordinator.refresh()

        let metadata = expectation(description: "Linked widget settings refresh")
        withObservationTracking { _ = coordinator.revision } onChange: { metadata.fulfill() }
        try write("[options.value]\ntype = 'number'\ndefault = 5", to: "settings.toml", in: target)
        await fulfillment(of: [metadata], timeout: 5)
        await coordinator.flush()
        XCTAssertEqual(coordinator.widgetSchemas["my-widget"]?.options["value"]?.kind, .number)
        let generation = coordinator.sourceGeneration
        let source = expectation(description: "Linked widget source invalidates preview generation")
        withObservationTracking { _ = coordinator.sourceGeneration } onChange: { source.fulfill() }
        try write("function render(ctx) return ui.text{ text = 'updated' } end", to: "init.luau", in: target)
        await fulfillment(of: [source], timeout: 5)
        await coordinator.flush()
        XCTAssertGreaterThan(coordinator.sourceGeneration, generation)
        XCTAssertNil(coordinator.metadataError)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("shell/widgets"),
            withIntermediateDirectories: true
        )
        return try SettingsFileAccess.canonicalURL(for: root)
    }

    private func scan(_ shell: URL) throws -> ShellConfigurationInputs {
        var config = ShellConfig()
        config.directories = [shell]
        return try ShellConfigurationInputs(directory: shell, config: config)
    }

    private func write(_ contents: String, to path: String, in directory: URL) throws {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }
}
