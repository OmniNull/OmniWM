// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellChromeView: NSView {
    let effectView = NSVisualEffectView()
    let glassView = NSGlassEffectView()
    let content: NSView

    var layers: [NSView] {
        [effectView, glassView, content]
    }

    var showsGlass: Bool {
        !glassView.isHidden
    }

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        effectView.state = .active
        effectView.isHidden = true
        glassView.isHidden = true
        effectView.wantsLayer = true
        effectView.layer?.masksToBounds = true
        glassView.style = .regular
        for view in [effectView, glassView] {
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func apply(_ chrome: ShellPopoutChrome, masksContent: Bool) {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effectView.material = reduceTransparency ? .windowBackground : .popover
        effectView.blendingMode = reduceTransparency ? .withinWindow : .behindWindow
        effectView.isHidden = chrome.glass || chrome.clear
        glassView.isHidden = !chrome.glass
        effectView.layer?.cornerRadius = chrome.radius
        glassView.cornerRadius = chrome.radius
        content.layer?.cornerRadius = chrome.radius
        content.layer?.masksToBounds = masksContent
    }

    func fill() {
        autoresizingMask = [.width, .height]
        for view in layers {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
        }
    }
}
