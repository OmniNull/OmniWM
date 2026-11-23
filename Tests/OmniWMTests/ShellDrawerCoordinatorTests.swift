// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
extension ShellDesktopEditorTests {
    func testDrawerProvenanceIncludesDefaultLayersAndExcludesRootOwnedDrawers() async throws {
        let fixture = try await drawerFixture()
        let base = fixture.shell.appendingPathComponent("default/shell.luau")
        _ = try ShellLuauDocument.write([(["drawer", "inherited"], .record([
            "widgets": .list([.string("clock")]), "edge": .string("left"), "reach": .integer(17)
        ]))], in: base.deletingLastPathComponent())
        try await fixture.configuration.set(51, key: "reach", table: "drawer.inherited", profile: "celestial")
        try await fixture.configuration.addDrawer("root-only", edge: .right, widget: "weather", profile: "default")
        try await fixture.configuration.refresh()
        await fixture.editor.reload()
        XCTAssertTrue(fixture.editor.isStyleDrawer("inherited"))
        XCTAssertEqual(fixture.editor.drawer("inherited")?.reach, 51)
        XCTAssertNil(fixture.editor.drawer("root-only"))
        let defaultConfig = try await fixture.configuration.previewConfig(profile: "default")
        XCTAssertNotNil(defaultConfig.drawers.first { $0.id == "root-only" })
        XCTAssertFalse(defaultConfig.styleDrawers.contains("root-only"))
        let before = try document(fixture)
        await drawerEdit(fixture) { fixture.editor.resetDrawer("inherited") }
        XCTAssertEqual(fixture.editor.drawer("inherited")?.reach, 17)
        XCTAssertEqual(fixture.editor.drawer("inherited")?.edge, .left)
        XCTAssertTrue(fixture.editor.isStyleDrawer("inherited"))
        XCTAssertEqual(outsideProfile("celestial", try document(fixture)), outsideProfile("celestial", before))
        let reset = try String(contentsOf: fixture.shell.appendingPathComponent("shell.luau"), encoding: .utf8)
        XCTAssertNil(try ShellLuauDocument(Data(reset.utf8)).value["profiles"]?["celestial"]?["drawer"]?["inherited"])
        do {
            try await fixture.configuration.deleteDrawer("inherited", profile: "celestial")
            XCTFail("Deleted an inherited style drawer")
        } catch {}
        XCTAssertNotNil(fixture.editor.drawer("dashboard"))
    }

    func testExplicitDrawerProfilesRejectInvalidTargetsWithoutWrites() async throws {
        let fixture = try await fixture(style: "celestial")
        let manager = FileManager.default
        let fileProfile = fixture.shell.appendingPathComponent("regular-profile")
        try Data("".utf8).write(to: fileProfile)
        let broken = fixture.shell.appendingPathComponent("broken")
        try manager.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("[invalid".utf8).write(to: broken.appendingPathComponent("shell.luau"))
        let reserved = fixture.shell.appendingPathComponent("lib")
        try manager.createDirectory(at: reserved, withIntermediateDirectories: true)
        let fallback = fixture.shell.appendingPathComponent(".fallback")
        try manager.createDirectory(at: fallback, withIntermediateDirectories: true)
        let file = fixture.shell.appendingPathComponent("shell.luau")
        let original = try Data(contentsOf: file)
        for profile in ["nonexistent", "regular-profile", "lib", "broken", ".fallback"] {
            await rejectsDrawerOperation { try await fixture.configuration.addDrawer(
                "tools",
                edge: .left,
                widget: "clock",
                profile: profile
            ) }
            await rejectsDrawerOperation { try await fixture.configuration.editDrawerWidgets(
                "dashboard",
                profile: profile
            ) { $0.append("clock") } }
            await rejectsDrawerOperation { try await fixture.configuration.deleteDrawer("dashboard", profile: profile) }
            XCTAssertEqual(try Data(contentsOf: file), original, profile)
        }
        try await fixture.configuration.addDrawer("tools", edge: .left, widget: "clock", profile: "default")
        let config = try await fixture.configuration.previewConfig(profile: "default")
        XCTAssertEqual(config.drawers.first { $0.id == "tools" }?.widgets, ["clock"])
    }

    func testDrawerCoordinatorRejectsFreshDuplicateNamesAndEmptyMemberEdits() async throws {
        let fixture = try await drawerFixture()
        let file = fixture.shell.appendingPathComponent("shell.luau")
        let before = try Data(contentsOf: file)
        await rejectsDrawerOperation {
            try await fixture.configuration.addDrawer("dashboard", edge: .left, widget: "clock", profile: "celestial")
        }
        await rejectsDrawerOperation {
            try await fixture.configuration.editDrawerWidgets("dashboard", profile: "celestial") { $0.removeAll() }
        }
        await rejectsDrawerOperation {
            try await fixture.configuration.editDrawerWidgets("missing", profile: "celestial") { $0.append("clock") }
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
        try await fixture.configuration.addDrawer("tools", edge: .left, widget: "clock", profile: "celestial")
        let added = try Data(contentsOf: file)
        await rejectsDrawerOperation {
            try await fixture.configuration.addDrawer("tools", edge: .right, widget: "weather", profile: "celestial")
        }
        XCTAssertEqual(try Data(contentsOf: file), added)
    }

    func testDrawerCoordinatorRejectsInstalledWidgetNamesBeforeWriting() async throws {
        let fixture = try await drawerFixture()
        XCTAssertNotNil(fixture.editor.layout?.source(of: "clock"))
        let file = fixture.shell.appendingPathComponent("shell.luau")
        let original = try Data(contentsOf: file)
        await rejectsDrawerOperation {
            try await fixture.configuration.addDrawer("clock", edge: .left, widget: "weather", profile: "celestial")
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testBackToBackDrawerMemberEditsReadTheFreshOrderedList() async throws {
        let fixture = try await drawerFixture()
        try await fixture.configuration.addDrawer("tools", edge: .left, widget: "clock", profile: "celestial")
        async let weather: Void = fixture.configuration
            .editDrawerWidgets("tools", profile: "celestial") { $0.append("weather") }
        async let volume: Void = fixture.configuration
            .editDrawerWidgets("tools", profile: "celestial") { $0.append("volume") }
        try await weather
        try await volume
        let config = try await fixture.configuration.previewConfig(profile: "celestial")
        let members = try XCTUnwrap(config.drawers.first { $0.id == "tools" }?.widgets)
        XCTAssertEqual(members.first, "clock")
        XCTAssertEqual(members.count, 3)
        XCTAssertEqual(Set(members), ["clock", "weather", "volume"])
        XCTAssertEqual(fixture.configuration.config.profile, "default")
    }

    private func rejectsDrawerOperation(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Drawer operation accepted an invalid target")
        } catch {}
    }
}
