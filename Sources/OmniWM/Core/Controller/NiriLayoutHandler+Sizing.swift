// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    func toggleFullscreen() {
        performWindowSizing(on: .focused) { engine, windowNode, context, state in
            engine.toggleFullscreen(windowNode, motion: context.motion, state: &state)
            if windowNode.sizingMode == .normal {
                engine.recoverSettledCoverage(context: context, state: &state)
            }
            return .fullscreenToggled(token: windowNode.token)
        }
    }

    func cycleSize(forward: Bool) {
        cycleContainerPrimarySpan(forward: forward)
    }

    @discardableResult
    func cycleContainerPrimarySpan(forward: Bool, target: WindowTarget = .focused) -> Bool {
        performWindowSizing(on: target) { engine, windowNode, context, state in
            guard let column = engine.findColumn(containing: windowNode, in: context.workspaceId) else { return nil }
            engine.toggleContainerPrimarySpan(column, forwards: forward, context: context, state: &state)
            return .containerPrimarySpanChanged
        }
    }

    @discardableResult
    func cycleWindowPrimarySpan(forward: Bool, target: WindowTarget = .focused) -> Bool {
        performWindowSizing(on: target) { engine, windowNode, context, state in
            engine.toggleWindowPrimarySpan(windowNode, forwards: forward, context: context, state: &state)
            return .windowSizeChanged(token: windowNode.token)
        }
    }

    @discardableResult
    func cycleWindowSecondarySpan(forward: Bool, target: WindowTarget = .focused) -> Bool {
        performWindowSizing(on: target) { engine, windowNode, context, _ in
            engine.toggleWindowSecondarySpan(
                windowNode,
                forwards: forward,
                in: context.workspaceId,
                geometry: NiriSizingGeometry(
                    workingFrame: context.workingFrame,
                    gaps: context.gaps,
                    orientation: context.orientation
                )
            )
            return .windowSizeChanged(token: windowNode.token)
        }
    }

    @discardableResult
    func toggleContainerFullPrimarySpan(target: WindowTarget = .focused) -> Bool {
        performWindowSizing(on: target) { engine, windowNode, context, state in
            guard let column = engine.findColumn(containing: windowNode, in: context.workspaceId) else { return nil }
            engine.toggleContainerFullPrimarySpan(column, context: context, state: &state)
            return .containerPrimarySpanChanged
        }
    }

    func expandContainerToAvailablePrimarySpan() {
        performWindowSizing(on: .focused) { engine, windowNode, context, state in
            guard let column = engine.findColumn(containing: windowNode, in: context.workspaceId) else { return nil }
            engine.expandContainerToAvailablePrimarySpan(column, context: context, state: &state)
            return .containerPrimarySpanChanged
        }
    }

    @discardableResult
    func resetWindowSecondarySpan(target: WindowTarget = .focused) -> Bool {
        performWindowSizing(on: target) { engine, windowNode, context, _ in
            engine.resetWindowSecondarySpan(windowNode, in: context.workspaceId, orientation: context.orientation)
            return .windowSizeChanged(token: windowNode.token)
        }
    }

    func centerColumn() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard engine.centerColumn(
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state
            ) else { return }

            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func centerVisibleColumns() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard engine.centerVisibleColumns(
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state
            ) else { return }

            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    @discardableResult
    func setContainerPrimarySpan(_ change: NiriSizeChange, target: WindowTarget = .focused) -> Bool {
        performWindowSizing(on: target) { engine, windowNode, context, state in
            guard let column = engine.findColumn(containing: windowNode, in: context.workspaceId) else { return nil }
            engine.setContainerPrimarySpan(column, change: change, context: context, state: &state)
            return .containerPrimarySpanChanged
        }
    }

    @discardableResult
    func setWindowPrimarySpan(_ change: NiriSizeChange, target: WindowTarget = .focused) -> Bool {
        performWindowSizing(on: target) { engine, windowNode, context, state in
            engine.setWindowPrimarySpan(windowNode, change: change, context: context, state: &state)
            return .windowSizeChanged(token: windowNode.token)
        }
    }

    @discardableResult
    func setWindowSecondarySpan(_ change: NiriSizeChange, target: WindowTarget = .focused) -> Bool {
        performWindowSizing(on: target) { engine, windowNode, context, _ in
            engine.setWindowSecondarySpan(
                windowNode,
                change: change,
                in: context.workspaceId,
                geometry: NiriSizingGeometry(
                    workingFrame: context.workingFrame,
                    gaps: context.gaps,
                    orientation: context.orientation
                )
            )
            return .windowSizeChanged(token: windowNode.token)
        }
    }

    func balanceSizes() {
        withNiriWorkspaceContext { engine, wsId, motion, state, _, workingFrame, gaps, orientation in
            guard engine.balanceSizes(
                in: wsId,
                motion: motion,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            ) else { return }
            engine.recoverSettledCoverage(
                context: .init(
                    workspaceId: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ),
                state: &state
            )
            recordLayoutOperation(.sizesBalanced, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
        }
    }

    func balanceSizesAllWorkspaces() {
        guard let controller else { return }
        var changed: Set<WorkspaceDescriptor.ID> = []
        for descriptor in controller.workspaceManager.workspaces {
            guard controller.settings.workspaces.layoutType(for: descriptor.name) != .dwindle else { continue }
            withNiriWorkspaceContext(for: descriptor.id) {
                engine, wsId, motion, state, _, workingFrame, gaps, orientation in
                guard engine.balanceSizes(
                    in: wsId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                ) else { return }
                engine.recoverSettledCoverage(
                    context: .init(
                        workspaceId: wsId,
                        motion: motion,
                        workingFrame: workingFrame,
                        gaps: gaps,
                        orientation: orientation
                    ),
                    state: &state
                )
                changed.insert(wsId)
                recordLayoutOperation(.sizesBalanced, in: wsId)
                startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
            }
        }
        if !changed.isEmpty {
            controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: changed)
        }
    }

    @discardableResult
    private func performWindowSizing(
        on target: WindowTarget,
        _ operation: (NiriLayoutEngine, NiriWindow, NiriInteractionContext, inout ViewportState) -> LayoutOperation?
    ) -> Bool {
        var performed = false
        withNiriWindowContext(target) { engine, windowNode, context, state in
            guard let layoutOperation = operation(engine, windowNode, context, &state) else { return }
            let workspaceId = context.workspaceId
            recordLayoutOperation(layoutOperation, in: workspaceId)
            requestLayoutCommandRelayout(in: workspaceId)
            startScrollAnimationIfNeeded(for: workspaceId, state: state, engine: engine)
            performed = true
        }
        return performed
    }
}
