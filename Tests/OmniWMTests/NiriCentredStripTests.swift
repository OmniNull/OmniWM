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

        var pixel: CGFloat {
            1 / engine.displayScale(in: workspaceId)
        }

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
        alwaysCenterSingleColumn: Bool = true
    ) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.alwaysCenterSingleColumn = alwaysCenterSingleColumn
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
            XCTAssertEqual(margins.leading, margins.trailing, accuracy: fixture.pixel, "\(index)")
        }
    }

    func testADropInAStripThatFitsSettlesCentredInOneMove() {
        var fixture = makeFixture(widths: [0.3, 0.25])
        fixture.show(0)
        XCTAssertTrue(fixture.engine.liveColumnMoveBegin(
            windowId: fixture.window(0).id,
            windowToken: fixture.tokens[0],
            context: fixture.context,
            state: &fixture.state
        ))
        let target = fixture.strip()[1]
        let cursor = CGPoint(x: target.maxX - fixture.gap, y: fixture.frame.midY)
        _ = fixture.engine.liveColumnMoveUpdate(cursor: cursor, at: 0, context: fixture.context, state: &fixture.state)
        _ = fixture.engine.liveColumnMoveUpdate(
            cursor: cursor,
            at: fixture.engine.liveHoverDelay,
            context: fixture.context,
            state: &fixture.state
        )

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))

        let settled = fixture.state.viewOffset
        let margins = fixture.margins()
        XCTAssertGreaterThan(margins.leading, fixture.gap)
        XCTAssertEqual(margins.leading, margins.trailing, accuracy: fixture.pixel)
        fixture.show(0)
        XCTAssertEqual(fixture.state.viewOffset, settled, accuracy: fixture.pixel / 2)
    }

    func testAStripThatDoesNotFitScrollsAsUsual() {
        var fixture = makeFixture(widths: [0.5, 0.5, 0.5])
        fixture.show(0)
        XCTAssertEqual(fixture.margins().leading, fixture.gap, accuracy: fixture.pixel)
    }

    func testWithAlwaysCenterSingleColumnOffAStripThatFitsIsNotCentred() {
        var fixture = makeFixture(widths: [0.3, 0.25], alwaysCenterSingleColumn: false)
        fixture.show(0)
        XCTAssertEqual(fixture.margins().leading, fixture.gap, accuracy: fixture.pixel)
    }

    func testClosingAWindowSoTheRestFitCentresTheStrip() {
        var fixture = makeFixture(widths: [0.3, 0.3, 0.5])
        fixture.show(0)
        XCTAssertEqual(fixture.margins().leading, fixture.gap, accuracy: fixture.pixel)

        fixture.engine.removeWindow(token: fixture.tokens[2], in: fixture.workspaceId)
        XCTAssertTrue(fixture.engine.correctViewportAfterColumnRemoval(context: fixture.context, state: &fixture.state))

        let margins = fixture.margins()
        XCTAssertGreaterThan(margins.leading, fixture.gap)
        XCTAssertEqual(margins.leading, margins.trailing, accuracy: fixture.pixel)
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

    func testANewWindowKeepsItsAppsWidthOnlyInAppWidthModeAndWithoutARuleWidth() {
        let fixture = makeFixture(widths: [0.3])
        func keeps(hasRuleWidth: Bool = false, keepsExistingWidth: Bool = false) -> Bool {
            fixture.engine.keepsEnteringWindowWidth(
                opening: true,
                hasRuleWidth: hasRuleWidth,
                keepsExistingWidth: keepsExistingWidth,
                in: fixture.workspaceId
            )
        }

        XCTAssertFalse(keeps())
        XCTAssertFalse(keeps(keepsExistingWidth: true))

        fixture.engine.policies.opensNewWindowsAtAppWidth = true
        XCTAssertTrue(keeps())
        XCTAssertFalse(keeps(hasRuleWidth: true))
    }

    func testAnExistingWindowKeepsItsWidthOnlyWithItsOwnSwitch() {
        let fixture = makeFixture(widths: [0.3])
        func keeps(hasRuleWidth: Bool = false, keepsExistingWidth: Bool) -> Bool {
            fixture.engine.keepsEnteringWindowWidth(
                opening: false,
                hasRuleWidth: hasRuleWidth,
                keepsExistingWidth: keepsExistingWidth,
                in: fixture.workspaceId
            )
        }

        fixture.engine.policies.opensNewWindowsAtAppWidth = true
        XCTAssertFalse(keeps(keepsExistingWidth: false))

        fixture.engine.policies.opensNewWindowsAtAppWidth = false
        XCTAssertTrue(keeps(keepsExistingWidth: true))
        XCTAssertTrue(keeps(hasRuleWidth: true, keepsExistingWidth: true))
    }

    func testAnOpeningWindowIsTakenOnlyOnce() {
        let fixture = makeFixture(widths: [0.3])
        let token = WindowToken(pid: 977, windowId: 1)
        XCTAssertFalse(fixture.engine.takeOpeningWindow(token))

        fixture.engine.noteOpeningWindow(token)

        XCTAssertTrue(fixture.engine.takeOpeningWindow(token))
        XCTAssertFalse(fixture.engine.takeOpeningWindow(token))
    }

    func testACentredStripStartsOnAWholePixelOnANonRetinaDisplay() {
        let stripSpan: CGFloat = 901
        let viewSpan: CGFloat = 1_500
        let gap: CGFloat = 12
        let centred = (stripSpan - viewSpan) / 2
        for scale: CGFloat in [1, 2] {
            XCTAssertEqual(
                ViewportState.centredStripOffset(stripSpan: stripSpan, viewSpan: viewSpan, gap: gap, scale: scale),
                centred.roundedToPhysicalPixel(scale: scale)
            )
        }
        XCTAssertNil(ViewportState.centredStripOffset(
            stripSpan: viewSpan - gap,
            viewSpan: viewSpan,
            gap: gap,
            scale: 1
        ))
    }

    func testAKeptWidthIsCappedToTheDisplay() {
        let fixture = makeFixture(widths: [0.3])
        func kept(_ width: CGFloat) -> ProportionalSize? {
            fixture.engine.keptContainerSizingState(
                primarySpan: width,
                in: fixture.workspaceId,
                workingSpan: fixture.frame.width,
                gaps: fixture.gap,
                orientation: .horizontal
            )?.width
        }

        let requested: CGFloat = 640
        XCTAssertEqual(kept(requested), .fixed(requested))
        XCTAssertEqual(kept(fixture.frame.width * 2), .fixed(fixture.frame.width - fixture.gap * 2))
        XCTAssertNil(kept(0))
    }
}
