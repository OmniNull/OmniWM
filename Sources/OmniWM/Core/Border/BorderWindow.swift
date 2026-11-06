// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class BorderWindow {
    struct Display {
        var scale: CGFloat
        var screenFrame: CGRect
        var colorSpace: CGColorSpace?
    }

    struct Operations {
        var createLayerPanel: @MainActor (CGRect) -> BorderLayerPanel?
        var excludeFromScreencaptureSelection: @MainActor (UInt32) -> Void
        var queryWindowInfoDeferred: @MainActor (UInt32) async throws -> WindowServerInfo?
        var backingScaleForFrame: @MainActor (CGRect) -> Display
        var orderWindow: @MainActor (UInt32, UInt32, SkyLightWindowOrder) -> Void
        var orderPanel: @MainActor (BorderLayerPanel, NSWindow.OrderingMode, UInt32) -> Void

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
                return Display(
                    scale: targetScreen?.backingScaleFactor ?? 2.0,
                    screenFrame: targetScreen?.frame ?? .null,
                    colorSpace: targetScreen?.colorSpace?.cgColorSpace
                )
            },
            orderWindow: { SkyLight.shared.orderWindow($0, relativeTo: $1, order: $2) },
            orderPanel: { $0.order($1, directlyRelativeTo: $2) }
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
    private var appliedPresentation: BorderPresentation?
    private var appliedIsMoving = false
    private var appliedOrdersAboveTarget = false
    private var orderedAboveWindowId: UInt32?
    private var isOrderedOutInWindowServer = false
    private var needsRedraw = true
    private var isVisible = false
    private var lastOrderedTargetToken: WindowToken?
    private var lastConfiguredScale: CGFloat = 0
    private var currentCornerRadii: WindowCornerRadii
    private var currentCornerContour: WindowCornerContour?
    private var cachedScale: CGFloat = 0
    private var cachedScaleScreenFrame: CGRect = .null
    private var cachedColorSpace: CGColorSpace?
    private var cachedTargetLevel: CachedTargetLevel?
    private var deferredLevelTarget: WindowToken?
    private var deferredLevelGeneration: UInt64 = 0
    private(set) var deferredLevelTask: Task<Void, Never>?
    private(set) var hasDeferredLevelUpdate = false
    var onWindowLevelResolved: (@MainActor () -> Void)?
    private var pendingTargetLevelRetryToken: WindowToken?
    private(set) var needsWindowLevelRetry = false
    private(set) var appliedTargetLevel: Int32 = 0

    private let defaultCornerRadii: WindowCornerRadii

    init(
        config: BorderConfig,
        operations: Operations = .live,
        defaultCornerRadii: WindowCornerRadii = .systemDefault
    ) {
        self.config = config
        self.operations = operations
        self.defaultCornerRadii = defaultCornerRadii
        self.currentCornerRadii = defaultCornerRadii
        currentCornerContour = nil
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
        orderedAboveWindowId = nil
        lastOrderedTargetToken = nil
        appliedTargetToken = nil
        appliedPresentation = nil
        appliedIsMoving = false
        cachedTargetLevel = nil
        pendingTargetLevelRetryToken = nil
        needsWindowLevelRetry = false
        currentCornerRadii = defaultCornerRadii
        currentCornerContour = nil
    }

    @discardableResult
    func update(
        frame targetFrame: CGRect,
        targetToken: WindowToken,
        presentation: BorderPresentation? = nil,
        isMoving: Bool = false,
        cornerRadii: WindowCornerRadii? = nil,
        cornerContour: WindowCornerContour? = nil,
        forceOrdering: Bool = false,
        ordersAboveTarget: Bool = false
    ) -> Bool {
        BorderOpMetricsRecorder.shared.noteUpdate()
        needsWindowLevelRetry = false
        guard let targetWid = UInt32(exactly: targetToken.windowId), targetWid != 0 else { return false }
        let displayScale = backingScale(for: presentation?.displayFrame ?? targetFrame)
        let scale = presentation?.scale ?? displayScale
        let resolvedCornerRadii = (cornerRadii ?? defaultCornerRadii).nonnegative
        let geometry = config.resolvedGeometry(for: targetFrame, scale: scale)
        let surfaceFrame = geometry.surfaceFrame
        appliedTargetFrame = geometry.targetFrame
        appliedSurfaceFrame = surfaceFrame
        let localGeometry = geometry.localized()
        let presentationChanged = appliedPresentation?.windowId != presentation?.windowId
        let targetChanged = appliedTargetToken != targetToken || presentationChanged
        if targetChanged {
            pendingTargetLevelRetryToken = nil
            invalidateDeferredLevel(target: presentation == nil ? targetToken : nil)
        }
        appliedPresentation = presentation
        appliedIsMoving = presentation?.isMoving ?? isMoving

        let createdWindow = wid == 0
        if createdWindow {
            createWindow(scale: scale)
            guard wid != 0 else { return false }
        }

        updateLayerGeometry(localGeometry, scale: scale, cornerRadii: resolvedCornerRadii, cornerContour: cornerContour)

        let retryingTargetLevel = pendingTargetLevelRetryToken == targetToken
        let orderingChanged = forceOrdering || createdWindow || !isVisible
            || lastOrderedTargetToken != targetToken || presentationChanged || retryingTargetLevel
            || appliedOrdersAboveTarget != ordersAboveTarget
        appliedOrdersAboveTarget = ordersAboveTarget
        move(
            relativeTo: targetToken,
            targetWid: presentation?.windowId ?? targetWid,
            needsOrdering: orderingChanged || hasDeferredLevelUpdate,
            ordersAtUnchangedLevel: orderingChanged,
            retryingTargetLevel: retryingTargetLevel
        )
        isVisible = true
        appliedTargetToken = targetToken
        lastOrderedTargetToken = targetToken
        return true
    }

    private func createWindow(scale: CGFloat) {
        guard let panel = operations.createLayerPanel(visibleSurfaceFrame) else { return }
        guard let windowId = UInt32(exactly: panel.windowNumber), windowId != 0 else {
            panel.close()
            return
        }
        panel.orderFront(nil)
        CATransaction.flush()
        layerPanel = panel
        wid = windowId
        isOrderedOutInWindowServer = false
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
        ordersAtUnchangedLevel: Bool,
        retryingTargetLevel: Bool
    ) {
        if needsOrdering {
            BorderOpMetricsRecorder.shared.noteMoveAndOrder()
            let level: Int32 = appliedPresentation == nil ? resolvedTargetLevel(
                for: targetToken,
                retrying: retryingTargetLevel
            ) : 0
            let levelChanged = level != appliedTargetLevel
            appliedTargetLevel = level
            if let layerPanel, ordersAtUnchangedLevel || levelChanged {
                layerPanel.level = NSWindow.Level(rawValue: Int(level))
                if isOrderedOutInWindowServer {
                    CATransaction.flush()
                    operations.orderWindow(wid, targetWid, .below)
                    isOrderedOutInWindowServer = false
                }
                operations.orderPanel(layerPanel, appliedOrdersAboveTarget ? .above : .below, targetWid)
                orderedAboveWindowId = appliedOrdersAboveTarget ? targetWid : nil
            }
            return
        }

        BorderOpMetricsRecorder.shared.noteMoveOnly()
    }

    func reorder(
        relativeTo targetToken: WindowToken,
        presentation: BorderPresentation? = nil,
        ordersAboveTarget: Bool = false
    ) {
        needsWindowLevelRetry = false
        guard wid != 0,
              let targetWid = UInt32(exactly: targetToken.windowId),
              targetWid != 0
        else { return }
        appliedPresentation = presentation
        appliedOrdersAboveTarget = ordersAboveTarget
        let retryingTargetLevel = pendingTargetLevelRetryToken == targetToken
        move(
            relativeTo: targetToken,
            targetWid: presentation?.windowId ?? targetWid,
            needsOrdering: true,
            ordersAtUnchangedLevel: true,
            retryingTargetLevel: retryingTargetLevel
        )
        isVisible = true
        appliedTargetToken = targetToken
        lastOrderedTargetToken = targetToken
    }

    func windowId(orderedAbove target: UInt32) -> UInt32? {
        orderedAboveWindowId == target ? wid : nil
    }

    func hide() {
        invalidateDeferredLevel(target: nil)
        guard wid != 0 else { return }
        BorderOpMetricsRecorder.shared.noteHide()
        operations.orderWindow(wid, 0, .out)
        orderedAboveWindowId = nil
        isOrderedOutInWindowServer = true
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
        wid == 0 || !isVisible ? nil : visibleSurfaceFrame
    }

    var targetFrameOnScreen: CGRect? {
        wid == 0 || !isVisible ? nil : appliedTargetFrame
    }
}

