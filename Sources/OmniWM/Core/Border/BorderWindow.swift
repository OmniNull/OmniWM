// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class BorderWindow {
    struct Operations {
        var createLayerPanel: @MainActor (CGRect) -> BorderLayerPanel?
        var excludeFromScreencaptureSelection: @MainActor (UInt32) -> Void
        var queryWindowInfoDeferred: @MainActor (UInt32) async throws -> WindowServerInfo?
        var backingScaleForFrame: @MainActor (CGRect) -> (scale: CGFloat, screenFrame: CGRect)
        var orderWindow: @MainActor (UInt32, UInt32, SkyLightWindowOrder) -> Void

        static let live = Self(
            createLayerPanel: { BorderLayerPanel(frame: $0) },
            excludeFromScreencaptureSelection: { SkyLight.shared.excludeFromScreencaptureWindowSelection($0) },
            queryWindowInfoDeferred: {
                try await SkyLight.shared.queryWindowInfoDeferred(windowIds: [$0])?[$0]
            },
            backingScaleForFrame: { targetFrame in
                let targetScreen = NSScreen.screens.first(where: {
                    $0.frame.contains(targetFrame.center)
                }) ?? NSScreen.main ?? NSScreen.screens.first
                return (targetScreen?.backingScaleFactor ?? 2.0, targetScreen?.frame ?? .null)
            },
            orderWindow: { SkyLight.shared.orderWindow($0, relativeTo: $1, order: $2) }
        )
    }

    private var wid: UInt32 = 0
    private var layerPanel: BorderLayerPanel?
    private var config: BorderConfig
    private let operations: Operations

    private struct CachedTargetLevel {
        let token: WindowToken
        let level: Int32
    }

    private var currentSurfaceFrame: CGRect = .zero
    private var appliedTargetFrame: CGRect = .zero
    private var appliedSurfaceFrame: CGRect = .zero
    private var appliedTargetToken: WindowToken?
    private var needsRedraw = true
    private var isVisible = false
    private var lastOrderedTargetToken: WindowToken?
    private var lastConfiguredScale: CGFloat = 0
    private var currentCornerRadii = WindowCornerRadii(uniform: 9.0)
    private var cachedScale: CGFloat = 0
    private var cachedScaleScreenFrame: CGRect = .null
    private var cachedTargetLevel: CachedTargetLevel?
    private var deferredLevelTarget: WindowToken?
    private var deferredLevelGeneration: UInt64 = 0
    private var deferredLevelTask: Task<Void, Never>?
    private(set) var hasDeferredLevelUpdate = false
    var onWindowLevelResolved: (@MainActor () -> Void)?
    private var pendingTargetLevelRetryToken: WindowToken?
    private(set) var needsWindowLevelRetry = false
    private(set) var appliedTargetLevel: Int32 = 0

    private let defaultCornerRadii = WindowCornerRadii(uniform: 9.0)

    init(config: BorderConfig, operations: Operations = .live) {
        self.config = config
        self.operations = operations
    }

    isolated deinit {
        destroy()
    }

    func destroy() {
        invalidateDeferredLevel(target: nil)
        if wid != 0 {
            layerPanel?.close()
            layerPanel = nil
            wid = 0
        }
        isVisible = false
        lastOrderedTargetToken = nil
        appliedTargetToken = nil
        cachedTargetLevel = nil
        pendingTargetLevelRetryToken = nil
        needsWindowLevelRetry = false
        currentCornerRadii = defaultCornerRadii
    }

    @discardableResult
    func update(
        frame targetFrame: CGRect,
        targetToken: WindowToken,
        cornerRadii: WindowCornerRadii = WindowCornerRadii(uniform: 9.0),
        forceOrdering: Bool = false
    ) -> Bool {
        BorderOpMetricsRecorder.shared.noteUpdate()
        needsWindowLevelRetry = false
        guard let targetWid = UInt32(exactly: targetToken.windowId), targetWid != 0 else { return false }
        let scale = backingScale(for: targetFrame)
        let resolvedCornerRadii = cornerRadii.nonnegative
        let geometry = config.resolvedGeometry(for: targetFrame, scale: scale)
        let surfaceFrame = geometry.surfaceFrame
        appliedTargetFrame = geometry.targetFrame
        appliedSurfaceFrame = surfaceFrame
        let localGeometry = geometry.localized()
        let targetChanged = appliedTargetToken != targetToken
        if targetChanged {
            pendingTargetLevelRetryToken = nil
            invalidateDeferredLevel(target: targetToken)
        }

        let createdWindow = wid == 0
        if createdWindow {
            createWindow(scale: scale)
            guard wid != 0 else { return false }
        }

        if scale != lastConfiguredScale, wid != 0 {
            BorderOpMetricsRecorder.shared.noteScaleReconfiguration()
            lastConfiguredScale = scale
            needsRedraw = true
        }

        if localGeometry.surfaceFrame.size != currentSurfaceFrame.size {
            BorderOpMetricsRecorder.shared.noteReshape()
            needsRedraw = true
        }
        if currentCornerRadii != resolvedCornerRadii {
            needsRedraw = true
        }
        currentSurfaceFrame = localGeometry.surfaceFrame
        currentCornerRadii = resolvedCornerRadii

        updateLayerGeometry(localGeometry)

        let retryingTargetLevel = pendingTargetLevelRetryToken == targetToken
        let needsOrdering = forceOrdering || createdWindow || !isVisible
            || lastOrderedTargetToken != targetToken || retryingTargetLevel || hasDeferredLevelUpdate
        move(
            relativeTo: targetToken,
            targetWid: targetWid,
            needsOrdering: needsOrdering,
            retryingTargetLevel: retryingTargetLevel
        )
        isVisible = true
        appliedTargetToken = targetToken
        lastOrderedTargetToken = targetToken
        return true
    }

    private func createWindow(scale: CGFloat) {
        guard let panel = operations.createLayerPanel(appliedSurfaceFrame) else { return }
        guard let windowId = UInt32(exactly: panel.windowNumber), windowId != 0 else {
            panel.close()
            return
        }
        layerPanel = panel
        wid = windowId
        needsRedraw = true
        lastConfiguredScale = scale
        BorderOpMetricsRecorder.shared.noteWindowCreation()
        BorderOpMetricsRecorder.shared.noteScaleReconfiguration()
        operations.excludeFromScreencaptureSelection(wid)
    }

    private func move(
        relativeTo targetToken: WindowToken,
        targetWid: UInt32,
        needsOrdering: Bool,
        retryingTargetLevel: Bool
    ) {
        if needsOrdering {
            BorderOpMetricsRecorder.shared.noteMoveAndOrder()
            let level = resolvedTargetLevel(
                for: targetToken,
                retrying: retryingTargetLevel
            )
            appliedTargetLevel = level
            if let layerPanel {
                layerPanel.level = NSWindow.Level(rawValue: Int(level))
                if !isVisible {
                    layerPanel.orderFront(nil)
                }
                operations.orderWindow(wid, targetWid, .below)
            }
            return
        }

        BorderOpMetricsRecorder.shared.noteMoveOnly()
    }

    private func resolvedTargetLevel(
        for targetToken: WindowToken,
        retrying: Bool
    ) -> Int32 {
        if deferredLevelTarget != targetToken {
            invalidateDeferredLevel(target: targetToken)
        }
        if hasDeferredLevelUpdate {
            hasDeferredLevelUpdate = false
            if retrying {
                startDeferredLevelQuery(for: targetToken, retrying: true)
            }
        } else {
            startDeferredLevelQuery(for: targetToken, retrying: retrying)
        }
        return cachedLevel(for: targetToken)
    }

    private func cachedLevel(for targetToken: WindowToken) -> Int32 {
        guard let cachedTargetLevel, cachedTargetLevel.token == targetToken else { return 0 }
        return cachedTargetLevel.level
    }

    private func acceptTargetLevel(
        _ info: WindowServerInfo?, for targetToken: WindowToken, retrying: Bool
    ) -> Int32 {
        if let info, Int(info.id) == targetToken.windowId, info.pid == targetToken.pid {
            cachedTargetLevel = CachedTargetLevel(token: targetToken, level: info.level)
            pendingTargetLevelRetryToken = nil
            return info.level
        }
        BorderOpMetricsRecorder.shared.noteLevelFallback()
        FallbackFiringRecorder.shared.note(.skylight, "borderTargetLevelDefault")
        if retrying {
            pendingTargetLevelRetryToken = nil
        } else {
            pendingTargetLevelRetryToken = targetToken
            needsWindowLevelRetry = true
        }
        return cachedLevel(for: targetToken)
    }

    private func invalidateDeferredLevel(target: WindowToken?) {
        deferredLevelGeneration &+= 1
        deferredLevelTarget = target
        deferredLevelTask?.cancel()
        hasDeferredLevelUpdate = false
        pendingTargetLevelRetryToken = nil
        needsWindowLevelRetry = false
    }

    private func startDeferredLevelQuery(for targetToken: WindowToken, retrying: Bool) {
        guard deferredLevelTask == nil,
              let targetWid = UInt32(exactly: targetToken.windowId)
        else { return }
        let generation = deferredLevelGeneration
        let query = operations.queryWindowInfoDeferred
        if retrying {
            pendingTargetLevelRetryToken = nil
            BorderOpMetricsRecorder.shared.noteLevelRetry()
        }
        BorderOpMetricsRecorder.shared.noteLevelQuery()
        deferredLevelTask = Task { @MainActor [weak self] in
            let info = try? await query(targetWid)
            guard let self else { return }
            deferredLevelTask = nil
            guard generation == deferredLevelGeneration,
                  deferredLevelTarget == targetToken, isVisible, wid != 0
            else {
                if isVisible, let deferredLevelTarget {
                    startDeferredLevelQuery(for: deferredLevelTarget, retrying: false)
                }
                return
            }
            _ = acceptTargetLevel(info, for: targetToken, retrying: retrying)
            hasDeferredLevelUpdate = true
            onWindowLevelResolved?()
        }
    }

    func reorder(relativeTo targetToken: WindowToken) {
        needsWindowLevelRetry = false
        guard wid != 0,
              let targetWid = UInt32(exactly: targetToken.windowId),
              targetWid != 0
        else { return }
        let retryingTargetLevel = pendingTargetLevelRetryToken == targetToken
        move(
            relativeTo: targetToken,
            targetWid: targetWid,
            needsOrdering: true,
            retryingTargetLevel: retryingTargetLevel
        )
        isVisible = true
        appliedTargetToken = targetToken
        lastOrderedTargetToken = targetToken
    }

    func hide() {
        invalidateDeferredLevel(target: nil)
        guard wid != 0 else { return }
        BorderOpMetricsRecorder.shared.noteHide()
        layerPanel?.orderOut(nil)
        isVisible = false
        lastOrderedTargetToken = nil
        pendingTargetLevelRetryToken = nil
        needsWindowLevelRetry = false
    }

    func updateConfig(_ newConfig: BorderConfig) {
        guard config != newConfig else { return }
        if config.color != newConfig.color || config.width != newConfig.width
            || config.gradient != newConfig.gradient || config.glow != newConfig.glow
        {
            needsRedraw = true
        }
        config = newConfig
    }

    var windowId: UInt32? {
        wid == 0 ? nil : wid
    }

    var frameOnScreen: CGRect? {
        wid == 0 || !isVisible ? nil : appliedSurfaceFrame
    }

    var targetFrameOnScreen: CGRect? {
        wid == 0 || !isVisible ? nil : appliedTargetFrame
    }
}

