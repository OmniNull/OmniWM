// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class OverviewLayerRenderer {
    typealias Colors = OverviewRenderStyle.Colors
    typealias Metrics = OverviewRenderStyle.Metrics
    static let searchPlaceholder = String(localized: "Type to search...")

    let root = CALayer()
    private let backdropGroup = CALayer()
    weak var glassLayer: CALayer?
    private var presentationProgress: Double = 0
    var ribbonMasks: [WindowHandle: CALayer] = [:]
    private let backdrop = CALayer()
    private let completionLayer = CALayer()
    private(set) var activeTransition: OverviewNativeTransition?
    var reflowTransition: OverviewNativeTransition?
    private var reflowGeneration: UInt64 = 0
    var reflowArrivals: Set<WindowHandle> = []
    let content = CALayer()
    let workspaceChrome = CALayer()
    private let cards = CALayer()
    let overflowPills = CALayer()
    let dropTarget = CAShapeLayer()
    let selectionOutline = CAShapeLayer()
    let search = CALayer()
    let searchText = OverviewRenderer.textLayer(size: 16, color: Colors.textDimmed, alignment: .center)
    let searchStatus = OverviewRenderer.textLayer(size: 11, color: Colors.textGray, alignment: .center)
    let searchClear = OverviewRenderer.textLayer(size: 12, color: Colors.textWhite, alignment: .center)
    let caret = CALayer()
    private(set) var windowLayers: [WindowHandle: OverviewWindowLayer] = [:]
    var previewForHandle: ((WindowHandle) -> OverviewPreviewFrame?)?
    var wallpaperForDisplay: ((CGDirectDisplayID, Int) -> CGImage?)?
    private let displayId: CGDirectDisplayID
    var chromeLayout: OverviewLayout?
    var chromeSections: [WorkspaceDescriptor.ID: CALayer] = [:]
    var tabControlLayers: [WindowHandle: CALayer] = [:]
    var columnLayers: [WorkspaceDescriptor.ID: [Int: CALayer]] = [:]
    var ribbonLayers: [WorkspaceDescriptor.ID: (wallpaper: CALayer, shade: CALayer)] = [:]
    private var previewAnimationsEnabled = true
    var contentsScale: CGFloat = 1

    init(displayId: CGDirectDisplayID = CGMainDisplayID()) {
        self.displayId = displayId
        root.masksToBounds = true
        root.addSublayer(backdropGroup)
        backdropGroup.addSublayer(backdrop)
        root.addSublayer(completionLayer)
        root.addSublayer(content)
        content.addSublayer(workspaceChrome)
        content.addSublayer(cards)
        content.addSublayer(overflowPills)
        content.addSublayer(dropTarget)
        content.addSublayer(selectionOutline)
        root.addSublayer(search)
        search.addSublayer(searchText)
        search.addSublayer(caret)
        search.addSublayer(searchStatus)
        search.addSublayer(searchClear)
        searchClear.string = String(localized: "Clear")
        selectionOutline.fillColor = nil
        selectionOutline.lineWidth = 2
        search.backgroundColor = Colors.searchBarBackground
        search.borderColor = Colors.searchBarBorder
        search.borderWidth = Metrics.searchBarBorderWidth
        search.cornerRadius = Metrics.searchBarCornerRadius
        caret.backgroundColor = Colors.textWhite
        dropTarget.fillColor = Colors.dropTarget
        dropTarget.strokeColor = Colors.dropTarget
        dropTarget.lineWidth = Metrics.dropOutlineWidth
    }

    func updateLayout(
        _ layout: OverviewLayout,
        state: OverviewRenderState,
        caretAnimated: Bool,
        update: OverviewLayoutUpdate = .preserve,
        animationsEnabled: Bool = true
    ) {
        previewAnimationsEnabled = animationsEnabled
        if !animationsEnabled {
            for layers in windowLayers.values { layers.finishPreviewReveal() }
        }
        if update == .immediate || !animationsEnabled { cancelReflow() }
        let reflow = (update == .structural || update == .viewport) && animationsEnabled
            && state.progress == 1 && activeTransition == nil && !root.bounds.isEmpty
        var chromeMotion = reflow || reflowTransition != nil
            ? (tabMotionLayers + columnMotionLayers + ribbonMotionLayers).map { OverviewLayerMotion($0) } : []
        if reflow, update == .structural {
            reflowArrivals = Set(layout.workspaceSections.flatMap { section in
                section.windows.compactMap { window in
                    window.isDisplayed && windowLayers[window.handle]?.root.isHidden != false ? window.handle : nil
                }
            })
        }
        OverviewRenderer.withoutAnimation {
            reconcileWindows(layout)
            chromeMotion.append(contentsOf: rebuildWorkspaceChrome(layout))
            updateSearch(layout, state: state, caretAnimated: caretAnimated)
            updateDropTarget(layout)
            updateSelectionOutline(layout, state: state)
        }
        if reflow {
            reflowGeneration &+= 1
            reflowTransition = OverviewNativeTransition(
                generation: reflowGeneration,
                startTime: CACurrentMediaTime(),
                from: 0,
                to: 1
            )
            updatePresentation(layout, state: state, replacing: true)
            reflowArrivals.removeAll(keepingCapacity: true)
        }
        if let reflowTransition {
            for motion in chromeMotion {
                motion.apply(reflowTransition, at: CACurrentMediaTime(), replacing: reflow)
            }
        }
    }

    func installAnimation(
        _ transition: OverviewNativeTransition,
        layout: OverviewLayout,
        state: OverviewRenderState,
        completion: OverviewAnimationCompletion
    ) {
        reflowTransition = nil
        reflowArrivals.removeAll(keepingCapacity: true)
        for mask in ribbonMasks.values { OverviewLayerMotion.remove(from: mask) }
        activeTransition = transition
        updatePresentation(layout, state: state, replacing: true)
        let animation = transition.makeAnimation(keyPath: "opacity")
        animation.beginTime = completionLayer.convertTime(transition.startTime, from: nil)
        animation.fromValue = 0
        animation.toValue = 1
        animation.delegate = completion
        completionLayer.add(animation, forKey: "overview.completion")
    }

    func cancelAnimation() {
        activeTransition = nil
        reflowTransition = nil
        reflowArrivals.removeAll(keepingCapacity: true)
        completionLayer.removeAnimation(forKey: "overview.completion")
        for layer in [backdropGroup, content, workspaceChrome, overflowPills, dropTarget, selectionOutline, search] {
            OverviewLayerMotion.remove(from: layer)
        }
        if let glassLayer { OverviewLayerMotion.remove(from: glassLayer) }
        for layers in windowLayers.values { layers.cancelAnimation() }
        for mask in ribbonMasks.values { OverviewLayerMotion.remove(from: mask) }
        for control in tabMotionLayers { OverviewLayerMotion.remove(from: control) }
        for layer in columnMotionLayers + ribbonMotionLayers { OverviewLayerMotion.remove(from: layer) }
    }

    func windowHit(at point: CGPoint, layout: OverviewLayout) -> OverviewLayout.WindowHit? {
        let displayedContent = OverviewLayerMotion.displayedFrame(of: content)
        let local = CGPoint(x: point.x - displayedContent.minX, y: point.y - displayedContent.minY)
        for section in layout.workspaceSections.reversed() {
            for window in section.windows.reversed() where window.matchesSearch && window.isDisplayed {
                let clip = section.clipFrame(for: window)
                if presentationProgress == 1, activeTransition == nil, !clip.isEmpty, !clip.contains(local) { continue }
                if let close = windowLayers[window.handle]?.hit(at: local) {
                    return OverviewLayout.WindowHit(window: window, isCloseButton: close)
                }
            }
        }
        return nil
    }

    func updatePresentation(_ layout: OverviewLayout, state: OverviewRenderState, replacing: Bool = false) {
        let time = CACurrentMediaTime()
        if !replacing, reflowTransition != nil, !isReflowing { reflowTransition = nil }
        presentationProgress = state.progress
        let motion = activeTransition.map(captureMotion)
            ?? (reflowTransition == nil ? [] : [OverviewLayerMotion(content)])
        let visible = visibleContentRect(for: layout, state: state)
        OverviewRenderer.withoutAnimation {
            root.frame = state.bounds
            backdropGroup.frame = root.bounds
            glassLayer?.opacity = Float(state.progress)
            backdrop.frame = root.bounds
            backdrop.backgroundColor = state.palette.backdrop
            backdropGroup.opacity = Float(state.progress)
            content.frame = root.bounds.offsetBy(dx: 0, dy: -layout.scrollOffset * CGFloat(state.progress))
            workspaceChrome.opacity = Float(state.progress)
            overflowPills.opacity = Float(state.progress)
            dropTarget.opacity = Float(state.progress)
            selectionOutline.opacity = Float(state.progress)
            search.opacity = Float(state.progress)
            for control in tabControlLayers.values { control.opacity = Float(state.progress) }
            if state.progress < 1 { caret.removeAnimation(forKey: "blink") }
            for section in layout.workspaceSections {
                chromeSections[section.workspaceId]?.isHidden = activeTransition == nil && !OverviewRenderGeometry
                    .shouldRender(
                        frame: OverviewRenderGeometry.sectionCullingFrame(section, progress: state.progress),
                        visibleContentRect: visible
                    )
                updateWindowPresentation(
                    section,
                    anchored: section.workspaceId == layout.anchorWorkspaceId,
                    state: state,
                    visible: visible,
                    pass: (replacing, time)
                )
            }
            if let transition = activeTransition ?? reflowTransition {
                for snapshot in motion { snapshot.apply(transition, at: time, replacing: replacing) }
            }
        }
    }

    func updateHover(from previous: WindowHandle?, layout: OverviewLayout, state: OverviewRenderState) {
        OverviewRenderer.withoutAnimation {
            for handle in [previous, state.hoveredWindowHandle].compactMap({ $0 }) {
                guard let window = layout.window(for: handle) else { continue }
                windowLayers[handle]?.updateEmphasis(window, state: state)
            }
        }
    }

    private func captureMotion(for transition: OverviewNativeTransition) -> [OverviewLayerMotion] {
        [OverviewLayerMotion(backdropGroup), OverviewLayerMotion(content)]
            + (glassLayer.map { [OverviewLayerMotion($0)] } ?? [])
            + [workspaceChrome, overflowPills, dropTarget, selectionOutline, search]
            .map { OverviewLayerMotion($0, response: transition.chromeExitResponse) }
            + tabMotionLayers.map { OverviewLayerMotion($0, response: transition.chromeExitResponse) }
            + ribbonMotionLayers.map { OverviewLayerMotion($0) }
    }

    func updatePreview(_ frame: OverviewPreviewFrame?, for handle: WindowHandle, animated: Bool = true) {
        guard let layers = windowLayers[handle] else { return }
        layers.updatePreview(frame, animated: animated && previewAnimationsEnabled && !layers.root.isHidden)
    }

    func clearPreviews() {
        caret.removeAnimation(forKey: "blink")
        for layers in windowLayers.values { layers.updatePreview(nil) }
    }

    func updateContentsScale(_ scale: CGFloat) {
        guard scale != contentsScale else { return }
        contentsScale = scale
        OverviewRenderer.withoutAnimation { updateScale(in: root) }
    }

    private func updateScale(in layer: CALayer) {
        layer.contentsScale = contentsScale
        for sublayer in layer.sublayers ?? [] { updateScale(in: sublayer) }
    }

    private func reconcileWindows(_ layout: OverviewLayout) {
        let handles = Set(layout.workspaceSections.flatMap { $0.windows.map(\.handle) })
        for handle in windowLayers.keys where !handles.contains(handle) {
            if let removed = windowLayers.removeValue(forKey: handle) {
                removed.updatePreview(nil)
                removed.root.removeFromSuperlayer()
                ribbonMasks.removeValue(forKey: handle)
            }
        }
        var order: [CALayer] = []
        order.reserveCapacity(handles.count)
        for section in layout.workspaceSections {
            for window in section.windows {
                let layers: OverviewWindowLayer
                if let existing = windowLayers[window.handle] {
                    layers = existing
                } else {
                    layers = OverviewWindowLayer()
                    windowLayers[window.handle] = layers
                    let mask = CALayer()
                    mask.backgroundColor = CGColor(gray: 1, alpha: 1)
                    ribbonMasks[window.handle] = mask
                    cards.addSublayer(layers.root)
                    layers.updatePreview(previewForHandle?(window.handle))
                }
                layers.updateContent(window, contentsScale: contentsScale)
                order.append(layers.root)
            }
        }
        if cards.sublayers?.elementsEqual(order, by: ===) != true { cards.sublayers = order }
    }
}
