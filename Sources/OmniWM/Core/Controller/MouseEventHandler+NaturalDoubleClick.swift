// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    nonisolated static let naturalDoubleClickArmRadius: CGFloat = 8

    nonisolated static func asksAboutNaturalDoubleClick(
        clickCount: Int64,
        flags: CGEventFlags,
        naturalWindowDrag: Bool,
        armedAt: CGPoint?,
        location: CGPoint
    ) -> Bool {
        guard clickCount == 2, naturalWindowDrag, flags.isDisjoint(with: relevantModifierFlags),
              let armedAt
        else { return false }
        return hypot(location.x - armedAt.x, location.y - armedAt.y) <= naturalDoubleClickArmRadius
    }

    func armNaturalDoubleClick(at location: CGPoint, modifiers: CGEventFlags, clickCount: Int64) {
        let armed = clickCount == 1
            && modifiers.isDisjoint(with: Self.relevantModifierFlags)
            && naturalDoubleClickCandidate(at: location) != nil
        let armedAt: CGPoint? = armed ? location : nil
        inputTapThread.updateFilterSnapshot { $0.naturalDoubleClickArmedAt = armedAt }
    }

    func handleNaturalDoubleClick(at location: CGPoint, modifiers: CGEventFlags) -> Bool {
        guard modifiers.isDisjoint(with: Self.relevantModifierFlags),
              !isInputSuppressed,
              !shouldBlockOwnWindowInput(at: location)
        else { return false }
        guard let target = naturalDoubleClickTarget(at: location) else { return false }
        clearNativeTitleBarDrag()
        performNaturalDoubleClick(on: target)
        state.capturedInteractionButton = .left
        return true
    }

    private struct NaturalDoubleClickCandidate {
        let hit: NaturalDoubleClickHit
        let entry: WindowState
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
    }

    private struct NaturalDoubleClickTarget {
        let handle: WindowHandle
        let window: NiriWindow
        let column: NiriContainer
        let workspaceId: WorkspaceDescriptor.ID
        let zone: NaturalDoubleClickZone
        let projectedWindowCount: Int
    }

    private func naturalDoubleClickCandidate(at location: CGPoint) -> NaturalDoubleClickCandidate? {
        guard let controller,
              controller.settings.niri.naturalWindowDrag,
              canHandleManagedMouseInteraction(controller: controller),
              let engine = controller.niriEngine,
              let workspaceId = workspaceIdForPointer(at: location),
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              resolvedNiriOrientation(engine: engine, workspaceId: workspaceId, monitor: monitor) == .horizontal,
              let hit = engine.naturalDoubleClickHit(
                  at: location,
                  in: workspaceId,
                  gap: controller.niriInteractionGeometry(for: monitor).innerGap,
                  bounds: monitor.visibleFrame
              ),
              let entry = controller.workspaceManager.entry(for: hit.window.token),
              entry.mode == .tiling
        else { return nil }
        return NaturalDoubleClickCandidate(hit: hit, entry: entry, engine: engine, workspaceId: workspaceId)
    }

    private func naturalDoubleClickTarget(at location: CGPoint) -> NaturalDoubleClickTarget? {
        guard !state.isMoving, !state.isResizing,
              state.capturedInteractionButton == nil,
              state.liveTabPull == nil,
              let candidate = naturalDoubleClickCandidate(at: location),
              let handle = controller?.workspaceManager.handle(for: candidate.hit.window.token),
              let column = candidate.engine.column(of: candidate.hit.window)
        else { return nil }
        if candidate.hit.zone == .titleBar,
           !TitleBarHitTest.isTitleBar(titleBarHitProvider(candidate.entry.pid, location))
        {
            return nil
        }
        return NaturalDoubleClickTarget(
            handle: handle,
            window: candidate.hit.window,
            column: column,
            workspaceId: candidate.workspaceId,
            zone: candidate.hit.zone,
            projectedWindowCount: candidate.engine.projectedWindows(in: column, workspaceId: candidate.workspaceId)
                .count
        )
    }

    private func performNaturalDoubleClick(on target: NaturalDoubleClickTarget) {
        guard let controller, let engine = controller.niriEngine else { return }
        forgetDoubleClickSizesOfGoneWindows(engine: engine, in: target.workspaceId)
        let layout = controller.niriLayoutHandler
        switch target.zone {
        case .titleBar:
            layout.performWindowSizing(on: .window(target.handle)) { engine, window, context, viewport in
                guard let column = engine.findColumn(containing: window, in: context.workspaceId) else { return nil }
                engine.cycleColumnWidthAroundCentre(column, context: context, state: &viewport)
                return .containerPrimarySpanChanged
            }
        case .edge(.left):
            stretchColumnFromDoubleClick(target, rightSide: false)
        case .edge(.right):
            stretchColumnFromDoubleClick(target, rightSide: true)
        case .edge:
            if target.projectedWindowCount > 1 {
                toggleTabbedFromDoubleClick(target)
            } else {
                toggleFullHeightFromDoubleClick(target)
            }
        }
    }

    private func toggleTabbedFromDoubleClick(_ target: NaturalDoubleClickTarget) {
        guard let controller, let engine = controller.niriEngine else { return }
        if !target.column.isTabbed {
            controller.workspaceManager.withEngineMutationScope(in: target.workspaceId) {
                engine.activateWindow(target.window.id, in: target.workspaceId)
            }
        }
        controller.niriLayoutHandler.toggleColumnTabbed(target: .window(target.handle))
    }

    private func stretchColumnFromDoubleClick(_ target: NaturalDoubleClickTarget, rightSide: Bool) {
        guard let controller else { return }
        let columnId = target.column.id
        controller.niriLayoutHandler
            .performWindowSizing(on: .window(target.handle)) { engine, window, context, viewport in
                guard let column = engine.findColumn(containing: window, in: context.workspaceId) else { return nil }
                let width = column.targetWidth ?? column.cachedWidth
                if let stretch = state.naturalDoubleClickWidths[columnId],
                   stretch.rightSide == rightSide, abs(stretch.stretch.width - width) < 1
                {
                    state.naturalDoubleClickWidths[columnId] = nil
                    engine.stretchColumn(
                        column,
                        to: ColumnStretch(width: stretch.width, keptSideShift: -stretch.stretch.keptSideShift),
                        rightSide: rightSide,
                        context: context,
                        state: &viewport
                    )
                    column.width = stretch.spec
                    column.presetWidthIdx = stretch.presetIndex
                    column.hasManualSingleWindowWidthOverride = stretch.hadManualWidth
                    return .containerPrimarySpanChanged
                }
                guard let reach = engine.columnStretchToScreenEdge(
                    column,
                    rightSide: rightSide,
                    context: context,
                    state: viewport
                ), reach.width > width + 1
                else { return nil }
                state.naturalDoubleClickWidths[columnId] = NaturalDoubleClickWidth(
                    workspaceId: context.workspaceId,
                    rightSide: rightSide,
                    width: width,
                    spec: column.width,
                    presetIndex: column.presetWidthIdx,
                    hadManualWidth: column.hasManualSingleWindowWidthOverride,
                    stretch: reach
                )
                engine.stretchColumn(column, to: reach, rightSide: rightSide, context: context, state: &viewport)
                return .containerPrimarySpanChanged
            }
    }

    private func toggleFullHeightFromDoubleClick(_ target: NaturalDoubleClickTarget) {
        guard let controller else { return }
        let token = target.window.token
        let layout = controller.niriLayoutHandler
        if !target.window.height.isAuto {
            let height = target.window.height
            let restsAtTop = target.window.restsAtTop(of: target.column)
            guard layout.resetWindowSecondarySpan(target: .window(target.handle)) else { return }
            state.naturalDoubleClickHeights[token] = NaturalDoubleClickHeight(
                height: height,
                revision: target.window.heightRevision,
                restsAtTop: restsAtTop
            )
            return
        }
        guard let remembered = state.naturalDoubleClickHeights.removeValue(forKey: token),
              remembered.revision == target.window.heightRevision
        else { return }
        layout.performWindowSizing(on: .window(target.handle)) { _, window, _, _ in
            window.height = remembered.height
            window.rest(atTop: remembered.restsAtTop, in: target.column)
            return .windowSizeChanged(token: window.token)
        }
    }

    private func forgetDoubleClickSizesOfGoneWindows(engine: NiriLayoutEngine, in workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        state.naturalDoubleClickHeights = state.naturalDoubleClickHeights.filter {
            controller.workspaceManager.entry(for: $0.key) != nil
        }
        state.naturalDoubleClickWidths = state.naturalDoubleClickWidths.filter {
            $0.value.workspaceId != workspaceId || engine.findNode(by: $0.key, in: workspaceId) is NiriContainer
        }
    }
}

struct NaturalDoubleClickHeight {
    let height: WeightedSize
    let revision: Int
    let restsAtTop: Bool
}

struct NaturalDoubleClickWidth {
    let workspaceId: WorkspaceDescriptor.ID
    let rightSide: Bool
    let width: CGFloat
    let spec: ProportionalSize
    let presetIndex: Int?
    let hadManualWidth: Bool
    let stretch: ColumnStretch
}
