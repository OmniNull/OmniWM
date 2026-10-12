// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class HiddenBarPanelController {
    private static let surfaceId = "hidden-bar-panel"
    nonisolated static let alongPadding: CGFloat = 4
    nonisolated static let crossPadding: CGFloat = 2
    nonisolated static let lineSpacing: CGFloat = 2
    nonisolated static let minimumTargetSide: CGFloat = 20

    var onActivate: ((MenuBarItemKey) -> Void)?
    var onVisibilityChanged: (() -> Void)?
    var onWorkspaceBarJoin: ((HiddenBarPanelPlacement.Join?) -> Void)?
    var isExemptWindow: ((NSWindow) -> Bool)?
    var motionPolicy: MotionPolicy?

    private var model: HiddenBarPanelModel?
    private(set) var panel: NonactivatingPanel?
    private var drawer: HiddenBarDrawerView? {
        panel?.contentView as? HiddenBarDrawerView
    }

    private let dismissalMonitor = PanelDismissalMonitor()
    private weak var previousKeyWindow: NSWindow?
    private weak var previousFirstResponder: NSResponder?
    private(set) var isVisible = false

    func toggle(placement: HiddenBarPanelPlacement, items: [HiddenBarGlyph]) {
        if isVisible {
            dismiss()
        } else {
            show(placement: placement, items: items)
        }
    }

    func dismiss(animated: Bool = true) {
        guard let panel, isVisible || (!animated && panel.isVisible) else { return }
        let edge = model?.placement?.attachment.edge ?? .below
        let keyWindow = previousKeyWindow
        let firstResponder = previousFirstResponder
        isVisible = false
        previousKeyWindow = nil
        previousFirstResponder = nil
        dismissalMonitor.stop()
        panel.ignoresMouseEvents = true
        panel.contentView?.setAccessibilityHidden(true)
        panel.resignKey()
        register(panel, interactive: false)
        drawer?.setVisible(
            false, edge: edge, motion: animated ? motionPolicy?.snapshot() ?? .disabled : .disabled
        ) { [weak self] in
            self?.completeDismissal()
        }
        if let keyWindow, keyWindow.isVisible {
            keyWindow.makeKey()
            if let firstResponder {
                keyWindow.makeFirstResponder(firstResponder)
            }
        }
    }

    private func completeDismissal() {
        guard !isVisible else { return }
        OwnedWindowRegistry.shared.unregister(surfaceId: Self.surfaceId)
        panel?.orderOut(nil)
        onWorkspaceBarJoin?(nil)
        onVisibilityChanged?()
    }

    func activate(_ key: MenuBarItemKey) {
        guard isVisible else { return }
        dismiss(animated: false)
        onActivate?(key)
    }

    func teardown() {
        dismiss(animated: false)
        model?.items = []
        panel?.close()
        panel = nil
        model = nil
    }

    nonisolated static func glyphDisplayWidth(for size: CGSize) -> CGFloat {
        max(minimumTargetSide, size.width.rounded(.up))
    }

    nonisolated static func rowRanges(itemWidths: [CGFloat], maxContentWidth: CGFloat) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var accumulated: CGFloat = 0
        for (index, width) in itemWidths.enumerated() {
            let candidate = index == start ? width : accumulated + width
            if index > start, candidate > maxContentWidth {
                ranges.append(start ..< index)
                start = index
                accumulated = width
            } else {
                accumulated = candidate
            }
        }
        if start < itemWidths.count {
            ranges.append(start ..< itemWidths.count)
        }
        return ranges
    }

    nonisolated static func itemRanges(
        itemWidths: [CGFloat], placement: HiddenBarPanelPlacement
    ) -> [Range<Int>] {
        guard placement.isVertical else {
            return rowRanges(itemWidths: itemWidths, maxContentWidth: placement.maxContentWidth)
        }
        let capacity = max(1, Int(placement.maxContentHeight / placement.cellHeight))
        return stride(from: 0, to: itemWidths.count, by: capacity).map {
            $0 ..< min($0 + capacity, itemWidths.count)
        }
    }

    nonisolated static func barSize(
        itemWidths: [CGFloat], placement: HiddenBarPanelPlacement
    ) -> CGSize {
        let cellHeight = placement.cellHeight
        guard !itemWidths.isEmpty else {
            return CGSize(width: 140, height: cellHeight + crossPadding * 2)
        }
        let ranges = itemRanges(itemWidths: itemWidths, placement: placement)
        let lines = CGFloat(ranges.count)
        if placement.isVertical {
            let width = ranges.reduce(CGFloat.zero) { $0 + (itemWidths[$1].max() ?? 0) }
                + lineSpacing * (lines - 1)
            let count = CGFloat(ranges.first?.count ?? 0)
            return CGSize(width: width + crossPadding * 2, height: count * cellHeight + alongPadding * 2)
        }
        let maxRowWidth = ranges.map { itemWidths[$0].reduce(0, +) }.max() ?? 0
        return CGSize(
            width: min(maxRowWidth, placement.maxContentWidth) + alongPadding * 2,
            height: lines * cellHeight + (lines - 1) * lineSpacing + crossPadding * 2
        )
    }

    private func show(placement: HiddenBarPanelPlacement, items: [HiddenBarGlyph]) {
        let model = self.model ?? HiddenBarPanelModel()
        self.model = model
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        if NSApp.keyWindow !== panel {
            previousKeyWindow = NSApp.keyWindow
            previousFirstResponder = NSApp.keyWindow?.firstResponder
        }
        applyContent(items: items, placement: placement, panel: panel, model: model)
        if !panel.isVisible {
            drawer?.setVisible(false, edge: placement.attachment.edge, motion: .disabled)
        }
        panel.ignoresMouseEvents = false
        panel.contentView?.setAccessibilityHidden(false)

        register(panel, interactive: true)
        panel.makeKeyAndOrderFront(nil)
        isVisible = true
        onVisibilityChanged?()
        drawer?.setVisible(true, edge: placement.attachment.edge, motion: motionPolicy?.snapshot() ?? .disabled)
        dismissalMonitor.start(
            panels: [panel],
            isExemptWindow: { [weak self] window in
                self?.isExemptWindow?(window) == true
            },
            containsPanelPoint: { panel, point in
                guard let drawer = panel.contentView as? HiddenBarDrawerView else { return false }
                return drawer.containsContent(at: drawer.convert(panel.convertPoint(fromScreen: point), from: nil))
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )
        let drawer = self.drawer
        let generation = drawer?.generation
        Task { @MainActor [weak self, weak drawer] in
            guard let self, let drawer, self.isVisible, self.drawer === drawer,
                  drawer.generation == generation else { return }
            self.model?.focusRequest &+= 1
        }
    }

    private func register(_ panel: NSPanel, interactive: Bool) {
        OwnedWindowRegistry.shared.register(
            panel,
            surfaceId: Self.surfaceId,
            policy: SurfacePolicy(
                kind: .hiddenBarPanel,
                hitTestPolicy: interactive ? .interactive : .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: interactive
            )
        )
    }

    func refresh(items: [HiddenBarGlyph]) {
        guard isVisible, let panel, let model, let placement = model.placement else { return }
        applyContent(items: items, placement: placement, panel: panel, model: model)
    }

    func updateWorkspaceBarPlacement(_ placement: (Monitor.ID) -> HiddenBarPanelPlacement?) {
        guard isVisible, let panel, let model, let bar = model.placement?.workspaceBar else { return }
        guard let next = placement(bar.monitorId) else {
            dismiss(animated: false)
            return
        }
        guard next != model.placement else { return }
        applyContent(items: model.items, placement: next, panel: panel, model: model)
    }

    private func applyContent(
        items: [HiddenBarGlyph],
        placement: HiddenBarPanelPlacement,
        panel: NonactivatingPanel,
        model: HiddenBarPanelModel
    ) {
        model.items = items
        model.placement = placement
        let widths = items.map { Self.glyphDisplayWidth(for: $0.size) }
        let size = Self.barSize(itemWidths: widths, placement: placement)
        let layout = placement.layout(size: size)
        model.layout = layout
        let appearance = NSApp.appearance
        panel.appearance = appearance
        panel.contentView?.appearance = appearance
        panel.hasShadow = placement.workspaceBar == nil
        panel.setFrame(layout.frame, display: true)
        drawer?.setRevealShape(
            layout.contour(edge: placement.attachment.edge).cgPath,
            spread: layout.seam == nil ? 0 : HiddenBarPanelPlacement.liftMargin
        )
        onWorkspaceBarJoin?(layout.squaresBar ? placement.join : nil)
    }

    private func makePanel(model: HiddenBarPanelModel) -> NonactivatingPanel {
        let panel = NonactivatingPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 200, height: 60)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        let hosting = NSHostingView(
            rootView: HiddenBarPanelView(
                model: model,
                onActivate: { [weak self] key in
                    self?.activate(key)
                },
                onDismiss: { [weak self] in
                    self?.dismiss()
                }
            )
        )
        hosting.sizingOptions = []
        panel.contentView = HiddenBarDrawerView(contentView: hosting)
        return panel
    }
}
