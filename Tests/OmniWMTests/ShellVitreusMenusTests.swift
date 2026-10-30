// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

private let unit = 1.35
private let safari = ShellMenuApp(pid: 7, name: "Safari", bundle: "com.apple.Safari")

@MainActor
final class ShellVitreusMenusTests: XCTestCase {
    static let classic = ["workspaces", "title", "tray", "search", "gear", "controls", "clock"]
    static let buttons = ["bar-search", "bar-gear", "bar-controls", "bar-clock"]

    func shell() throws -> URL {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        return shell
    }

    func bar(hides: Bool) -> ShellBarData {
        var bar = VitreusFixture.bar()
        bar.style.hidesMenuBar = hides
        bar.workspaces = ["1", "2"].map { id in
            ShellBarWorkspace(id: id, name: id, focused: id == "1", windows: [ShellBarItem(
                id: id, bundle: "test.app", name: "App", focused: id == "1", count: 1, hidden: 0,
                windows: [.init(id: "window-" + id, title: "Window " + id, focused: id == "1", hidden: false)]
            )])
        }
        return bar
    }

    func widget(
        _ shell: URL, layout: String = "island", pieces: [String]? = nil, hides: Bool = true,
        app: ShellMenuApp? = safari, title: String = "A document", tray: Bool = false
    ) throws -> ShellRenderedWidget {
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), resources: VitreusFixture.resources(shell)
        )
        var settings: [String: ShellComponentValue] = ["layout": .string(layout)]
        if let pieces { settings["pieces"] = .strings(pieces) }
        VitreusFixture.settings(widget, settings)
        let items = tray ? [ShellHiddenBarItem(id: "wifi", name: "Wi-Fi", image: nil, width: 22, height: 22)] : []
        widget.set("clock") { $0.string("6:42 pm") }
        widget.set("date") { $0.string("Tue 28") }
        widget.set("app") { $0.string("Safari") }
        widget.set("title") { $0.string(title) }
        widget.set("hiddenBar") { ShellHiddenBarData(items: items).write(into: &$0) }
        widget.set("menuApp") { writer in app.map { $0.write(into: &writer) } ?? writer.null() }
        VitreusFixture.show(widget, bar: bar(hides: hides))
        return widget
    }

    func frame(_ widget: ShellRenderedWidget, _ key: String) throws -> CGRect {
        try VitreusFixture.frame(widget, key: key)
    }

    func has(_ widget: ShellRenderedWidget, _ key: String) -> Bool {
        ShellVitreusBarTests.has(widget, key)
    }

    func content(_ widget: ShellRenderedWidget, _ key: String) throws -> Content {
        try widget.surface.layout.core.content(of: VitreusFixture.element(widget, key: key))
    }

    func paint(_ widget: ShellRenderedWidget, _ key: String) throws -> Paint {
        try widget.surface.layout.core.paint(of: VitreusFixture.element(widget, key: key))
    }

    func picture(_ widget: ShellRenderedWidget, _ name: String) throws -> Content {
        let layout = widget.surface.layout
        let icon = try VitreusFixture.element(widget, key: "bar-\(name)-icon")
        let child = try XCTUnwrap(layout.core.elements { _ in true }.first { layout.core.parent(of: $0) == icon }, name)
        XCTAssertEqual(layout.core.kind(of: child), name == "apple" ? .symbol : .image, name)
        return layout.core.content(of: child)
    }

    func deps(_ widget: ShellRenderedWidget) -> UInt64 {
        widget.output().withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
    }

    func hover(_ widget: ShellRenderedWidget, _ key: String, _ phase: ShellEvent.Phase) throws {
        var event = ShellEvent()
        event.phase = phase
        widget.invoke(try content(widget, key).hoverAction, event: event)
        VitreusFixture.show(widget, bar: bar(hides: true))
    }

    func assertMoved(
        _ moved: ShellRenderedWidget, _ still: ShellRenderedWidget, _ keys: [String], dx: CGFloat = 0, dy: CGFloat = 0,
        _ label: String
    ) throws {
        for key in keys {
            ShellVitreusBarTests.assertRect(
                try frame(moved, key), try frame(still, key).offsetBy(dx: dx, dy: dy), "\(label) \(key)"
            )
        }
    }

    func assertLead(_ widget: ShellRenderedWidget, x: CGFloat, top: CGFloat, height: CGFloat, _ label: String) throws {
        ShellVitreusBarTests.assertRect(
            try frame(widget, "bar-apple"),
            CGRect(x: x + 6 * unit - 12 * unit, y: top, width: 24 * unit, height: height), "\(label) apple"
        )
        ShellVitreusBarTests.assertRect(
            try frame(widget, "bar-app"),
            CGRect(x: x + 32 * unit - 13 * unit, y: top, width: 26 * unit, height: height), "\(label) app"
        )
    }
}

