// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func placeFloatingWindow(_ handle: WindowHandle, frame: CGRect) {
        guard workspaceManager.handle(for: handle.id) === handle,
              let entry = workspaceManager.entry(for: handle), entry.mode == .floating,
              entry.layoutReason == .standard,
              let monitor = workspaceManager.monitorForWorkspace(entry.workspaceId)
        else { return }
        let targetFrame = FloatingFrameGeometry.clamped(frame, in: monitor.visibleFrame)
        workspaceManager.updateFloatingGeometry(
            frame: targetFrame, for: entry.token, referenceMonitor: monitor, restoreToFloating: true
        )
        guard !workspaceManager.isHiddenInCorner(entry.token),
              shouldApplyFloatingFrameImmediately(for: entry.workspaceId)
        else { return }
        applyFloatingWindowFrame(targetFrame, to: entry)
    }

    private func applyFloatingWindowFrame(_ frame: CGRect, to entry: WindowState) {
        guard let axRef = entry.axRef else {
            _ = shellAppWindowManager.setFloatingFrame(frame, for: entry.token)
            return
        }
        axManager.forceApplyNextFrame(for: entry.windowId)
        axManager.applyFramesParallel([
            .init(pid: entry.pid, window: axRef, frame: frame)
        ])
    }

    func liveFrame(for entry: WindowState) -> CGRect? {
        guard let axRef = entry.axRef else { return shellAppWindowManager.frame(for: entry.token) }
        return AXWindowService.framePreferFast(axRef)
            ?? axManager.lastAppliedFrame(for: entry.windowId)
            ?? (try? AXWindowService.frame(axRef))
    }

    func floatingPlacementMonitor(
        for entry: WindowState,
        preferredMonitor: Monitor? = nil,
        frame: CGRect? = nil
    ) -> Monitor? {
        if let preferredMonitor {
            return preferredMonitor
        }
        if let interactionMonitor = monitorForInteraction() {
            return interactionMonitor
        }
        if let workspaceMonitor = workspaceManager.monitor(for: entry.workspaceId) {
            return workspaceMonitor
        }
        if let frame,
           let approximatedMonitor = frame.center.monitorApproximation(in: workspaceManager.monitors)
        {
            return approximatedMonitor
        }
        return workspaceManager.monitors.first
    }

    private func initialFloatingFrame(
        for entry: WindowState,
        preferredMonitor: Monitor?,
        sourceFrame: CGRect? = nil,
        allowLiveFrameFallback: Bool = true
    ) -> CGRect? {
        guard let frame = sourceFrame ?? (allowLiveFrameFallback ? liveFrame(for: entry) : nil) else { return nil }
        let offsetFrame = frame.offsetBy(dx: 50, dy: 50)
        guard let monitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        ) else {
            return offsetFrame
        }
        let workingFrame = layoutFrames(for: monitor, scale: backingScaleFactor(for: monitor)).workingFrame
        var placed = FloatingFrameGeometry.clamped(offsetFrame, in: workingFrame)
        placed.origin.y = min(placed.origin.y, workingFrame.maxY - placed.height)
        return placed
    }

    private func shouldApplyFloatingFrameImmediately(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let monitor = workspaceManager.monitor(for: workspaceId) else { return false }
        return workspaceManager.activeWorkspace(on: monitor.id)?.id == workspaceId
    }

    func seedFloatingGeometryIfNeeded(
        for token: WindowToken,
        preferredMonitor: Monitor? = nil,
        observedFrame: CGRect? = nil,
        allowLiveFrameFallback: Bool = true
    ) {
        guard workspaceManager.floatingState(for: token) == nil,
              let entry = workspaceManager.entry(for: token),
              let frame = observedFrame ?? (allowLiveFrameFallback ? liveFrame(for: entry) : nil)
        else {
            return
        }

        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        )
        workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true
        )
    }

    @discardableResult
    func captureVisibleFloatingGeometry(
        for token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) -> CGRect? {
        guard !workspaceManager.isHiddenInCorner(token),
              let entry = workspaceManager.entry(for: token),
              let frame = liveFrame(for: entry)
        else {
            return nil
        }

        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        )
        workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true
        )
        return frame
    }

    @discardableResult
    func transitionWindowMode(
        for token: WindowToken,
        to targetMode: TrackedWindowMode,
        preferredMonitor: Monitor? = nil,
        applyFloatingFrame: Bool? = nil,
        observedFrame: CGRect? = nil,
        allowLiveFrameFallback: Bool = true
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token) else { return false }
        guard entry.target.hostedMetadata?.role.parent == nil else { return false }
        let currentMode = entry.mode
        guard currentMode != targetMode else { return false }

        let currentFrame = observedFrame ?? (allowLiveFrameFallback ? liveFrame(for: entry) : nil)
        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: currentFrame
        )

        switch (currentMode, targetMode) {
        case (.tiling, .floating):
            return promoteWindowToFloating(
                entry,
                currentFrame: currentFrame,
                referenceMonitor: referenceMonitor,
                allowLiveFrameFallback: allowLiveFrameFallback,
                applyFloatingFrame: applyFloatingFrame
            )
        case (.floating, .tiling):
            return restoreWindowToTiling(entry, currentFrame: currentFrame, referenceMonitor: referenceMonitor)
        case (.tiling, .tiling),
             (.floating, .floating):
            return false
        }
    }

    private func promoteWindowToFloating(
        _ entry: WindowState,
        currentFrame: CGRect?,
        referenceMonitor: Monitor?,
        allowLiveFrameFallback: Bool,
        applyFloatingFrame: Bool?
    ) -> Bool {
        let token = entry.token
        let targetFrame = initialFloatingFrame(
            for: entry,
            preferredMonitor: referenceMonitor,
            sourceFrame: currentFrame,
            allowLiveFrameFallback: allowLiveFrameFallback
        )
        _ = workspaceManager.setWindowMode(.floating, for: token)
        mouseEventHandler.discardNativeTitleBarDrag(for: token)
        if let targetFrame {
            workspaceManager.updateFloatingGeometry(
                frame: targetFrame,
                for: token,
                referenceMonitor: referenceMonitor,
                restoreToFloating: true
            )
            if applyFloatingFrame
                ?? shouldApplyFloatingFrameImmediately(
                    for: workspaceManager.workspace(for: token) ?? entry.workspaceId
                )
            {
                applyFloatingWindowFrame(targetFrame, to: entry)
            }
        }
        return true
    }

    private func restoreWindowToTiling(
        _ entry: WindowState,
        currentFrame: CGRect?,
        referenceMonitor: Monitor?
    ) -> Bool {
        let token = entry.token
        if let currentFrame {
            workspaceManager.updateFloatingGeometry(
                frame: currentFrame,
                for: token,
                referenceMonitor: referenceMonitor,
                restoreToFloating: true
            )
        } else if var floatingState = workspaceManager.floatingState(for: token) {
            floatingState.restoreToFloating = true
            workspaceManager.setFloatingState(floatingState, for: token)
        }
        _ = workspaceManager.setWindowMode(.tiling, for: token)
        if workspaceManager.isScratchpadToken(token) {
            cleanupScratchpadWindowResources(for: token)
            if workspaceManager.hiddenState(for: token)?.isScratchpad == true {
                workspaceManager.setHiddenState(nil, for: token)
            }
        }
        return true
    }
}
