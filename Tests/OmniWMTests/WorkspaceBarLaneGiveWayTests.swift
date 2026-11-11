// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

private let bar: CGFloat = 1000
private let inset: CGFloat = 4
private let spacing: CGFloat = 8
private let notch: ClosedRange<CGFloat> = 400 ... 600
private let gap = WorkspaceBarGeometry.notchGap

@MainActor
final class WorkspaceBarLaneGiveWayTests: XCTestCase {
    private typealias Item = WorkspaceBarZoneLayout.Item
    private typealias Span = WorkspaceBarZoneLayout.Span

    private func spans(
        _ items: [Item],
        _ mode: WorkspaceBarFullWidthNotchMode,
        notch: ClosedRange<CGFloat>? = nil
    ) -> [Span] {
        let spans = WorkspaceBarZoneLayout.spans(
            of: items,
            length: bar,
            zones: WorkspaceBarZones(notch: notch, mode: mode),
            spacing: spacing,
            inset: inset
        )
        assertSeparated(spans, avoiding: [.rightOfNotch, .leftOfNotch, .splitAroundNotch].contains(mode) ? notch : nil)
        return spans
    }

    private func run(_ lengths: [CGFloat], from start: CGFloat) -> [Span] {
        var cursor = start
        return lengths.map { length in
            defer { cursor += length + spacing }
            return Span(start: cursor, length: length)
        }
    }

    private func extent(_ lengths: [CGFloat]) -> CGFloat {
        lengths.reduce(0, +) + spacing * CGFloat(lengths.count - 1)
    }

    private func assertSeparated(
        _ spans: [Span],
        avoiding notch: ClosedRange<CGFloat>?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let visible = spans.filter { $0.length > 0 }.sorted { $0.start < $1.start }
        for (before, after) in zip(visible, visible.dropFirst()) {
            XCTAssertGreaterThanOrEqual(after.start, before.start + before.length + spacing, file: file, line: line)
        }
        for span in visible {
            XCTAssertGreaterThanOrEqual(span.start, inset, file: file, line: line)
            XCTAssertLessThanOrEqual(span.start + span.length, bar - inset, file: file, line: line)
            if let notch {
                XCTAssertTrue(
                    span.start + span.length <= notch.lowerBound - gap || span.start >= notch.upperBound + gap,
                    "\(span) enters the notch",
                    file: file,
                    line: line
                )
            }
        }
    }

    func testCenterWidgetsFollowTheNotchModeAndEdgesStayPinned() {
        let leading: [CGFloat] = [50, 30]
        let center: [CGFloat] = [40, 20, 10]
        let trailing: [CGFloat] = [60]
        let items = leading.map { Item(lane: .leading, length: $0) } + center.map { Item(lane: .center, length: $0) }
            + trailing.map { Item(lane: .trailing, length: $0) }
        let edges = (leading: run(leading, from: inset), trailing: run(trailing, from: bar - inset - extent(trailing)))
        let split = (center.count + 1) / 2
        let centered = run(center, from: (bar - extent(center)) / 2)

        XCTAssertEqual(
            spans(items, .rightOfNotch, notch: notch),
            edges.leading + run(center, from: notch.upperBound + gap) + edges.trailing
        )
        XCTAssertEqual(
            spans(items, .leftOfNotch, notch: notch),
            edges.leading + run(center, from: notch.lowerBound - gap - extent(center)) + edges.trailing
        )
        XCTAssertEqual(
            spans(items, .splitAroundNotch, notch: notch),
            edges.leading
                + run(Array(center.prefix(split)), from: notch.lowerBound - gap - extent(Array(center.prefix(split))))
                + run(Array(center.dropFirst(split)), from: notch.upperBound + gap) + edges.trailing
        )
        XCTAssertEqual(spans(items, .off, notch: notch), edges.leading + centered + edges.trailing)
        XCTAssertEqual(spans(items, .rightOfNotch), edges.leading + centered + edges.trailing)
    }

    func testCenterWidgetsShiftClearOfSideLanesAndGiveWayWhenTheyDoNotFit() {
        func layout(_ leading: CGFloat, _ center: CGFloat, _ trailing: CGFloat) -> [Span] {
            spans([
                Item(lane: .leading, length: leading, priority: 0),
                Item(lane: .center, length: center, priority: 2),
                Item(lane: .trailing, length: trailing, priority: 1)
            ], .off)
        }
        func sides(_ leading: CGFloat, _ trailing: CGFloat) -> (leading: Span, trailing: Span) {
            (Span(start: inset, length: leading), Span(start: bar - inset - trailing, length: trailing))
        }

        var edge = sides(100, 100)
        XCTAssertEqual(layout(100, 200, 100), [edge.leading, Span(start: (bar - 200) / 2, length: 200), edge.trailing])

        edge = sides(400, 100)
        XCTAssertEqual(
            layout(400, 300, 100),
            [edge.leading, Span(start: inset + 400 + spacing, length: 300), edge.trailing]
        )

        edge = sides(100, 450)
        XCTAssertEqual(
            layout(100, 300, 450),
            [edge.leading, Span(start: bar - inset - 450 - spacing - 300, length: 300), edge.trailing]
        )

        edge = sides(500, 400)
        let overflow = 500 + 300 + 400 + spacing * 2 - (bar - inset * 2)
        XCTAssertEqual(
            layout(500, 300, 400),
            [edge.leading, Span(start: inset + 500 + spacing, length: 300 - overflow), edge.trailing]
        )
    }