extension ShellVitreusMenusTests {
    func testTheMenusRunTheNativeMenuActionsWithTheButtonsHaloHoverAndHelp() throws {
        let widget = try widget(shell())
        for (name, help, rest) in [("apple", "Apple Menu", 0.65), ("app", "Safari", 0.88)] {
            let zone = try frame(widget, "bar-" + name)
            XCTAssertEqual(widget.surface.command(at: CGPoint(x: zone.midX, y: zone.midY)), "menu " + name, name)
            XCTAssertEqual(widget.text.string(try content(widget, "bar-" + name).help), help, name)
            let icon = try paint(widget, "bar-\(name)-icon")
            XCTAssertEqual(icon.shadow.role & 0xFF, UInt16(ShellRole.shadow.rawValue + 1), name)
            XCTAssertEqual(Double(icon.shadow.role >> 8) / 255, 1, accuracy: 0.003, name)
            XCTAssertEqual(Double(icon.shadowRadius), 2.4 * unit, accuracy: 1e-4, name)
            XCTAssertEqual([icon.shadowOffsetX, icon.shadowOffsetY], [0, 0], name)
            XCTAssertEqual(Double(icon.opacity), rest, accuracy: 1e-6, name)
            XCTAssertEqual(icon.scale, 1, name)
            try hover(widget, "bar-" + name, .began)
            XCTAssertEqual(try paint(widget, "bar-\(name)-icon").opacity, 1, accuracy: 1e-6, name)
            XCTAssertEqual(try paint(widget, "bar-\(name)-icon").scale, 1.14, accuracy: 1e-6, name)
            try hover(widget, "bar-" + name, .ended)
            XCTAssertEqual(Double(try paint(widget, "bar-\(name)-icon").opacity), rest, accuracy: 1e-6, name)
        }
        let apple = try picture(widget, "apple")
        XCTAssertEqual(widget.text.string(apple.text), "applelogo")
        XCTAssertEqual(apple.color.role & 0xFF, UInt16(ShellRole.foreground.rawValue + 1))
        let app = try picture(widget, "app")
        XCTAssertEqual(app.iconSource, .bundle)
        XCTAssertEqual(widget.text.string(app.text), "com.apple.Safari")
        XCTAssertEqual(widget.text.string(app.placeholder), "app.dashed")
        widget.set("menuApp") { ShellMenuApp(pid: 42, name: "Tool", bundle: "").write(into: &$0) }
        VitreusFixture.show(widget, bar: bar(hides: true))
        let fallback = try picture(widget, "app")
        XCTAssertEqual(fallback.iconSource, .pid)
        XCTAssertEqual(widget.text.string(fallback.iconRef), "42")
        XCTAssertEqual(widget.text.string(try content(widget, "bar-app").help), "Tool")
    }

    func testTheMenusShowOnlyWhileTheBarHidesTheMenuBarAndTheAppOnlyForAFocusedApp() throws {
        let widget = try widget(shell(), app: nil)
        XCTAssertTrue(has(widget, "bar-apple"))
        XCTAssertFalse(has(widget, "bar-app"))
        XCTAssertNotEqual(deps(widget) & ShellDataKey.menuApp.bit, 0)
        XCTAssertEqual(try frame(widget, "shell").width, (450 + 24) * unit, accuracy: 0.001)
        widget.set("menuApp") { safari.write(into: &$0) }
        VitreusFixture.show(widget, bar: bar(hides: true))
        XCTAssertTrue(has(widget, "bar-app"))
        XCTAssertEqual(try frame(widget, "shell").width, (450 + 52) * unit, accuracy: 0.001)
        VitreusFixture.show(widget, bar: bar(hides: false))
        XCTAssertFalse(has(widget, "bar-apple"))
        XCTAssertFalse(has(widget, "bar-app"))
        XCTAssertEqual(try frame(widget, "shell").width, 450 * unit, accuracy: 0.001)
        XCTAssertEqual(deps(widget) & ShellDataKey.menuApp.bit, 0)
    }

    func testHiddenMenusLeaveEveryLayoutAsItIsWithoutThem() throws {
        let shell = try shell()
        for layout in ["island", "ftop", "fbottom", "seg", "left", "right"] {
            let classic = try widget(shell, layout: layout, pieces: Self.classic, hides: false, tray: true)
            let hidden = try widget(shell, layout: layout, hides: false, tray: true)
            XCTAssertFalse(has(hidden, "bar-apple"), layout)
            XCTAssertFalse(has(hidden, "bar-app"), layout)
            XCTAssertEqual(hidden.strings(), classic.strings(), layout)
            let before = classic.surface.layout
            let after = hidden.surface.layout
            let old = before.core.elements { _ in true }
            let new = after.core.elements { _ in true }
            XCTAssertEqual(new.map { after.core.key(of: $0) }, old.map { before.core.key(of: $0) }, layout)
            for (element, reference) in zip(new, old) {
                ShellVitreusBarTests.assertRect(
                    CGRect(after.core.absoluteFrame(of: element)), CGRect(before.core.absoluteFrame(of: reference)),
                    "\(layout) \(after.core.key(of: element))"
                )
            }
        }
    }

