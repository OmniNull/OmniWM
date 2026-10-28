// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriStripEndsViewportTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let frame: CGRect
        let gap: CGFloat
        let tokens: [WindowToken]
        var state: ViewportState

        var context: NiriInteractionContext {
            .init(workspaceId: workspaceId, motion: .disabled, workingFrame: frame, gaps: gap, orientation: .horizontal)
        }

        func window(_ index: Int) -> NiriWindow {
            engine.findNode(for: tokens[index], in: workspaceId)!
        }

        func span(of index: Int) -> ClosedRange<CGFloat> {
            let column = engine.findColumn(containing: window(index), in: workspaceId)!
            return engine.columnScreenSpan(column, context: context, state: state)!
        }

        mutating func focus(_ index: Int, from previous: Int) {
            state.selectedNodeId = window(index).id
            engine.ensureSelectionVisible(
                node: window(index),
                context: context,
                state: &state,
                fromContainerIndex: previous
            )
        }
    }

    func testWithNaturalWindowDragTheFirstColumnStaysAtTheScreenEdge() {
        var fixture = makeFixture(keepsStripEndsOnScreen: true)

        fixture.focus(0, from: 1)

        XCTAssertEqual(fixture.span(of: 0).lowerBound, fixture.frame.minX + fixture.gap, accuracy: 0.5)
    }

    func testWithNaturalWindowDragTheLastColumnStaysAtTheScreenEdge() {
        var fixture = makeFixture(keepsStripEndsOnScreen: true)
        fixture.focus(2, from: 1)

        fixture.focus(3, from: 2)

        XCTAssertEqual(fixture.span(of: 3).upperBound, fixture.frame.maxX - fixture.gap, accuracy: 0.5)
    }

    func testWithNaturalWindowDragAMiddleColumnIsStillCentred() {
        var fixture = makeFixture(keepsStripEndsOnScreen: true)

        fixture.focus(2, from: 1)

        let span = fixture.span(of: 2)
        XCTAssertEqual((span.lowerBound + span.upperBound) / 2, fixture.frame.midX, accuracy: 0.5)
    }

    func testWithoutNaturalWindowDragTheFirstColumnIsCentred() {
        var fixture = makeFixture(keepsStripEndsOnScreen: false)

        fixture.focus(0, from: 1)

        let span = fixture.span(of: 0)
        XCTAssertEqual((span.lowerBound + span.upperBound) / 2, fixture.frame.midX, accuracy: 0.5)
        XCTAssertGreaterThan(span.lowerBound, fixture.frame.minX + fixture.gap + 1)
    }

    func testAStripNarrowerThanTheScreenIsLeftAsItWas() {
        var fixture = makeFixture(widths: [0.4, 0.3], keepsStripEndsOnScreen: true)
        let unclamped = makeFixture(widths: [0.4, 0.3], keepsStripEndsOnScreen: false)
        var reference = unclamped

        fixture.focus(0, from: 1)
        reference.focus(0, from: 1)

        XCTAssertEqual(fixture.state.viewOffset, reference.state.viewOffset, accuracy: 0.001)
    }

    private func makeFixture(
        widths: [CGFloat] = [0.66, 0.42, 0.66, 0.42],
        keepsStripEndsOnScreen: Bool
    ) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.centerFocusedColumn = .onOverflow
        engine.keepsStripEndsOnScreen = keepsStripEndsOnScreen
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 0, y: 0, width: 1_500, height: 900)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 94), displayId: 94, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Strip ends"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        let tokens = widths.indices.map { WindowToken(pid: 941, windowId: $0 + 1) }
        var previous: NiriWindow?
        for token in tokens {
            previous = engine.addWindow(token: token, to: workspaceId, afterSelection: previous?.id)
        }
        for (column, width) in zip(engine.columns(in: workspaceId), widths) {
            column.width = .proportion(width)
        }
        let gap: CGFloat = 12
        engine.resolvePrimaryContainerSpans(in: workspaceId, workingFrame: frame, gaps: gap, orientation: .horizontal)
        let active = engine.findNode(for: tokens[1], in: workspaceId)!
        var state = ViewportState(selectedNodeId: active.id)
        state.activeColumnIndex = 1
        state.jumpOffset(to: -gap)
        return Fixture(engine: engine, workspaceId: workspaceId, frame: frame, gap: gap, tokens: tokens, state: state)
    }
}
