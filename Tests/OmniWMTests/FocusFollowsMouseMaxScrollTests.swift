// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class FocusFollowsMouseMaxScrollTests: XCTestCase {
    func testHoverIgnoresPartiallyVisibleWindowAtZeroMaxScroll() throws {
        let fixture = try Fixture(maxScrollPercent: 0)

        fixture.hover(fixture.partialPointer, windowId: fixture.partial.windowId)

        XCTAssertTrue(fixture.focusedTokens.isEmpty)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.lastFocusFollowsMouseTime, .distantPast)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testHoverIgnoresPartiallyVisibleWindowFoundByGeometryAtZeroMaxScroll() throws {
        let fixture = try Fixture(maxScrollPercent: 0)

        fixture.hover(fixture.partialPointer, windowId: nil)

        XCTAssertTrue(fixture.focusedTokens.isEmpty)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.lastFocusFollowsMouseTime, .distantPast)
    }

    func testHoverFocusesFullyVisibleWindowAtZeroMaxScroll() throws {
        let fixture = try Fixture(maxScrollPercent: 0)

        fixture.hover(fixture.visiblePointer, windowId: fixture.visible.windowId)

        XCTAssertEqual(fixture.focusedTokens, [fixture.visible])
        XCTAssertGreaterThan(fixture.controller.mouseEventHandler.state.lastFocusFollowsMouseTime, .distantPast)
    }

    func testHoverFocusesFullyVisibleWindowFoundByGeometryAtZeroMaxScroll() throws {
        let fixture = try Fixture(maxScrollPercent: 0)

        fixture.hover(fixture.visiblePointer, windowId: nil)

        XCTAssertEqual(fixture.focusedTokens, [fixture.visible])
    }

    func testHoverFocusesPartiallyVisibleWindowAtDefaultMaxScroll() throws {
        let fixture = try Fixture(maxScrollPercent: 100)

        fixture.hover(fixture.partialPointer, windowId: fixture.partial.windowId)

        XCTAssertEqual(fixture.focusedTokens, [fixture.partial])
    }

    func testHoverFocusesPartiallyVisibleWindowFoundByGeometryAtDefaultMaxScroll() throws {
        let fixture = try Fixture(maxScrollPercent: 100)

        fixture.hover(fixture.partialPointer, windowId: nil)

        XCTAssertEqual(fixture.focusedTokens, [fixture.partial])
    }

    func testHoverFocusesWindowFillingWorkingFrameAtZeroMaxScroll() throws {
        let fixture = try Fixture(maxScrollPercent: 0)
        fixture.setColumnSpan(of: fixture.visible, to: fixture.extent - 2 * fixture.gap)

        fixture.hover(fixture.visiblePointer, windowId: fixture.visible.windowId)

        XCTAssertEqual(fixture.focusedTokens, [fixture.visible])
    }

    func testHoverIgnoresWindowOverflowingWorkingFrameBeyondToleranceAtZeroMaxScroll() throws {
        let fixture = try Fixture(maxScrollPercent: 0)
        fixture.setColumnSpan(of: fixture.visible, to: fixture.extent + 4)

        fixture.hover(fixture.visiblePointer, windowId: fixture.visible.windowId)

        XCTAssertTrue(fixture.focusedTokens.isEmpty)
    }

    func testLatestFocusFollowsMouseTokenIsNilForPartiallyVisibleWindowAtZeroMaxScroll() throws {
        let fixture = try Fixture(maxScrollPercent: 0)

        fixture.hover(fixture.partialPointer, windowId: fixture.partial.windowId)
        XCTAssertNil(fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken())

        fixture.hover(fixture.visiblePointer, windowId: fixture.visible.windowId)
        XCTAssertEqual(fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken(), fixture.visible)
    }

    func testLatestFocusFollowsMouseTokenResolvesPartiallyVisibleWindowAtDefaultMaxScroll() throws {
        let fixture = try Fixture(maxScrollPercent: 100)

        fixture.hover(fixture.partialPointer, windowId: fixture.partial.windowId)

        XCTAssertEqual(fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken(), fixture.partial)
    }

    private static let leadingColumnShare: CGFloat = 0.5
    private static let trailingColumnShare: CGFloat = 0.8
    private static let spansNeedingAboutThirtyPercentScroll: Fixture.SpanPlan = { extent, _ in
        [extent * leadingColumnShare, extent * trailingColumnShare]
    }

    private func assertScrollingWindowFocus(
        percent: Int,
        orientation: Monitor.Orientation,
        isFocused expected: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = try Fixture(
            maxScrollPercent: percent,
            orientation: orientation,
            spans: Self.spansNeedingAboutThirtyPercentScroll
        )
        let scrollingWindow = fixture.partial

        fixture.hover(fixture.partialPointer, windowId: scrollingWindow.windowId)

        XCTAssertEqual(
            fixture.focusedTokens,
            expected ? [scrollingWindow] : [],
            file: file,
            line: line
        )
    }

    func testScrollingWindowFixtureOverflowsWorkingFrameByAboutThirtyPercent() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let fixture = try Fixture(
                maxScrollPercent: 100,
                orientation: orientation,
                spans: Self.spansNeedingAboutThirtyPercentScroll
            )
            let frame = try XCTUnwrap(fixture.frame(of: fixture.partial))
            let overflow = orientation == .horizontal
                ? frame.maxX - fixture.workingFrame.maxX
                : frame.maxY - fixture.workingFrame.maxY
            let overflowShare = overflow / fixture.extent
            let expectedShare = Self.leadingColumnShare + Self.trailingColumnShare - 1

            XCTAssertEqual(overflowShare, expectedShare, accuracy: 0.05)
        }
    }

    func testHoverScrollingAboutThirtyPercentIsBlockedAtZeroPercent() throws {
        try assertScrollingWindowFocus(percent: 0, orientation: .horizontal, isFocused: false)
    }

    func testHoverScrollingAboutThirtyPercentIsBlockedAtTwentyPercent() throws {
        try assertScrollingWindowFocus(percent: 20, orientation: .horizontal, isFocused: false)
    }

    func testHoverScrollingAboutThirtyPercentIsAllowedAtFiftyPercent() throws {
        try assertScrollingWindowFocus(percent: 50, orientation: .horizontal, isFocused: true)
    }

    func testHoverScrollingAboutThirtyPercentIsAllowedAtOneHundredPercent() throws {
        try assertScrollingWindowFocus(percent: 100, orientation: .horizontal, isFocused: true)
    }

    func testVerticalHoverScrollingAboutThirtyPercentIsBlockedAtTwentyPercent() throws {
        try assertScrollingWindowFocus(percent: 20, orientation: .vertical, isFocused: false)
    }

    func testVerticalHoverScrollingAboutThirtyPercentIsAllowedAtFiftyPercent() throws {
        try assertScrollingWindowFocus(percent: 50, orientation: .vertical, isFocused: true)
    }

    func testHoverNeedingNoScrollIsAllowedAtZeroPercentWhenNextColumnIsAlsoFullyVisible() throws {
        let fixture = try Fixture(
            maxScrollPercent: 0,
            spans: { extent, _ in [extent * 0.3, extent * 0.3] }
        )

        fixture.hover(fixture.partialPointer, windowId: fixture.partial.windowId)

        XCTAssertEqual(fixture.focusedTokens, [fixture.partial])
    }

    private static let parkedStripShare: CGFloat = 0.45
    private static let parkedStripSpans: Fixture.SpanPlan = { extent, gap in
        [extent - 2 * gap, extent * parkedStripShare]
    }

    private func parkedStripFixture(percent: Int) throws -> Fixture {
        let fixture = try Fixture(maxScrollPercent: percent, spans: Self.parkedStripSpans)
        let stripFrame = try XCTUnwrap(fixture.frame(of: fixture.partial))
        XCTAssertEqual(stripFrame.minX, fixture.monitorFrame.maxX - 1, accuracy: 0.001)
        XCTAssertEqual(stripFrame.width, fixture.extent * Self.parkedStripShare, accuracy: 1)
        return fixture
    }

    func testParkedStripScrollAmountIsWithinFiftyPercentLimit() throws {
        let fixture = try parkedStripFixture(percent: 50)

        let amount = try XCTUnwrap(fixture.hoverScrollAmount(of: fixture.partial))

        XCTAssertTrue(
            NiriHoverScroll.allows(amount: amount, percent: 50, extent: fixture.extent, scale: fixture.scale)
        )
    }

    func testHoverIgnoresParkedStripFoundByWindowIdAtFiftyPercent() throws {
        let fixture = try parkedStripFixture(percent: 50)

        fixture.hover(fixture.stripPointer, windowId: fixture.partial.windowId)

        XCTAssertTrue(fixture.focusedTokens.isEmpty)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.lastFocusFollowsMouseTime, .distantPast)
    }

    func testHoverIgnoresParkedStripFoundByGeometryAtFiftyPercent() throws {
        let fixture = try parkedStripFixture(percent: 50)

        fixture.hover(fixture.stripPointer, windowId: nil)

        XCTAssertTrue(fixture.focusedTokens.isEmpty)
    }

    func testHoverStillFocusesActiveColumnNextToParkedStripAtFiftyPercent() throws {
        let fixture = try parkedStripFixture(percent: 50)

        fixture.hover(fixture.visiblePointer, windowId: fixture.visible.windowId)
        fixture.hover(fixture.visiblePointer, windowId: nil)

        XCTAssertEqual(fixture.focusedTokens, [fixture.visible])
    }

    func testHoverFocusesParkedStripFoundByWindowIdAtOneHundredPercent() throws {
        let fixture = try parkedStripFixture(percent: 100)

        fixture.hover(fixture.stripPointer, windowId: fixture.partial.windowId)

        XCTAssertEqual(fixture.focusedTokens, [fixture.partial])
    }

    func testHoverFocusesParkedStripFoundByGeometryAtOneHundredPercent() throws {
        let fixture = try parkedStripFixture(percent: 100)

        fixture.hover(fixture.stripPointer, windowId: nil)

        XCTAssertEqual(fixture.focusedTokens, [fixture.partial])
    }

    func testLatestFocusFollowsMouseTokenIsNilForParkedStrip() throws {
        let fixture = try parkedStripFixture(percent: 50)

        fixture.hover(fixture.stripPointer, windowId: fixture.partial.windowId)
        XCTAssertNil(fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken())

        fixture.hover(fixture.visiblePointer, windowId: fixture.visible.windowId)
        XCTAssertEqual(fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken(), fixture.visible)
    }

    func testHoverFocusesColumnShowingMoreThanParkedStripWhenScrollLimitAllows() throws {
        let fixture = try Fixture(
            maxScrollPercent: 50,
            spans: { extent, _ in [extent * 0.7, extent * 0.5] }
        )
        let frame = try XCTUnwrap(fixture.frame(of: fixture.partial))
        let visibleLength = frame.intersection(fixture.monitorFrame).width
        XCTAssertGreaterThan(visibleLength, 2)

        fixture.hover(fixture.partialPointer, windowId: fixture.partial.windowId)
        fixture.hover(fixture.partialPointer, windowId: nil)

        XCTAssertEqual(fixture.focusedTokens, [fixture.partial])
    }

    func testVerticalHoverIgnoresParkedStripAtFiftyPercent() throws {
        let fixture = try Fixture(
            maxScrollPercent: 50,
            orientation: .vertical,
            spans: Self.parkedStripSpans
        )
        let stripFrame = try XCTUnwrap(fixture.frame(of: fixture.partial))
        XCTAssertEqual(stripFrame.minY, fixture.monitorFrame.maxY - 1, accuracy: 0.001)

        fixture.hover(fixture.stripPointer, windowId: fixture.partial.windowId)
        fixture.hover(fixture.stripPointer, windowId: nil)

        XCTAssertTrue(fixture.focusedTokens.isEmpty)
    }

    func testHoverStillFocusesFloatingWindowAtZeroMaxScroll() throws {
        let fixture = try Fixture(maxScrollPercent: 0)
        let floatingFrame = CGRect(
            x: fixture.workingFrame.maxX - 60,
            y: fixture.workingFrame.minY + 300,
            width: 240,
            height: 160
        )
        let floating = fixture.controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(767_020), windowId: 767_120),
            pid: 767_020,
            windowId: 767_120,
            to: fixture.workspaceId,
            mode: .floating
        )
        fixture.controller.workspaceManager.updateFloatingGeometry(frame: floatingFrame, for: floating)

        fixture.hover(floatingFrame.center, windowId: floating.windowId)

        XCTAssertEqual(fixture.focusedTokens, [floating])
    }
}