    func testTheMenusLeadTheIslandPillAndTheTopAndBottomStrips() throws {
        let shell = try shell()
        let shown = try widget(shell)
        let hidden = try widget(shell, hides: false)
        let pill = try frame(shown, "shell")
        XCTAssertEqual(pill.width, try frame(hidden, "shell").width + 52 * unit, accuracy: 0.001)
        XCTAssertEqual(pill.midX, 960, accuracy: 0.001)
        try assertLead(shown, x: pill.minX + 16 * unit, top: pill.minY, height: pill.height, "island")
        try assertMoved(shown, hidden, Self.buttons + ["workspace-overview", "title-button"], dx: 26 * unit, "island")
        for layout in ["ftop", "fbottom"] {
            let shown = try widget(shell, layout: layout)
            let hidden = try widget(shell, layout: layout, hides: false)
            let strip = try frame(shown, "bar-hover")
            try assertLead(shown, x: 28 * unit, top: strip.minY, height: strip.height, layout)
            try assertMoved(shown, hidden, ["workspace-overview"], dx: 52 * unit, layout)
            try assertMoved(shown, hidden, Self.buttons + ["title-button"], layout)
        }
    }

    func testNotchesPutTheMenusInTheLeftPieceBeforeTheWorkspaces() throws {
        let shell = try shell()
        let shown = try widget(shell, layout: "seg")
        let hidden = try widget(shell, layout: "seg", hides: false)
        let area = try VitreusFixture.element(shown, key: "bar-hover-left")
        for key in ["bar-apple", "bar-app"] {
            XCTAssertTrue(shown.surface.isWithin(try VitreusFixture.element(shown, key: key), area), key)
        }
        try assertLead(shown, x: 26 * unit, top: 0, height: 36 * unit, "seg")
        XCTAssertLessThan(try frame(shown, "bar-app").maxX, try frame(shown, "workspace-overview").minX)
        try assertMoved(shown, hidden, ["workspace-overview"], dx: 52 * unit, "seg")
        let left = try frame(shown, "notch-left")
        let before = try frame(hidden, "notch-left")
        XCTAssertEqual(left.minX, before.minX, accuracy: 0.001)
        XCTAssertEqual(left.width, before.width + 52 * unit, accuracy: 0.001)
        let rest = ["notch-middle", "notch-right", "bar-hover-middle", "bar-hover-right", "title-button"]
        try assertMoved(shown, hidden, Self.buttons + rest, "seg")
        let pieces = ["apple", "title", "gear"]
        let alone = try widget(shell, layout: "seg", pieces: pieces)
        XCTAssertEqual(try frame(alone, "bar-hover-left").width, (26 + 12 + 14 + 12) * unit, accuracy: 0.001)
        let lone = try VitreusFixture.element(alone, key: "bar-apple")
        XCTAssertTrue(alone.surface.isWithin(lone, try VitreusFixture.element(alone, key: "bar-hover-left")))
        XCTAssertFalse(has(try widget(shell, layout: "seg", pieces: pieces, hides: false), "notch-left"))
    }

    func testVerticalStripsStackTheMenusAboveSearchAndMoveOnlyTheTrayAndTitleUp() throws {
        let shell = try shell()
        let title = String(repeating: "A long document title ", count: 8)
        for (layout, centre) in [("left", 23 * unit), ("right", 1920 - 23 * unit)] {
            let shown = try widget(shell, layout: layout, title: title, tray: true)
            let hidden = try widget(shell, layout: layout, hides: false, title: title, tray: true)
            let search = try frame(shown, "bar-search")
            for (index, key) in ["bar-app", "bar-apple"].enumerated() {
                let y = search.midY - CGFloat(index + 1) * 32 * unit
                ShellVitreusBarTests.assertRect(
                    try frame(shown, key),
                    CGRect(x: centre - 18 * unit, y: y - 15 * unit, width: 36 * unit, height: 30 * unit),
                    "\(layout) \(key)"
                )
            }
            let kept = Self.buttons + ["workspace-overview", "workspace-hit-1", "workspace-hit-2"]
            try assertMoved(shown, hidden, kept, layout)
            XCTAssertEqual(
                try frame(shown, "tray-wifi").midY, try frame(hidden, "tray-wifi").midY - 64 * unit, accuracy: 1,
                layout
            )
            let text = try frame(shown, "title-button")
            let before = try frame(hidden, "title-button")
            XCTAssertEqual(text.minY, before.minY, accuracy: 0.001, layout)
            XCTAssertEqual(text.maxY, before.maxY - 64 * unit, accuracy: 0.001, layout)
            XCTAssertLessThan(text.maxY, try frame(shown, "tray-wifi").minY, layout)
        }
    }
}