    func testTheLowestPriorityGivesWayFirstWhateverItsLane() {
        let leading: CGFloat = 500
        let center: CGFloat = 300
        let trailing: CGFloat = 400
        let cut = trailing - (leading + center + trailing + spacing * 2 - (bar - inset * 2))
        XCTAssertEqual(
            spans([
                Item(lane: .leading, length: leading, priority: 0),
                Item(lane: .center, length: center, priority: 1),
                Item(lane: .trailing, length: trailing, priority: 2)
            ], .off),
            [
                Span(start: inset, length: leading),
                Span(start: inset + leading + spacing, length: center),
                Span(start: bar - inset - cut, length: cut)
            ]
        )
    }

    func testAWidgetTooLargeToCutIsHiddenAndOnlyTheNextOneIsCut() {
        let items = [
            Item(lane: .leading, length: 300, priority: 0),
            Item(lane: .leading, length: 60, priority: 3),
            Item(lane: .center, length: 300, priority: 1),
            Item(lane: .trailing, length: 400, priority: 2)
        ]
        let room = bar - inset * 2
        let firstOverflow = items.reduce(0) { $0 + $1.length } + spacing * 3 - room
        XCTAssertGreaterThanOrEqual(firstOverflow, items[1].length)
        let secondOverflow = items.reduce(0) { $0 + $1.length } - items[1].length + spacing * 2 - room
        let trailing = items[3].length - secondOverflow
        let result = spans(items, .off)

        XCTAssertEqual(result[1].length, 0)
        XCTAssertEqual(result[0], Span(start: inset, length: items[0].length))
        XCTAssertEqual(result[2], Span(start: inset + items[0].length + spacing, length: items[2].length))
        XCTAssertEqual(result[3], Span(start: bar - inset - trailing, length: trailing))
        XCTAssertEqual(zip(result, items).filter { $0.length > 0 && $0.length < $1.length }.count, 1)
    }

    func testRightOfNotchCutsTheTitleWhereALongTrailingLaneBegins() {
        let title: CGFloat = 200
        let trailing: [CGFloat] = [120, 150]
        let room = bar - inset - notch.upperBound - gap
        let cut = title - (title + spacing + extent(trailing) - room)
        let result = spans(
            [Item(lane: .leading, length: 100, priority: 0), Item(lane: .center, length: title, priority: 3)]
                + trailing.enumerated().map { Item(lane: .trailing, length: $1, priority: $0 + 1) },
            .rightOfNotch,
            notch: notch
        )

        XCTAssertEqual(result[1], Span(start: notch.upperBound + gap, length: cut))
        XCTAssertEqual(Array(result.suffix(trailing.count)), run(trailing, from: bar - inset - extent(trailing)))
    }

    func testLeftOfNotchKeepsTheTitleBesideALongLeadingLane() {
        let leading: [CGFloat] = [120, 180]
        let title: CGFloat = 260
        let room = notch.lowerBound - gap - inset
        let items = [
            Item(lane: .leading, length: leading[0], priority: 1),
            Item(lane: .leading, length: leading[1], priority: 0),
            Item(lane: .center, length: title, priority: 4),
            Item(lane: .trailing, length: 100, priority: 2)
        ]
        let cut = title - (extent(leading) + spacing + title - room)
        var result = spans(items, .leftOfNotch, notch: notch)
        XCTAssertEqual(Array(result.prefix(2)), run(leading, from: inset))
        XCTAssertEqual(result[2], Span(start: inset + extent(leading) + spacing, length: cut))
        XCTAssertEqual(result[2].start + result[2].length, notch.lowerBound - gap)

        var ranked = items
        ranked[1].priority = 5
        ranked[2].priority = 0
        result = spans(ranked, .leftOfNotch, notch: notch)
        XCTAssertLessThanOrEqual(leading[1], extent(leading) + spacing + title - room)
        XCTAssertEqual(result[1].length, 0)
        XCTAssertEqual(result[0], Span(start: inset, length: leading[0]))
        XCTAssertEqual(result[2], Span(start: notch.lowerBound - gap - title, length: title))
    }

