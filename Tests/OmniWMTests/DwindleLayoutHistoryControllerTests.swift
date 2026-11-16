// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

extension CrossDisplayDragTests {
    func testDwindleNativeResizeRecordsOneCompletedGestureForCommandUndoRedo() throws {
        let (fixture, tokens) = try makeDwindleHistoryNativeFixture()
        let blocker = blockDwindleHistoryRefreshes(fixture)
        defer { unblockDwindleHistoryRefreshes(fixture, blocker) }
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitors[0])
        let original = dwindleHistoryFrames(fixture, tokens: tokens, cut: area.width / 2)
        let grown = dwindleHistoryFrames(fixture, tokens: tokens, cut: area.width / 2 + area.width / 8)
        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), original)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 0)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).redo, 0)

        try driveDwindleHistoryNativeResize(fixture, tokens: tokens, deltas: [area.width / 16, area.width / 8])

        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), grown)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 1)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).redo, 0)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.sizing(.undo)), .executed)
        fixture.layout()
        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), original)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 0)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).redo, 1)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.sizing(.redo)), .executed)
        fixture.layout()
        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), grown)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 1)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).redo, 0)
        for token in tokens {
            XCTAssertEqual(fixture.manager.workspace(for: token), fixture.source)
            XCTAssertEqual(fixture.dwindleTile(token), [token])
        }
        XCTAssertNil(fixture.dwindle.interactiveResize)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
    }

    func testDwindleNativeResizeReturningExactlyToStartRecordsNoHistory() throws {
        let (fixture, tokens) = try makeDwindleHistoryNativeFixture()
        let blocker = blockDwindleHistoryRefreshes(fixture)
        defer { unblockDwindleHistoryRefreshes(fixture, blocker) }
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitors[0])
        let original = dwindleHistoryFrames(fixture, tokens: tokens, cut: area.width / 2)

        try driveDwindleHistoryNativeResize(fixture, tokens: tokens, deltas: [area.width / 16, area.width / 8, 0])

        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), original)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 0)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).redo, 0)
        for command: HotkeyCommand in [.sizing(.undo), .sizing(.redo)] {
            XCTAssertEqual(fixture.controller.commandHandler.performCommand(command), .executed)
            fixture.layout()
            XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), original)
            XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 0)
            XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).redo, 0)
        }
        for token in tokens {
            XCTAssertEqual(fixture.manager.workspace(for: token), fixture.source)
            XCTAssertEqual(fixture.dwindleTile(token), [token])
        }
        XCTAssertNil(fixture.dwindle.interactiveResize)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
    }

    func testDwindleHistoryCommandsKeepSharedCompatibilityAndNiriGuards() throws {
        for action: SizingAction in [.undo, .redo] {
            XCTAssertEqual(action.compatibility, .shared)
            XCTAssertTrue(CommandHandler.isLayoutCompatible(action.compatibility, with: .dwindle))
            XCTAssertTrue(CommandHandler.isLayoutCompatible(action.compatibility, with: .niri))
        }
        XCTAssertEqual(SizingAction.cycleWindowPrimarySpanForward.compatibility, .niri)
        let (fixture, _) = try makeDwindleHistoryNativeFixture()
        XCTAssertNil(fixture.controller.niriLayoutHandler.layoutChangeStart(in: fixture.source))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo, in: fixture.source))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.stepLayoutHistory(.redo, in: fixture.source))
    }

    func testDwindleRatioAndTreeCommandsUndoAndRedoTheirDeclaredLayouts() throws {
        for command: HotkeyCommand in [.dwindle(.resizeAlongAxis(.horizontal, true)), .dwindle(.toggleSplit)] {
            let (fixture, tokens) = try makeDwindleHistoryNativeFixture()
            let blocker = blockDwindleHistoryRefreshes(fixture)
            defer { unblockDwindleHistoryRefreshes(fixture, blocker) }
            focusDwindleHistoryToken(tokens[0], fixture)
            let area = fixture.controller.insetWorkingFrame(for: fixture.monitors[0])
            let original = dwindleHistoryFrames(fixture, tokens: tokens, cut: area.width / 2)
            let resized = command == .dwindle(.toggleSplit)
                ? dwindleHistoryFrames(fixture, tokens: tokens, cut: area.height / 2, horizontal: false)
                : dwindleHistoryFrames(
                    fixture, tokens: tokens,
                    cut: area.width * fixture.dwindle.settings.ratioToFraction(1 + fixture.dwindle.settings.resizeStep)
                )
            stepDwindleHistoryCommand(command, fixture)
            XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), resized)
            XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 1)
            stepDwindleHistoryCommand(.sizing(.undo), fixture)
            XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), original)
            stepDwindleHistoryCommand(.sizing(.redo), fixture)
            XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), resized)
        }
    }

    func testDwindleGroupAndMemberReorderCommandsUndoAndRedo() throws {
        let (fixture, tokens) = try makeDwindleHistoryNativeFixture()
        let blocker = blockDwindleHistoryRefreshes(fixture)
        defer { unblockDwindleHistoryRefreshes(fixture, blocker) }
        focusDwindleHistoryToken(tokens[0], fixture)
        stepDwindleHistoryCommand(.move(.right), fixture)
        XCTAssertEqual(fixture.dwindleTile(tokens[0]), [tokens[1], tokens[0]])
        XCTAssertEqual(fixture.dwindle.projectedActiveToken(in: fixture.source), tokens[0])
        stepDwindleHistoryCommand(.windowMovement(.up), fixture)
        XCTAssertEqual(fixture.dwindleTile(tokens[0]), tokens)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 2)
        stepDwindleHistoryCommand(.sizing(.undo), fixture)
        XCTAssertEqual(fixture.dwindleTile(tokens[0]), [tokens[1], tokens[0]])
        stepDwindleHistoryCommand(.sizing(.undo), fixture)
        for token in tokens { XCTAssertEqual(fixture.dwindleTile(token), [token]) }
        stepDwindleHistoryCommand(.sizing(.redo), fixture)
        XCTAssertEqual(fixture.dwindleTile(tokens[0]), [tokens[1], tokens[0]])
        stepDwindleHistoryCommand(.sizing(.redo), fixture)
        XCTAssertEqual(fixture.dwindleTile(tokens[0]), tokens)
        XCTAssertEqual(fixture.dwindle.projectedActiveToken(in: fixture.source), tokens[0])
    }

    func testDwindleFullscreenCommandAndEdgeDoubleClickUndoAndRedo() throws {
        for edge in [false, true] {
            let (fixture, tokens) = try makeDwindleHistoryNativeFixture()
            let blocker = blockDwindleHistoryRefreshes(fixture)
            defer { unblockDwindleHistoryRefreshes(fixture, blocker) }
            focusDwindleHistoryToken(tokens[0], fixture)
            let area = fixture.controller.insetWorkingFrame(for: fixture.monitors[0])
            let minimumRaw = area.width / 64
            fixture.manager.setCachedConstraints(WindowSizeConstraints(
                minSize: CGSize(width: minimumRaw - fixture.dwindle.settings.innerGap / 2, height: 1),
                maxSize: .zero, isFixed: false
            ), for: tokens[1])
            fixture.controller.dwindleLayoutHandler.refreshEngineConstraints(
                workspaceId: fixture.source, monitor: fixture.monitors[0]
            )
            fixture.layout()
            let original = dwindleHistoryFrames(fixture, tokens: tokens, cut: area.width / 2)
            let expanded = dwindleHistoryFrames(fixture, tokens: tokens, cut: area.width - minimumRaw)
            if edge {
                let start = try XCTUnwrap(original[tokens[0]])
                let point = CGPoint(x: start.maxX - NiriLayoutEngine.doubleClickEdgeInset / 2, y: start.midY)
                fixture.handler.topmostWindowIdProvider = { _ in tokens[0].windowId }
                for clickCount: Int64 in [1, 2] {
                    XCTAssertEqual(fixture.handler.dispatchAuthoritativeTap(
                        type: .leftMouseDown, location: point, modifiers: [], buttonNumber: 0,
                        scrollPayload: nil, clickCount: clickCount
                    ), clickCount == 2)
                    XCTAssertEqual(fixture.handler.dispatchAuthoritativeTap(
                        type: .leftMouseUp, location: point, modifiers: [], buttonNumber: 0, scrollPayload: nil
                    ), clickCount == 2)
                }
                fixture.layout()
            } else {
                stepDwindleHistoryCommand(.fullscreen(.managed), fixture)
            }
            XCTAssertEqual(fixture.frame(tokens[0]), edge ? expanded[tokens[0]] : area)
            XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), edge ? [] : [tokens[0]])
            XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 1)
            stepDwindleHistoryCommand(.sizing(.undo), fixture)
            XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), original)
            XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), [])
            stepDwindleHistoryCommand(.sizing(.redo), fixture)
            XCTAssertEqual(fixture.frame(tokens[0]), edge ? expanded[tokens[0]] : area)
            XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.source), edge ? [] : [tokens[0]])
            if edge { XCTAssertNotNil(fixture.dwindle.root(for: fixture.source)?.edgeExpansion) }
        }
    }

    func testDwindleHistoryRoutesToVisibleFocusedWorkspaceInsteadOfInteractionWorkspace() throws {
        let fixture = try makeNativeFixture([.niri, .dwindle], orientations: [.horizontal, .vertical])
        let niriToken = addWindow(1, to: fixture.source, fixture)
        let first = addWindow(2, to: fixture.target, fixture)
        fixture.manager.withEngineMutationScope(in: fixture.target) {
            _ = fixture.dwindle.setPreselection(.right, in: fixture.target)
        }
        let second = addWindow(3, to: fixture.target, fixture)
        let blocker = blockDwindleHistoryRefreshes(fixture)
        defer { unblockDwindleHistoryRefreshes(fixture, blocker) }
        fixture.layout()
        let originalRatio = try XCTUnwrap(fixture.dwindle.root(for: fixture.target)).splitRatio
        XCTAssertTrue(fixture.controller.dwindleLayoutHandler.toggleFullscreen(for: first, in: fixture.target))
        fixture.layout()
        XCTAssertTrue(fixture.manager.confirmManagedFocus(
            first, in: fixture.target, onMonitor: fixture.monitors[1].id, activateWorkspaceOnMonitor: true
        ))
        fixture.manager.setInteractionMonitor(fixture.monitors[0].id)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.source)
        XCTAssertEqual(fixture.controller.niriLayoutHandler.layoutHistoryWorkspaceId(), fixture.target)
        let niriFrame = fixture.frame(niriToken)
        stepDwindleHistoryCommand(.sizing(.undo), fixture)
        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.target), [])
        stepDwindleHistoryCommand(.sizing(.redo), fixture)
        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: fixture.target), [first])
        XCTAssertEqual(fixture.dwindle.root(for: fixture.target)?.splitRatio, originalRatio)
        XCTAssertEqual(fixture.dwindleTile(second), [second])
        XCTAssertEqual(fixture.frame(niriToken), niriFrame)
        XCTAssertNil(fixture.niri.peekLayoutHistory(.undo, in: fixture.source))
    }

    func testDwindleHistorySurvivesLayoutSwitchAndKeepsNiriHistorySeparate() throws {
        let (fixture, tokens) = try makeDwindleHistoryNativeFixture()
        let blocker = blockDwindleHistoryRefreshes(fixture)
        defer { unblockDwindleHistoryRefreshes(fixture, blocker) }
        focusDwindleHistoryToken(tokens[0], fixture)
        stepDwindleHistoryCommand(.dwindle(.resizeAlongAxis(.horizontal, true)), fixture)
        let grownRatio = 1 + fixture.dwindle.settings.resizeStep
        XCTAssertTrue(fixture.controller.commandHandler.setWorkspaceLayout(.niri, forWorkspaceNamed: "1"))
        fixture.manager.withBatchedLayoutBuild {
            fixture.controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [fixture.source])
        }
        fixture.layout()
        let first = try XCTUnwrap(fixture.niri.findNode(for: tokens[0], in: fixture.source))
        let column = try XCTUnwrap(fixture.niri.findColumn(containing: first, in: fixture.source))
        let span = fixture.controller.insetWorkingFrame(for: fixture.monitors[0]).width
        let originalWidth = ProportionalSize.fixed(span / 2)
        fixture.manager.withEngineMutationScope(in: fixture.source) { column.width = originalWidth }
        fixture.layout()
        let requested = span / 4
        fixture.manager.withNiriViewportState(for: fixture.source) { $0.selectedNodeId = first.id }
        stepDwindleHistoryCommand(.sizing(.setContainerPrimarySpan(.setFixed(requested))), fixture)
        XCTAssertNotNil(fixture.niri.peekLayoutHistory(.undo, in: fixture.source))
        XCTAssertTrue(fixture.controller.commandHandler.setWorkspaceLayout(.dwindle, forWorkspaceNamed: "1"))
        fixture.layout()
        XCTAssertEqual(fixture.dwindle.root(for: fixture.source)?.splitRatio, grownRatio)
        XCTAssertFalse(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo, in: fixture.source))
        stepDwindleHistoryCommand(.sizing(.undo), fixture)
        XCTAssertEqual(fixture.dwindle.root(for: fixture.source)?.splitRatio, 1)
        XCTAssertTrue(fixture.controller.commandHandler.setWorkspaceLayout(.niri, forWorkspaceNamed: "1"))
        stepDwindleHistoryCommand(.sizing(.undo), fixture)
        XCTAssertEqual(column.width, originalWidth)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).redo, 1)
    }

    func testDwindleHistoryDoesNotConsumeEntriesDuringMoveOrResize() throws {
        for resize in [false, true] {
            let (fixture, tokens) = try makeDwindleHistoryNativeFixture()
            let blocker = blockDwindleHistoryRefreshes(fixture)
            defer { unblockDwindleHistoryRefreshes(fixture, blocker) }
            focusDwindleHistoryToken(tokens[0], fixture)
            stepDwindleHistoryCommand(.dwindle(.resizeAlongAxis(.horizontal, true)), fixture)
            let ratio = 1 + fixture.dwindle.settings.resizeStep
            let start = try XCTUnwrap(fixture.frame(tokens[0]))
            if resize {
                XCTAssertTrue(fixture.dwindle.interactiveResizeBegin(
                    token: tokens[0], edges: .right, startLocation: start.origin, in: fixture.source,
                    innerGap: fixture.dwindle.settings.innerGap
                ))
            } else {
                XCTAssertTrue(fixture.dwindle.interactiveMoveBegin(
                    token: tokens[0], startLocation: start.center, in: fixture.source
                ))
            }
            stepDwindleHistoryCommand(.sizing(.undo), fixture)
            XCTAssertEqual(fixture.dwindle.root(for: fixture.source)?.splitRatio, ratio)
            XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 1)
            XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).redo, 0)
            if resize { fixture.dwindle.clearInteractiveResize() } else { fixture.dwindle.interactiveMoveCancel() }
            stepDwindleHistoryCommand(.sizing(.undo), fixture)
            XCTAssertEqual(fixture.dwindle.root(for: fixture.source)?.splitRatio, 1)
            XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).redo, 1)
        }
    }

    func testDwindleNativeVerticalCornerAndCenteredHistoryRecordsOnlyFinalChanges() throws {
        for kind in [DwindleHistoryGesture.vertical, .corner, .centered] {
            for returnsToStart in [false, true] {
                let (fixture, tokens) = try makeDwindleHistoryGestureFixture(kind)
                let blocker = blockDwindleHistoryRefreshes(fixture)
                defer { unblockDwindleHistoryRefreshes(fixture, blocker) }
                let layouts = dwindleHistoryGestureLayouts(kind, fixture, tokens: tokens)
                let original = layouts[0]
                let final = returnsToStart ? original : layouts[2]
                let observations = returnsToStart ? layouts + [original] : layouts
                let target = tokens[kind == .vertical ? 0 : 1]
                try driveDwindleHistoryObservations(
                    fixture, token: target, layouts: observations,
                    edges: kind == .corner ? [.left, .top] : (kind == .vertical ? .top : .right),
                    modifiers: kind == .centered ? .maskAlternate : []
                )
                XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), final)
                XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, returnsToStart ? 0 : 1)
                XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).redo, 0)
                stepDwindleHistoryCommand(.sizing(.undo), fixture)
                XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), original)
                XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 0)
                XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).redo, returnsToStart ? 0 : 1)
                stepDwindleHistoryCommand(.sizing(.redo), fixture)
                XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), final)
                for token in tokens { XCTAssertEqual(fixture.dwindleTile(token), [token]) }
                XCTAssertNil(fixture.dwindle.interactiveResize)
                XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
            }
        }
    }

    private enum DwindleHistoryGesture {
        case vertical
        case corner
        case centered
    }

    private func makeDwindleHistoryGestureFixture(_ kind: DwindleHistoryGesture) throws -> (Fixture, [WindowToken]) {
        let (fixture, pair) = try makeDwindleHistoryNativeFixture(horizontal: kind != .vertical)
        if kind == .vertical { return (fixture, pair) }
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            fixture.dwindle.setSelectedNode(
                fixture.dwindle.findNode(for: pair[1], in: fixture.source), in: fixture.source
            )
            _ = fixture.dwindle.setPreselection(kind == .corner ? .up : .right, in: fixture.source)
        }
        let third = addWindow(3, to: fixture.source, fixture)
        if kind == .corner {
            fixture.layout()
            return (fixture, pair + [third])
        }
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            fixture.dwindle.setSelectedNode(
                fixture.dwindle.findNode(for: pair[1], in: fixture.source), in: fixture.source
            )
            _ = fixture.dwindle.setPreselection(.right, in: fixture.source)
        }
        let near = addWindow(4, to: fixture.source, fixture)
        let inner = try XCTUnwrap(fixture.dwindle.findNode(for: pair[1], in: fixture.source)?.parent)
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            inner.kind = .split(orientation: .horizontal, ratio: 1 / 2)
        }
        let span = fixture.controller.insetWorkingFrame(for: fixture.monitors[0]).width / 2
        fixture.manager.setCachedConstraints(WindowSizeConstraints(
            minSize: CGSize(width: 9 * span / 16 - fixture.dwindle.settings.innerGap / 2, height: 1),
            maxSize: .zero, isFixed: false
        ), for: third)
        fixture.controller.dwindleLayoutHandler.refreshEngineConstraints(
            workspaceId: fixture.source, monitor: fixture.monitors[0]
        )
        fixture.layout()
        return (fixture, pair + [near, third])
    }

    private func dwindleHistoryGestureLayouts(
        _ kind: DwindleHistoryGesture, _ fixture: Fixture, tokens: [WindowToken]
    ) -> [[WindowToken: CGRect]] {
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitors[0])
        switch kind {
        case .vertical:
            return [0, area.height / 16, area.height / 8].map { delta in
                dwindleHistoryFrames(fixture, tokens: tokens, cut: area.height / 2 + delta, horizontal: false)
            }
        case .corner:
            return [CGFloat(0), 1 / 16, 1 / 8].map { fraction in
                let cutX = area.width / 2 - area.width * fraction
                let cutY = area.height / 2 + area.height * fraction
                return dwindleHistoryProjectedFrames(fixture, tokens: tokens, raw: [
                    CGRect(x: area.minX, y: area.minY, width: cutX, height: area.height),
                    CGRect(x: area.minX + cutX, y: area.minY, width: area.width - cutX, height: cutY),
                    CGRect(
                        x: area.minX + cutX, y: area.minY + cutY,
                        width: area.width - cutX, height: area.height - cutY
                    )
                ])
            }
        case .centered:
            let span = area.width / 2
            return [
                [span, 7 * span / 64, 21 * span / 64, 9 * span / 16],
                [7 * span / 8, 23 * span / 64, 13 * span / 64, 9 * span / 16],
                [13 * span / 16, 31 * span / 64, 7 * span / 64, 19 * span / 32]
            ].map { widths in
                var x = area.minX
                let raw = widths.map { width in
                    defer { x += width }
                    return CGRect(x: x, y: area.minY, width: width, height: area.height)
                }
                return dwindleHistoryProjectedFrames(fixture, tokens: tokens, raw: raw)
            }
        }
    }

    private func dwindleHistoryProjectedFrames(
        _ fixture: Fixture, tokens: [WindowToken], raw: [CGRect]
    ) -> [WindowToken: CGRect] {
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitors[0])
        return Dictionary(uniqueKeysWithValues: zip(tokens, raw).map { token, rectangle in
            (token, DwindleGapCalculator.applyGaps(
                nodeRect: rectangle, tilingArea: area, settings: fixture.dwindle.settings
            ))
        })
    }

    private func driveDwindleHistoryObservations(
        _ fixture: Fixture, token: WindowToken, layouts: [[WindowToken: CGRect]],
        edges: ResizeEdge, modifiers: CGEventFlags
    ) throws {
        let original = try XCTUnwrap(layouts.first)
        let start = try XCTUnwrap(original[token])
        let entry = try XCTUnwrap(fixture.manager.entry(for: token))
        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), original)
        fixture.handler.nativeWindowFrameProvider = { reference in
            original.first { $0.key.windowId == reference.windowId }?.value
        }
        fixture.controller.axEventHandler.windowInfoProvider = { windowId in
            guard let pair = original.first(where: { $0.key.windowId == Int(windowId) }) else { return nil }
            return WindowServerInfo(id: windowId, pid: pair.key.pid, level: 0, frame: pair.value)
        }
        for (window, frame) in original {
            fixture.controller.axManager.confirmFrameWrite(for: window.windowId, frame: frame)
        }
        let press = CGPoint(
            x: edges.contains(.left) ? start.minX.nextUp : (edges.contains(.right) ? start.maxX.nextDown : start.midX),
            y: edges.contains(.top) ? start.maxY.nextDown : start.midY
        )
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: press, modifiers: modifiers, windowIdUnderPointer: token.windowId
        ))
        var release = press
        for layout in layouts.dropFirst() {
            let frame = try XCTUnwrap(layout[token])
            release = CGPoint(
                x: press.x + (edges.contains(.left) ? frame.minX - start.minX : frame.maxX - start.maxX),
                y: press.y + (edges.contains(.top) ? frame.maxY - start.maxY : 0)
            )
            fixture.handler.dispatchMouseDragged(at: release)
            fixture.handler.nativeWindowFrameProvider = { reference in
                layout.first { $0.key.windowId == reference.windowId }?.value
            }
            XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: entry))
            fixture.layout()
            XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), layout)
            XCTAssertNotNil(fixture.dwindle.interactiveResize)
            XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 0)
        }
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.dispatchMouseUp(at: release)
        fixture.layout()
    }

    func testDwindleFirstEmptyWorkspacePreselectionCommandUndoesAndRedoes() throws {
        let fixture = try makeNativeFixture([.dwindle])
        let blocker = blockDwindleHistoryRefreshes(fixture)
        defer { unblockDwindleHistoryRefreshes(fixture, blocker) }
        XCTAssertNil(fixture.dwindle.existingState(for: fixture.source))
        XCTAssertTrue(fixture.manager.entries(in: fixture.source).isEmpty)

        stepDwindleHistoryCommand(.dwindle(.preselect(.right)), fixture)
        try assertEmptyDwindleHistory(fixture, preselection: .right, undo: 1, redo: 0)
        stepDwindleHistoryCommand(.sizing(.undo), fixture)
        try assertEmptyDwindleHistory(fixture, preselection: nil, undo: 0, redo: 1)
        stepDwindleHistoryCommand(.sizing(.redo), fixture)
        try assertEmptyDwindleHistory(fixture, preselection: .right, undo: 1, redo: 0)
    }

    func testDwindleClearPreselectionCommandUndoesAndRedoesWhileEmpty() throws {
        let fixture = try makeNativeFixture([.dwindle])
        let blocker = blockDwindleHistoryRefreshes(fixture)
        defer { unblockDwindleHistoryRefreshes(fixture, blocker) }
        stepDwindleHistoryCommand(.dwindle(.preselect(.up)), fixture)
        try assertEmptyDwindleHistory(fixture, preselection: .up, undo: 1, redo: 0)

        stepDwindleHistoryCommand(.dwindle(.preselectClear), fixture)
        try assertEmptyDwindleHistory(fixture, preselection: nil, undo: 2, redo: 0)
        stepDwindleHistoryCommand(.sizing(.undo), fixture)
        try assertEmptyDwindleHistory(fixture, preselection: .up, undo: 1, redo: 1)
        stepDwindleHistoryCommand(.sizing(.redo), fixture)
        try assertEmptyDwindleHistory(fixture, preselection: nil, undo: 2, redo: 0)
    }

    func testDwindlePreselectionHistoryAfterLastWindowClosesKeepsTheWorkspaceEmpty() throws {
        let fixture = try makeNativeFixture([.dwindle])
        let token = addWindow(1, to: fixture.source, fixture)
        let blocker = blockDwindleHistoryRefreshes(fixture)
        defer { unblockDwindleHistoryRefreshes(fixture, blocker) }
        stepDwindleHistoryCommand(.dwindle(.preselect(.left)), fixture)
        stepDwindleHistoryCommand(.dwindle(.preselect(.up)), fixture)
        XCTAssertEqual(fixture.dwindleTile(token), [token])
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 2)

        XCTAssertNotNil(fixture.manager.removeWindow(pid: token.pid, windowId: token.windowId))
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            fixture.dwindle.removeWindow(token: token, from: fixture.source)
        }
        fixture.layout()
        try assertEmptyDwindleHistory(fixture, preselection: .up, undo: 2, redo: 0)
        stepDwindleHistoryCommand(.sizing(.undo), fixture)
        try assertEmptyDwindleHistory(fixture, preselection: .left, undo: 1, redo: 1)
        XCTAssertNil(fixture.manager.entry(for: token))
        XCTAssertNil(fixture.dwindle.findNode(for: token, in: fixture.source))
        stepDwindleHistoryCommand(.sizing(.redo), fixture)
        try assertEmptyDwindleHistory(fixture, preselection: .up, undo: 2, redo: 0)
        XCTAssertNil(fixture.manager.entry(for: token))
        XCTAssertNil(fixture.dwindle.findNode(for: token, in: fixture.source))
    }

    private func assertEmptyDwindleHistory(
        _ fixture: Fixture, preselection: Direction?, undo: Int, redo: Int
    ) throws {
        let state = try XCTUnwrap(fixture.dwindle.existingState(for: fixture.source))
        XCTAssertTrue(fixture.manager.entries(in: fixture.source).isEmpty)
        XCTAssertTrue(state.leafByToken.isEmpty)
        XCTAssertEqual(state.tileCount, 0)
        XCTAssertTrue(state.root.isLeaf)
        XCTAssertNil(state.root.tile)
        XCTAssertTrue(state.root.children.isEmpty)
        XCTAssertNil(state.selectedNodeId)
        XCTAssertEqual(state.preselection, preselection)
        XCTAssertEqual(fixture.dwindle.currentFrames(in: fixture.source), [:])
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, undo)
        XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).redo, redo)
    }

    private func focusDwindleHistoryToken(_ token: WindowToken, _ fixture: Fixture) {
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            fixture.dwindle.setSelectedNode(
                fixture.dwindle.findNode(for: token, in: fixture.source), in: fixture.source
            )
        }
        XCTAssertTrue(fixture.manager.confirmManagedFocus(
            token, in: fixture.source, onMonitor: fixture.monitors[0].id, activateWorkspaceOnMonitor: true
        ))
    }

    private func stepDwindleHistoryCommand(_ command: HotkeyCommand, _ fixture: Fixture) {
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(command), .executed)
        fixture.layout()
    }

    private func makeDwindleHistoryNativeFixture(horizontal: Bool = true) throws -> (Fixture, [WindowToken]) {
        let fixture = try makeNativeFixture(
            [.dwindle], orientations: [horizontal ? .horizontal : .vertical],
            frames: [CGRect(x: 137, y: -241, width: horizontal ? 1512 : 912, height: horizontal ? 912 : 1512)]
        )
        let first = addWindow(1, to: fixture.source, fixture)
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            _ = fixture.dwindle.setPreselection(horizontal ? .right : .up, in: fixture.source)
        }
        let second = addWindow(2, to: fixture.source, fixture)
        fixture.controller.motionPolicy.animationsEnabled = false
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            fixture.controller.dwindleLayoutHandler.applyResolvedSettings(
                fixture.controller.resolvedDwindleSettings(for: fixture.monitors[0]), to: fixture.dwindle
            )
        }
        fixture.layout()
        fixture.controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        fixture.controller.hasStartedServices = true
        return (fixture, [first, second])
    }

    private func driveDwindleHistoryNativeResize(
        _ fixture: Fixture, tokens: [WindowToken], deltas: [CGFloat]
    ) throws {
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitors[0])
        let original = dwindleHistoryFrames(fixture, tokens: tokens, cut: area.width / 2)
        let token = tokens[0]
        let start = try XCTUnwrap(original[token])
        let entry = try XCTUnwrap(fixture.manager.entry(for: token))
        var reported = Dictionary(uniqueKeysWithValues: original.map { ($0.key.windowId, $0.value) })
        fixture.handler.nativeWindowFrameProvider = { [reported] in reported[$0.windowId] }
        fixture.controller.axEventHandler.windowInfoProvider = { windowId in
            guard let window = tokens.first(where: { $0.windowId == Int(windowId) }),
                  let frame = original[window] else { return nil }
            return WindowServerInfo(id: windowId, pid: window.pid, level: 0, frame: frame)
        }
        for (window, frame) in original {
            fixture.controller.axManager.confirmFrameWrite(for: window.windowId, frame: frame)
        }
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        let press = CGPoint(x: start.maxX.nextDown, y: start.midY)
        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: press, modifiers: [], windowIdUnderPointer: token.windowId
        ))
        for delta in deltas {
            let pointer = CGPoint(x: press.x + delta, y: press.y)
            fixture.handler.dispatchMouseDragged(at: pointer)
            reported[token.windowId] = CGRect(
                x: start.minX, y: start.minY, width: start.width + delta, height: start.height
            )
            fixture.handler.nativeWindowFrameProvider = { [reported] in reported[$0.windowId] }
            XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: entry))
            fixture.layout()
            XCTAssertEqual(
                fixture.dwindle.currentFrames(in: fixture.source),
                dwindleHistoryFrames(fixture, tokens: tokens, cut: area.width / 2 + delta)
            )
            XCTAssertNotNil(fixture.dwindle.interactiveResize)
            XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).undo, 0)
            XCTAssertEqual(fixture.dwindle.layoutHistoryCounts(in: fixture.source).redo, 0)
        }
        let finalDelta = try XCTUnwrap(deltas.last)
        fixture.handler.dispatchMouseUp(at: CGPoint(x: press.x + finalDelta, y: press.y))
        fixture.layout()
        XCTAssertNil(fixture.dwindle.interactiveResize)
    }

    private func dwindleHistoryFrames(
        _ fixture: Fixture, tokens: [WindowToken], cut: CGFloat, horizontal: Bool = true
    ) -> [WindowToken: CGRect] {
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitors[0])
        let rectangles = [
            CGRect(
                x: area.minX,
                y: area.minY,
                width: horizontal ? cut : area.width,
                height: horizontal ? area.height : cut
            ),
            CGRect(
                x: horizontal ? area.minX + cut : area.minX, y: horizontal ? area.minY : area.minY + cut,
                width: horizontal ? area.width - cut : area.width, height: horizontal ? area.height : area.height - cut
            )
        ]
        return Dictionary(uniqueKeysWithValues: zip(tokens, rectangles).map { token, rectangle in
            (token, DwindleGapCalculator.applyGaps(
                nodeRect: rectangle, tilingArea: area, settings: fixture.dwindle.settings
            ))
        })
    }

    private struct DwindleHistoryRefreshBlocker {
        let task: Task<Void, Never>
        let completion: AsyncStream<Void>.Continuation
    }

    private func blockDwindleHistoryRefreshes(_ fixture: Fixture) -> DwindleHistoryRefreshBlocker {
        let (events, completion) = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            var iterator = events.makeAsyncIterator()
            _ = await iterator.next()
        }
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = task
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout, reason: .layoutCommand, affectedWorkspaceIds: [fixture.source]
        )
        return DwindleHistoryRefreshBlocker(task: task, completion: completion)
    }

    private func unblockDwindleHistoryRefreshes(_ fixture: Fixture, _ blocker: DwindleHistoryRefreshBlocker) {
        blocker.completion.finish()
        blocker.task.cancel()
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = nil
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = nil
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
    }
}
