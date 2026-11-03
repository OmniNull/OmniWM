// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

final class ShellAppNativeWindow: NSWindow {
    private var blockedBySheet: Bool {
        guard let sheet = parent?.attachedSheet else { return false }
        return sheet !== self
    }

    override var canBecomeKey: Bool {
        !blockedBySheet && super.canBecomeKey
    }

    override var canBecomeMain: Bool {
        !blockedBySheet && super.canBecomeMain
    }

    override func sendEvent(_ event: NSEvent) {
        if blockedBySheet {
            switch event.type {
            case .leftMouseDown,
                 .leftMouseUp,
                 .rightMouseDown,
                 .rightMouseUp,
                 .mouseMoved,
                 .leftMouseDragged,
                 .rightMouseDragged,
                 .mouseEntered,
                 .mouseExited,
                 .keyDown,
                 .keyUp,
                 .flagsChanged,
                 .scrollWheel,
                 .tabletPoint,
                 .tabletProximity,
                 .otherMouseDown,
                 .otherMouseUp,
                 .otherMouseDragged,
                 .gesture,
                 .magnify,
                 .swipe,
                 .rotate,
                 .beginGesture,
                 .endGesture,
                 .smartMagnify,
                 .quickLook,
                 .pressure,
                 .directTouch,
                 .changeMode,
                 .mouseCancelled:
                return
            case .appKitDefined,
                 .systemDefined,
                 .applicationDefined,
                 .periodic,
                 .cursorUpdate:
                break
            @unknown default:
                break
            }
        }
        super.sendEvent(event)
    }

    override func miniaturize(_ sender: Any?) {
        guard parent == nil, sheetParent == nil else { return }
        super.miniaturize(sender)
    }

    override func toggleFullScreen(_ sender: Any?) {
        guard parent == nil, sheetParent == nil else { return }
        super.toggleFullScreen(sender)
    }
}
