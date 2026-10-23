// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

extension OverviewLayerRenderer {
    var ribbonMotionLayers: [CALayer] {
        ribbonLayers.values.flatMap { [$0.wallpaper, $0.shade] }
    }

    var columnMotionLayers: [CALayer] {
        columnLayers.values.flatMap { $0.values.flatMap { [$0] + ($0.sublayers ?? []) } }
    }

    var tabMotionLayers: [CALayer] {
        tabControlLayers.values.flatMap { [$0] + ($0.sublayers ?? []) + ($0.mask.map { [$0] } ?? []) }
    }

    var isReflowing: Bool {
        reflowTransition != nil && (
            content.animation(forKey: "overview.position") != nil
                || windowLayers.values.contains(where: \.isAnimating)
                || tabControlLayers.values.contains(where: {
                    $0.animation(forKey: "overview.position") != nil || $0.animation(forKey: "overview.bounds") != nil
                })
                || ribbonLayers.values.contains(where: {
                    $0.wallpaper.animation(forKey: "overview.position") != nil
                        || $0.wallpaper.animation(forKey: "overview.bounds") != nil
                })
        )
    }

    func cancelReflow() {
        guard reflowTransition != nil else { return }
        reflowTransition = nil
        reflowArrivals.removeAll(keepingCapacity: true)
        OverviewLayerMotion.remove(from: content)
        for layers in windowLayers.values { layers.cancelAnimation() }
        for mask in ribbonMasks.values { OverviewLayerMotion.remove(from: mask) }
        for control in tabMotionLayers { OverviewLayerMotion.remove(from: control) }
        for layer in columnMotionLayers + ribbonMotionLayers { OverviewLayerMotion.remove(from: layer) }
    }

    func freezingReflow(in layout: OverviewLayout) -> OverviewLayout {
        guard isReflowing else { return layout }
        var frozen = layout
        frozen.scrollOffset = -OverviewLayerMotion.displayedFrame(of: content).minY
        OverviewRenderer.withoutAnimation {
            for control in tabMotionLayers + columnMotionLayers + ribbonMotionLayers {
                control.frame = OverviewLayerMotion.displayedFrame(of: control)
                OverviewLayerMotion.remove(from: control)
            }
        }
        chromeLayout = nil
        frozen.replaceWorkspaceSections(layout.workspaceSections.map { section in
            var section = section
            for index in section.windows.indices {
                if let layers = windowLayers[section.windows[index].handle] {
                    section.windows[index].overviewFrame = layers.displayedFrame
                }
            }
            return section
        })
        for section in frozen.workspaceSections {
            frozen.niriColumnsByWorkspace[section.workspaceId] = frozen.niriColumnsByWorkspace[section.workspaceId]?
                .map {
                    var column = $0
                    if let layer = columnLayers[section.workspaceId]?[column.columnIndex] {
                        column.frame = layer.frame.offsetBy(dx: section.ribbonFrame.minX, dy: section.ribbonFrame.minY)
                    }
                    return column
                }
        }
        return frozen
    }

    func tabControl(at point: CGPoint, layout: OverviewLayout) -> OverviewTabControl? {
        let displayedContent = OverviewLayerMotion.displayedFrame(of: content)
        let local = CGPoint(x: point.x - displayedContent.minX, y: point.y - displayedContent.minY)
        for section in layout.workspaceSections.reversed() {
            guard section.ribbonFrame.contains(local) else { continue }
            for control in layout.tabControls(for: section) {
                guard let layers = windowLayers[control.handle], !layers.root.isHidden,
                      let controlLayer = tabControlLayers[control.handle] else { continue }
                let frame = OverviewLayerMotion.displayedFrame(of: controlLayer).offsetBy(
                    dx: layers.displayedFrame.minX,
                    dy: layers.displayedFrame.minY
                )
                guard frame.contains(local) else { continue }
                if let mask = controlLayer.mask,
                   !OverviewLayerMotion.displayedFrame(of: mask)
                       .offsetBy(dx: frame.minX, dy: frame.minY).contains(local)
                {
                    continue
                }
                return OverviewTabControl(
                    handle: control.handle,
                    previousHandle: control.previousHandle,
                    nextHandle: control.nextHandle,
                    frame: frame.offsetBy(dx: displayedContent.minX, dy: displayedContent.minY),
                    positionLabel: control.positionLabel,
                    style: control.style
                )
            }
        }
        return nil
    }

    func layoutPoint(at point: CGPoint, layout: OverviewLayout) -> CGPoint {
        let displayed = OverviewLayerMotion.displayedFrame(of: content)
        return CGPoint(x: point.x - displayed.minX, y: point.y - displayed.minY - layout.scrollOffset)
    }

    func visibleContentRect(for layout: OverviewLayout, state: OverviewRenderState) -> CGRect {
        let visible = OverviewRenderGeometry.visibleContentRect(
            bounds: state.bounds,
            scrollOffset: layout.scrollOffset,
            progress: state.progress,
            transitioning: activeTransition != nil
        )
        guard reflowTransition != nil else { return visible }
        let displayed = OverviewLayerMotion.displayedFrame(of: content)
        return visible.union(state.bounds.offsetBy(dx: -displayed.minX, dy: -displayed.minY))
    }

    func updateWindowPresentation(
        _ section: OverviewWorkspaceSection,
        anchored: Bool,
        state: OverviewRenderState,
        visible: CGRect,
        pass: (replacing: Bool, time: CFTimeInterval)
    ) {
        for window in section.windows {
            let frame = window.interpolatedFrame(progress: state.progress)
            guard let layers = windowLayers[window.handle] else { continue }
            let transition = activeTransition ?? reflowTransition
            if reflowArrivals.contains(window.handle) {
                layers.updateGeometry(window, frame: frame, state: state, anchored: anchored)
                layers.root.opacity = 0
            }
            layers.root.isHidden = !window.isDisplayed || !OverviewRenderGeometry.shouldRender(
                frame: activeTransition != nil
                    ? (window.restFrame ?? window.originalFrame).union(window.overviewFrame)
                    : (reflowTransition == nil ? frame : layers.displayedFrame.union(frame)),
                visibleContentRect: visible
            ) || (transition == nil && !section.containsInRibbon(window.overviewFrame))
            let maskMotion = updateRibbonMask(
                for: window,
                layers: layers,
                clip: section.clipFrame(for: window),
                frame: frame,
                pass: (pass.replacing, state.progress)
            )
            layers.updateGeometry(
                window,
                frame: frame,
                state: state,
                transition: transition,
                replacing: pass.replacing,
                time: pass.time,
                anchored: anchored
            )
            if let reflowTransition {
                maskMotion?.apply(reflowTransition, at: pass.time, replacing: pass.replacing)
            }
        }
    }

    private func updateRibbonMask(
        for window: OverviewWindowItem,
        layers: OverviewWindowLayer,
        clip: CGRect,
        frame: CGRect,
        pass: (replacing: Bool, progress: Double)
    ) -> OverviewLayerMotion? {
        guard activeTransition == nil, pass.progress == 1,
              let mask = ribbonMasks[window.handle], !clip.isEmpty
        else {
            layers.root.mask = nil
            return nil
        }
        if pass.replacing, reflowTransition != nil {
            OverviewLayerMotion.remove(from: mask)
            mask.frame = clip.offsetBy(dx: -layers.displayedFrame.minX, dy: -layers.displayedFrame.minY)
        }
        let motion = reflowTransition.map { _ in OverviewLayerMotion(mask) }
        mask.frame = clip.offsetBy(dx: -frame.minX, dy: -frame.minY)
        layers.root.mask = mask
        return motion
    }
}
