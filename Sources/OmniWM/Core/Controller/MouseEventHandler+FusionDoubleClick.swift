// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    nonisolated static let fusionDoubleClickArmRadius: CGFloat = 8

    nonisolated static func takesFusionDoubleClick(_ flags: CGEventFlags) -> Bool {
        flags.isDisjoint(with: relevantModifierFlags)
    }

    nonisolated static func asksAboutFusionDoubleClick(
        clickCount: Int64,
        flags: CGEventFlags,
        armedAt: CGPoint?,
        location: CGPoint
    ) -> Bool {
        guard clickCount == 2, takesFusionDoubleClick(flags), let armedAt else { return false }
        return hypot(location.x - armedAt.x, location.y - armedAt.y) <= fusionDoubleClickArmRadius
    }

    nonisolated static let coveringWindowLayers = 0 ..< Int(CGWindowLevelForKey(.dockWindow))

    nonisolated static func topmostWindowId(at location: CGPoint) -> Int? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return topmostWindowId(
            in: windows,
            at: ScreenCoordinateSpace.toWindowServer(point: location),
            ownPid: ProcessInfo.processInfo.processIdentifier
        )
    }

    nonisolated static func topmostWindowId(in windows: [[String: Any]], at point: CGPoint, ownPid: pid_t) -> Int? {
        for window in windows {
            guard let windowId = window[kCGWindowNumber as String] as? Int,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPid,
                  let layer = window[kCGWindowLayer as String] as? Int, coveringWindowLayers.contains(layer),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(point)
            else { continue }
            return windowId
        }
        return nil
    }

    func armFusionDoubleClick(
        at location: CGPoint,
        modifiers: CGEventFlags,
        clickCount: Int64,
        in strip: inout PressedStrip?
    ) {
        var armed = false
        if clickCount == 1, Self.takesFusionDoubleClick(modifiers), let pressed = strip {
            if pressed.layoutKind == .dwindle {
                let hit = dwindlePressHit(at: location, in: pressed.workspaceId)
                strip?.doubleClick = .dwindle(hit)
                armed = hit?.zone != nil
            } else {
                let candidate = lookUpFusionDoubleClickCandidate(at: location, in: pressed)
                armed = candidate != nil
                if pressed.hasEdgePeeks {
                    strip?.doubleClick = .done(candidate)
                }
            }
        }
        let armedAt: CGPoint? = armed ? location : nil
        guard armedAt != inputTapThread.filterSnapshot.fusionDoubleClickArmedAt else { return }
        inputTapThread.updateFilterSnapshot { $0.fusionDoubleClickArmedAt = armedAt }
    }

    func handleFusionDoubleClick(at location: CGPoint, modifiers: CGEventFlags) -> Bool {
        guard Self.takesFusionDoubleClick(modifiers),
              !isInputSuppressed,
              !shouldBlockOwnWindowInput(at: location),
              !state.isMoving, !state.isResizing,
              tapInputs.capturedInteractionButton == nil,
              liveDragSession?.carriedWindow == nil,
              let strip = pressedStrip(at: location)
        else { return false }
        if strip.layoutKind == .dwindle {
            return handleDwindleDoubleClick(at: location, in: strip.workspaceId)
        }
        guard let target = fusionDoubleClickTarget(at: location, in: strip) else { return false }
        clearNativeTitleBarDrag()
        controller?.noteUserAction()
        performFusionDoubleClick(on: target)
        tapInputs.capturedInteractionButton = .left
        return true
    }

    struct FusionDoubleClickCandidate {
        let hit: FusionDoubleClickHit
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let orientation: Monitor.Orientation
    }

    private struct FusionDoubleClickTarget {
        let handle: WindowHandle
        let window: NiriWindow
        let column: NiriContainer
        let workspaceId: WorkspaceDescriptor.ID
        let orientation: Monitor.Orientation
        let zone: FusionDoubleClickZone
    }

    func fusionDoubleClickCandidate(at location: CGPoint, in strip: PressedStrip) -> FusionDoubleClickCandidate? {
        if case let .done(candidate) = strip.doubleClick { return candidate }
        return lookUpFusionDoubleClickCandidate(at: location, in: strip)
    }

    private func lookUpFusionDoubleClickCandidate(
        at location: CGPoint,
        in strip: PressedStrip
    ) -> FusionDoubleClickCandidate? {
        guard strip.layoutKind == .niri,
              let controller,
              canHandleManagedMouseInteraction(controller: controller),
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: strip.workspaceId)
        else { return nil }
        let orientation = resolvedNiriOrientation(engine: engine, workspaceId: strip.workspaceId, monitor: monitor)
        guard let hit = engine.fusionDoubleClickHit(
                  at: location,
                  in: strip.workspaceId,
                  gap: controller.innerGap(for: monitor),
                  bounds: monitor.visibleFrame
              ),
              controller.workspaceManager.entry(for: hit.window.token)?.mode == .tiling
        else { return nil }
        return FusionDoubleClickCandidate(
            hit: hit, engine: engine, workspaceId: strip.workspaceId, orientation: orientation
        )
    }

    private func fusionDoubleClickTarget(at location: CGPoint, in strip: PressedStrip) -> FusionDoubleClickTarget? {
        guard let candidate = lookUpFusionDoubleClickCandidate(at: location, in: strip),
              let handle = controller?.workspaceManager.handle(for: candidate.hit.window.token),
              let column = candidate.engine.column(of: candidate.hit.window)
        else { return nil }
        let pid = candidate.hit.window.token.pid
        let titleBarHit = candidate.hit.zone == .titleBar ? titleBarHitProvider(pid, location) : nil
        if candidate.hit.zone == .titleBar, !TitleBarHitTest.isTitleBar(titleBarHit) {
            return nil
        }
        if case .edge = candidate.hit.zone,
           let topmost = topmostWindowIdProvider(location),
           topmost != candidate.hit.window.token.windowId
        {
            return nil
        }
        return FusionDoubleClickTarget(
            handle: handle,
            window: candidate.hit.window,
            column: column,
            workspaceId: candidate.workspaceId,
            orientation: candidate.orientation,
            zone: candidate.hit.zone
        )
    }

    private func performFusionDoubleClick(on target: FusionDoubleClickTarget) {
        guard let controller, let engine = controller.niriEngine else { return }
        forgetDoubleClickSizesOfGoneColumns(engine: engine, in: target.workspaceId)
        let layout = controller.niriLayoutHandler
        let changeStart = layout.layoutChangeStart(in: target.workspaceId)
        defer { layout.recordLayoutChange(since: changeStart) }
        switch target.zone {
        case .titleBar:
            layout.performWindowSizing(on: .window(target.handle)) { engine, window, context, viewport in
                guard let column = engine.findColumn(containing: window, in: context.workspaceId) else { return nil }
                guard engine.toggleColumnFullSpanAndBack(column, context: context, state: &viewport)
                else { return nil }
                return .containerPrimarySpanChanged
            }
        case let .edge(edge):
            let isPrimary = target.orientation == .horizontal
                ? edge == .left || edge == .right : edge == .bottom || edge == .top
            if isPrimary {
                stretchColumnFromDoubleClick(target, towardTrailingEdge: edge == .right || edge == .top)
            } else if engine.projectedWindows(in: target.column, workspaceId: target.workspaceId).count > 1 {
                toggleTabbedFromDoubleClick(target)
            }
        }
    }

    private func toggleTabbedFromDoubleClick(_ target: FusionDoubleClickTarget) {
        guard let controller, let engine = controller.niriEngine else { return }
        if !target.column.isTabbed {
            controller.workspaceManager.withEngineMutationScope(in: target.workspaceId) {
                engine.activateWindow(target.window.id, in: target.workspaceId)
            }
        }
        controller.niriLayoutHandler.toggleColumnTabbed(target: .window(target.handle))
    }

    private func stretchColumnFromDoubleClick(_ target: FusionDoubleClickTarget, towardTrailingEdge: Bool) {
        guard let controller else { return }
        let columnId = target.column.id
        controller.niriLayoutHandler
            .performWindowSizing(on: .window(target.handle)) { engine, window, context, viewport in
                guard let column = engine.findColumn(containing: window, in: context.workspaceId) else { return nil }
                let horizontal = context.orientation == .horizontal
                let span = horizontal ? column.settledWidth : column.settledHeight
                if let stretch = state.fusionDoubleClickSpans[columnId],
                   stretch.orientation == context.orientation, stretch.towardTrailingEdge == towardTrailingEdge,
                   abs(stretch.stretch.span - span) < 1
                {
                    state.fusionDoubleClickSpans[columnId] = nil
                    engine.stretchColumn(
                        column,
                        to: ColumnStretch(span: stretch.span, keptSideShift: -stretch.stretch.keptSideShift),
                        towardTrailingEdge: towardTrailingEdge,
                        context: context,
                        state: &viewport
                    )
                    stretch.restoreSpecification(on: column)
                    return .containerPrimarySpanChanged
                }
                guard let reach = engine.columnStretchToScreenEdge(
                    column,
                    towardTrailingEdge: towardTrailingEdge,
                    context: context,
                    state: viewport
                ), reach.span > span + 1
                else { return nil }
                state.fusionDoubleClickSpans[columnId] = FusionDoubleClickSpan(
                    workspaceId: context.workspaceId,
                    orientation: context.orientation,
                    towardTrailingEdge: towardTrailingEdge,
                    span: span,
                    spec: horizontal ? column.width : column.height,
                    presetIndex: horizontal ? column.presetWidthIdx : nil,
                    hadManualSpan: horizontal
                        ? column.hasManualSingleWindowWidthOverride : column.hasManualSingleWindowHeightOverride,
                    stretch: reach
                )
                engine.stretchColumn(
                    column,
                    to: reach,
                    towardTrailingEdge: towardTrailingEdge,
                    context: context,
                    state: &viewport
                )
                return .containerPrimarySpanChanged
            }
    }

    private func forgetDoubleClickSizesOfGoneColumns(engine: NiriLayoutEngine, in workspaceId: WorkspaceDescriptor.ID) {
        state.fusionDoubleClickSpans = state.fusionDoubleClickSpans.filter {
            $0.value.workspaceId != workspaceId || engine.findNode(by: $0.key, in: workspaceId) is NiriContainer
        }
    }
}

struct FusionDoubleClickSpan {
    let workspaceId: WorkspaceDescriptor.ID
    let orientation: Monitor.Orientation
    let towardTrailingEdge: Bool
    let span: CGFloat
    let spec: ProportionalSize
    let presetIndex: Int?
    let hadManualSpan: Bool
    let stretch: ColumnStretch

    func restoreSpecification(on column: NiriContainer) {
        if orientation == .horizontal {
            column.width = spec
            column.presetWidthIdx = presetIndex
            column.hasManualSingleWindowWidthOverride = hadManualSpan
        } else {
            column.height = spec
            column.hasManualSingleWindowHeightOverride = hadManualSpan
        }
    }
}
