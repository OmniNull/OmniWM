// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreText
import OmniWMShellCore

struct ShellOwnedInputAppearance: Equatable {
    let text: String
    let style: UInt32
    let color: Color
    let width: CGFloat
    let lines: Int
}

extension ShellWidgetSurface {
    var preferredFirstResponder: NSResponder {
        textInputs[focused]?.responder ?? view
    }

    var hasFocusedTextInput: Bool {
        declaredFocus && textInputs[focused] != nil
    }

    func focusPreferredResponder() {
        if hasFocusedTextInput { realizeTextInputFocus() }
        else { view.window?.makeFirstResponder(preferredFirstResponder) }
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
        inputAppearances.removeValue(forKey: handle)
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
        positionTextInputs()
        realizeTextInputFocus()
    }

    func layoutTextInputs() {
        var commands: [ShellLayerCommand] = []
        layoutTextInputs(into: &commands)
        scene.submit(commands, animated: false)
    }

    func layoutTextInputs(into commands: inout [ShellLayerCommand]) {
        if positionTextInputs() { commands += ownedInputCommands() }
    }

    func editorPresentsTransiently(_ handle: ElementHandle, in presentation: SurfacePresentation?) -> Bool {
        guard let owner = manipulationOwner(of: handle) else {
            return editorHasHiddenReveal(handle, in: presentation)
        }
        return manipulation?.target == owner || followMotion(of: owner) != nil
            || presentedScale(of: handle, in: presentation) != 1 || isRevealing(handle, in: presentation)
    }

    private func editorHasHiddenReveal(_ handle: ElementHandle, in presentation: SurfacePresentation?) -> Bool {
        guard let groups = presentation?.groups, !groups.isEmpty else { return false }
        var current = handle
        while layout.core.contains(current) {
            if groups[current]?.visible == false { return true }
            current = layout.core.parent(of: current)
        }
        return false
    }

    @discardableResult
    private func positionTextInputs() -> Bool {
        let presentation = presentation
        var transitioned = false
        for (handle, input) in textInputs where layout.core.contains(handle) {
            let active = declaredFocus && focused == handle
            let transient = active ? editorPresentsTransiently(handle, in: presentation)
                : editorHasHiddenReveal(handle, in: presentation)
            transitioned = input.setPresentsTransiently(transient) || transitioned
            let frame = CGRect(presentedFrame(of: handle, in: presentation))
            var clip = view.bounds
            var opacity: CGFloat = 1
            var ancestor = handle
            while layout.core.contains(ancestor) {
                opacity *= CGFloat(layout.core.paint(of: ancestor).opacity)
                if layout.core.content(of: ancestor).scrolls || isManipulationClip(ancestor) {
                    clip = clip.intersection(CGRect(presentedFrame(of: ancestor, in: presentation)))
                }
                ancestor = layout.core.parent(of: ancestor)
            }
            if transient {
                input.measure(frame: frame, clip: clip, opacity: opacity)
                continue
            }
            let preservingFocus = manipulation != nil && manipulationOwner(of: handle) == manipulation?.target
            input.layout(frame: frame, clip: clip, opacity: opacity, preservingFocus: preservingFocus)
            if manipulationOwner(of: handle) != nil, !active {
                input.view.isHidden = true
            }
        }
        return transitioned
    }

    func focusTextInput(_ input: ShellTextInput) {
        guard textInputs[input.handle] === input,
              !input.view.isHidden || manipulationOwner(of: input.handle) != nil,
              let window = view.window, window.isVisible else { return }
        if let owner = manipulationOwner(of: input.handle) { selectManipulation(owner: owner) }
        recordDeclaredFocus(input.handle)
        layoutTextInputs()
        guard declaredFocus, focused == input.handle, !input.view.isHidden else { return }
        input.focus(in: window)
    }

    func realizeTextInputFocus() {
        guard view.window?.isVisible == true else { return }
        if declaredFocus, let input = textInputs[focused], !input.editing { focusTextInput(input)
            return
        }
        if let input = orderedTextInputs().first(where: { $0.pendingFocus && $0.onScreen }) { focusTextInput(input) }
    }

    func moveTextInputFocus(from handle: ElementHandle, backwards: Bool) {
        let inputs = orderedTextInputs()
        guard let index = inputs.firstIndex(where: { $0.handle == handle }), !inputs.isEmpty else { return }
        let next = (index + (backwards ? -1 : 1) + inputs.count) % inputs.count
        focusTextInput(inputs[next])
    }

    func ownedInputCommands() -> [ShellLayerCommand] {
        guard let text else { return [] }
        return textInputs.compactMap { handle, input in
            guard layout.core.contains(handle), manipulationOwner(of: handle) != nil else { return nil }
            let content = layout.core.content(of: handle)
            let active = declaredFocus && focused == handle
            let value = input.text.isEmpty ? text.string(content.placeholder) : input.text
            let frame = layout.core.layoutFrame(of: handle)
            let font = text.font(content.style)
            let lineHeight = max(1, CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
            let lines = content.inputMultiline ? max(2, Int(CGFloat(frame.height) / lineHeight)) : 1
            let appearance = ShellOwnedInputAppearance(
                text: active && !input.presentsTransiently ? "" : value,
                style: content.style,
                color: content.color,
                width: CGFloat(frame.width),
                lines: lines
            )
            guard inputAppearances[handle] != appearance else { return nil }
            inputAppearances[handle] = appearance
            return .text(
                slot: handle.slot,
                text: appearance.text,
                style: appearance.style,
                color: palette.color(appearance.color, default: .foreground),
                maxWidth: appearance.width,
                lines: appearance.lines,
                animation: nil
            )
        }
    }

    func reconcileOwnedEditorFocus() {
        guard declaredFocus, let input = textInputs[focused], let owner = manipulationOwner(of: focused),
              manipulation?.target != owner else { return }
        let frame = presentedFrame(of: input.handle)
        let point = CGPoint(x: CGFloat(frame.x + frame.width / 2), y: CGFloat(frame.y + frame.height / 2))
        let top = element(at: point) { $0.acceptsPointer }
        if manipulationOwner(of: top) != owner { blurDeclaredFocus() }
    }

    func refreshOwnedInputs() {
        guard !manipulationTargets.isEmpty else { return }
        positionTextInputs()
        scene.submit(ownedInputCommands() + effectNeutralCommands(), animated: false)
    }

    func routeNativeInput(_ event: NSEvent, at point: CGPoint) -> Bool {
        let handle = element(at: point) { $0.acceptsPointer }
        guard let input = textInputs[handle], manipulationOwner(of: handle) != nil else { return false }
        focusTextInput(input)
        if let field = input.field { field.mouseDown(with: event) }
        else { input.editor?.mouseDown(with: event) }
        return true
    }

    func allowsNativeHit(_ hit: NSView, at point: CGPoint) -> Bool {
        guard !manipulationTargets.isEmpty else { return true }
        guard let input = textInputs.values.first(where: { hit === $0.view || hit.isDescendant(of: $0.view) }),
              let owner = manipulationOwner(of: input.handle) else { return true }
        let top = element(at: point) { $0.acceptsPointer }
        return manipulationOwner(of: top) == owner
    }

    private func orderedTextInputs() -> [ShellTextInput] {
        textInputs.values.filter { !$0.view.isHidden || manipulationOwner(of: $0.handle) != nil && $0.onScreen }
            .sorted {
                let lhs = $0.view.frame
                let rhs = $1.view.frame
                return lhs.minY == rhs.minY ? lhs.minX < rhs.minX : lhs.minY < rhs.minY
            }
    }
}
