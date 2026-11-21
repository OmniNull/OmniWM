// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import SwiftUI
import XCTest

@MainActor
final class WorkspaceBarOverflowTests: XCTestCase {
    private typealias Item = WorkspaceBarZoneLayout.Item
    private typealias Span = WorkspaceBarZoneLayout.Span

    private let inset: CGFloat = 4
    private let spacing: CGFloat = 8
    private let tight = WorkspaceBarZoneLayout.tightSpacing
    private let fade = ShellWidgetSurface.scrollFade
    private let zones = WorkspaceBarZones(notch: nil, mode: .off)

    private func spans(_ items: [Item], length: CGFloat) -> [Span] {
        WorkspaceBarZoneLayout.spans(of: items, length: length, zones: zones, spacing: spacing, inset: inset)
    }

    private func data(windows: [Int], names: [String]? = nil, room: Double? = nil) -> ShellBarData {
        var data = ShellBarData()
        data.style.height = 33
        data.workspacesRoom = room
        data.workspaces = windows.enumerated().map { offset, count in
            let name = names?[offset] ?? "\(offset + 1)"
            return ShellBarWorkspace(
                id: name, name: name, focused: offset == 0,
                windows: (0 ..< count).map { index in
                    ShellBarItem(
                        id: "app\(offset)_\(index)", bundle: "com.example.app\(index)", name: "App", focused: false,
                        count: 1, hidden: 0, floating: false,
                        windows: [ShellBarWindow(
                            id: "app\(offset)_\(index)_0", title: "Window", focused: false, hidden: false
                        )]
                    )
                }
            )
        }
        return data
    }

    func testGapsTightenBeforeAnyWidgetIsCut() {
        let items = [
            Item(lane: .leading, length: 100, priority: 0),
            Item(lane: .leading, length: 200, priority: 1),
            Item(lane: .trailing, length: 50, priority: 2)
        ]
        let content: CGFloat = 350

        let squeezed = inset * 2 + content + 5 * 2
        XCTAssertEqual(spans(items, length: squeezed), [
            Span(start: inset, length: 100),
            Span(start: inset + 100 + 5, length: 200),
            Span(start: squeezed - inset - 50, length: 50)
        ])

        let short = inset * 2 + content + tight * 2 - 10
        XCTAssertEqual(spans(items, length: short), [
            Span(start: inset, length: 100),
            Span(start: inset + 100 + tight, length: 200),
            Span(start: short - inset - 40, length: 40)
        ])
    }

    func testAWidgetsRoomIsWhatItsNeighboursLeaveAtTightGaps() {
        let slots = [
            WorkspaceBarShellWidget(id: "apple-menu", size: CGSize(width: 29, height: 29), lane: .leading),
            WorkspaceBarShellWidget(id: "workspaces", size: CGSize(width: 520, height: 29), lane: .leading),
            WorkspaceBarShellWidget(id: "scratchpads", size: .zero, lane: .leading),
            WorkspaceBarShellWidget(id: "system-stats", size: CGSize(width: 24.75, height: 29), lane: .trailing)
        ]
        XCTAssertEqual(
            WorkspaceBarManager.workspacesRoom(beside: slots, length: 656, zones: zones),
            Double(656 - inset * 2 - 29 - 24.75 - tight * 2)
        )
        XCTAssertNil(WorkspaceBarManager.workspacesRoom(beside: [slots[0]], length: 656, zones: zones))
        XCTAssertEqual(
            WorkspaceBarManager.workspacesRoom(beside: slots, length: 656, zones: zones, scratchpads: 80),
            Double(656 - inset * 2 - 29 - 24.75 - 80 - tight * 3)
        )

        let notch = WorkspaceBarZones(notch: 400 ... 600, mode: .rightOfNotch)
        XCTAssertEqual(
            WorkspaceBarManager.workspacesRoom(beside: slots, length: 1000, zones: notch),
            Double(400 - WorkspaceBarGeometry.notchGap - inset - 29 - tight)
        )
    }

    func testTheWorkspacesStripTightensItsPaddingOnlyWhenItsRoomRunsOut() throws {
        let windows = [1, 2, 0, 2, 0, 3, 1]
        func width(room: Double?, indicator: String? = nil, names: [String]? = nil) throws -> CGFloat {
            let widget = try ShellRenderedWidget("workspaces")
            widget.set("settings") {
                $0.map(indicator == nil ? 0 : 1)
                if let indicator {
                    $0.key("indicator")
                    $0.string(indicator)
                }
            }
            widget.render(data(windows: windows, names: names, room: room))
            return widget.surface.naturalSize.width
        }
        let regular = try width(room: nil)
        let saved = CGFloat(windows.count) * 6 + CGFloat(windows.count - 1) * 4

        XCTAssertEqual(try width(room: Double(regular)), regular)
        XCTAssertEqual(try width(room: Double(regular) - 0.5), regular - saved)

        let named = ["Web", "Mail", "3", "Code", "5", "Chat", "Music"]
        for (indicator, names) in [("numbers", nil), ("pills", named), ("numbers", named)] as [(String, [String]?)] {
            let regular = try width(room: nil, indicator: indicator, names: names)
            XCTAssertEqual(try width(room: Double(regular) + 0.5, indicator: indicator, names: names), regular)
            XCTAssertLessThan(try width(room: Double(regular) - 0.5, indicator: indicator, names: names), regular)
        }
    }