    func testSideLanesStopBeforeTheNotch() {
        let leading: [CGFloat] = [300, 200]
        let room = notch.lowerBound - gap - inset
        let cut = leading[0] - (extent(leading) - room)
        let result = spans([
            Item(lane: .leading, length: leading[0], priority: 1),
            Item(lane: .leading, length: leading[1], priority: 0)
        ], .rightOfNotch, notch: notch)

        XCTAssertEqual(result, run([cut, leading[1]], from: inset))
        XCTAssertEqual(result[1].start + result[1].length, notch.lowerBound - gap)
    }

    func testSplitAroundNotchKeepsEachCenterWidgetOnItsSide() {
        let center: [CGFloat] = [100, 100, 20]
        let trailing: CGFloat = 385
        let near = Array(center.prefix((center.count + 1) / 2))
        let result = spans(
            center.enumerated().map { Item(lane: .center, length: $1, priority: $0 + 1) }
                + [Item(lane: .trailing, length: trailing, priority: 0)],
            .splitAroundNotch,
            notch: notch
        )

        XCTAssertGreaterThan(center[2] + spacing + trailing, bar - inset - notch.upperBound - gap)
        XCTAssertEqual(Array(result.prefix(near.count)), run(near, from: notch.lowerBound - gap - extent(near)))
        XCTAssertEqual(result[2].length, 0)
        XCTAssertEqual(result[3], Span(start: bar - inset - trailing, length: trailing))
    }

    func testEveryModeKeepsVisibleWidgetsApartWhenTheBarOverflows() {
        let lengths: [CGFloat] = [180, 90, 260, 140, 70, 210, 120, 160]
        let lanes: [ShellLane] = [.leading, .leading, .center, .center, .trailing, .trailing, .leading, .trailing]
        let items = zip(lanes, lengths).enumerated().map { Item(lane: $1.0, length: $1.1, priority: ($0 * 5) % 8) }
        for mode in WorkspaceBarFullWidthNotchMode.allCases {
            for notch: ClosedRange<CGFloat>? in [notch, nil] {
                _ = spans(items, mode, notch: notch)
            }
        }
    }
}

@MainActor
final class WorkspaceBarLaneClipTests: XCTestCase {
    func testDropRegionsStopAtTheVisibleSpanAlongTheBar() {
        let row = CGRect(x: 100, y: 0, width: 60, height: 32)
        let shown = CGRect(x: 120, y: 4, width: 20, height: 24)
        XCTAssertEqual(
            WorkspaceBarManager.clamp(row, to: shown, orientation: .horizontal),
            CGRect(x: shown.minX, y: row.minY, width: shown.width, height: row.height)
        )
        XCTAssertEqual(WorkspaceBarManager.clamp(row, to: nil, orientation: .horizontal), row)
        let column = CGRect(x: 0, y: 100, width: 32, height: 60)
        let top = CGRect(x: 4, y: 90, width: 24, height: 30)
        XCTAssertEqual(
            WorkspaceBarManager.clamp(column, to: top, orientation: .vertical),
            CGRect(x: column.minX, y: column.minY, width: column.width, height: top.maxY - column.minY)
        )
        let elsewhere = CGRect(x: row.maxX + shown.width, y: 0, width: shown.width, height: row.height)
        XCTAssertEqual(WorkspaceBarManager.clamp(row, to: elsewhere, orientation: .horizontal).width, 0)
    }

