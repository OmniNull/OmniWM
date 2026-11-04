// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    nonisolated static let fusionDoubleClickArmRadius: CGFloat = 8
    nonisolated static let fusionClickChainWindow: TimeInterval = 1

    nonisolated static func fusionClickCyclesForwards(_ flags: CGEventFlags) -> Bool? {
        let modifiers = flags.intersection(relevantModifierFlags)
        if modifiers.isEmpty { return true }
        return modifiers == .maskShift ? false : nil
    }

    nonisolated static func asksAboutFusionDoubleClick(
        clickCount: Int64,
        flags: CGEventFlags,
        macOSFusion: Bool,
        armedAt: CGPoint?,
        location: CGPoint
    ) -> Bool {
        guard clickCount == 2, macOSFusion, fusionClickCyclesForwards(flags) != nil,
              let armedAt
        else { return false }
        return hypot(location.x - armedAt.x, location.y - armedAt.y) <= fusionDoubleClickArmRadius
    }

    nonisolated static func continuesFusionClickChain(
        _ chain: FusionClickChain?,
        flags: CGEventFlags,
        location: CGPoint,
        now: TimeInterval
    ) -> Bool {
        guard let chain, now <= chain.deadline, fusionClickCyclesForwards(flags) != nil else { return false }
        return hypot(location.x - chain.location.x, location.y - chain.location.y) <= fusionDoubleClickArmRadius
    }

    func continuesFusionClickChain(at location: CGPoint, modifiers: CGEventFlags) -> Bool {
        Self.continuesFusionClickChain(
            state.fusionClickChain,
            flags: modifiers,
            location: location,
            now: fusionClickClock()
        )
    }

    func disarmFusionClickChain() {
        guard state.fusionClickChain != nil else { return }
        state.fusionClickChain = nil
        state.fusionClickChainToken = nil
        inputTapThread.updateFilterSnapshot { $0.fusionClickChain = nil }
    }

    private func armFusionClickChain(at location: CGPoint, token: WindowToken) {
        let chain = FusionClickChain(location: location, deadline: fusionClickClock() + Self.fusionClickChainWindow)
        state.fusionClickChain = chain
        state.fusionClickChainToken = token
        inputTapThread.updateFilterSnapshot { $0.fusionClickChain = chain }
    }

    func armFusionDoubleClick(at location: CGPoint, modifiers: CGEventFlags, clickCount: Int64) {
        let armed = clickCount == 1
            && Self.fusionClickCyclesForwards(modifiers) != nil
            && fusionDoubleClickCandidate(at: location) != nil
        let armedAt: CGPoint? = armed ? location : nil
        guard armedAt != inputTapThread.filterSnapshot.fusionDoubleClickArmedAt else { return }
        inputTapThread.updateFilterSnapshot { $0.fusionDoubleClickArmedAt = armedAt }
    }

    func handleFusionDoubleClick(at location: CGPoint, modifiers: CGEventFlags, chained: Bool = false) -> Bool {
        guard let forwards = Self.fusionClickCyclesForwards(modifiers),
              !isInputSuppressed,
              !shouldBlockOwnWindowInput(at: location)
        else { return false }
        guard let target = fusionDoubleClickTarget(at: location),
              !chained || target.zone == .titleBar && target.window.token == state.fusionClickChainToken,
              forwards || target.zone == .titleBar && target.isBareTitleBar
        else { return false }
        clearNativeTitleBarDrag()
        performFusionDoubleClick(on: target, forwards: forwards)
        if target.zone == .titleBar {
            armFusionClickChain(at: location, token: target.window.token)
        } else {
            disarmFusionClickChain()
        }
        state.capturedInteractionButton = .left
        return true
    }

    private struct FusionDoubleClickCandidate {
        let hit: FusionDoubleClickHit
        let entry: WindowState
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
    }

    private struct FusionDoubleClickTarget {
        let handle: WindowHandle
        let window: NiriWindow
        let column: NiriContainer
        let workspaceId: WorkspaceDescriptor.ID
        let zone: FusionDoubleClickZone
        let isBareTitleBar: Bool
        let projectedWindowCount: Int
    }

    private func fusionDoubleClickCandidate(at location: CGPoint) -> FusionDoubleClickCandidate? {
        guard let controller,
              controller.settings.niri.macOSFusion,
              canHandleManagedMouseInteraction(controller: controller),
              let engine = controller.niriEngine,
              let workspaceId = workspaceIdForPointer(at: location),
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              resolvedNiriOrientation(engine: engine, workspaceId: workspaceId, monitor: monitor) == .horizontal,
              let hit = engine.fusionDoubleClickHit(
                  at: location,
                  in: workspaceId,
                  gap: controller.niriInteractionGeometry(for: monitor).innerGap,
                  bounds: monitor.visibleFrame
              ),
              let entry = controller.workspaceManager.entry(for: hit.window.token),
              entry.mode == .tiling
        else { return nil }
        return FusionDoubleClickCandidate(hit: hit, entry: entry, engine: engine, workspaceId: workspaceId)
    }

    func holdsTitleBarDragStill(at location: CGPoint, windowIdUnderPointer: Int? = nil) -> Bool {
        guard let candidate = fusionDoubleClickCandidate(at: location),
              candidate.hit.zone == .titleBar,
              windowIdUnderPointer == nil || windowIdUnderPointer == candidate.entry.windowId,
              TitleBarHitTest.isBareTitleBar(titleBarHitProvider(candidate.entry.pid, location))
        else { return false }
        MouseTrace.record("title-bar drag held still token=\(TraceFormat.token(candidate.entry.token))")
        return true
    }

    private func fusionDoubleClickTarget(at location: CGPoint) -> FusionDoubleClickTarget? {
        guard !state.isMoving, !state.isResizing,
              state.capturedInteractionButton == nil,
              state.liveTabPull == nil,
              let candidate = fusionDoubleClickCandidate(at: location),
              let handle = controller?.workspaceManager.handle(for: candidate.hit.window.token),
              let column = candidate.engine.column(of: candidate.hit.window)
        else { return nil }
        let titleBarHit = candidate.hit.zone == .titleBar ? titleBarHitProvider(candidate.entry.pid, location) : nil
        if candidate.hit.zone == .titleBar, !TitleBarHitTest.isTitleBar(titleBarHit) {
            return nil
        }
        return FusionDoubleClickTarget(
            handle: handle,
            window: candidate.hit.window,
            column: column,
            workspaceId: candidate.workspaceId,
            zone: candidate.hit.zone,
            isBareTitleBar: TitleBarHitTest.isBareTitleBar(titleBarHit),
            projectedWindowCount: candidate.engine.projectedWindows(in: column, workspaceId: candidate.workspaceId)
                .count
        )
    }

    private func performFusionDoubleClick(on target: FusionDoubleClickTarget, forwards: Bool) {
        guard let controller, let engine = controller.niriEngine else { return }
        forgetDoubleClickSizesOfGoneWindows(engine: engine, in: target.workspaceId)
        let layout = controller.niriLayoutHandler
        let changeStart = layout.layoutChangeStart(in: target.workspaceId)
        defer { layout.recordLayoutChange(since: changeStart) }
        switch target.zone {
        case .titleBar:
            layout.performWindowSizing(on: .window(target.handle)) { engine, window, context, viewport in
                guard let column = engine.findColumn(containing: window, in: context.workspaceId) else { return nil }
                engine.cycleColumnWidthAroundCentre(column, forwards: forwards, context: context, state: &viewport)
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

    private func toggleTabbedFromDoubleClick(_ target: FusionDoubleClickTarget) {
        guard let controller, let engine = controller.niriEngine else { return }
        if !target.column.isTabbed {
            controller.workspaceManager.withEngineMutationScope(in: target.workspaceId) {
                engine.activateWindow(target.window.id, in: target.workspaceId)
            }
        }
        controller.niriLayoutHandler.toggleColumnTabbed(target: .window(target.handle))
    }

    private func stretchColumnFromDoubleClick(_ target: FusionDoubleClickTarget, rightSide: Bool) {
        guard let controller else { return }
        let columnId = target.column.id
        controller.niriLayoutHandler
            .performWindowSizing(on: .window(target.handle)) { engine, window, context, viewport in
                guard let column = engine.findColumn(containing: window, in: context.workspaceId) else { return nil }
                let width = column.targetWidth ?? column.cachedWidth
                if let stretch = state.fusionDoubleClickWidths[columnId],
                   stretch.rightSide == rightSide, abs(stretch.stretch.width - width) < 1
                {
                    state.fusionDoubleClickWidths[columnId] = nil
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
                state.fusionDoubleClickWidths[columnId] = FusionDoubleClickWidth(
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

    private func toggleFullHeightFromDoubleClick(_ target: FusionDoubleClickTarget) {
        guard let controller else { return }
        let token = target.window.token
        let layout = controller.niriLayoutHandler
        if !target.window.height.isAuto {
            let height = target.window.height
            let restsAtTop = target.window.restsAtTop(of: target.column)
            guard layout.resetWindowSecondarySpan(target: .window(target.handle)) else { return }
            state.fusionDoubleClickHeights[token] = FusionDoubleClickHeight(
                height: height,
                revision: target.window.heightRevision,
                restsAtTop: restsAtTop
            )
            return
        }
        guard let remembered = state.fusionDoubleClickHeights.removeValue(forKey: token),
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
        state.fusionDoubleClickHeights = state.fusionDoubleClickHeights.filter {
            controller.workspaceManager.entry(for: $0.key) != nil
        }
        state.fusionDoubleClickWidths = state.fusionDoubleClickWidths.filter {
            $0.value.workspaceId != workspaceId || engine.findNode(by: $0.key, in: workspaceId) is NiriContainer
        }
    }
}

struct FusionDoubleClickHeight {
    let height: WeightedSize
    let revision: Int
    let restsAtTop: Bool
}

struct FusionDoubleClickWidth {
    let workspaceId: WorkspaceDescriptor.ID
    let rightSide: Bool
    let width: CGFloat
    let spec: ProportionalSize
    let presetIndex: Int?
    let hadManualWidth: Bool
    let stretch: ColumnStretch
}

struct FusionClickChain: Sendable, Equatable {
    let location: CGPoint
    let deadline: TimeInterval
}
