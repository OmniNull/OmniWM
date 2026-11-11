// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellInputField: NSTextField {
    weak var owner: ShellTextInput?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { owner?.beganEditing() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        owner?.requestFocus()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        owner?.editCommand(event) == true || super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ShellInputTextView: NSTextView {
    weak var owner: ShellTextInput?
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { owner?.beganEditing() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { owner?.endedEditing() }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        owner?.requestFocus()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        owner?.editCommand(event) == true || super.performKeyEquivalent(with: event)
    }

    override func unmarkText() {
        super.unmarkText()
        owner?.changed()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = CGPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        (placeholder as NSString).draw(
            at: origin,
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.placeholderTextColor
            ]
        )
    }
}

@MainActor
final class ShellInputClipView: NSView {
    override var isFlipped: Bool {
        true
    }
}
