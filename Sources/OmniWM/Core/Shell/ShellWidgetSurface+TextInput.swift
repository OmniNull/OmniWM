// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

extension ShellWidgetSurface {
    var preferredFirstResponder: NSResponder {
        textInputs[focused]?.responder ?? view
    }

    var hasFocusedTextInput: Bool {
        declaredFocus && textInputs[focused] != nil
    }

    func insertTextInput(_ handle: ElementHandle) {
        guard textInputs[handle] == nil else { return }
        let input = ShellTextInput(
            handle: handle,
            surface: self,
            multiline: layout.core.content(of: handle).inputMultiline
        )
        textInputs[handle] = input
        view.addSubview(input.view)
    }

    func removeTextInput(_ handle: ElementHandle) {
        textInputs.removeValue(forKey: handle)?.remove()
    }

    func updateTextInputs() {
        guard !textInputs.isEmpty, let text else { return }
        for (handle, existing) in textInputs {
            guard layout.core.contains(handle) else {
                removeTextInput(handle)
                continue
            }
            let content = layout.core.content(of: handle)
            if (existing.editor != nil) != content.inputMultiline {
                removeTextInput(handle)
                insertTextInput(handle)
            }
            guard let input = textInputs[handle] else { continue }
            let color = NSColor(cgColor: palette.color(content.color, default: .foreground)) ?? .labelColor
            input.update(content: content, text: text, color: color)
        }
        layoutTextInputs()
        realizeTextInputFocus()
    }

    func layoutTextInputs() {
        for (handle, input) in textInputs where layout.core.contains(handle) {
            let frame = CGRect(layout.core.absoluteFrame(of: handle))
            var clip = view.bounds
            var opacity: CGFloat = 1
            var ancestor = handle
            while layout.core.contains(ancestor) {
                opacity *= CGFloat(layout.core.paint(of: ancestor).opacity)
                if layout.core.content(of: ancestor).scrolls {
                    clip = clip.intersection(CGRect(layout.core.absoluteFrame(of: ancestor)))
                }
                ancestor = layout.core.parent(of: ancestor)
            }
            input.layout(frame: frame, clip: clip, opacity: opacity)
        }
    }

    func focusTextInput(_ input: ShellTextInput) {
        guard textInputs[input.handle] === input, !input.view.isHidden,
              let window = view.window, window.isVisible else { return }
        focusDeclared(input.handle)
        if window.makeFirstResponder(input.responder) { input.focusApplied() }
    }

    func realizeTextInputFocus() {
        guard view.window?.isVisible == true else { return }
        if declaredFocus, let input = textInputs[focused], !input.editing { focusTextInput(input)
            return
        }
        if let input = orderedTextInputs().first(where: \.pendingFocus) { focusTextInput(input) }
    }

    func moveTextInputFocus(from handle: ElementHandle, backwards: Bool) {
        let inputs = orderedTextInputs()
        guard let index = inputs.firstIndex(where: { $0.handle == handle }), !inputs.isEmpty else { return }
        let next = (index + (backwards ? -1 : 1) + inputs.count) % inputs.count
        focusTextInput(inputs[next])
    }

    private func orderedTextInputs() -> [ShellTextInput] {
        textInputs.values.filter { !$0.view.isHidden }.sorted {
            let lhs = $0.view.frame
            let rhs = $1.view.frame
            return lhs.minY == rhs.minY ? lhs.minX < rhs.minX : lhs.minY < rhs.minY
        }
    }
}
