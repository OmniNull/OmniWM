// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

extension NiriLayoutHandler {
    func edgePictureState(for input: WorkspaceRefreshInput) -> NiriEdgePictureState {
        guard input.isActiveWorkspace, input.monitor.orientation == .vertical, let controller else { return .none }
        let available = ScreenCapturePermissionMonitor.shared.isGranted
        let cached = controller.niriEdgePictures.readyTokens
        var ready: Set<WindowToken> = []
        var parkedAbove: Set<WindowToken> = []
        var parkedBelow: Set<WindowToken> = []
        for window in input.windows where !window.isNativeFullscreenSuspended
            && !input.excludedTokens.contains(window.token)
            && controller.workspaceManager.entry(for: window.token)?.axRef != nil
        {
            if available, cached.contains(window.token) { ready.insert(window.token) }
            if window.hiddenState?.offscreenSide == AxisHideEdge.maximum.encodedHideSide {
                parkedAbove.insert(window.token)
            } else if window.hiddenState?.offscreenSide == AxisHideEdge.minimum.encodedHideSide {
                parkedBelow.insert(window.token)
            }
        }
        return NiriEdgePictureState(
            isAvailable: available, readyTokens: ready, parkedAboveTokens: parkedAbove, parkedBelowTokens: parkedBelow
        )
    }

    func picturePreferredFocus(
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        pictures: NiriEdgePictureState,
        isRelayout: Bool
    ) -> WindowToken? {
        guard isRelayout, let controller else { return nil }
        if let selectedId = state.selectedNodeId,
           let selected = controller.niriEngine?.findNode(by: selectedId, in: workspaceId) as? NiriWindow,
           pictures.parkedAboveTokens.contains(selected.token) || pictures.parkedBelowTokens.contains(selected.token)
        {
            return selected.token
        }
        return controller.workspaceManager.preferredFocusToken(in: workspaceId)
    }

    func shouldPreparePictures(snapshot: NiriWorkspaceSnapshot, animationTime: TimeInterval?) -> Bool {
        guard snapshot.isActiveWorkspace, snapshot.monitor.orientation == .vertical,
              snapshot.edgePictures.isAvailable else { return false }
        guard animationTime != nil else { return true }
        guard let controller else { return false }
        return controller.workspaceManager.animationDriver.hasGesture(in: snapshot.workspaceId)
            || controller.niriEdgePictures.needsMotionPreparation(in: snapshot.workspaceId)
    }

    func picturePreparation(
        engine: NiriLayoutEngine,
        snapshot: NiriWorkspaceSnapshot,
        state: ViewportState,
        isSettled: Bool,
        time: TimeInterval = CACurrentMediaTime()
    ) -> NiriPicturePreparation? {
        guard snapshot.isActiveWorkspace, snapshot.monitor.orientation == .vertical,
              snapshot.edgePictures.isAvailable,
              engine.interactiveResize?.workspaceId != snapshot.workspaceId
        else { return nil }
        let columns = engine.projectedColumns(in: snapshot.workspaceId)
        guard !columns.isEmpty else { return nil }
        let activeIndex = engine.projectedActiveColumnIndex(state: state, columns: columns, in: snapshot.workspaceId)
        let geometry = pictureColumnGeometry(
            columns: columns, activeIndex: activeIndex, state: state, snapshot: snapshot, time: time,
            isSettled: isSettled
        )
        let edgeIndex = geometry.lastIndex { $0.live.minY < snapshot.monitor.frame.maxY } ?? columns.startIndex
        let bottomIndex = geometry.firstIndex {
            $0.live.maxY > snapshot.niriWorkingFrame.minY && $0.live.minY < snapshot.monitor.frame.maxY
        }
        let gesture = controller?.workspaceManager.animationDriver.hasGesture(in: snapshot.workspaceId) == true
        var warm: [WindowToken: CGSize] = [:]
        var motion: [WindowToken: CGSize] = [:]
        for index in columns.indices {
            let isWarm = index == edgeIndex || index == edgeIndex + 1 || index == bottomIndex
            let isMotion = !isSettled && pictureMotionCandidate(
                columns[index], geometry: geometry[index], snapshot: snapshot,
                isActive: index == activeIndex, isGesture: gesture
            )
            guard isWarm || isMotion else { continue }
            let sizes = pictureWindowSizes(in: columns[index], engine: engine, snapshot: snapshot)
            if isWarm { warm.merge(sizes) { _, current in current } }
            if isMotion { motion.merge(sizes) { _, current in current } }
        }
        return NiriPicturePreparation(isSettled: isSettled, warmCandidates: warm, motionCandidates: motion)
    }

