// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

extension OverviewLayerRenderer {
    func rebuildWorkspaceChrome(_ layout: OverviewLayout) -> [OverviewLayerMotion] {
        guard workspaceChromeNeedsUpdate(layout) else { return [] }
        chromeLayout = layout
        workspaceChrome.sublayers = nil
        overflowPills.sublayers = nil
        var tabHandles: Set<WindowHandle> = []
        var newMaskMotion: [OverviewLayerMotion] = []
        chromeSections.removeAll(keepingCapacity: true)
        let workspaceIds = Set(layout.workspaceSections.map(\.workspaceId))
        for id in columnLayers.keys where !workspaceIds.contains(id) { columnLayers.removeValue(forKey: id) }
        for id in ribbonLayers.keys where !workspaceIds.contains(id) { ribbonLayers.removeValue(forKey: id) }
        for section in layout.workspaceSections {
            let sectionLayer = CALayer()
            workspaceChrome.addSublayer(sectionLayer)
            chromeSections[section.workspaceId] = sectionLayer
            addRibbon(for: section, frame: layout.backgroundFrame(for: section), to: sectionLayer)
            let color = section.isActive ? Colors.workspaceLabelActive : Colors.workspaceLabelInactive
            let label = OverviewRenderer.textLayer(size: 16, color: color)
            label.string = section.name
            label.frame = section.labelFrame
            label.contentsScale = contentsScale
            sectionLayer.addSublayer(label)
            addColumnChrome(section, layout: layout, to: sectionLayer)
            for control in layout.tabControls(for: section) {
                guard let window = layout.window(for: control.handle),
                      let card = windowLayers[control.handle] else { continue }
                if let motion = reconcileTabControl(
                    control, window: window, card: card,
                    isDwindle: layout.dwindleGroupsByWorkspace[section.workspaceId] != nil
                ) {
                    newMaskMotion.append(motion)
                }
                tabHandles.insert(control.handle)
            }
            for pill in layout.overflowPills(for: section) {
                overflowPills.addSublayer(makeOverflowPillLayer(pill))
            }
        }
        if let target = layout.newWorkspaceTarget {
            let layer = makeControlLayer(frame: target.frame, label: "+")
            workspaceChrome.addSublayer(layer)
        }
        for handle in tabControlLayers.keys where !tabHandles.contains(handle) {
            tabControlLayers.removeValue(forKey: handle)?.removeFromSuperlayer()
        }
        return newMaskMotion
    }

    private func reconcileTabControl(
        _ control: OverviewTabControl,
        window: OverviewWindowItem,
        card: OverviewWindowLayer,
        isDwindle: Bool
    ) -> OverviewLayerMotion? {
        let frame = control.frame.offsetBy(dx: -window.overviewFrame.minX, dy: -window.overviewFrame.minY)
        let previousLayer = tabControlLayers[control.handle]
        let layer: CALayer
        if let previousLayer,
           previousLayer.sublayers?.first?.isHidden == (control.style == .pickerOnly)
        {
            layer = previousLayer
        } else {
            previousLayer?.removeFromSuperlayer()
            layer = CALayer()
        }
        layer.frame = frame
        updateTabControlLayer(layer, control: control)
        let maskMotion: OverviewLayerMotion?
        if control.style == .segmented, isDwindle {
            maskMotion = updateDwindleTabMask(layer, frame: frame, card: card, window: window)
        } else {
            layer.mask = nil
            maskMotion = nil
        }
        if layer.superlayer !== card.root { card.root.addSublayer(layer) }
        tabControlLayers[control.handle] = layer
        return maskMotion
    }

    private func updateDwindleTabMask(
        _ layer: CALayer,
        frame: CGRect,
        card: OverviewWindowLayer,
        window: OverviewWindowItem
    ) -> OverviewLayerMotion? {
        func maskFrame(for size: CGSize) -> CGRect {
            CGRect(
                x: 8 - frame.minX, y: -frame.minY,
                width: max(0, size.width - 16), height: max(0, size.height - 30)
            )
        }
        let mask: CALayer
        let motion: OverviewLayerMotion?
        if let existing = layer.mask {
            mask = existing
            motion = nil
        } else {
            mask = CALayer()
            mask.backgroundColor = CGColor(gray: 1, alpha: 1)
            mask.frame = maskFrame(for: card.displayedFrame.size)
            motion = OverviewLayerMotion(mask)
            layer.mask = mask
        }
        mask.frame = maskFrame(for: window.overviewFrame.size)
        return motion
    }

