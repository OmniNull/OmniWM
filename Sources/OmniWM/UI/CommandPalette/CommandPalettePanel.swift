// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import QuartzCore
import SwiftUI

@MainActor
final class CommandPalettePanel {
    static let width: CGFloat = 640
    static let expandedHeight: CGFloat = 430
    static let collapsedHeight: CGFloat = 56
    static let expansionDuration: TimeInterval = 0.3
    static let dismissalDuration: TimeInterval = 0.626

    private(set) var panel: NSPanel?
    private let motionPolicy: MotionPolicy
    private let ownedWindowRegistry: OwnedWindowRegistry
    private var savedOrigin: NSPoint?
    private var savedExpandedSize = NSSize(width: CommandPalettePanel.width, height: CommandPalettePanel.expandedHeight)
    private var displayedExpandedSize = NSSize(
        width: CommandPalettePanel.width,
        height: CommandPalettePanel.expandedHeight
    )
    private var transitionID = 0
    private var dismissalCompletion: (@MainActor () -> Void)?

    var animatesPresentation: Bool {
        motionPolicy.animationsEnabled
    }

    init(motionPolicy: MotionPolicy, ownedWindowRegistry: OwnedWindowRegistry) {
        self.motionPolicy = motionPolicy
        self.ownedWindowRegistry = ownedWindowRegistry
    }

    func create(controller: CommandPaletteController) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.expandedHeight),
            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.delegate = controller
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.contentMinSize = NSSize(width: Self.width, height: Self.collapsedHeight)
        panel.collectionBehavior = [.moveToActiveSpace]

        let hostingView = NSHostingView(rootView: CommandPaletteView(
            controller: controller,
            motionPolicy: motionPolicy
        ))
        panel.contentView = hostingView

        ownedWindowRegistry.register(panel)
        self.panel = panel
    }

    func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main else { return }

        transitionID += 1
        dismissalCompletion = nil
        panel.alphaValue = animatesPresentation ? 0 : 1
        panel.ignoresMouseEvents = false

        let visibleFrame = screen.visibleFrame
        let size = NSSize(
            width: min(savedExpandedSize.width, visibleFrame.width),
            height: min(savedExpandedSize.height, visibleFrame.height)
        )
        let savedTopCenter = savedOrigin.map {
            NSPoint(
                x: $0.x + displayedExpandedSize.width / 2,
                y: $0.y + displayedExpandedSize.height - Self.collapsedHeight / 2
            )
        }
        let preferredOrigin = if let savedOrigin, let savedTopCenter, screen.frame.contains(savedTopCenter) {
            savedOrigin
        } else {
            NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2 + 80)
        }
        let x = min(max(preferredOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
        let y = min(max(preferredOrigin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        displayedExpandedSize = size
        panel.contentMinSize = NSSize(width: Self.width, height: Self.collapsedHeight)
        panel.setFrame(
            NSRect(x: x, y: y + size.height - Self.collapsedHeight, width: size.width, height: Self.collapsedHeight),
            display: true
        )
    }

    func reveal(_ panel: NSPanel) {
        guard animatesPresentation else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func expand(_ panel: NSPanel) {
        let frame = NSRect(
            x: panel.frame.minX,
            y: panel.frame.maxY - displayedExpandedSize.height,
            width: panel.frame.width,
            height: displayedExpandedSize.height
        )
        transitionID += 1
        panel.contentMinSize = NSSize(width: Self.width, height: Self.expandedHeight)
        guard animatesPresentation else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.expansionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    func rememberPlacement(_ panel: NSPanel, expanded: Bool) {
        let frame = panel.frame
        if expanded, frame.height >= Self.expandedHeight {
            if frame.size != displayedExpandedSize {
                savedExpandedSize = frame.size
            }
            displayedExpandedSize = frame.size
        }
        savedOrigin = NSPoint(
            x: frame.minX,
            y: frame.maxY - displayedExpandedSize.height
        )
    }

    func dismiss(_ panel: NSPanel, completion: @escaping @MainActor () -> Void) {
        transitionID += 1
        let currentTransition = transitionID
        dismissalCompletion = completion
        let frame = NSRect(
            x: panel.frame.minX,
            y: panel.frame.maxY - Self.collapsedHeight,
            width: panel.frame.width,
            height: Self.collapsedHeight
        )
        panel.contentMinSize = NSSize(width: Self.width, height: Self.collapsedHeight)
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.dismissalDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.completeDismissal(currentTransition)
            }
        }
    }

    private func completeDismissal(_ transition: Int) {
        guard transitionID == transition else { return }
        panel?.orderOut(nil)
        let completion = dismissalCompletion
        dismissalCompletion = nil
        completion?()
    }
}
