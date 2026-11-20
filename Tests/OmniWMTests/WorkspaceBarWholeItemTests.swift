// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import SwiftUI
import XCTest

@MainActor
final class WorkspaceBarWholeItemTests: XCTestCase {
    private typealias Item = WorkspaceBarZoneLayout.Item
    private typealias Span = WorkspaceBarZoneLayout.Span

    private let inset: CGFloat = 4
    private let spacing: CGFloat = 8

    private func spans(_ items: [Item], length: CGFloat) -> [Span] {
        WorkspaceBarZoneLayout.spans(
            of: items,
            length: length,
            zones: WorkspaceBarZones(notch: nil, mode: .off),
            spacing: spacing,
            inset: inset
        )
    }

    private func strip(_ sizes: [CGFloat], gap: Int = 6) throws -> ShellRenderedWidget {
        let boxes = sizes.map { "ui.box{w=\(Int($0)),h=20}" }.joined(separator: ",")
        let widget = try ShellRenderedWidget(name: "strip", source: """
        function render(ctx)
            return ui.row{gap=\(gap), \(boxes)}
        end
        """)
        widget.render(ShellBarData())
        return widget
    }

    func testAStripGivesWayBetweenItsItemsOnTheSideItKeeps() {
        let stops: [CGFloat] = [40, 100, 180, 240]
        let length: CGFloat = 300
        let bar: CGFloat = 500
        let room = bar - inset * 2
        let fixed: CGFloat = 220
        let cut = length - (fixed + WorkspaceBarZoneLayout.tightSpacing + length - room)
        XCTAssertEqual(cut, 268)

        let leading = spans([
            Item(lane: .leading, length: fixed, priority: 0),
            Item(lane: .leading, length: length, priority: 1, stops: stops)
        ], length: bar)
        XCTAssertEqual(leading[1], Span(start: inset + fixed + spacing, length: 240))

        let trailing = spans([
            Item(lane: .leading, length: fixed, priority: 0),
            Item(lane: .trailing, length: length, priority: 1, stops: stops)
        ], length: bar)
        XCTAssertEqual(trailing[1], Span(start: bar - inset - 240, length: 240))

        let whole = spans([
            Item(lane: .leading, length: fixed, priority: 0),
            Item(lane: .leading, length: length, priority: 1, stops: stops)
        ], length: fixed + spacing + length + inset * 2)
        XCTAssertEqual(whole[1].length, length)
    }

    func testAWidgetInOnePieceIsHiddenRatherThanCut() {
        let items = [
            Item(lane: .leading, length: 300, priority: 0),
            Item(lane: .leading, length: 200, priority: 1, stops: [60, 130]),
            Item(lane: .trailing, length: 30, priority: 2, stops: [])
        ]
        let room = items.reduce(0) { $0 + $1.length } + spacing * 2 - 10
        let result = spans(items, length: room + inset * 2)

        XCTAssertEqual(result[2].length, 0)
        XCTAssertEqual(result[0], Span(start: inset, length: 300))
        XCTAssertEqual(result[1], Span(start: inset + 300 + spacing, length: 200))
    }

    func testPartsAreTheChildrenOfAPlainStrip() throws {
        let widget = try strip([30, 50, 20])
        let size = widget.surface.naturalSize
        let parts = widget.surface.layout.parts

        XCTAssertEqual(size.width, 112)
        XCTAssertEqual(parts.frames.map(\.minX), [0, 36, 92])
        XCTAssertEqual(parts.stops(in: size, vertical: false, keepsEnd: false), [30, 86])
        XCTAssertEqual(parts.stops(in: size, vertical: false, keepsEnd: true), [20, 76])
        XCTAssertNil(parts.stops(in: size, vertical: true, keepsEnd: false))
    }

    func testAButtonOrAPaintedGroupIsOnePieceAndAMarqueeTakesAnyCut() throws {
        func parts(_ root: String) throws -> ShellWidgetParts {
            let widget = try ShellRenderedWidget(name: "piece", source: """
            function render(ctx)
                return ui.row{\(root) ui.box{w=30,h=20}, ui.box{w=50,h=20}}
            end
            """)
            widget.render(ShellBarData())
            return widget.surface.layout.parts
        }
        let size = CGSize(width: 80, height: 20)

        XCTAssertEqual(try parts("").frames.count, 2)
        for root in [
            "onClick='focus left',",
            "onClick=ui.popout,",
            "fill='#FFFFFF20',",
            "border='#FFFFFF',borderWidth=1,"
        ] {
            XCTAssertEqual(try parts(root).stops(in: size, vertical: false, keepsEnd: false), [], root)
        }

        let ticker = try ShellRenderedWidget(name: "ticker", source: """
        function render(ctx)
            return ui.row{ui.box{w=18,h=18},
                ui.row{scroll=true,marquee=true,maxWidth=40,ui.text{text='A long window title to scroll',size=13}}}
        end
        """)
        ticker.render(ShellBarData())
        let marquee = ticker.surface.layout.parts
        XCTAssertNil(marquee.stops(in: ticker.surface.naturalSize, vertical: false, keepsEnd: false))
        XCTAssertNotNil(marquee.stops(in: ticker.surface.naturalSize, vertical: false, keepsEnd: true))
    }

    func testAnInstanceReportsItemsThatMoveWhileItsSizeStays() throws {
        let widget = try ShellRenderedWidget(name: "strip", source: """
        function render(ctx)
            local wide = ctx.data.wide
            return ui.row{gap=6, ui.box{w=wide and 50 or 30,h=20}, ui.box{w=wide and 30 or 50,h=20}}
        end
        """)
        let instance = ShellWidgetHost.InstanceState()
        widget.render(ShellBarData())
        XCTAssertTrue(instance.apply(.init(nodes: widget.output(), sequence: 1), text: widget.text))
        XCTAssertFalse(instance.apply(.init(nodes: widget.output(), sequence: 2), text: widget.text))

        widget.set("wide") { $0.bool(true) }
        widget.render(ShellBarData())
        XCTAssertTrue(instance.apply(.init(nodes: widget.output(), sequence: 3), text: widget.text))
        XCTAssertEqual(instance.size.width, 86)
        XCTAssertEqual(instance.parts.frames.map(\.maxX), [50, 86])
    }
}
