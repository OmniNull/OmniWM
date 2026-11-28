// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
extension ShellDesktopEditorTests {
    func testLibraryEntriesFollowTheirSelectedStyleAndTarget() async throws {
        let fixture = try await drawerFixture()
        let editor = fixture.editor
        let bar = editor.libraryEntries(.bar)
        XCTAssertEqual(bar.map(\.name), editor.layout?.addable.map(\.name))
        XCTAssertTrue(bar.contains { $0.name == "status" && $0.available })
        XCTAssertFalse(bar.contains { $0.name == "clock" })
        let drawer = editor.libraryEntries(.drawer("dashboard"))
        XCTAssertEqual(drawer.map(\.name), editor.drawerCandidates("dashboard"))
        XCTAssertFalse(drawer.contains { $0.name == "dashboard" })
        XCTAssertTrue(drawer.contains { $0.name == "clock" })
        let selected = await editor.selectStyle("lake")
        XCTAssertTrue(selected)
        XCTAssertEqual(editor.libraryEntries(.island).map(\.name), editor.islandEntries.map(\.widget))
        XCTAssertTrue(editor.libraryEntries(.island).contains { $0.name == "world-clock" && $0.available })
        XCTAssertEqual(fixture.configuration.config.profile, "default")
    }

    func testIslandLibraryKeepsInvalidEntriesWithTheirActualError() async throws {
        let fixture = try await fixture()
        let directory = fixture.shell.appendingPathComponent("lake/widgets/broken-entry")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("title = [invalid".utf8).write(to: directory.appendingPathComponent("component.manifest.luau"))
        try await fixture.configuration.refresh()
        await fixture.editor.reload()
        let entry = try XCTUnwrap(fixture.editor.libraryEntries(.island).first { $0.name == "broken-entry" })
        XCTAssertFalse(entry.available)
        XCTAssertNotNil(entry.problem)
        XCTAssertEqual(entry.problem, fixture.editor.islandEntries.first { $0.widget == "broken-entry" }?.error)
        XCTAssertTrue(fixture.editor.libraryEntries(.island).contains { $0.name == "world-clock" && $0.available })
    }

    func testOptionsOpensAnUnplacedCelestialWidgetWithoutWritingOrAddingIt() async throws {
        let fixture = try await drawerFixture()
        let editor = fixture.editor
        let before = try document(fixture)
        XCTAssertNil(editor.layout?.lane(of: "status"))
        XCTAssertNotNil(editor.schema(for: "status")?.options["network"])
        let opened = await editor.showOptions("status")
        XCTAssertTrue(opened)
        XCTAssertEqual(editor.surface, .bar)
        XCTAssertEqual(editor.selectedWidget, "status")
        XCTAssertNil(editor.layout?.lane(of: "status"))
        XCTAssertEqual(try document(fixture), before)
        XCTAssertEqual(fixture.saves.count, 0)
        await editor.reload()
        XCTAssertEqual(editor.selectedWidget, "status")
    }

    func testOptionsCancellingADirtyDraftRetainsTheWholePriorContext() async throws {
        let fixture = try await drawerFixture()
        let editor = fixture.editor
        let key = await dirtyText(editor)
        XCTAssertTrue(editor.draft(key)?.dirty == true)
        let previous = editor.destination
        let before = try document(fixture)
        let opened = await editor.showOptions("status")
        XCTAssertFalse(opened)
        XCTAssertNotNil(editor.pendingTransition)
        XCTAssertEqual(editor.destination, previous)
        await editor.resolve(.cancel)
        XCTAssertEqual(editor.destination, previous)
        XCTAssertTrue(editor.draft(key)?.dirty == true)
        XCTAssertEqual(try document(fixture), before)
        XCTAssertNil(editor.layout?.lane(of: "status"))
    }

    func testLibraryAddUsesTheChosenBarLaneAndSelectedDrawer() async throws {
        let fixture = try await drawerFixture()
        let editor = fixture.editor
        let barAdded = await editor.libraryAdd("status", to: .bar, lane: .center)
        XCTAssertTrue(barAdded)
        XCTAssertEqual(editor.layout?.lane(of: "status"), .center)
        XCTAssertEqual(editor.selectedWidget, "status")
        let memberAdded = await editor.libraryAdd("clock", to: .drawer("dashboard"))
        XCTAssertTrue(memberAdded)
        XCTAssertEqual(editor.drawerMembers("dashboard"), ["dashboard", "clock"])
        XCTAssertFalse(editor.libraryEntries(.drawer("dashboard")).contains { $0.name == "clock" })
        XCTAssertEqual(fixture.configuration.config.profile, "default")
    }

    func testFailedBarAndDrawerLibraryAddsKeepConfigurationSelectionAndMembers() async throws {
        let fixture = try await drawerFixture()
        let editor = fixture.editor
        let selected = await editor.selectWidget("clock")
        XCTAssertTrue(selected)
        let destination = editor.destination
        let members = editor.drawerMembers("dashboard")
        let file = fixture.shell.appendingPathComponent("shell.luau")
        let original = try Data(contentsOf: file)
        try Data("[invalid".utf8).write(to: file)
        let invalid = try Data(contentsOf: file)
        for (name, target) in [
            ("status", ShellDesktopEditor.LibraryTarget.bar),
            ("clock", .drawer("dashboard"))
        ] {
            editor.problem = nil
            let added = await editor.libraryAdd(name, to: target, lane: .center)
            XCTAssertFalse(added)
            XCTAssertNotNil(editor.problem)
            XCTAssertEqual(try Data(contentsOf: file), invalid)
            XCTAssertEqual(editor.destination, destination)
            XCTAssertEqual(editor.drawerMembers("dashboard"), members)
            XCTAssertNil(editor.layout?.lane(of: "status"))
        }
        try original.write(to: file)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testLibraryMetadataAndRuntimeStatesBelongOnlyToTheActiveStyle() async throws {
        let fixture = try await fixture(style: "default")
        let editor = fixture.editor
        let host = ShellWidgetHost(
            configDirectory: fixture.shell.deletingLastPathComponent(),
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        host.config = fixture.configuration.config
        host.widgets["clock"] = .init(name: "clock", sourceURL: fixture.shell.appendingPathComponent("clock.luau"))
        editor.controller.workspaceBarManager.shellHost = host
        defer { editor.controller.workspaceBarManager.shellHost = nil
            host.stop()
        }
        XCTAssertEqual(editor.status(for: "clock")?.state, "loading")
        let file = fixture.shell.appendingPathComponent("default/widgets/clock/settings.luau")
        try Data("return { options =".utf8).write(to: file)
        try await fixture.configuration.refresh()
        await editor.reload()
        XCTAssertNotNil(fixture.configuration.metadataError)
        XCTAssertEqual(editor.metadataProblem, fixture.configuration.metadataError)
        let selected = await editor.selectStyle("celestial")
        XCTAssertTrue(selected)
        XCTAssertNil(editor.status(for: "clock"))
        XCTAssertNil(editor.metadataProblem)
        let returned = await editor.selectStyle("default")
        XCTAssertTrue(returned)
        host.config.profile = "lake"
        XCTAssertNil(editor.status(for: "clock"))
    }
}