extension BorderWindow {
    func invalidateScaleCache() {
        cachedScale = 0
        cachedScaleScreenFrame = .null
        lastConfiguredScale = 0
        needsRedraw = true
    }

    private func backingScale(for targetFrame: CGRect) -> CGFloat {
        if cachedScale > 0, cachedScaleScreenFrame.contains(targetFrame.center) {
            return cachedScale
        }
        let (scale, screenFrame) = operations.backingScaleForFrame(targetFrame)
        cachedScale = scale
        cachedScaleScreenFrame = screenFrame
        return scale
    }

    private func draw(geometry: BorderConfig.ResolvedGeometry) {
        guard let layerPanel else { return }
        let color = BorderLayerPanel.cgColor(config.color)
        layerPanel.updateBorder(
            geometry: geometry, cornerRadii: currentCornerRadii,
            color: color, scale: lastConfiguredScale
        )
        layerPanel.updateEffects(
            geometry: geometry, cornerRadii: currentCornerRadii,
            config: config, baseColor: color, scale: lastConfiguredScale
        )
        needsRedraw = false
        BorderOpMetricsRecorder.shared.noteRedraw()
    }
}

extension BorderWindow {
    private func updateLayerGeometry(_ geometry: BorderConfig.ResolvedGeometry) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layerPanel?.applyFrame(targetFrame: appliedTargetFrame, surfaceFrame: appliedSurfaceFrame)
        if needsRedraw { draw(geometry: geometry) }
    }
}
