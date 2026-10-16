// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore

extension ShellWidgetSurface {
    func focusPath() -> [ElementHandle] {
        guard focusAxis != nil || declaredFocus, layout.core.contains(focused) else { return [] }
        let frame = layout.core.absoluteFrame(of: focused)
        return layout.core.hitPath(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2) { $0.hasHoverEffect }
            .filter {
                let inner = layout.core.absoluteFrame(of: $0)
                return inner.x >= frame.x && inner.y >= frame.y
                    && inner.x + inner.width <= frame.x + frame.width && inner.y + inner.height <= frame.y + frame
                    .height
            }
    }

    func focusRingTarget(in path: [ElementHandle]) -> ElementHandle {
        guard layout.core.contains(focused), layout.core.content(of: focused).focusRing else { return .none }
        let target = path.last ?? focused
        return layout.core.content(of: target).focusRing ? target : .none
    }

    func focusLines() -> (items: [ElementHandle], starts: [Int]) {
        guard let focusAxis else { return ([], []) }
        let vertical = focusAxis == .vertical
        var entries: [FocusEntry] = []
        for handle in layout.core.elements(matching: Self.isAction) where layout.core.kind(of: handle) != .slider {
            entries.append((handle, layout.core.absoluteFrame(of: handle)))
        }
        entries.sort(by: vertical ? Self.columnsFirst : Self.rowsFirst)
        var items: [ElementHandle] = []
        items.reserveCapacity(entries.count)
        var starts: [Int] = []
        var lineEnd = -Float.infinity
        for entry in entries {
            let start = vertical ? entry.frame.x : entry.frame.y
            if start >= lineEnd {
                starts.append(items.count)
                lineEnd = start + (vertical ? entry.frame.width : entry.frame.height)
            }
            items.append(entry.handle)
        }
        return (items, starts)
    }

    private typealias FocusEntry = (handle: ElementHandle, frame: Rect)

    private nonisolated static func isAction(_ content: Content) -> Bool {
        content.action != 0
    }

    private nonisolated static func rowsFirst(_ lhs: FocusEntry, _ rhs: FocusEntry) -> Bool {
        (lhs.frame.y, lhs.frame.x) < (rhs.frame.y, rhs.frame.x)
    }

    private nonisolated static func columnsFirst(_ lhs: FocusEntry, _ rhs: FocusEntry) -> Bool {
        (lhs.frame.x, lhs.frame.y) < (rhs.frame.x, rhs.frame.y)
    }

    func handleKey(_ code: UInt16, shift: Bool) -> Bool {
        guard !hasFocusedTextInput, let focusAxis else { return false }
        let vertical = focusAxis == .vertical
        switch Int(code) {
        case kVK_Tab: moveFocus(by: shift ? -1 : 1, acrossLines: false)
        case kVK_LeftArrow: moveFocus(by: -1, acrossLines: vertical)
        case kVK_RightArrow: moveFocus(by: 1, acrossLines: vertical)
        case kVK_UpArrow: moveFocus(by: -1, acrossLines: !vertical)
        case kVK_DownArrow: moveFocus(by: 1, acrossLines: !vertical)
        case kVK_Return,
             kVK_ANSI_KeypadEnter,
             kVK_Space: activateFocus()
        default: return false
        }
        return true
    }

    private func moveFocus(by offset: Int, acrossLines: Bool) {
        let (items, starts) = focusLines()
        guard let index = items.firstIndex(of: focused) else {
            focused = items.first ?? .none
            refreshFocus()
            return
        }
        if !acrossLines {
            focused = items[(index + offset + items.count) % items.count]
        } else if starts.count > 1, let line = starts.lastIndex(where: { $0 <= index }) {
            let next = (line + offset + starts.count) % starts.count
            let end = next + 1 < starts.count ? starts[next + 1] : items.count
            focused = items[min(starts[next] + index - starts[line], end - 1)]
        }
        refreshFocus()
    }

    func refreshFocus() {
        var commands: [ShellLayerCommand] = []
        updateHover(into: &commands, reapply: false)
        scene.submit(commands, animated: animates && motionPolicy.animationsEnabled)
    }

    private func activateFocus() {
        guard layout.core.contains(focused) else { return }
        if let input = textInputs[focused] { focusTextInput(input)
            return
        }
        let content = layout.core.content(of: focused)
        onAction?(ShellClick(
            action: content.action,
            opensPopout: content.opensPopout,
            anchor: anchor(of: focused),
            event: ShellEvent(button: .left),
            target: content.target,
            source: focused
        ))
    }

