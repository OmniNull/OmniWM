// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class WorkspaceBarDragGhost: NSPanel {
    private static let iconSize: CGFloat = 24
    private static let padding: CGFloat = 6

    private let ownedWindowRegistry: OwnedWindowRegistry
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var surfaceId: String?

    init(icon: NSImage?, ownedWindowRegistry: OwnedWindowRegistry) {
        self.ownedWindowRegistry = ownedWindowRegistry
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 120, height: Self.iconSize + Self.padding * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        ignoresMouseEvents = true
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        configureContent(icon: icon)

        let surfaceId = "workspace-bar-drag-ghost-\(ObjectIdentifier(self).hashValue)"
        self.surfaceId = surfaceId
        ownedWindowRegistry.register(
            self,
            surfaceId: surfaceId,
            policy: SurfacePolicy(
                kind: .dragGhost,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
    }

    isolated deinit {
        destroy()
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    private func configureContent(icon: NSImage?) {
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        contentView = background

        iconView.image = icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        background.addSubview(iconView)
        background.addSubview(label)
    }

    func update(label text: String, isValid: Bool) {
        guard label.stringValue != text || label.textColor != (isValid ? .labelColor : .systemRed) else { return }
        label.stringValue = text
        label.textColor = isValid ? .labelColor : .systemRed
        label.isHidden = text.isEmpty
        let labelWidth = text.isEmpty ? 0 : min(240, ceil(label.intrinsicContentSize.width))
        let width = Self.iconSize + Self.padding * 2 + (text.isEmpty ? 0 : labelWidth + Self.padding)
        let height = Self.iconSize + Self.padding * 2
        setContentSize(CGSize(width: width, height: height))
        iconView.frame = CGRect(x: Self.padding, y: Self.padding, width: Self.iconSize, height: Self.iconSize)
        label.frame = CGRect(
            x: Self.padding * 2 + Self.iconSize,
            y: (height - label.intrinsicContentSize.height) / 2,
            width: labelWidth,
            height: label.intrinsicContentSize.height
        )
    }

    func moveTo(cursorLocation: CGPoint) {
        guard surfaceId != nil else { return }
        var target = CGRect(
            origin: CGPoint(x: cursorLocation.x + 12, y: cursorLocation.y - frame.height - 12),
            size: frame.size
        )
        if let screen = NSScreen.screen(containing: cursorLocation) {
            target = FloatingFrameGeometry.clamped(target, in: screen.frame)
        }
        setFrameOrigin(target.origin)
        if !isVisible {
            orderFrontRegardless()
        }
    }

    func destroy() {
        guard let surfaceId else { return }
        self.surfaceId = nil
        ownedWindowRegistry.unregister(surfaceId: surfaceId)
        orderOut(nil)
        close()
    }
}
