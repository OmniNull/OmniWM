// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
extension ShellDesktopEditorTests {
    func testDrawerActionsWriteOnlyTheSelectedStyle() async throws {
        let fixture = try await drawerFixture()
        let editor = fixture.editor
        let original = try document(fixture)
        let active = fixture.configuration.config
        XCTAssertTrue(editor.isStyleDrawer("dashboard"))
        let refused = await editor.deleteDrawer("dashboard")
        XCTAssertFalse(refused)
        XCTAssertEqual(try document(fixture), original)
        editor.problem = nil
        let added = await editor.addDrawer(name: " tools ", edge: .left, widget: "clock")
        XCTAssertTrue(added)
        XCTAssertEqual(editor.selectedDrawer, "tools")
        XCTAssertFalse(editor.isStyleDrawer("tools"))
        await drawerEdit(fixture) { editor.setDrawer("tools", key: "edge", value: "bottom") }
        await drawerEdit(fixture) { editor.setDrawer("tools", key: "hover", value: true) }
        await drawerEdit(fixture) { editor.setDrawer("tools", key: "close", value: "leave") }
        await drawerEdit(fixture) { editor.setDrawer("tools", key: "chrome", value: false) }
        await drawerEdit(fixture) { editor.setDrawer("tools", key: "width", value: 420.0) }
        editor.setDrawer("tools", key: "reach", value: 37.0, continuous: true)
        let drained = await editor.writes.drain()
        XCTAssertTrue(drained)
        let edited = try XCTUnwrap(editor.drawer("tools"))
        XCTAssertEqual(edited.edge, .bottom)
        XCTAssertTrue(edited.hover)
        XCTAssertTrue(edited.closesOnLeave)
        XCTAssertFalse(edited.chrome)
        XCTAssertEqual(edited.width, 420)
        XCTAssertEqual(edited.reach, 37)
        await drawerEdit(fixture) { editor.setDrawer("tools", key: "width", value: Optional<Double>.none) }
        XCTAssertNil(editor.drawer("tools")?.width)
        XCTAssertEqual(outsideProfile("celestial", try document(fixture)), outsideProfile("celestial", original))
        XCTAssertEqual(fixture.configuration.config, active)
        XCTAssertEqual(editor.scope, .previewing(active: "default"))
    }

    func testDrawerMembersResetAndDeleteStayInTheSelectedStyle() async throws {
        let fixture = try await drawerFixture()
        let editor = fixture.editor
        let original = try document(fixture)
        let active = fixture.configuration.config
        let preset = try XCTUnwrap(editor.drawer("dashboard"))
        let added = await editor.addDrawer(name: "tools", edge: .left, widget: "clock")
        XCTAssertTrue(added)
        let memberAdded = await editor.addDrawerWidget("weather", to: "tools")
        XCTAssertTrue(memberAdded)
        let secondMember = await editor.addDrawerWidget("volume", to: "tools")
        XCTAssertTrue(secondMember)
        await drawerEdit(fixture) { editor.moveDrawerWidget("volume", in: "tools", to: 0) }
        XCTAssertEqual(editor.drawerMembers("tools"), ["volume", "clock", "weather"])
        await drawerEdit(fixture) { editor.shiftDrawerWidget("volume", in: "tools", by: 1) }
        XCTAssertEqual(editor.drawerMembers("tools"), ["clock", "volume", "weather"])
        await drawerEdit(fixture) {
            XCTAssertTrue(editor.dropDrawerWidget(
                editor.drawerWidgetPayload("clock", in: "tools"),
                into: "tools",
                at: 3
            ))
        }
        XCTAssertEqual(editor.drawerMembers("tools"), ["volume", "weather", "clock"])
        await drawerEdit(fixture) { editor.removeDrawerWidget("weather", from: "tools") }
        XCTAssertEqual(editor.drawerMembers("tools"), ["volume", "clock"])
        await drawerEdit(fixture) { editor.setDrawer("dashboard", key: "chrome", value: true) }
        await drawerEdit(fixture) { editor.resetDrawer("dashboard") }
        XCTAssertEqual(editor.drawer("dashboard"), preset)
        let beforeUserReset = editor.drawerMembers("tools")
        let savesBeforeReset = fixture.saves.count
        editor.resetDrawer("tools")
        let configuration = fixture.configuration
        let edited = await editor.run {
            try await configuration.set(false, key: "chrome", table: "drawer.tools", profile: "celestial")
        }
        XCTAssertTrue(edited)
        await configuration.flush()
        await editor.reload()
        XCTAssertEqual(editor.drawerMembers("tools"), beforeUserReset)
        XCTAssertEqual(fixture.saves.count, savesBeforeReset + 1)
        let deleted = await editor.deleteDrawer("tools")
        XCTAssertTrue(deleted)
        XCTAssertNil(editor.drawer("tools"))
        XCTAssertEqual(editor.selectedDrawer, "dashboard")
        XCTAssertEqual(editor.drawer("dashboard"), preset)
        XCTAssertEqual(outsideProfile("celestial", try document(fixture)), outsideProfile("celestial", original))
        XCTAssertEqual(fixture.configuration.config, active)
        XCTAssertEqual(editor.scope, .previewing(active: "default"))
    }