    func addRibbon(for section: OverviewWorkspaceSection, frame: CGRect, to sectionLayer: CALayer) {
        guard !frame.isEmpty else {
            ribbonLayers.removeValue(forKey: section.workspaceId)
            return
        }
        let layers = ribbonLayers[section.workspaceId] ?? (wallpaper: CALayer(), shade: CALayer())
        ribbonLayers[section.workspaceId] = layers
        let clip = CALayer()
        clip.frame = section.ribbonFrame.isEmpty ? frame : section.ribbonFrame
        clip.bounds = clip.frame
        clip.cornerRadius = Metrics.ribbonCornerRadius
        clip.masksToBounds = true
        sectionLayer.addSublayer(clip)
        let ribbon = layers.wallpaper
        ribbon.frame = frame
        ribbon.cornerRadius = Metrics.ribbonCornerRadius
        ribbon.masksToBounds = true
        ribbon.backgroundColor = Colors.ribbonFallback
        ribbon.contentsGravity = .resizeAspectFill
        if let displayId = section.displayId {
            let pixelSize = OverviewWallpaperCache.bucketedPixelSize(frame.width * contentsScale)
            ribbon.contents = wallpaperForDisplay?(displayId, pixelSize)
        } else {
            ribbon.contents = nil
        }
        clip.addSublayer(ribbon)
        let shade = layers.shade
        shade.frame = frame
        shade.cornerRadius = Metrics.ribbonCornerRadius
        shade.backgroundColor = section.isActive ? Colors.ribbonShadeActive : Colors.ribbonShadeInactive
        clip.addSublayer(shade)
    }

    func makeOverflowPillLayer(_ pill: OverviewOverflowPill) -> CALayer {
        let leading = pill.orientation == .horizontal ? "←" : "↓"
        let trailing = pill.orientation == .horizontal ? "→" : "↑"
        let label = pill.edge == .leading ? "\(leading) \(pill.count)" : "\(pill.count) \(trailing)"
        return makeControlLayer(frame: pill.frame, label: label)
    }