@MainActor
private final class Fixture {
    typealias SpanPlan = (_ extent: CGFloat, _ gap: CGFloat) -> [CGFloat]

    let controller: WMController
    let workspaceId: WorkspaceDescriptor.ID
    let workingFrame: CGRect
    let gap: CGFloat
    let orientation: Monitor.Orientation
    let tokens: [WindowToken]
    private let monitor: Monitor
    private let recorder = FocusRecorder()

    var focusedTokens: [WindowToken] {
        recorder.tokens
    }

    var visible: WindowToken {
        tokens[0]
    }

    var partial: WindowToken {
        tokens[1]
    }

    var extent: CGFloat {
        orientation == .horizontal ? workingFrame.width : workingFrame.height
    }

    var visiblePointer: CGPoint {
        pointerOnVisiblePortion(of: visible)
    }

    var partialPointer: CGPoint {
        pointerOnVisiblePortion(of: partial)
    }

    var monitorFrame: CGRect {
        monitor.frame
    }

    var scale: CGFloat {
        controller.niriEngine?.displayScale(in: workspaceId) ?? 1
    }

    var stripPointer: CGPoint {
        guard let frame = frame(of: partial) else { return .zero }
        switch orientation {
        case .horizontal:
            return CGPoint(x: frame.minX + 0.5, y: frame.midY)
        case .vertical:
            return CGPoint(x: frame.midX, y: frame.minY + 0.5)
        }
    }