    func testDrawerDropRejectsForeignStaleUnknownAndSamePositionPayloads() async throws {
        let fixture = try await drawerFixture()
        let editor = fixture.editor
        let added = await editor.addDrawer(name: "tools", edge: .right, widget: "clock")
        XCTAssertTrue(added)
        let member = await editor.addDrawerWidget("weather", to: "tools")
        XCTAssertTrue(member)
        let other = await editor.addDrawer(name: "other", edge: .right, widget: "clock")
        XCTAssertTrue(other)
        let otherMember = await editor.addDrawerWidget("weather", to: "other")
        XCTAssertTrue(otherMember)
        let before = try document(fixture)
        let payload = editor.drawerWidgetPayload("clock", in: "tools")
        for value in [
            "clock", ["omniwm-drawer", "foreign", "celestial", "tools", "clock"].joined(separator: "\n"),
            ["omniwm-drawer", editor.dragToken, "default", "tools", "clock"].joined(separator: "\n"),
            editor.drawerWidgetPayload("clock", in: "missing"),
            editor.drawerWidgetPayload("missing", in: "tools")
        ] {
            XCTAssertFalse(editor.dropDrawerWidget(value, into: "tools", at: 2), value)
        }
        XCTAssertFalse(editor.dropDrawerWidget(payload, into: "other", at: 2))
        XCTAssertFalse(editor.dropDrawerWidget(payload, into: "tools", at: 0))
        XCTAssertFalse(editor.dropDrawerWidget(payload, into: "tools", at: 1))
        XCTAssertEqual(try document(fixture), before)
        await drawerEdit(fixture) { XCTAssertTrue(editor.dropDrawerWidget(payload, into: "tools", at: 2)) }
        XCTAssertEqual(editor.drawerMembers("tools"), ["weather", "clock"])
        let switched = await editor.selectStyle("lake")
        XCTAssertTrue(switched)
        XCTAssertFalse(editor.dropDrawerWidget(payload, into: "tools", at: 0))
    }

    func testFailedDrawerAddKeepsSelectionConfigurationAndProblem() async throws {
        let fixture = try await drawerFixture()
        let editor = fixture.editor
        let file = fixture.shell.appendingPathComponent("shell.luau")
        let original = try Data(contentsOf: file)
        let selection = editor.selectedDrawer
        try Data("[invalid".utf8).write(to: file)
        let failed = try Data(contentsOf: file)
        let added = await editor.addDrawer(name: "tools", edge: .left, widget: "clock")
        XCTAssertFalse(added)
        XCTAssertEqual(editor.selectedDrawer, selection)
        XCTAssertNotNil(editor.problem)
        XCTAssertEqual(try Data(contentsOf: file), failed)
        try original.write(to: file)
        let accepted = await editor.addDrawer(name: "tools", edge: .left, widget: "clock")
        XCTAssertTrue(accepted)
        XCTAssertEqual(editor.selectedDrawer, "tools")
    }

    func drawerFixture() async throws -> Fixture {
        let fixture = try await fixture(style: "celestial")
        let selected = await fixture.editor.selectSurface(.drawers)
        XCTAssertTrue(selected)
        XCTAssertEqual(fixture.editor.selectedDrawer, "dashboard")
        return fixture
    }

    func drawerEdit(_ fixture: Fixture, _ operation: @MainActor () -> Void) async {
        let count = fixture.saves.count + 1
        operation()
        await fixture.saves.wait(count)
        await fixture.editor.reload()
    }

    func outsideProfile(_ profile: String, _ value: [String: SettingsLuauValue]) -> [String: SettingsLuauValue] {
        var value = value
        if case var .record(profiles)? = value["profiles"] {
            profiles[profile] = nil
            value["profiles"] = .record(profiles)
        }
        return value
    }
}
