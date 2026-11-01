// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriCentredStripTests: XCTestCase {
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

        func strip() -> [LiveColumnMove.StripColumn] {
            engine.liveColumnStrip(context: context, state: state)
        }

        func margins() -> (leading: CGFloat, trailing: CGFloat) {
            let strip = strip()
            return (strip.first!.minX - frame.minX, frame.maxX - strip.last!.maxX)
        }

        mutating func show(_ index: Int) {
            engine.ensureSelectionVisible(node: window(index), context: context, state: &state)
        }
    }

    private func makeFixture(
        widths: [CGFloat],
        activeIndex: Int = 0,
        naturalWindowDrag: Bool = true
    ) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.alwaysCenterSingleColumn = true
        engine.applyNaturalWindowDrag(.init(enabled: naturalWindowDrag))
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 0, y: 0, width: 1_500, height: 900)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 95), displayId: 95, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Centred strip"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        let tokens = widths.indices.map { WindowToken(pid: 951, windowId: $0 + 1) }
        for token in tokens {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        for (column, width) in zip(engine.columns(in: workspaceId), widths) {
            column.width = .proportion(width)
        }
        let gap: CGFloat = 12
        engine.resolvePrimaryContainerSpans(in: workspaceId, workingFrame: frame, gaps: gap, orientation: .horizontal)
        let active = engine.findNode(for: tokens[activeIndex], in: workspaceId)!
        var state = ViewportState(selectedNodeId: active.id)
        state.activeColumnIndex = activeIndex
        state.jumpOffset(to: -gap)
        return Fixture(engine: engine, workspaceId: workspaceId, frame: frame, gap: gap, tokens: tokens, state: state)
    }

    func testWindowsThatFitTogetherAreCentredAsAStripWhicheverIsFocused() {
        var fixture = makeFixture(widths: [0.3, 0.25])
        for index in [0, 1, 0] {
            fixture.show(index)
            let margins = fixture.margins()
            XCTAssertGreaterThan(margins.leading, fixture.gap, "\(index)")
            XCTAssertEqual(margins.leading, margins.trailing, accuracy: 1, "\(index)")
        }
    }

    func testAStripThatDoesNotFitScrollsAsUsual() {
        var fixture = makeFixture(widths: [0.5, 0.5, 0.5])
        fixture.show(0)
        XCTAssertEqual(fixture.margins().leading, fixture.gap, accuracy: 1)
    }

    func testWithoutNaturalWindowDragOnlyASingleColumnIsCentred() {
        var fixture = makeFixture(widths: [0.3, 0.25], naturalWindowDrag: false)
        fixture.show(0)
        XCTAssertEqual(fixture.margins().leading, fixture.gap, accuracy: 1)
    }

    func testClosingAWindowSoTheRestFitCentresTheStrip() {
        var fixture = makeFixture(widths: [0.3, 0.3, 0.5])
        fixture.show(0)
        XCTAssertEqual(fixture.margins().leading, fixture.gap, accuracy: 1)

        fixture.engine.removeWindow(token: fixture.tokens[2], in: fixture.workspaceId)
        XCTAssertTrue(fixture.engine.correctViewportAfterColumnRemoval(context: fixture.context, state: &fixture.state))

        let margins = fixture.margins()
        XCTAssertGreaterThan(margins.leading, fixture.gap)
        XCTAssertEqual(margins.leading, margins.trailing, accuracy: 1)
    }

    func testTheStripHoldsStillDuringALiveDrag() {
        var fixture = makeFixture(widths: [0.3, 0.25])
        XCTAssertTrue(fixture.engine.liveColumnMoveBegin(
            windowId: fixture.window(0).id,
            windowToken: fixture.tokens[0],
            context: fixture.context,
            state: &fixture.state
        ))

        XCTAssertFalse(fixture.engine.viewportEdgeRules(in: fixture.workspaceId).centersFittingStrip)
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertTrue(fixture.engine.viewportEdgeRules(in: fixture.workspaceId).centersFittingStrip)
    }
}