    init(
        maxScrollPercent: Int,
        orientation: Monitor.Orientation = .horizontal,
        spans: SpanPlan = { extent, _ in [extent * 0.3, extent * 0.9] }
    ) throws {
        let recorder = recorder
        controller = WindowAdmissionTestSupport.controller(
            prefix: "FocusFollowsMouseMaxScrollTests",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    recorder.tokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        self.orientation = orientation
        workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.settings.focus.hoverFocusMaxScrollPercent = maxScrollPercent
        controller.setFocusFollowsMouse(true)
        controller.motionPolicy.animationsEnabled = false
        let initialMonitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        controller.settings.monitors.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: initialMonitor.name,
                monitorDisplayId: initialMonitor.displayId,
                orientation: orientation
            ),
            for: initialMonitor
        )
        controller.workspaceManager.applyMonitorConfigurationChange([initialMonitor])
        controller.niriLayoutHandler.enableNiriLayout()
        monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let geometry = controller.niriInteractionGeometry(for: monitor)
        workingFrame = geometry.workingFrame
        gap = geometry.innerGap

        let columnSpans = spans(orientation == .horizontal ? workingFrame.width : workingFrame.height, gap)
        var addedTokens: [WindowToken] = []
        for (index, span) in columnSpans.enumerated() {
            addedTokens.append(try Self.addWindow(
                pid: pid_t(767_001 + index),
                span: span,
                orientation: orientation,
                to: workspaceId,
                controller: controller
            ))
        }
        tokens = addedTokens