    func makeControlLayer(frame: CGRect, label: String) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.backgroundColor = Colors.overflowPillBackground
        layer.cornerRadius = min(frame.height / 2, 12)
        let text = OverviewRenderer.textLayer(size: 12, color: Colors.textWhite, alignment: .center)
        text.string = label
        text.frame = CGRect(x: 0, y: (frame.height - 15) / 2, width: frame.width, height: 15)
        text.contentsScale = contentsScale
        layer.addSublayer(text)
        return layer
    }

    private func updateTabControlLayer(_ layer: CALayer, control: OverviewTabControl) {
        layer.backgroundColor = Colors.overflowPillBackground
        layer.cornerRadius = min(layer.bounds.height / 2, 12)
        if layer.sublayers == nil {
            layer.sublayers = OverviewTabControl.Segment.allCases.map { _ in
                OverviewRenderer.textLayer(size: 12, color: Colors.textWhite, alignment: .center)
            }
        }
        for (segment, child) in zip(OverviewTabControl.Segment.allCases, layer.sublayers ?? []) {
            guard let text = child as? CATextLayer else { continue }
            text.isHidden = control.style == .pickerOnly && segment != .picker
            guard !text.isHidden else { continue }
            let frame = control.frame(for: segment).offsetBy(dx: -control.frame.minX, dy: -control.frame.minY)
            text.frame = CGRect(x: frame.minX, y: (frame.height - 15) / 2, width: frame.width, height: 15)
            text.string = control.label(for: segment)
            text.opacity = control.isEnabled(segment) ? 1 : 0.35
            text.contentsScale = contentsScale
        }
    }

    func workspaceChromeNeedsUpdate(_ layout: OverviewLayout) -> Bool {
        guard let previous = chromeLayout,
              previous.niriColumnsByWorkspace == layout.niriColumnsByWorkspace,
              previous.dwindleGroupsByWorkspace == layout.dwindleGroupsByWorkspace,
              previous.newWorkspaceTarget?.frame == layout.newWorkspaceTarget?.frame,
              previous.workspaceSections.count == layout.workspaceSections.count
        else { return true }
        return zip(previous.workspaceSections, layout.workspaceSections).contains { previous, next in
            previous.workspaceId != next.workspaceId || previous.name != next.name
                || previous.isActive != next.isActive || previous.labelFrame != next.labelFrame
                || previous.visibleFrame != next.visibleFrame
                || previous.ribbonFrame != next.ribbonFrame
                || previous.hiddenColumnsBefore != next.hiddenColumnsBefore
                || previous.hiddenColumnsAfter != next.hiddenColumnsAfter
                || previous.windows.count != next.windows.count
                || zip(previous.windows, next.windows)
                .contains { pair in
                    pair.0.handle != pair.1.handle || pair.0.overviewFrame != pair.1.overviewFrame || pair.0
                        .isDisplayed != pair.1.isDisplayed
                        || pair.0.matchesSearch != pair.1.matchesSearch
                }
        }
    }

    func updateSearch(_ layout: OverviewLayout, state: OverviewRenderState, caretAnimated: Bool) {
        search.frame = layout.searchBarFrame
        let text = state.searchQuery.isEmpty ? Self.searchPlaceholder : state.searchQuery
        if searchText.string as? String != text { searchText.string = text }
        searchText.foregroundColor = state.searchQuery.isEmpty ? Colors.textDimmed : Colors.textWhite
        let textWidth = max(0, search.bounds.width - 124)
        let rowHeight = search.bounds.height / 2
        searchText.fontSize = min(16, max(11, rowHeight - 3))
        searchText.frame = CGRect(
            x: 62,
            y: rowHeight - 1,
            width: textWidth,
            height: rowHeight
        )
        searchText.contentsScale = contentsScale
        searchStatus.string = layout.searchFeedback(query: state.searchQuery)
        searchStatus.fontSize = min(11, max(9, rowHeight - 5))
        searchStatus.frame = CGRect(x: 62, y: 1, width: textWidth, height: rowHeight - 1)
        searchStatus.contentsScale = contentsScale
        searchClear.isHidden = state.searchQuery.isEmpty
        searchClear.frame = CGRect(
            x: search.bounds.width - 62,
            y: (search.bounds.height - 16) / 2,
            width: 62,
            height: 16
        )
        searchClear.contentsScale = contentsScale
        let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: searchText.fontSize)])
            .width
        caret.frame = CGRect(
            x: min(search.bounds.midX + width / 2 + 2, search.bounds.maxX - 64),
            y: rowHeight + 1,
            width: 2,
            height: max(8, rowHeight - 5)
        )
        caret.isHidden = state.searchQuery.isEmpty
        if !caret.isHidden, caretAnimated {
            if caret.animation(forKey: "blink") == nil {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1
                animation.toValue = 0
                animation.duration = .pi / 3
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                caret.add(animation, forKey: "blink")
            }
        } else {
            caret.removeAnimation(forKey: "blink")
            caret.opacity = 1
        }
    }

    func updateDropTarget(_ layout: OverviewLayout) {
        dropTarget.path = nil
        dropTarget.fillColor = Colors.dropTarget
        guard let target = layout.dragTarget else { return }
        let rect: CGRect
        switch target {
        case let .floatingPlacement(_, _, previewFrame):
            rect = previewFrame
            dropTarget.fillColor = nil
        case let .niriWindowInsert(_, handle, position):
            guard let window = layout.window(for: handle) else { return }
            let orientation = layout.workspaceSections.first { $0.workspaceId == window.workspaceId }?
                .orientation ?? .horizontal
            rect = orientation == .horizontal
                ? CGRect(
                    x: window.overviewFrame.minX,
                    y: position == .before ? window.overviewFrame.maxY - Metrics.dropLineHeight : window
                        .overviewFrame.minY,
                    width: window.overviewFrame.width,
                    height: Metrics.dropLineHeight
                )
                : CGRect(
                    x: position == .before ? window.overviewFrame.maxX - Metrics.dropLineHeight : window.overviewFrame
                        .minX,
                    y: window.overviewFrame.minY,
                    width: Metrics.dropLineHeight,
                    height: window.overviewFrame.height
                )
        case let .niriColumnInsert(workspaceId, insertIndex):
            guard let zone = layout.niriColumnDropZonesByWorkspace[workspaceId]?
                .first(where: { $0.insertIndex == insertIndex }) else { return }
            guard let section = layout.workspaceSections.first(where: { $0.workspaceId == workspaceId }) else { return }
            let axis = OverviewRibbonAxis(section.orientation)
            rect = axis.frame(
                start: (axis.minimum(zone.frame) + axis.maximum(zone.frame) - Metrics.dropLineWidth) / 2,
                span: Metrics.dropLineWidth,
                across: zone.frame
            ).intersection(section.ribbonFrame)
        case .newWorkspace:
            guard let target = layout.newWorkspaceTarget else { return }
            rect = target.frame
            dropTarget.fillColor = nil
        case let .workspaceMove(workspaceId):
            guard let section = layout.workspaceSections.first(where: { $0.workspaceId == workspaceId }) else { return }
            rect = section.sectionFrame
            dropTarget.fillColor = nil
        }
        dropTarget.path = CGPath(rect: rect, transform: nil)
    }

    func updateSelectionOutline(_ layout: OverviewLayout, state: OverviewRenderState) {
        selectionOutline.path = nil
        selectionOutline.strokeColor = state.palette.selectedBorder
        guard let selection = state.selection, selection.windowHandle == nil,
              let frame = selection.frame(in: layout) else { return }
        selectionOutline.path = CGPath(
            roundedRect: frame.insetBy(dx: -3, dy: -3),
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil
        )
    }
}
