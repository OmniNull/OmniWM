// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    func activateNode(
        _ node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        options: NodeActivationOptions = NodeActivationOptions()
    ) {
        guard let controller, controller.niriEngine != nil else { return }
        controller.workspaceManager.withEngineMutationScope {
            prepareNodeActivation(node, in: workspaceId, state: &state, options: options)
        }
        completeNodeActivation(node, in: workspaceId, state: state, options: options)
    }

    func prepareNodeActivation(
        _ node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        options: NodeActivationOptions
    ) {
        guard let controller, let engine = controller.niriEngine else { return }

        state.selectedNodeId = node.id
        let usesSingleWindowFit = engine.singleWindowLayoutContext(in: workspaceId) != nil
        if usesSingleWindowFit,
           engine.effectiveSettings(in: workspaceId).edgeOverscroll == .disabled
           || (options.ensureVisible && !options.preserveViewportAnchor)
        {
            if state.activeColumnIndex != 0 || state.viewOffset != 0
                || state.activatePrevColumnOnRemoval != nil || state.viewOffsetToRestore != nil
            {
                resetViewportForSingleWindowFit(state: &state)
            }
        } else if !options.ensureVisible, !options.preserveViewportAnchor {
            rebaseViewportAnchor(to: node, in: workspaceId, state: &state)
        }

        if options.activateWindow {
            engine.activateWindow(node.id, in: workspaceId)
        }

        if !usesSingleWindowFit,
           options.ensureVisible,
           let monitor = controller.workspaceManager.monitor(for: workspaceId)
        {
            let geometry = controller.niriInteractionGeometry(for: monitor)
            engine.ensureSelectionVisible(
                node: node,
                context: .init(
                    workspaceId: workspaceId,
                    motion: controller.motionPolicy.snapshot(),
                    workingFrame: geometry.workingFrame,
                    gaps: geometry.innerGap,
                    orientation: resolvedOrientation(
                        for: workspaceId,
                        monitor: monitor,
                        engine: engine
                    )
                ),
                state: &state
            )
        }

        if options.updateTimestamp, let windowNode = node as? NiriWindow {
            engine.updateFocusTimestamp(for: windowNode.id, in: workspaceId)
        }
    }

    func completeNodeActivation(
        _ node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        options: NodeActivationOptions
    ) {
        guard let controller else { return }

        let focusedToken = (node as? NiriWindow)?.token
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id,
            focusedToken: focusedToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        if options.layoutRefresh {
            let focusToken = options.axFocus ? (node as? NiriWindow)?.token : nil
            requestLayoutCommandRelayout(
                in: workspaceId
            ) { [weak controller] in
                if let focusToken {
                    controller?.focusWindow(focusToken, origin: options.focusOrigin)
                }
            }
            if options.startAnimation, state.hasPendingOffsetAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
            }
        } else {
            if options.axFocus, let windowNode = node as? NiriWindow {
                controller.focusWindow(windowNode.token, origin: options.focusOrigin)
            }
            if options.startAnimation, state.hasPendingOffsetAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
            }
        }
    }

    private func rebaseViewportAnchor(
        to node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        guard let column = engine.column(of: node) else { return }
        let columns = engine.columns(in: workspaceId)
        guard let targetIndex = columns.firstIndex(where: { $0 === column }) else { return }
        let currentIndex = min(max(state.activeColumnIndex, 0), columns.count - 1)
        guard currentIndex != targetIndex else { return }

        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else {
            state.activeColumnIndex = targetIndex
            return
        }

        let gap = controller.innerGap(for: monitor)
        let workingFrame = controller.niriWorkingFrame(for: monitor)
        let orientation = controller.settings.monitors.effectiveOrientation(for: monitor)

        switch orientation {
        case .horizontal:
            for column in columns where column.cachedWidth <= 0 {
                column.resolveAndCacheWidth(
                    workingAreaWidth: workingFrame.width,
                    gaps: gap,
                    contentInset: engine.tabContentInset(for: column)
                )
            }
            rebaseViewportAnchor(
                indices: (from: currentIndex, to: targetIndex),
                columns: columns,
                gap: gap,
                state: &state,
                sizeKeyPath: \.cachedWidth
            )
        case .vertical:
            for column in columns where column.cachedHeight <= 0 {
                column.resolveAndCacheHeight(workingAreaHeight: workingFrame.height, gaps: gap)
            }
            rebaseViewportAnchor(
                indices: (from: currentIndex, to: targetIndex),
                columns: columns,
                gap: gap,
                state: &state,
                sizeKeyPath: \.cachedHeight
            )
        }
    }

    private func rebaseViewportAnchor(
        indices: (from: Int, to: Int),
        columns: [NiriContainer],
        gap: CGFloat,
        state: inout ViewportState,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) {
        let previousPosition = state.containerPosition(
            at: indices.from,
            containers: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        let targetPosition = state.containerPosition(
            at: indices.to,
            containers: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        state.rebaseOffset(by: previousPosition - targetPosition)
        state.activeColumnIndex = indices.to
    }
}
