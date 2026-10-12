// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Cocoa

final class QuakeTerminalWindow: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override var contentLayoutRect: NSRect {
        NSRect(origin: .zero, size: frame.size)
    }

    var initialFrame: NSRect?
    var isAnimating: Bool = false

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        setup()
    }

    private func setup() {
        identifier = NSUserInterfaceItemIdentifier(rawValue: "com.omniwm.quakeTerminal")
        setAccessibilitySubrole(.floatingWindow)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        tabbingMode = .disallowed
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if isAnimating {
            super.setFrame(initialFrame ?? frameRect, display: flag)
        } else {
            super.setFrame(frameRect, display: flag)
        }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
