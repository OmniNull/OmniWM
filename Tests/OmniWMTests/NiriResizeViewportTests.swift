// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriResizeViewportTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let workingFrame: CGRect
        let gap: CGFloat
        let columnSpan: CGFloat
        var state: ViewportState

        var columns: [NiriContainer] {
            engine.columns(in: workspaceId)
        }

        var trailingColumn: NiriContainer {
            columns[columns.count - 1]
        }

        var fullSpan: CGFloat {
            workingFrame.width - gap * 2
        }

        var rightAlignedOffset: CGFloat {
            -(workingFrame.width - gap - columnSpan)
        }

        func viewStart(sizeKeyPath: KeyPath<NiriContainer, CGFloat>) -> CGFloat {
            state.containerPosition(
                at: state.activeColumnIndex,
                containers: columns,
                gap: gap,
                sizeKeyPath: sizeKeyPath
            ) + state.viewOffset
        }
    }

    private func makeFixture(
        columnCount: Int,
        gap: CGFloat = 16,
        viewportWidth: CGFloat = 2_560,
        viewportHeight: CGFloat = 1_440
    ) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.updateConfiguration(centerFocusedColumn: .never)

        let workspaceId = WorkspaceDescriptor.ID()
        let workingFrame = CGRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 7),
            displayId: 7,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Resize viewport"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )

        for index in 0 ..< columnCount {
            _ = engine.addWindow(
                token: WindowToken(pid: 1, windowId: index + 1),
                to: workspaceId,
                afterSelection: nil
            )
        }

        let columnSpan = (viewportWidth - gap) * 0.5 - gap
        let columns = engine.columns(in: workspaceId)
        for column in columns {
            column.width = .proportion(0.5)
            column.cachedWidth = columnSpan
        }

        var state = ViewportState()
        let lastIndex = columns.count - 1
        state.activeColumnIndex = lastIndex
        state.selectedNodeId = columns[lastIndex].windowNodes.first?.id
        state.jumpOffset(to: -(viewportWidth - gap - columnSpan))

        return Fixture(
            engine: engine,
            workspaceId: workspaceId,
            workingFrame: workingFrame,
            gap: gap,
            columnSpan: columnSpan,
            state: state
        )
    }

    private func applyRelayoutViewportPasses(_ fixture: inout Fixture) -> Bool {
        let selectedId = fixture.state.selectedNodeId
        if let selectedId, let node = fixture.engine.findNode(by: selectedId, in: fixture.workspaceId) {
            fixture.engine.ensureSelectionVisible(
                node: node,
                context: .init(
                    workspaceId: fixture.workspaceId,
                    motion: .enabled,
                    workingFrame: fixture.workingFrame,
                    gaps: fixture.gap,
                    orientation: .horizontal
                ),
                state: &fixture.state
            )
        }
        return fixture.engine.correctViewportAfterColumnRemoval(
            context: .init(
                workspaceId: fixture.workspaceId,
                motion: .enabled,
                workingFrame: fixture.workingFrame,
                gaps: fixture.gap,
                orientation: .horizontal
            ),
            state: &fixture.state,
            preservesCenteredView: true
        )
    }

    func testFullPrimarySpanOnTrailingColumnSurvivesRelayoutViewportPasses() throws {
        var fixture = makeFixture(columnCount: 3)
        let trailing = fixture.trailingColumn

        fixture.engine.toggleContainerFullPrimarySpan(
            trailing,
            context: .init(
                workspaceId: fixture.workspaceId,
                motion: .enabled,
                workingFrame: fixture.workingFrame,
                gaps: fixture.gap,
                orientation: .horizontal
            ),
            state: &fixture.state
        )

        XCTAssertEqual(trailing.settledWidth, fixture.fullSpan)
        XCTAssertEqual(trailing.cachedWidth, fixture.columnSpan)
        XCTAssertEqual(fixture.state.viewOffset, -fixture.gap)

        XCTAssertFalse(applyRelayoutViewportPasses(&fixture))
        XCTAssertEqual(fixture.state.viewOffset, -fixture.gap)
    }

    func testIncreasingTrailingColumnPrimarySpanSurvivesRelayoutViewportPasses() throws {
        var fixture = makeFixture(columnCount: 3)
        let trailing = fixture.trailingColumn

        fixture.engine.setContainerPrimarySpan(
            trailing,
            change: .adjustProportion(10),
            context: .init(
                workspaceId: fixture.workspaceId,
                motion: .enabled,
                workingFrame: fixture.workingFrame,
                gaps: fixture.gap,
                orientation: .horizontal
            ),
            state: &fixture.state
        )

        let grownSpan = (fixture.workingFrame.width - fixture.gap) * 0.6 - fixture.gap
        let expectedOffset = -(fixture.workingFrame.width - fixture.gap - grownSpan)
        XCTAssertEqual(trailing.settledWidth, grownSpan)
        XCTAssertEqual(fixture.state.viewOffset, expectedOffset)

        XCTAssertFalse(applyRelayoutViewportPasses(&fixture))
        XCTAssertEqual(fixture.state.viewOffset, expectedOffset)
    }

    func testCyclingTrailingColumnPrimarySpanSurvivesRelayoutViewportPasses() throws {
        var fixture = makeFixture(columnCount: 3)
        let trailing = fixture.trailingColumn

        fixture.engine.toggleContainerPrimarySpan(
            trailing,
            forwards: true,
            context: .init(
                workspaceId: fixture.workspaceId,
                motion: .enabled,
                workingFrame: fixture.workingFrame,
                gaps: fixture.gap,
                orientation: .horizontal
            ),
            state: &fixture.state
        )

        let grownSpan = trailing.settledWidth
        XCTAssertGreaterThan(grownSpan, fixture.columnSpan)
        let offsetAfterResize = fixture.state.viewOffset
        XCTAssertEqual(
            fixture.viewStart(sizeKeyPath: \.settledWidth) + fixture.workingFrame.width - fixture.gap,
            fixture.state.containerPosition(
                at: fixture.state.activeColumnIndex,
                containers: fixture.columns,
                gap: fixture.gap,
                sizeKeyPath: \.settledWidth
            ) + grownSpan
        )

        XCTAssertFalse(applyRelayoutViewportPasses(&fixture))
        XCTAssertEqual(fixture.state.viewOffset, offsetAfterResize)
    }

    func testUntogglingFullPrimarySpanKeepsTrailingColumnRightAligned() throws {
        var fixture = makeFixture(columnCount: 3)
        let trailing = fixture.trailingColumn

        fixture.engine.toggleContainerFullPrimarySpan(
            trailing,
            context: .init(
                workspaceId: fixture.workspaceId,
                motion: .disabled,
                workingFrame: fixture.workingFrame,
                gaps: fixture.gap,
                orientation: .horizontal
            ),
            state: &fixture.state
        )
        XCTAssertEqual(trailing.cachedWidth, fixture.fullSpan)

        fixture.engine.toggleContainerFullPrimarySpan(
            trailing,
            context: .init(
                workspaceId: fixture.workspaceId,
                motion: .enabled,
                workingFrame: fixture.workingFrame,
                gaps: fixture.gap,
                orientation: .horizontal
            ),
            state: &fixture.state
        )

        XCTAssertEqual(trailing.settledWidth, fixture.columnSpan)
        XCTAssertEqual(trailing.cachedWidth, fixture.fullSpan)
        XCTAssertEqual(fixture.state.viewOffset, fixture.rightAlignedOffset)

        XCTAssertFalse(applyRelayoutViewportPasses(&fixture))
        XCTAssertEqual(fixture.state.viewOffset, fixture.rightAlignedOffset)
    }

    func testViewportClampStillCorrectsOffsetScrolledPastContent() throws {
        var fixture = makeFixture(columnCount: 3)
        fixture.state.jumpOffset(to: -fixture.gap)

        XCTAssertTrue(
            fixture.engine.correctViewportAfterColumnRemoval(
                context: .init(
                    workspaceId: fixture.workspaceId,
                    motion: .disabled,
                    workingFrame: fixture.workingFrame,
                    gaps: fixture.gap,
                    orientation: .horizontal
                ),
                state: &fixture.state
            )
        )
        XCTAssertEqual(fixture.state.viewOffset, fixture.rightAlignedOffset)
    }

    func testCenteredFirstAndLastColumnsSurviveRelayoutViewportPasses() throws {
        var fixture = makeFixture(columnCount: 3)
        let context = NiriInteractionContext(
            workspaceId: fixture.workspaceId,
            motion: .disabled,
            workingFrame: fixture.workingFrame,
            gaps: fixture.gap,
            orientation: .horizontal
        )
        let centeredOffset = -(fixture.workingFrame.width - fixture.columnSpan) / 2

        for index in [0, fixture.columns.count - 1] {
            fixture.state.activeColumnIndex = index
            fixture.state.selectedNodeId = fixture.columns[index].windowNodes.first?.id
            XCTAssertTrue(fixture.engine.centerColumn(context: context, state: &fixture.state))
            XCTAssertEqual(fixture.state.viewOffset, centeredOffset)

            XCTAssertFalse(applyRelayoutViewportPasses(&fixture))
            XCTAssertEqual(fixture.state.viewOffset, centeredOffset)
        }
    }

    func testRemovalFitsAutoCenteredColumnOnceItsOverflowingPairIsGone() throws {
        var fixture = makeFixture(columnCount: 2, gap: 0, viewportWidth: 1_000)
        fixture.engine.updateConfiguration(centerFocusedColumn: .onOverflow)
        for (column, span) in zip(fixture.columns, [CGFloat(400), 600]) {
            column.width = .fixed(span)
            column.cachedWidth = span
        }
        fixture.state.activeColumnIndex = 1
        fixture.state.jumpOffset(to: -200)

        XCTAssertTrue(
            fixture.engine.correctViewportAfterColumnRemoval(
                context: .init(
                    workspaceId: fixture.workspaceId,
                    motion: .disabled,
                    workingFrame: fixture.workingFrame,
                    gaps: fixture.gap,
                    orientation: .horizontal
                ),
                state: &fixture.state
            )
        )
        XCTAssertEqual(fixture.viewStart(sizeKeyPath: \.settledWidth), 0)
    }
}
