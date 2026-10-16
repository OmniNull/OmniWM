// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellHiddenBarMenuTests: XCTestCase {
    private func row(
        _ id: String,
        enabled: Bool = true,
        mark: String? = nil,
        shortcut: String? = nil,
        submenu: Bool = false,
        separator: Bool = false
    ) -> HiddenBarMenuRow {
        HiddenBarMenuRow(
            id: id,
            title: id,
            enabled: enabled,
            mark: mark,
            shortcut: shortcut,
            submenu: submenu,
            separator: separator
        )
    }

    func testRowsPreserveMenuContentAndDisableUnavailableActions() throws {
        let widget = try ShellRenderedWidget("hidden-bar-menu")
        var data = ShellHiddenBarData()
        data.menu = HiddenBarMenuPage(title: "Options", rows: [
            row("checked", mark: "✓", shortcut: "⌘K"),
            row("disabled", enabled: false),
            row("separator", separator: true),
            row("submenu", submenu: true)
        ], backID: "back")
        widget.set("hiddenBar") { data.write(into: &$0) }
        let tree = widget.renderPopout()
        let commands = tree.compactMap { $0.content.action == 0 ? nil : widget.text.string($0.content.action) }
        XCTAssertEqual(commands, ["hidden-bar-menu back", "hidden-bar-menu checked", "hidden-bar-menu submenu"])
        let strings = widget.strings(OMNI_VIEW_POPOUT)
        for text in ["Options", "checked", "✓", "⌘K", "disabled", "submenu"] {
            XCTAssertTrue(strings.contains(text), text)
        }
        XCTAssertTrue(tree.first?.content.scrolls == true)
    }

    func testLongMenusScrollToTheirLastAction() throws {
        let widget = try ShellRenderedWidget("hidden-bar-menu")
        var data = ShellHiddenBarData(maxHeight: 140)
        data.menu = HiddenBarMenuPage(title: nil, rows: (0 ..< 30).map { row("item-\($0)") }, backID: nil)
        widget.set("hiddenBar") { data.write(into: &$0) }
        widget.layoutPopout()
        XCTAssertEqual(widget.surface.size.height, 140)
        widget.surface.press(at: CGPoint(x: 60, y: 18))
        widget.surface.release(at: CGPoint(x: 60, y: 18))
        XCTAssertEqual(widget.clicks.last?.action, "hidden-bar-menu item-0")
        XCTAssertTrue(widget.surface.scroll(
            at: CGPoint(x: 60, y: 18),
            event: ShellEvent(button: .none),
            content: CGPoint(x: 0, y: 10000)
        ))
        widget.surface.press(at: CGPoint(x: 60, y: 121))
        widget.surface.release(at: CGPoint(x: 60, y: 121))
        XCTAssertEqual(widget.clicks.last?.action, "hidden-bar-menu item-29")
    }

    func testMenuAttachmentUsesTheIconAndFitsWithinTheScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let icon = CGRect(x: 970, y: 740, width: 20, height: 20)
        let anchor = ShellAnchor(frame: icon, level: .popUpMenu, container: visible)
        let attachment = ShellPopout.fittedAttachment(
            anchor: anchor,
            size: CGSize(width: 320, height: 200),
            visibleFrame: visible
        )
        XCTAssertEqual(attachment, PopupAttachment(sourceFrame: icon, edge: .below))
        let frame = attachment.frame(size: CGSize(width: 320, height: 200), visibleFrame: visible)
        XCTAssertEqual(frame.maxX, visible.maxX - 8)
        XCTAssertEqual(frame.maxY, icon.minY - 4)
        let bottom = CGRect(x: 300, y: 12, width: 20, height: 20)
        XCTAssertEqual(
            ShellPopout.fittedAttachment(
                anchor: ShellAnchor(frame: bottom, level: .popUpMenu),
                size: CGSize(width: 320, height: 200),
                visibleFrame: visible
            ),
            PopupAttachment(sourceFrame: bottom, edge: .above)
        )
    }

    func testChildMenuKeepsParentRegisteredAndRejectsOldPageActions() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first else { throw XCTSkip("menu panels need a screen") }
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        let widget = try ShellRenderedWidget(name: "icons", source: """
        function render(ctx) return ui.row{} end
        function popout(ctx) return ui.box{ w = 120, h = 30 } end
        """)
        let parent = makeParent(screen: screen, resources: resources)
        _ = widget.renderPopout()
        XCTAssertTrue(parent.apply(widget.output(OMNI_VIEW_POPOUT), text: widget.text))
        defer { parent.close(animated: false) }
        let icon = CGRect(x: parent.panel.frame.minX + 12, y: parent.panel.frame.minY + 5, width: 20, height: 20)
        var selected: [String] = []
        var failures = 0
        let menu = ShellHiddenBarMenu(
            page: HiddenBarMenuPage(title: nil, rows: [row("first")], backID: nil),
            anchor: ShellAnchor(frame: icon, level: parent.panel.level, container: parent.panel.frame),
            parent: parent,
            resources: resources,
            source: try source(),
            directories: [],
            onSelect: { selected.append($0) },
            onFailure: { failures += 1 }
        )
        defer { menu.close() }
        while !menu.popout.panel.isVisible, failures == 0 { await Task.yield() }
        XCTAssertEqual(failures, 0)
        XCTAssertTrue(OwnedWindowRegistry.shared.contains(window: parent.panel))
        XCTAssertTrue(OwnedWindowRegistry.shared.contains(window: menu.popout.panel))
        XCTAssertEqual(menu.popout.panel.frame.midX, icon.midX, accuracy: 0.5)
        XCTAssertEqual(menu.popout.panel.frame.maxY, icon.minY - 4, accuracy: 0.5)
        let childPoint = CGPoint(x: menu.popout.panel.frame.midX, y: menu.popout.panel.frame.midY)
        XCTAssertTrue(parent.contains(screenPoint: childPoint, in: menu.popout.panel))
        XCTAssertTrue(menu.popout.surface.handleKey(UInt16(kVK_DownArrow), shift: false))
        XCTAssertTrue(menu.popout.surface.handleKey(UInt16(kVK_Return), shift: false))
        XCTAssertEqual(selected, ["first"])
        menu.update(page: HiddenBarMenuPage(title: "Next", rows: [row("second")], backID: "back"))
        menu.popout.surface.press(at: CGPoint(x: 40, y: 18))
        menu.popout.surface.release(at: CGPoint(x: 40, y: 18))
        XCTAssertEqual(selected, ["first"])
        while menu.popout.surface.size.height < 90, failures == 0 { await Task.yield() }
        menu.popout.surface.press(at: CGPoint(x: 40, y: 18))
        menu.popout.surface.release(at: CGPoint(x: 40, y: 18))
        XCTAssertEqual(selected, ["first", "back"])
        menu.close()
        XCTAssertFalse(menu.popout.panel.isVisible)
        XCTAssertFalse(OwnedWindowRegistry.shared.contains(window: menu.popout.panel))
        XCTAssertTrue(parent.panel.isVisible)
        XCTAssertTrue(OwnedWindowRegistry.shared.contains(window: parent.panel))
        XCTAssertFalse(parent.contains(screenPoint: childPoint, in: menu.popout.panel))
    }

    func testFailedScriptClosesOnlyItsChildPresentation() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first else { throw XCTSkip("menu panels need a screen") }
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        let parent = makeParent(screen: screen, resources: resources)
        defer { parent.close(animated: false) }
        var failures = 0
        let menu = ShellHiddenBarMenu(
            page: HiddenBarMenuPage(title: nil, rows: [], backID: nil),
            anchor: ShellAnchor(frame: screen.visibleFrame, level: .popUpMenu),
            parent: parent,
            resources: resources,
            source: ShellWidgetSource(chunk: "=invalid", main: "not valid Luau", modules: []),
            directories: [],
            onSelect: { _ in XCTFail("failed script selected an action") },
            onFailure: { failures += 1 }
        )
        defer { menu.close() }
        while failures == 0 { await Task.yield() }
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(menu.popout.panel.isVisible)
        menu.update(page: HiddenBarMenuPage(title: nil, rows: [row("closed")], backID: nil))
        XCTAssertNil(menu.popout.surface.onAction)
    }

    private func makeParent(screen: NSScreen, resources: ShellResources) -> ShellPopout {
        ShellPopout(
            widget: "icons",
            key: ShellBarKey(monitor: Monitor.ID(displayId: screen.displayId ?? CGMainDisplayID())),
            anchor: ShellAnchor(
                frame: CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 40, width: 20, height: 20),
                level: .statusBar
            ),
            screen: screen,
            resources: resources,
            directories: [],
            onDismiss: {}
        )
    }

    private func source() throws -> ShellWidgetSource {
        let url = try XCTUnwrap(ShellConfig.bundledWidget("hidden-bar-menu"))
        return ShellWidgetSource(
            chunk: "=hidden-bar-menu",
            main: try String(contentsOf: url, encoding: .utf8),
            modules: []
        )
    }
}
