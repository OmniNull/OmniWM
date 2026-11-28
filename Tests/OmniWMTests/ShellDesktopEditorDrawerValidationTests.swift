// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
extension ShellDesktopEditorTests {
    func testHiddenInternalAndIslandRootWidgetNamesCannotBecomeDrawers() async throws {
        let fixture = try await fixture(style: "default")
        let file = fixture.shell.appendingPathComponent("shell.luau")
        let original = try Data(contentsOf: file)
        for (profile, name) in [
            ("default", "hidden-bar"), ("default", "hidden-bar-menu"),
            ("default", "effects-lab"), ("default", "focus-ribbon"), ("lake", "lake")
        ] {
            let selected = await fixture.editor.selectStyle(profile)
            XCTAssertTrue(selected)
            XCTAssertNotNil(fixture.editor.snapshot?.config.widget(name))
            XCTAssertNil(fixture.editor.layout?.source(of: name))
            XCTAssertNotNil(fixture.editor.drawerNameProblem(name), "\(profile): \(name)")
            let rejected = await fixture.editor.addDrawer(name: name, edge: .left, widget: "clock")
            XCTAssertFalse(rejected)
            XCTAssertEqual(try Data(contentsOf: file), original)
            do {
                try await fixture.configuration.addDrawer(name, edge: .left, widget: "clock", profile: profile)
                XCTFail("Allowed drawer to shadow \(profile)'s \(name)")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
        XCTAssertEqual(fixture.configuration.config.profile, "default")
    }

    func testPreviewedDrawerKeepsAccessToAnExistingShortcutBinding() async throws {
        let fixture = try await drawerFixture()
        let editor = fixture.editor
        let file = fixture.shell.appendingPathComponent("shell.luau")
        let original = try Data(contentsOf: file)
        let action = ActionCatalog.shellTogglePrefix + "dashboard"
        editor.settings.hotkeyBindings.removeAll { $0.id == action }
        XCTAssertEqual(editor.scope, .previewing(active: "default"))
        XCTAssertEqual(editor.drawerShortcut("dashboard"), .previewing)
        let binding = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(id: action, trigger: .unassigned))
        editor.settings.hotkeyBindings.append(binding)
        XCTAssertEqual(editor.drawerShortcut("dashboard"), .available)
        XCTAssertEqual(editor.scope, .previewing(active: "default"))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
