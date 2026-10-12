// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Cocoa

enum QuakeSplitDividerMetrics {
    static let visibleThickness: CGFloat = 2
    static let hitThickness: CGFloat = 12
}

@MainActor
final class QuakeSplitContainer: NSView {
    private(set) var root: SplitNode
    private(set) var focusedView: GhosttySurfaceView?
    private var dividerViews: [SplitDividerView] = []

    var onFocusChanged: ((GhosttySurfaceView) -> Void)?

    override var isFlipped: Bool {
        false
    }

    init(initialView: GhosttySurfaceView) {
        self.root = .leaf(initialView)
        self.focusedView = initialView
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        addSubview(initialView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func allSurfaceViews() -> [GhosttySurfaceView] {
        root.allSurfaceViews()
    }

    func split(view: GhosttySurfaceView, direction: SplitDirection, newView: GhosttySurfaceView, before: Bool) {
        root = root.inserting(at: view, direction: direction, newView: newView, before: before)
        addSubview(newView)
        focusedView = newView
        relayout(rebuildDividers: true)
    }

    func remove(view: GhosttySurfaceView) -> Bool {
        guard let newRoot = root.removing(view) else {
            return false
        }
        view.removeFromSuperview()
        root = newRoot

        if focusedView === view {
            focusedView = root.allSurfaceViews().first
        }

        relayout(rebuildDividers: true)
        return true
    }

    func contains(view: GhosttySurfaceView) -> Bool {
        root.contains(view)
    }

    func focus(view: GhosttySurfaceView) {
        focusedView = view
        window?.makeFirstResponder(view)
        onFocusChanged?(view)
    }

    func equalize() {
        root = root.equalized()
        relayout(rebuildDividers: true)
    }

    func relayout(rebuildDividers: Bool = false) {
        layoutPanes()
        reconcileDividerViews(rebuild: rebuildDividers)
    }

    private func layoutPanes() {
        let leafBounds = root.calculateBounds(in: bounds)
        for lb in leafBounds {
            lb.view.frame = lb.rect
        }

        updateSurfaceSizes()
    }

    private func reconcileDividerViews(rebuild: Bool) {
        let dividerInfos = root.calculateDividers(
            in: bounds,
            visibleThickness: QuakeSplitDividerMetrics.visibleThickness,
            hitThickness: QuakeSplitDividerMetrics.hitThickness
        )

        if rebuild || dividerViewAddresses() != dividerInfos.map(\.address) {
            rebuildDividerViews(with: dividerInfos)
        } else {
            updateDividerViews(with: dividerInfos)
        }
    }

    private func rebuildDividerViews(with dividerInfos: [SplitNode.DividerInfo]) {
        for dv in dividerViews {
            dv.removeFromSuperview()
        }
        dividerViews.removeAll()

        for info in dividerInfos {
            let dv = SplitDividerView(info: info, container: self)
            dv.frame = info.hitRect
            addSubview(dv)
            dividerViews.append(dv)
        }
    }

    private func updateDividerViews(with dividerInfos: [SplitNode.DividerInfo]) {
        guard dividerViews.count == dividerInfos.count else {
            rebuildDividerViews(with: dividerInfos)
            return
        }

        for (view, info) in zip(dividerViews, dividerInfos) {
            view.update(with: info)
        }
    }

    private func dividerViewAddresses() -> [SplitNode.SplitAddress] {
        dividerViews.map(\.address)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        relayout(rebuildDividers: true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout(rebuildDividers: true)
    }

    private func updateSurfaceSizes() {
        let scale = window?.backingScaleFactor
        for view in root.allSurfaceViews() {
            view.syncGhosttySurfaceSize(backingScale: scale)
        }
    }

    func handleDividerDrag(info: SplitNode.DividerInfo, delta: CGFloat) {
        let totalSize: CGFloat
        switch info.direction {
        case .horizontal: totalSize = bounds.width
        case .vertical: totalSize = bounds.height
        }

        guard totalSize > 0 else { return }
        let ratioDelta = delta / totalSize
        guard let currentRatio = root.ratio(at: info.address) else { return }
        let newRatio = min(max(currentRatio + ratioDelta, 0.1), 0.9)

        root = root.updatingRatio(at: info.address, newRatio: newRatio)
        relayout()
    }
}

@MainActor
private final class SplitDividerView: NSView {
    private var info: SplitNode.DividerInfo
    private weak var container: QuakeSplitContainer?
    private let visibleDividerLayer = CALayer()
    private var dragStart: NSPoint?

    override var isFlipped: Bool {
        false
    }

    var address: SplitNode.SplitAddress {
        info.address
    }

    init(info: SplitNode.DividerInfo, container: QuakeSplitContainer) {
        self.info = info
        self.container = container
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        visibleDividerLayer.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
        layer?.addSublayer(visibleDividerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(with info: SplitNode.DividerInfo) {
        self.info = info
        frame = info.hitRect
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        visibleDividerLayer.frame = info.visibleRect.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch info.direction {
        case .horizontal: cursor = .resizeLeftRight
        case .vertical: cursor = .resizeUpDown
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let current = NSEvent.mouseLocation
        let delta: CGFloat
        switch info.direction {
        case .horizontal: delta = current.x - start.x
        case .vertical: delta = -(current.y - start.y)
        }
        dragStart = current
        container?.handleDividerDrag(info: info, delta: delta)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }
}