    static func ringed(_ base: Paint) -> Paint {
        var paint = base
        paint.stroke = Color(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0,
            role: UInt16(ShellRole.accent.rawValue + 1) | UInt16(255) << 8
        )
        paint.strokeWidth = 2
        return paint
    }

    func hoverPaint(_ handle: ElementHandle) -> Paint {
        Self.hovered(layout.core.paint(of: handle), by: layout.core.content(of: handle))
    }

    static func hovered(_ base: Paint, by content: Content) -> Paint {
        var paint = base
        if content.hoverMaterial > 0 {
            paint.material = content.hoverMaterial
        }
        if content.hover.isVisible {
            paint.fill = content.hover
        }
        if content.hoverScale > 0 {
            paint.scale = content.hoverScale
        }
        if content.hoverOpacity >= 0 {
            paint.opacity = content.hoverOpacity
        }
        return paint
    }
}

extension ShellWidgetSurface {
    func focusDeclared(_ handle: ElementHandle) {
        guard layout.core.contains(handle), layout.core.content(of: handle).focusable else { return }
        focused = handle
        let changed = !declaredFocus
        declaredFocus = true
        updateDeclaredKeys()
        refreshFocus()
        if changed { onFocusChange?(true) }
        view.window?.makeFirstResponder(preferredFirstResponder)
    }

    func blurDeclaredFocus() {
        guard declaredFocus else { return }
        let input = textInputs[focused]
        declaredFocus = false
        focused = .none
        declaredKeys = []
        keyDeclaration = 0
        cancelInput(hover: false)
        refreshFocus()
        input?.blur()
        onFocusChange?(false)
    }

    func updateDeclaredKeys() {
        guard declaredFocus else { return }
        if !layout.core.contains(focused) || !layout.core.content(of: focused).focusable {
            let root = layout.core.rootHandle
            guard layout.core.contains(root) else { blurDeclaredFocus()
                return
            }
            let next = layout.core.content(of: root).focusable ? root : layout.core
                .firstDescendant(of: root) { $0.focusable }
            guard next.slot >= 0 else { blurDeclaredFocus()
                return
            }
            focused = next
        }
        let content = layout.core.content(of: focused)
        guard content.keys != keyDeclaration else { return }
        keyDeclaration = content.keys
        declaredKeys = Set((text?.string(content.keys) ?? "").split(separator: "\n").map(String.init))
    }

    func handleDeclaredKey(_ event: NSEvent) -> Bool {
        guard !hasFocusedTextInput, declaredFocus, layout.core.contains(focused),
              let key = Self.keyName(code: event.keyCode, characters: event.charactersIgnoringModifiers)
        else { return false }
        let content = layout.core.content(of: focused)
        let consumed = content.keyAction != 0 && declaredKeys.contains(key)
        if consumed {
            var input = ShellEvent(button: .none, modifiers: event.modifierFlags)
            input.kind = .key
            input.key = key
            input.characters = event.characters
            input.isRepeat = event.isARepeat
            let capture = capture(focused)
            emit(content.keyAction, capture: capture, point: capture.origin, event: input)
        }
        if consumed, key == "escape" { blurDeclaredFocus() }
        return consumed
    }

    static func keyName(code: UInt16, characters: String?) -> String? {
        switch Int(code) {
        case kVK_Escape: "escape"
        case kVK_Return,
             kVK_ANSI_KeypadEnter: "return"
        case kVK_Space: "space"
        case kVK_Tab: "tab"
        case kVK_LeftArrow: "left"
        case kVK_RightArrow: "right"
        case kVK_UpArrow: "up"
        case kVK_DownArrow: "down"
        case kVK_Delete: "backspace"
        case kVK_ForwardDelete: "delete"
        case kVK_Home: "home"
        case kVK_End: "end"
        case kVK_PageUp: "pageup"
        case kVK_PageDown: "pagedown"
        case kVK_F1: "f1"
        case kVK_F2: "f2"
        case kVK_F3: "f3"
        case kVK_F4: "f4"
        case kVK_F5: "f5"
        case kVK_F6: "f6"
        case kVK_F7: "f7"
        case kVK_F8: "f8"
        case kVK_F9: "f9"
        case kVK_F10: "f10"
        case kVK_F11: "f11"
        case kVK_F12: "f12"
        case kVK_F13: "f13"
        case kVK_F14: "f14"
        case kVK_F15: "f15"
        case kVK_F16: "f16"
        case kVK_F17: "f17"
        case kVK_F18: "f18"
        case kVK_F19: "f19"
        case kVK_F20: "f20"
        default: characters?.isEmpty == false ? characters?.lowercased() : nil
        }
    }
}