extension BorderWindow {
    private var visibleSurfaceFrame: CGRect {
        appliedPresentation?.displayClip(for: appliedSurfaceFrame).map {
            appliedSurfaceFrame.integral.intersection($0)
        } ?? appliedSurfaceFrame
    }

    func invalidateScaleCache() {
        cachedScale = 0
        cachedScaleScreenFrame = .null
        lastConfiguredScale = 0
        needsRedraw = true
        layerPanel?.invalidatePlacement()
    }

    private func backingScale(for targetFrame: CGRect) -> CGFloat {
        if cachedScale > 0, cachedScaleScreenFrame.contains(targetFrame.center) {
            return cachedScale
        }
        let display = operations.backingScaleForFrame(targetFrame)
        cachedScale = display.scale
        cachedScaleScreenFrame = display.screenFrame
        cachedColorSpace = display.colorSpace
        return display.scale
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
            config: config, baseColor: color, scale: lastConfiguredScale,
            cornerContour: currentCornerContour
        )
        needsRedraw = false
        BorderOpMetricsRecorder.shared.noteRedraw()
    }
}

extension BorderWindow {
    private func updateLayerGeometry(
        _ geometry: BorderConfig.ResolvedGeometry,
        scale: CGFloat,
        cornerRadii: WindowCornerRadii,
        cornerContour: WindowCornerContour?
    ) {
        if scale != lastConfiguredScale, wid != 0 {
            BorderOpMetricsRecorder.shared.noteScaleReconfiguration()
            lastConfiguredScale = scale
            needsRedraw = true
        }
        let resized = geometry.surfaceFrame.size != currentSurfaceFrame.size
        if resized {
            BorderOpMetricsRecorder.shared.noteReshape()
            needsRedraw = true
        }
        if currentCornerRadii != cornerRadii || currentCornerContour != cornerContour {
            needsRedraw = true
        }
        currentSurfaceFrame = geometry.surfaceFrame
        currentCornerRadii = cornerRadii
        currentCornerContour = cornerContour
        layerPanel?.setDisplayColorSpace(cachedColorSpace)
        let displayClip = appliedPresentation?.displayClip(for: appliedSurfaceFrame)
        if appliedIsMoving, displayClip == nil, !needsRedraw {
            layerPanel?.applyFrame(
                targetFrame: appliedTargetFrame, surfaceFrame: appliedSurfaceFrame,
                presentation: appliedPresentation, isMoving: true
            )
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layerPanel?.applyFrame(
            targetFrame: appliedTargetFrame, surfaceFrame: appliedSurfaceFrame,
            displayClip: displayClip,
            presentation: appliedPresentation,
            isMoving: appliedIsMoving
        )
        if needsRedraw { draw(geometry: geometry) }
        CATransaction.commit()
        if resized { CATransaction.flush() }
    }
}

extension BorderWindow {
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
}
