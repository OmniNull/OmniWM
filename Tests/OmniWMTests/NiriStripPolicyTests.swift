// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriStripPolicyTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 1_500, height: 900)
    private let gap: CGFloat = 12

    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]
        var state: ViewportState
        let context: NiriInteractionContext

        func column(_ index: Int) -> NiriContainer {
            engine.findColumn(containing: engine.findNode(for: tokens[index], in: workspaceId)!, in: workspaceId)!
        }
    }

    private func display(_ displayId: UInt32, x: CGFloat = 0, width: CGFloat = 1_500) -> Monitor {
        let frame = CGRect(x: x, y: 0, width: width, height: 900)
        return Monitor(
            id: Monitor.ID(displayId: displayId), displayId: displayId, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Strip policy \(displayId)"
        )
    }

    private func makeFixture(
        widths: [CGFloat],
        policies: NiriStripPolicies = NiriStripPolicies(),
        visibleCount: Int = 3
    ) -> Fixture {
        let engine = NiriLayoutEngine(visibleContainerCount: visibleCount)
        engine.defaultContainerPrimarySpan = nil
        engine.policies = policies
        let workspaceId = WorkspaceDescriptor.ID()
        let monitor = display(97)
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        let tokens = widths.indices.map { WindowToken(pid: 971, windowId: $0 + 1) }
        var previous: NiriWindow?
        for token in tokens {
            previous = engine.addWindow(token: token, to: workspaceId, afterSelection: previous?.id)
        }
        for (column, width) in zip(engine.columns(in: workspaceId), widths) {
            column.width = .fixed(width)
            column.cachedWidth = 0
        }
        engine.resolvePrimaryContainerSpans(in: workspaceId, workingFrame: frame, gaps: gap, orientation: .horizontal)
        var state = ViewportState(selectedNodeId: engine.findNode(for: tokens[0], in: workspaceId)!.id)
        state.activeColumnIndex = 0
        state.jumpOffset(to: -gap)
        let context = NiriInteractionContext(
            workspaceId: workspaceId,
            motion: .disabled,
            workingFrame: frame,
            gaps: gap,
            orientation: .horizontal
        )
        return Fixture(engine: engine, workspaceId: workspaceId, tokens: tokens, state: state, context: context)
    }

    func testAWindowExpelledIntoANewColumnKeepsItsWidthWithKeepSizeOnUnstack() {
        for keeps in [true, false] {
            var fixture = makeFixture(widths: [640, 400], policies: NiriStripPolicies(keepsSizeOnUnstack: keeps))
            let moved = fixture.engine.findNode(for: fixture.tokens[1], in: fixture.workspaceId)!
            let first = fixture.column(0)
            first.appendChild(moved)
            fixture.engine.columns(in: fixture.workspaceId).filter(\.windowNodes.isEmpty).forEach { $0.remove() }

            XCTAssertTrue(fixture.engine.insertWindowInNewColumn(
                moved,
                insertIndex: 1,
                context: fixture.context,
                state: &fixture.state
            ))

            let expected: ProportionalSize = keeps
                ? .fixed(640)
                : .proportion(1.0 / CGFloat(fixture.engine.visibleContainerCount))
            XCTAssertEqual(fixture.column(1).width, expected, "\(keeps)")
        }
    }

    func testANewColumnOnAutoGetsTheFirstPresetOnlyWithVisibleContainersOff() {
        let firstPreset: CGFloat = 0.4
        for fits in [true, false] {
            let fixture = makeFixture(widths: [640], policies: NiriStripPolicies(fitsVisibleContainerCount: fits))
            fixture.engine.presetContainerPrimarySpans = [.proportion(firstPreset), .proportion(0.6)]
            let token = WindowToken(pid: 971, windowId: 99)

            _ = fixture.engine.addWindow(token: token, to: fixture.workspaceId, afterSelection: nil)

            let column = fixture.engine.findColumn(
                containing: fixture.engine.findNode(for: token, in: fixture.workspaceId)!,
                in: fixture.workspaceId
            )!
            XCTAssertEqual(
                column.width,
                .proportion(fits ? 1.0 / CGFloat(fixture.engine.visibleContainerCount) : firstPreset),
                "\(fits)"
            )
        }
    }

    func testAWorkspaceMovedToAnotherDisplayKeepsItsColumnWidthsWithKeepSizesOnDisplayMove() {
        for keeps in [true, false] {
            let fixture = makeFixture(
                widths: [640, 400],
                policies: NiriStripPolicies(keepsSizesOnDisplayMove: keeps)
            )
            let other = display(98, x: 1_500, width: 2_000)

            fixture.engine.syncWorkspaceAssignments(
                [(workspaceId: fixture.workspaceId, monitor: other)],
                orientations: [other.id: .horizontal]
            )

            XCTAssertEqual(
                fixture.column(1).width,
                keeps ? .fixed(400) : .proportion(1.0 / CGFloat(fixture.engine.visibleContainerCount)),
                "\(keeps)"
            )
        }
    }

    func testFewerColumnsThanVisibleContainersAreWidenedOnlyWhileFittingIsOn() {
        for fits in [true, false] {
            let fixture = makeFixture(
                widths: [400, 400],
                policies: NiriStripPolicies(fitsVisibleContainerCount: fits)
            )
            for column in fixture.engine.columns(in: fixture.workspaceId) {
                column.width = .proportion(1.0 / 3.0)
                column.cachedWidth = 0
            }

            fixture.engine.reconcilePrimarySpanFit(
                in: fixture.workspaceId,
                workingFrame: frame,
                gaps: gap,
                orientation: .horizontal,
                motion: nil
            )

            let fitted = fixture.engine.columns(in: fixture.workspaceId).contains { $0.fittedWidth != nil }
            XCTAssertEqual(fitted, fits, "\(fits)")
        }
    }

    func testAPortraitStripFitsOnlyWhenVisibleContainersIsOnAndClearsAnOldFit() {
        let fixture = makeFixture(widths: [400, 400], policies: NiriStripPolicies(fitsVisibleContainerCount: true))
        let portrait = CGRect(x: 0, y: 0, width: frame.height, height: frame.width)
        let span = ProportionalSize.proportion(1 / CGFloat(fixture.engine.visibleContainerCount))
        let columns = fixture.engine.columns(in: fixture.workspaceId)
        for column in columns {
            column.height = span
            column.cachedHeight = 0
        }
        func reconcile() {
            fixture.engine.reconcilePrimarySpanFit(
                in: fixture.workspaceId,
                workingFrame: portrait,
                gaps: gap,
                orientation: .vertical,
                motion: .disabled
            )
        }

        reconcile()
        XCTAssertTrue(columns.allSatisfy { $0.fittedHeight != nil })

        fixture.engine.policies.fitsVisibleContainerCount = false
        reconcile()

        for column in columns {
            XCTAssertNil(column.fittedHeight)
            XCTAssertEqual(column.height, span)
        }
        reconcile()
        XCTAssertTrue(columns.allSatisfy { $0.fittedHeight == nil })
    }

    func testBalanceSizesResetsEveryColumnToOneOverVisibleContainersOnAuto() {
        let visibleCount = 4
        for fits in [false, true] {
            let fixture = makeFixture(
                widths: [500, 900, 700, 600],
                policies: NiriStripPolicies(fitsVisibleContainerCount: fits),
                visibleCount: visibleCount
            )
            XCTAssertNotEqual(
                fixture.engine.presetContainerPrimarySpans.first?.kind,
                .proportion(1.0 / CGFloat(visibleCount))
            )

            XCTAssertTrue(fixture.engine.balanceSizes(
                in: fixture.workspaceId,
                motion: .disabled,
                workingFrame: frame,
                gaps: gap,
                orientation: .horizontal
            ))

            for index in fixture.tokens.indices {
                XCTAssertEqual(
                    fixture.column(index).width,
                    .proportion(1.0 / CGFloat(visibleCount)),
                    "fits=\(fits) column=\(index)"
                )
                XCTAssertNil(fixture.column(index).presetWidthIdx)
            }
        }
    }

    func testBalanceSizesResetsEveryColumnToACustomDefaultWidth() {
        let customDefault = 0.5
        for fits in [false, true] {
            let fixture = makeFixture(
                widths: [500, 900, 700, 600],
                policies: NiriStripPolicies(fitsVisibleContainerCount: fits)
            )
            fixture.engine.defaultContainerPrimarySpan = customDefault

            XCTAssertTrue(fixture.engine.balanceSizes(
                in: fixture.workspaceId,
                motion: .disabled,
                workingFrame: frame,
                gaps: gap,
                orientation: .horizontal
            ))

            for index in fixture.tokens.indices {
                XCTAssertEqual(
                    fixture.column(index).width,
                    .proportion(CGFloat(customDefault)),
                    "fits=\(fits) column=\(index)"
                )
            }
        }
    }
}
