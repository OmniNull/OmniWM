// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

@MainActor
final class ShellTextInput: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    let handle: ElementHandle
    let view = ShellInputClipView()
    let field: ShellInputField?
    let editor: ShellInputTextView?
    private let scroll: NSScrollView?
    weak var surface: ShellWidgetSurface?
    var capture: ShellPointerCapture
    private(set) var editing = false
    private(set) var pendingFocus = false
    private var focusDeclaration: Int8 = -1
    private var maximum = 65536
    private var lastChange: String?
    private var style: UInt32?

    init(handle: ElementHandle, surface: ShellWidgetSurface, multiline: Bool) {
        self.handle = handle
        self.surface = surface
        capture = surface.capture(handle)
        if multiline {
            let editor = ShellInputTextView(frame: .zero)
            editor.isRichText = false
            editor.importsGraphics = false
            editor.allowsUndo = true
            editor.drawsBackground = false
            editor.isHorizontallyResizable = false
            editor.isVerticallyResizable = true
            editor.autoresizingMask = [.width]
            editor.textContainer?.widthTracksTextView = true
            editor.textContainerInset = NSSize(width: 3, height: 3)
            let scroll = NSScrollView(frame: .zero)
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = editor
            self.editor = editor
            self.scroll = scroll
            field = nil
        } else {
            let field = ShellInputField(frame: .zero)
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.isEditable = true
            field.isSelectable = true
            field.usesSingleLineMode = true
            field.lineBreakMode = .byClipping
            self.field = field
            editor = nil
            scroll = nil
        }
        super.init()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        if let field { field.owner = self
            field.delegate = self
            view.addSubview(field)
        }
        if let editor, let scroll { editor.owner = self
            editor.delegate = self
            view.addSubview(scroll)
        }
    }

    var responder: NSResponder {
        if let field { return field }
        if let editor { return editor }
        return view
    }

    var text: String {
        textEditor?.string ?? field?.stringValue ?? ""
    }

    var textEditor: NSTextView? {
        field?.currentEditor() as? NSTextView ?? editor
    }

    var hasMarkedText: Bool {
        textEditor?.hasMarkedText() == true
    }

    func update(content: Content, text: ShellTextStore, color: NSColor) {
        capture = surface?.capture(handle) ?? capture
        maximum = Int(content.inputMaxLength)
        if style != content.style {
            style = content.style
            let font = ShellTextStyle.font(for: content.style) as NSFont
            field?.font = font
            editor?.font = font
        }
        field?.textColor = color
        let placeholder = text.string(content.placeholder)
        if field?.placeholderString != placeholder { field?.placeholderString = placeholder }
        editor?.textColor = color
        editor?.placeholder = placeholder
        if !editing { replace(String(text.string(content.text).prefix(maximum))) }
        if content.inputFocus != focusDeclaration {
            focusDeclaration = content.inputFocus
            pendingFocus = content.inputFocus == 1
            if content.inputFocus == 0, surface?.focused == handle { surface?.blurDeclaredFocus() }
        }
    }

    func layout(frame: CGRect, clip: CGRect, opacity: CGFloat) {
        let visible = frame.intersection(clip)
        view.isHidden = visible.isNull || visible.isEmpty || opacity <= 0
        view.alphaValue = opacity
        guard !view.isHidden else {
            if surface?.focused == handle { surface?.blurDeclaredFocus() }
            return
        }
        view.frame = visible
        let inner = CGRect(
            origin: CGPoint(x: frame.minX - visible.minX, y: frame.minY - visible.minY),
            size: frame.size
        )
        field?.frame = inner
        scroll?.frame = inner
        if let editor, let scroll {
            editor.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            editor.frame.size.width = scroll.contentSize.width
        }
    }

    func requestFocus() {
        surface?.focusTextInput(self)
    }

    func focusApplied() {
        pendingFocus = false
    }

    func beganEditing() {
        guard !editing else { return }
        editing = true
        pendingFocus = false
        lastChange = text
        if surface?.focused != handle || surface?.declaredFocus != true { surface?.focusDeclared(handle) }
        emit(capture.content.inputFocusAction, kind: .textFocus, focused: true)
    }

    func endedEditing() {
        guard editing else { return }
        changed()
        editing = false
        emit(capture.content.inputFocusAction, kind: .textFocus, focused: false)
        if surface?.focused == handle { surface?.blurDeclaredFocus() }
    }

    func changed() {
        guard !hasMarkedText else { return }
        let current = text
        let limited = String(current.prefix(maximum))
        if limited != current { replace(limited, preserveSelection: true) }
        guard limited != lastChange else { return }
        lastChange = limited
        emit(capture.content.action, kind: .textChange, text: limited)
    }

    func finish(commit: Bool) {
        guard !hasMarkedText else { return }
        changed()
        emit(
            commit ? capture.content.inputCommitAction : capture.content.inputCancelAction,
            kind: commit ? .textCommit : .textCancel,
            text: commit ? text : nil
        )
        if surface?.focused == handle { surface?.blurDeclaredFocus() }
    }

    func blur() {
        guard editing else { return }
        if view.window?.firstResponder === textEditor || view.window?.firstResponder === responder {
            view.window?.makeFirstResponder(surface?.view)
        }
        endedEditing()
    }

    func remove() {
        pendingFocus = false
        blur()
        field?.delegate = nil
        editor?.delegate = nil
        view.removeFromSuperview()
    }

    private func replace(_ text: String, preserveSelection: Bool = false) {
        guard self.text != text else { return }
        let selection = preserveSelection ? textEditor?.selectedRange() : nil
        field?.stringValue = text
        if let textEditor { textEditor.string = text }
        if let selection, let textEditor {
            let end = text.utf16.count
            let location = min(selection.location, end)
            textEditor.setSelectedRange(NSRange(location: location, length: min(selection.length, end - location)))
        }
        editor?.needsDisplay = true
    }

    private func emit(_ action: UInt32, kind: ShellEvent.Kind, text: String? = nil, focused: Bool? = nil) {
        var event = ShellEvent(button: .none)
        event.kind = kind
        event.text = text
        event.focused = focused
        event.coalescingTarget = UInt64(handle.generation) << 32 | UInt64(UInt32(bitPattern: handle.slot))
        if kind == .textChange { event.phase = .changed }
        surface?.emit(action, capture: capture, point: capture.origin, event: event)
    }

    func command(_ selector: Selector) -> Bool {
        if hasMarkedText { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): finish(commit: false)
        case #selector(NSResponder.insertNewline(_:)):
            guard field != nil || NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return false }
            finish(commit: true)
        case #selector(NSResponder.insertTab(_:)): surface?.moveTextInputFocus(from: handle, backwards: false)
        case #selector(NSResponder.insertBacktab(_:)): surface?.moveTextInputFocus(from: handle, backwards: true)
        default: return false
        }
        return true
    }

    func editCommand(_ event: NSEvent) -> Bool {
        guard editing, event.modifierFlags.intersection([.command, .control, .option]) == .command,
              let editor = textEditor else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": editor.copy(nil)
        case "v": editor.paste(nil)
        case "x": editor.cut(nil)
        case "a": editor.selectAll(nil)
        case "z":
            if event.modifierFlags.contains(.shift) { editor.undoManager?.redo() }
            else { editor.undoManager?.undo() }
        case "\r",
             "\n":
            guard self.editor != nil else { return false }
            finish(commit: true)
        default: return false
        }
        return true
    }

    func controlTextDidBeginEditing(_: Notification) {
        beganEditing()
    }

    func controlTextDidChange(_: Notification) {
        changed()
    }

    func controlTextDidEndEditing(_: Notification) {
        endedEditing()
    }

    func control(
        _: NSControl,
        textView _: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        command(commandSelector)
    }

    func textDidBeginEditing(_: Notification) {
        beganEditing()
    }

    func textDidChange(_: Notification) {
        changed()
        editor?.needsDisplay = true
    }

    func textDidEndEditing(_: Notification) {
        endedEditing()
    }

    func textView(_: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        command(commandSelector)
    }
}

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