    private func pictureMotionCandidate(
        _ column: NiriProjectedColumn,
        geometry: (live: CGRect, target: CGRect),
        snapshot: NiriWorkspaceSnapshot,
        isActive: Bool,
        isGesture: Bool
    ) -> Bool {
        if isActive, column.windows.allSatisfy({ snapshot.edgePictures.parkedAboveTokens.contains($0.token) }) {
            return true
        }
        if bottomPictureMotionCandidate(geometry: geometry, snapshot: snapshot, isGesture: isGesture) {
            return true
        }
        guard geometry.live.intersects(snapshot.monitor.frame),
              isGesture || geometry.target.maxY > snapshot.monitor.frame.maxY
        else { return false }
        let activeTab = column.column.isTabbed ? controller?.niriEngine?.projectedActiveWindow(in: column) : nil
        let displayed = activeTab.map { [$0] } ?? column.windows
        return displayed.allSatisfy { window in
            snapshot.windows.contains { $0.token == window.token && $0.hiddenState == nil }
        }
    }

    private func bottomPictureMotionCandidate(
        geometry: (live: CGRect, target: CGRect),
        snapshot: NiriWorkspaceSnapshot,
        isGesture: Bool
    ) -> Bool {
        let bottom = snapshot.monitor.visibleFrame.minY
        let floor = bottom + NiriLayoutViewport.minimumNativeBottomVisibility
        let live = geometry.live.maxY
        let target = isGesture ? live : geometry.target.maxY
        return min(live, target) < floor && max(live, target) > bottom
    }

    private func pictureColumnGeometry(
        columns: [NiriProjectedColumn],
        activeIndex: Int,
        state: ViewportState,
        snapshot: NiriWorkspaceSnapshot,
        time: TimeInterval,
        isSettled: Bool = false
    ) -> [(live: CGRect, target: CGRect)] {
        let containers = columns.map(\.column)
        let active = columns[activeIndex].column
        let liveOffset = isSettled ? state.viewOffset : controller.map {
            $0.workspaceManager.animationDriver.plannedRenderOffset(
                in: snapshot.workspaceId, localState: state,
                storeOffset: $0.workspaceManager.niriViewportState(for: snapshot.workspaceId).viewOffset,
                at: time
            )
        } ?? state.viewOffset
        let livePosition = (active.frame?.minY ?? snapshot.niriWorkingFrame.minY) - snapshot.niriWorkingFrame.minY
            + liveOffset
        let targetPosition = state.containerPosition(
            at: activeIndex, containers: containers, gap: snapshot.gap, sizeKeyPath: \.settledHeight
        ) + state.viewOffset
        var position: CGFloat = 0
        return columns.map { projected in
            let column = projected.column
            let height = column.settledHeight.roundedToPhysicalPixel(scale: snapshot.monitor.scale)
            let target = CGRect(
                x: snapshot.niriWorkingFrame.minX, y: snapshot.niriWorkingFrame.minY + position - targetPosition,
                width: snapshot.niriWorkingFrame.width, height: height
            )
            position += column.settledHeight + snapshot.gap
            let offset = column.renderOffset(at: time)
            let canonical = column.frame ?? target.offsetBy(dx: 0, dy: targetPosition)
            let live = canonical.offsetBy(dx: offset.x, dy: offset.y - livePosition)
            return (live.roundedToPhysicalPixels(scale: snapshot.monitor.scale), target)
        }
    }

    private func pictureWindowSizes(
        in column: NiriProjectedColumn,
        engine: NiriLayoutEngine,
        snapshot: NiriWorkspaceSnapshot
    ) -> [WindowToken: CGSize] {
        guard column.windows.allSatisfy({ $0.sizingMode == .normal }), let controller else { return [:] }
        let activeTab = column.column.isTabbed ? engine.projectedActiveWindow(in: column) : nil
        var sizes: [WindowToken: CGSize] = [:]
        for window in column.windows where activeTab == nil || window === activeTab {
            guard controller.workspaceManager.entry(for: window.token)?.axRef != nil,
                  !snapshot.excludedTokens.contains(window.token), let frame = window.frame
            else { continue }
            let size = CGSize(
                width: frame.width,
                height: column.column.settledHeight.roundedToPhysicalPixel(scale: snapshot.monitor.scale)
            )
            if size.hasFinitePositiveDimensions() { sizes[window.token] = size }
        }
        return sizes
    }
}
