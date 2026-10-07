// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class WorkspaceBarPanel: NSPanel, NSWindowDelegate {
    var targetScreen: NSScreen?
    var interactionHandler: ((NSEvent, WorkspaceBarPanel) -> Bool)?
    var onSheetChanged: (() -> Void)?
    private(set) var hasPresentedSheet = false

    func windowWillBeginSheet(_ notification: Notification) {
        hasPresentedSheet = true
        onSheetChanged?()
    }

    func windowDidEndSheet(_ notification: Notification) {
        hasPresentedSheet = false
        onSheetChanged?()
    }

    override func sendEvent(_ event: NSEvent) {
        if interactionHandler?(event, self) == true { return }
        super.sendEvent(event)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let constrainingScreen = targetScreen ?? screen else {
            return frameRect
        }

        var constrained = frameRect
        let screenFrame = constrainingScreen.frame

        constrained.origin.x = max(screenFrame.minX, min(constrained.origin.x, screenFrame.maxX - constrained.width))
        constrained.origin.y = WorkspaceBarGeometry.constrainedOriginY(
            constrained.origin.y, height: constrained.height, screenFrame: screenFrame
        )

        return constrained
    }

    static func defaultPanel() -> WorkspaceBarPanel {
        let panel = WorkspaceBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.delegate = panel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        return panel
    }
}
