// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

extension ShellVitreusBarTests {
    private static let shownIcons = 4

    private func sharedItem(_ id: String, focused: Bool = false) -> ShellBarItem {
        ShellBarItem(
            id: id, bundle: "test." + id, name: "App " + id, focused: focused, count: 1, hidden: 0,
            windows: [.init(id: "window-" + id, title: "Window " + id, focused: focused, hidden: false)]
        )
    }

    private func sharedWorkspace(_ id: String, windows: Int, focused: Bool = false) -> ShellBarWorkspace {
        ShellBarWorkspace(
            id: id, name: id, focused: focused,
            windows: (0 ..< windows).map { sharedItem("\(id)-\($0)", focused: focused && $0 == 0) }
        )
    }

    private func sharedWidget(
        _ data: ShellBarData, layout: String = "island", pieces: [String]? = nil,
        on monitor: Monitor = VitreusFixture.monitor()
    ) throws -> ShellRenderedWidget {
        let folder = try shell()
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(folder), scale: 1, resources: VitreusFixture.resources(folder)
        )
        var settings: [String: ShellComponentValue] = ["layout": .string(layout)]
        if let pieces { settings["pieces"] = .strings(pieces) }
        VitreusFixture.settings(widget, settings)
        VitreusFixture.show(widget, on: monitor, bar: data)
        return widget
    }

    func testWorkspaceIconsFollowTheirMarkAndFocusTheirWindow() throws {
        var data = VitreusFixture.bar()
        data.workspaces = [sharedWorkspace("1", windows: 2, focused: true), sharedWorkspace("2", windows: 1)]
        let widget = try sharedWidget(data, pieces: ["workspaces"])
        let pill = try VitreusFixture.frame(widget, key: "workspace-pill-shape")
        let first = try VitreusFixture.frame(widget, key: "workspace-icon-1-1-0")
        let second = try VitreusFixture.frame(widget, key: "workspace-icon-1-1-1")
        let nextMark = try VitreusFixture.frame(widget, key: "workspace-square-2")
        XCTAssertGreaterThanOrEqual(first.minX, pill.maxX)
        XCTAssertGreaterThanOrEqual(second.minX, first.maxX)
        XCTAssertGreaterThanOrEqual(nextMark.minX, second.maxX)
        XCTAssertEqual(first.midY, pill.midY, accuracy: .floatRounding(operations: 8, at: pill.maxY))
        for (key, command) in [
            ("workspace-icon-2-2-0", "window focus 2-0"), ("workspace-hit-2", "switch-workspace 2")
        ] {
            let frame = try VitreusFixture.frame(widget, key: key)
            XCTAssertEqual(widget.surface.command(at: CGPoint(x: frame.midX, y: frame.midY)), command)
        }
    }

    func testABusyWorkspaceShowsItsFirstIconsThenHowManyMore() throws {
        var data = VitreusFixture.bar()
        let hidden = 2
        data.workspaces = [sharedWorkspace("1", windows: Self.shownIcons + hidden, focused: true)]
        let widget = try sharedWidget(data, pieces: ["workspaces"])
        for index in 0 ..< Self.shownIcons {
            XCTAssertTrue(Self.has(widget, "workspace-icon-1-1-\(index)"))
        }
        XCTAssertFalse(Self.has(widget, "workspace-icon-1-1-\(Self.shownIcons)"))
        XCTAssertTrue(widget.strings().contains("+\(hidden)"))
    }

    func testACrowdedBarDropsIconsBeforeItDropsWorkspaces() throws {
        var data = VitreusFixture.bar()
        let count = 24
        data.workspaces = (1 ... count).map { sharedWorkspace(String($0), windows: 3, focused: $0 == 1) }
        let widget = try sharedWidget(data, pieces: ["workspaces"])
        for id in 1 ... count {
            XCTAssertTrue(Self.has(widget, "workspace-hit-\(id)"), "\(id)")
            XCTAssertFalse(Self.has(widget, "workspace-icon-\(id)-\(id)-0"), "\(id)")
        }
    }

    func testScratchpadsFollowTheWorkspacesAndToggleOnClick() throws {
        var data = VitreusFixture.bar()
        data.workspaces = [sharedWorkspace("1", windows: 1, focused: true)]
        data.scratchpads = [
            ShellBarScratchpad(
                id: 1, name: "Notes", focused: false, revealed: false, visible: false,
                windows: [sharedItem("note"), sharedItem("mail")]
            ),
            ShellBarScratchpad(id: 2, name: "Music", focused: false, revealed: false, visible: false, windows: [])
        ]
        let widget = try sharedWidget(data, pieces: ["workspaces", "scratchpads"])
        let icon = try VitreusFixture.frame(widget, key: "workspace-icon-1-1-0")
        let first = try VitreusFixture.frame(widget, key: "scratchpad-1")
        let second = try VitreusFixture.frame(widget, key: "scratchpad-2")
        XCTAssertGreaterThanOrEqual(first.minX, icon.maxX)
        XCTAssertGreaterThanOrEqual(second.minX, first.maxX)
        XCTAssertGreaterThan(first.width, second.width)
        try VitreusFixture.click(widget, key: "scratchpad-1")
        XCTAssertEqual(widget.clicks.last?.action, "scratchpad toggle 1")

        data.scratchpads = []
        VitreusFixture.show(widget, bar: data)
        XCTAssertFalse(Self.has(widget, "scratchpad-1"))
    }

    func testStatsButtonTogglesTheSharedWidgetAndFollowsTheBarSetting() throws {
        var data = VitreusFixture.bar()
        let widget = try sharedWidget(data, pieces: ["stats"])
        XCTAssertTrue(Self.has(widget, "bar-stats"))
        try VitreusFixture.click(widget, key: "bar-stats")
        XCTAssertEqual(widget.clicks.last?.action, "shell toggle system-stats")

        let shown = try VitreusFixture.frame(widget, key: "shell")
        data.style.statsButton = false
        VitreusFixture.show(widget, bar: data)
        XCTAssertFalse(Self.has(widget, "bar-stats"))
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "shell").width, shown.width)
    }

    func testTheNewPiecesStayApartAndOnScreenInEveryLayout() throws {
        var data = VitreusFixture.bar()
        data.workspaces = [sharedWorkspace("1", windows: 2, focused: true), sharedWorkspace("2", windows: 2)]
        data.scratchpads = [
            ShellBarScratchpad(
                id: 1, name: "Notes", focused: false, revealed: false, visible: false, windows: [sharedItem("note")]
            )
        ]
        let monitor = VitreusFixture.monitor()
        let frameRounding = CGFloat(Float(monitor.frame.maxX).ulp)
        let screen = monitor.frame.insetBy(dx: -frameRounding, dy: -frameRounding)
        let keys = [
            "workspace-square-2", "workspace-icon-1-1-0", "workspace-icon-1-1-1", "workspace-icon-2-2-0",
            "workspace-icon-2-2-1", "scratchpad-1", "bar-search", "bar-stats", "bar-omniwm", "bar-controls"
        ]
        for layout in ["island", "ftop", "fbottom", "seg", "left", "right"] {
            let widget = try sharedWidget(data, layout: layout)
            let frames = try keys.map { try VitreusFixture.frame(widget, key: $0) }
            for (index, rect) in frames.enumerated() {
                XCTAssertTrue(screen.contains(rect), "\(layout) \(keys[index]) \(rect)")
                for (otherIndex, other) in frames.enumerated().dropFirst(index + 1) {
                    let overlap = rect.intersection(other)
                    XCTAssertFalse(
                        overlap.width > frameRounding && overlap.height > frameRounding,
                        "\(layout) \(keys[index]) \(rect) overlaps \(keys[otherIndex]) \(other)"
                    )
                }
            }
        }
    }
}