    func testTheBarViewPlacesWidgetsInTheirZones() {
        let names = ["left", "middle", "right"]
        let size = CGSize(width: 40, height: 20)
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            backgroundOpacity: 0.1,
            barHeight: 24,
            shellWidgets: zip(names, [ShellLane.leading, .center, .trailing]).map {
                WorkspaceBarShellWidget(id: $0, size: size, lane: $1)
            }
        )
        let views = Dictionary(uniqueKeysWithValues: names.map { ($0, NSView()) })
        func minX(zones: WorkspaceBarZones?) -> [CGFloat] {
            let model = WorkspaceBarModel(snapshot: snapshot)
            model.zones = zones
            let host = NSHostingView(rootView: WorkspaceBarView(
                model: model,
                motionPolicy: MotionPolicy(animationsEnabled: false),
                shellSurface: { views[$0] }
            ))
            host.frame = CGRect(x: 0, y: 0, width: bar, height: 24)
            host.layoutSubtreeIfNeeded()
            defer { names.forEach { views[$0]?.removeFromSuperview() } }
            return names.map { views[$0]!.convert(views[$0]!.bounds, to: host).minX.rounded() }
        }
        let trailing = bar - inset - size.width
        XCTAssertEqual(
            minX(zones: WorkspaceBarZones(notch: notch, mode: .rightOfNotch)),
            [inset, notch.upperBound + gap, trailing]
        )
        XCTAssertEqual(
            minX(zones: WorkspaceBarZones(notch: nil, mode: .rightOfNotch)),
            [inset, (bar - size.width) / 2, trailing]
        )
        let stack = size.width * 3 + spacing * 2
        let first = (bar - stack) / 2
        XCTAssertEqual(minX(zones: nil), [first, first + size.width + spacing, first + (size.width + spacing) * 2])
    }

    private func hostBar(
        _ lengths: [CGFloat],
        priorities: [Int],
        vertical: Bool = false
    ) -> (host: NSHostingView<WorkspaceBarView>, views: [NSView]) {
        let lanes: [ShellLane] = [.leading, .center, .trailing]
        let views = lanes.map { _ in NSView() }
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            backgroundOpacity: 0.1,
            barHeight: 24,
            orientation: vertical ? .vertical : .horizontal,
            shellWidgets: lanes.indices.map { index in
                WorkspaceBarShellWidget(
                    id: lanes[index].rawValue,
                    size: vertical
                        ? CGSize(width: 20, height: lengths[index])
                        : CGSize(width: lengths[index], height: 20),
                    lane: lanes[index],
                    priority: priorities[index]
                )
            }
        )
        let model = WorkspaceBarModel(snapshot: snapshot)
        model.zones = WorkspaceBarZones(notch: nil, mode: .off)
        let host = NSHostingView(rootView: WorkspaceBarView(
            model: model,
            motionPolicy: MotionPolicy(animationsEnabled: false),
            shellSurface: { name in lanes.firstIndex { $0.rawValue == name }.map { views[$0] } }
        ))
        host.frame = vertical
            ? CGRect(x: 0, y: 0, width: 28, height: bar)
            : CGRect(x: 0, y: 0, width: bar, height: 24)
        host.layoutSubtreeIfNeeded()
        return (host, views)
    }

    private func clip(_ view: NSView) throws -> ShellWidgetClipView {
        try XCTUnwrap(view.superview as? ShellWidgetClipView)
    }

    func testTheBarViewClipsTheWidgetThatGivesWayAndKeepsItsClicksInside() throws {
        let lengths: [CGFloat] = [500, 300, 400]
        let (host, views) = hostBar(lengths, priorities: [0, 2, 1])
        let cut = lengths[1] - (lengths.reduce(0, +) + spacing * 2 - (bar - inset * 2))
        let middle = try clip(views[1])
        XCTAssertEqual(middle.frame.width, cut)
        XCTAssertTrue(middle.clipsToBounds)
        XCTAssertEqual(views[1].frame, CGRect(x: 0, y: 0, width: lengths[1], height: 20))
        XCTAssertFalse(try clip(views[0]).clipsToBounds)
        XCTAssertFalse(try clip(views[2]).clipsToBounds)
        let container = try XCTUnwrap(middle.superview)
        let visible = container.convert(CGPoint(x: cut / 2, y: middle.bounds.midY), from: middle)
        let hiddenPart = container.convert(CGPoint(x: cut + spacing / 2, y: middle.bounds.midY), from: middle)
        XCTAssertTrue(middle.hitTest(visible) === views[1])
        XCTAssertNil(middle.hitTest(hiddenPart))
        withExtendedLifetime(host) {}
    }

    func testTheBarViewHidesAWidgetWithNoRoomLeft() throws {
        let lengths: [CGFloat] = [500, 60, 480]
        XCTAssertGreaterThanOrEqual(lengths.reduce(0, +) + spacing * 2 - (bar - inset * 2), lengths[1])
        let (host, views) = hostBar(lengths, priorities: [0, 2, 1])
        XCTAssertEqual(try clip(views[1]).frame.width, 0)
        XCTAssertTrue(try clip(views[1]).clipsToBounds)
        withExtendedLifetime(host) {}
    }

    func testAVerticalBarCutsAlongItsHeightAndKeepsTheTrailingWidgetsEnd() throws {
        let lengths: [CGFloat] = [500, 400, 300]
        let (host, views) = hostBar(lengths, priorities: [0, 1, 2], vertical: true)
        let trailing = try clip(views[2])
        let kept = lengths[2] - (lengths.reduce(0, +) + spacing * 2 - (bar - inset * 2))
        XCTAssertEqual(trailing.frame.height, kept)
        XCTAssertEqual(views[2].frame.origin.y, kept - lengths[2])
        let placed = trailing.convert(trailing.bounds, to: host)
        XCTAssertEqual(host.isFlipped ? placed.maxY : host.bounds.height - placed.minY, bar - inset)
    }
}