    func testACutWorkspacesStripScrollsFadesItsEdgesAndFollowsFocus() throws {
        let widget = try ShellRenderedWidget("workspaces")
        widget.render(data(windows: [2, 3, 1, 3, 1, 4, 3]))
        let surface = widget.surface
        let natural = surface.naturalSize
        let stats = NSView()
        let statsWidth: CGFloat = 24
        let bar: CGFloat = 400
        let shown = bar - inset * 2 - tight - statsWidth
        XCTAssertGreaterThan(natural.width, shown)
        XCTAssertFalse(surface.layout.scrolls(cutTo: CGSize(width: natural.width - 0.5, height: natural.height)))

        let model = WorkspaceBarModel(snapshot: WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            backgroundOpacity: 0.1,
            barHeight: 33,
            shellWidgets: [
                WorkspaceBarShellWidget(
                    id: "workspaces", size: natural, lane: .leading, priority: 1,
                    stops: surface.layout.parts.stops(in: natural, vertical: false, keepsEnd: false)
                ),
                WorkspaceBarShellWidget(
                    id: "system-stats", size: CGSize(width: statsWidth, height: 20), lane: .trailing, priority: 0
                )
            ]
        ))
        model.zones = zones
        let host = NSHostingView(rootView: WorkspaceBarView(
            model: model,
            motionPolicy: MotionPolicy(animationsEnabled: false),
            shellSurface: { $0 == "workspaces" ? surface.view : stats }
        ))
        host.frame = CGRect(x: 0, y: 0, width: bar, height: 33)
        host.layoutSubtreeIfNeeded()
        defer {
            surface.view.removeFromSuperview()
            stats.removeFromSuperview()
        }
        let clip = try XCTUnwrap(surface.view.superview as? ShellWidgetClipView)
        func locations() throws -> [CGFloat] {
            try XCTUnwrap((clip.layer?.mask as? CAGradientLayer)?.locations).map { CGFloat($0.doubleValue) }
        }

        XCTAssertEqual(clip.frame.width, shown)
        XCTAssertEqual(surface.layout.size.width, shown)
        XCTAssertEqual(try XCTUnwrap(surface.rootScroll).limit, natural.width - shown, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(surface.rootScroll).offset, 0)
        XCTAssertEqual(try locations(), [0, 0, 1 - fade / shown, 1])

        surface.followedTarget = "workspace 7"
        XCTAssertEqual(try XCTUnwrap(surface.rootScroll).offset, natural.width - shown, accuracy: 0.01)
        XCTAssertEqual(try locations(), [0, fade / shown, 1, 1])

        surface.followedTarget = "workspace 4"
        func assertFourthPillClearOfTheFades(line: UInt = #line) throws {
            let pill = surface.layout.parts.frames[3]
            let offset = try XCTUnwrap(surface.rootScroll).offset
            XCTAssertGreaterThanOrEqual(pill.minX - offset, fade - 0.01, line: line)
            XCTAssertLessThanOrEqual(pill.maxX - offset, shown - fade + 0.01, line: line)
        }
        try assertFourthPillClearOfTheFades()
        widget.render(data(windows: [1, 3, 1, 3, 1, 4, 4]))
        XCTAssertEqual(try XCTUnwrap(surface.rootScroll).limit, natural.width - shown, accuracy: 0.01)
        try assertFourthPillClearOfTheFades()

        surface.followedTarget = "workspace 1"
        XCTAssertEqual(try XCTUnwrap(surface.rootScroll).offset, 0)

        XCTAssertTrue(surface.scroll(
            at: CGPoint(x: shown / 2, y: natural.height / 2),
            event: ShellEvent(button: .none, modifiers: []),
            content: CGPoint(x: 30, y: 0)
        ))
        XCTAssertEqual(try XCTUnwrap(surface.rootScroll).offset, 30)
        XCTAssertEqual(try locations(), [0, fade / shown, 1 - fade / shown, 1])

        surface.followedTarget = "workspace 4"
        for _ in 0 ..< 60 {
            _ = surface.scroll(
                at: CGPoint(x: shown / 2, y: natural.height / 2),
                event: ShellEvent(button: .none, modifiers: []),
                content: CGPoint(x: 1.37, y: 0)
            )
            let parked = try XCTUnwrap(surface.rootScroll).offset
            widget.render(data(windows: [1, 3, 1, 3, 1, 4, 4]))
            XCTAssertEqual(try XCTUnwrap(surface.rootScroll).offset, parked)
        }

        let parked = try XCTUnwrap(surface.rootScroll).offset
        surface.followedTarget = "workspace 9"
        XCTAssertEqual(try XCTUnwrap(surface.rootScroll).offset, parked)
        widget.render(data(windows: [2, 3, 1, 3, 1, 4, 3], names: ["9", "2", "3", "4", "5", "6", "7"]))
        XCTAssertEqual(try XCTUnwrap(surface.rootScroll).limit, natural.width - shown, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(surface.rootScroll).offset, 0)
        withExtendedLifetime(host) {}
    }
}
