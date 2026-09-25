// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

private let mouseWheelAxisEpsilon: CGFloat = 0.001

extension MouseEventHandler {
    private struct MouseWheelColumnDelta {
        var axis: MouseWheelColumnAxis
        var value: CGFloat
    }

    private enum MouseWheelColumnAxis {
        case horizontal
        case vertical
    }

    func handleScrollWheelFromTap(_ payload: MouseScrollIntake) {
        let modifiers = payload.modifiers
        guard let controller else { return }
        guard canHandleMouseWheel(controller: controller, at: payload.location) else { return }

        let isTrackpad = payload.momentumPhase != 0 || payload.phase != 0
        if isTrackpad {
            return
        }

        let requiredModifiers = controller.settings.gestures.scrollModifierKey.cgEventFlag
        guard Self.mouseWheelModifiersMatch(modifiers, required: requiredModifiers) else {
            resetMouseWheelTrackers()
            return
        }

        guard let columnDelta = Self.resolvedMouseWheelColumnDelta(
            deltaX: payload.deltaX,
            deltaY: payload.deltaY,
            allowVerticalFallback: modifiers.contains(.maskShift)
        ) else { return }
        guard let context = resolveScrollContext(at: payload.location) else { return }

        let ticks: Int
        switch columnDelta.axis {
        case .horizontal:
            ticks = state.horizontalWheelTracker.accumulate(columnDelta.value)
        case .vertical:
            ticks = state.verticalWheelTracker.accumulate(columnDelta.value)
        }
        guard ticks != 0 else { return }

        applyMouseWheelColumnTicks(
            ticks,
            engine: context.engine,
            wsId: context.wsId,
            monitor: context.monitor
        )
    }

    private func canHandleMouseWheel(controller: WMController, at location: CGPoint) -> Bool {
        guard controller.isEnabled else {
            cancelActiveMouseInteraction()
            return false
        }
        guard controller.settings.gestures.scrollEnabled else { return false }
        if controller.isOverviewOpen() {
            cancelActiveMouseInteraction()
            return false
        }
        if shouldBlockOwnWindowInput(at: location) { return false }
        guard !state.isResizing, !state.isMoving else { return false }

        return true
    }

    private func applyMouseWheelColumnTicks(
        _ ticks: Int,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) {
        guard let controller else { return }
        let geometry = controller.niriInteractionGeometry(for: monitor)
        let step = ticks > 0 ? 1 : -1
        let motion = controller.motionPolicy.snapshot()
        let orientation = resolvedNiriOrientation(
            engine: engine,
            workspaceId: wsId,
            monitor: monitor
        )

        if controller.workspaceManager.animationDriver.trackpadGestureActive(in: wsId) {
            return
        }

        let context = NiriInteractionContext(
            workspaceId: wsId,
            motion: motion,
            workingFrame: geometry.workingFrame,
            gaps: geometry.innerGap,
            orientation: orientation
        )
        let columns = engine.projectedColumns(in: wsId)
        var didApply = false
        var shouldStartAnimation = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            for _ in 0 ..< abs(ticks) {
                guard advanceMouseWheelColumn(
                    step: step, engine: engine, columns: columns, context: context, viewportState: &vstate
                ) else { break }
                didApply = true
            }
            shouldStartAnimation = vstate.hasPendingOffsetAnimation
        }

        if didApply {
            controller.niriLayoutHandler.focusSelectedWindowAndRequestRelayout(
                in: wsId, raisesWindow: false, defersRetryRaise: true
            )
            if shouldStartAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: wsId)
            }
        }
    }

    private func advanceMouseWheelColumn(
        step: Int, engine: NiriLayoutEngine, columns: [NiriProjectedColumn], context: NiriInteractionContext,
        viewportState: inout ViewportState
    ) -> Bool {
        guard let controller else { return false }
        let activeColumnIndex = engine.projectedActiveColumnIndex(
            state: viewportState,
            columns: columns,
            in: context.workspaceId
        )
        let targetColumnIndex = activeColumnIndex + step
        guard columns.indices.contains(targetColumnIndex),
              let currentNode = currentSelectionNode(
                  engine: engine,
                  wsId: context.workspaceId,
                  state: viewportState,
                  columns: columns
              ),
              let newNode = engine.focusColumn(
                  targetColumnIndex,
                  currentSelection: currentNode,
                  context: context,
                  state: &viewportState
              )
        else {
            return false
        }

        controller.niriLayoutHandler.activateNode(
            newNode,
            in: context.workspaceId,
            state: &viewportState,
            options: .init(
                activateWindow: true,
                ensureVisible: false,
                updateTimestamp: true,
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        )
        return true
    }

    nonisolated static func resolvedWheelAxisDelta(
        pointDelta: CGFloat, fixedPointDelta: CGFloat, isContinuous: Bool
    ) -> CGFloat {
        let delta = abs(pointDelta) > mouseWheelAxisEpsilon ? pointDelta : fixedPointDelta
        guard !isContinuous, abs(delta) > mouseWheelAxisEpsilon else { return delta }
        return delta > 0 ? niriWheelScrollTickAmount : -niriWheelScrollTickAmount
    }

    nonisolated static func mouseWheelModifiersMatch(_ modifiers: CGEventFlags, required: CGEventFlags) -> Bool {
        modifierFlagsMatch(modifiers, required: required)
    }

    private nonisolated static func resolvedMouseWheelColumnDelta(
        deltaX: CGFloat,
        deltaY: CGFloat,
        allowVerticalFallback: Bool
    ) -> MouseWheelColumnDelta? {
        if abs(deltaX) > mouseWheelAxisEpsilon {
            return MouseWheelColumnDelta(axis: .horizontal, value: deltaX)
        }
        guard allowVerticalFallback else {
            return nil
        }
        guard abs(deltaY) > mouseWheelAxisEpsilon else {
            return nil
        }
        return MouseWheelColumnDelta(axis: .vertical, value: deltaY)
    }
}