        var viewport = controller.workspaceManager.niriViewportState(for: workspaceId)
        viewport.activeColumnIndex = 0
        viewport.viewOffset = -gap
        controller.workspaceManager.updateNiriViewportState(viewport, for: workspaceId)
        relayout()
    }

    func hover(_ location: CGPoint, windowId: Int?) {
        controller.mouseEventHandler.dispatchMouseMoved(at: location, windowIdUnderPointer: windowId)
    }

    func frame(of token: WindowToken) -> CGRect? {
        let node = controller.niriEngine?.findNode(for: token, in: workspaceId)
        return node?.renderedFrame ?? node?.frame
    }

    func hoverScrollAmount(of token: WindowToken) -> CGFloat? {
        guard let engine = controller.niriEngine,
              let node = engine.findNode(for: token, in: workspaceId),
              let column = engine.column(of: node)
        else { return nil }
        let columns = engine.columns(in: workspaceId)
        guard let columnIndex = columns.firstIndex(where: { $0 === column }) else { return nil }
        let settings = engine.effectiveSettings(in: workspaceId)
        return NiriHoverScroll.scrollAmount(
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            columnIndex: columnIndex,
            columns: columns,
            context: NiriInteractionContext(
                workspaceId: workspaceId,
                motion: controller.motionPolicy.snapshot(),
                workingFrame: workingFrame,
                gaps: gap,
                orientation: orientation
            ),
            centerMode: settings.centerFocusedColumn,
            alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
            scale: scale,
            viewFrame: monitor.frame
        )
    }

    func setColumnSpan(of token: WindowToken, to span: CGFloat) {
        guard let engine = controller.niriEngine,
              let node = engine.findNode(for: token, in: workspaceId),
              let column = engine.column(of: node)
        else { return }
        Self.applySpan(span, to: column, orientation: orientation)
        relayout()
    }

    private func relayout() {
        guard let engine = controller.niriEngine else { return }
        let scale = engine.displayScale(in: workspaceId)
        _ = engine.calculateLayout(
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            screenFrame: monitor.frame,
            gaps: (horizontal: gap, vertical: gap),
            scale: scale,
            workingArea: WorkingAreaContext(workingFrame: workingFrame, viewFrame: monitor.frame, scale: scale),
            orientation: orientation,
            isSettled: true
        )
    }

    private func pointerOnVisiblePortion(of token: WindowToken) -> CGPoint {
        guard let frame = frame(of: token) else { return .zero }
        let visibleRegion = frame.intersection(workingFrame)
        return visibleRegion.isNull ? frame.center : visibleRegion.center
    }

    private static func applySpan(_ span: CGFloat, to column: NiriContainer, orientation: Monitor.Orientation) {
        switch orientation {
        case .horizontal:
            column.width = .fixed(span)
            column.cachedWidth = span
        case .vertical:
            column.height = .fixed(span)
            column.cachedHeight = span
        }
    }

    private static func addWindow(
        pid: pid_t,
        span: CGFloat,
        orientation: Monitor.Orientation,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) throws -> WindowToken {
        let windowId = Int(pid) + 100
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let node = try XCTUnwrap(engine.addWindow(token: token, to: workspaceId, afterSelection: nil))
        let column = try XCTUnwrap(engine.column(of: node))
        applySpan(span, to: column, orientation: orientation)
        return token
    }
}

private final class FocusRecorder {
    var tokens: [WindowToken] = []
}
