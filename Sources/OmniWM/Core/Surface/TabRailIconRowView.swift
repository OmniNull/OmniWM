// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

final class TabRailIconRowView: NSView {
    let imageView = NSImageView()
    let selectionLayer = CAShapeLayer()
    private let motionPolicy: MotionPolicy
    private var selected = false
    private var hovered = false

    init(image: NSImage?, motionPolicy: MotionPolicy) {
        self.motionPolicy = motionPolicy
        super.init(frame: .zero)
        wantsLayer = true
        selectionLayer.fillColor = NSColor.clear.cgColor
        selectionLayer.actions = [
            "path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(),
            "bounds": NSNull(), "position": NSNull()
        ]
        layer?.addSublayer(selectionLayer)
        imageView.image = image ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let size = TabRailStyle.iconSize
        imageView.frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        selectionLayer.frame = bounds
        selectionLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 5, cornerHeight: 5, transform: nil
        )
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        selectionLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    func update(selected: Bool, hovered: Bool, animate: Bool) {
        let changed = self.selected != selected
        guard changed || self.hovered != hovered else { return }
        self.selected = selected
        self.hovered = hovered
        updateAppearance(animate: animate && changed && motionPolicy.animationsEnabled)
    }

    func refreshAppearance() {
        updateAppearance(animate: false)
    }

    private func updateAppearance(animate: Bool) {
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let fill = selected
            ? NSColor.controlAccentColor.withAlphaComponent(highContrast ? 0.45 : 0.25)
            : (hovered ? TabRailMetrics.hoverColor : NSColor.clear)
        let fromColor = selectionLayer.presentation()?.fillColor ?? selectionLayer.fillColor
        selectionLayer.removeAnimation(forKey: "selection.color")
        selectionLayer.fillColor = fill.cgColor
        selectionLayer.strokeColor = selected ? NSColor.labelColor.withAlphaComponent(highContrast ? 1 : 0.65)
            .cgColor : nil
        selectionLayer.lineWidth = highContrast ? 2 : 1
        guard animate, let fromColor else { return }
        let animation = CABasicAnimation(keyPath: "fillColor")
        animation.fromValue = fromColor
        animation.toValue = fill.cgColor
        animation.duration = 0.25
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        selectionLayer.add(animation, forKey: "selection.color")
    }
}
