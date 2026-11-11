// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

@MainActor
final class ShellTextInput: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    private enum FocusState {
        case idle, acquiring, editing
    }

    fileprivate(set) var handle: ElementHandle
    let view = ShellInputClipView()
    let field: ShellInputField?
    let editor: ShellInputTextView?
    private let scroll: NSScrollView?
    weak var surface: ShellWidgetSurface?
    var capture: ShellPointerCapture
    private var focusState = FocusState.idle
    var editing: Bool {
        focusState == .editing
    }

    private(set) var pendingFocus = false
    private(set) var onScreen = false
    private var focusDeclaration: Int8 = -1
    fileprivate var maximum = 65536
    fileprivate var lastChange: String?
    private var style: UInt32?
    private var editable = true
    private var wraps = true
    private var editorLayoutDirty = true
    private var modelText: UInt32?
    private var modelStore: ObjectIdentifier?
    private(set) var presentsTransiently = false
    fileprivate let onText: (@MainActor (ShellEvent) -> Void)?

    fileprivate init(
        handle: ElementHandle,
        surface: ShellWidgetSurface,
        capture: ShellPointerCapture,
        multiline: Bool,
        onText: (@MainActor (ShellEvent) -> Void)?
    ) {
        self.handle = handle
        self.surface = surface
        self.capture = capture
        self.onText = onText
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
        let maximumChanged = maximum != Int(content.inputMaxLength)
        maximum = Int(content.inputMaxLength)
        updateOptions(content)
        if style != content.style {
            style = content.style
            let font = ShellTextStyle.font(for: content.style) as NSFont
            field?.font = font
            editor?.font = font
            editorLayoutDirty = true
        }
        field?.textColor = color
        let placeholder = text.string(content.placeholder)
        if field?.placeholderString != placeholder { field?.placeholderString = placeholder }
        editor?.textColor = color
        editor?.placeholder = placeholder
        guard !isPinned else { return }
        if !editing || !editable {
            let store = ObjectIdentifier(text)
            if editable || modelText != content.text || modelStore != store || maximumChanged {
                replace(String(text.string(content.text).prefix(maximum)))
                modelText = content.text
                modelStore = store
            }
        }
        if content.inputFocus != focusDeclaration {
            focusDeclaration = content.inputFocus
            pendingFocus = content.inputFocus == 1
            if content.inputFocus == 0, surface?.focused == handle { surface?.blurDeclaredFocus() }
        }
    }

    private func updateOptions(_ content: Content) {
        let nextEditable = isPinned || content.inputEditable
        if editable != nextEditable {
            editable = nextEditable
            field?.isEditable = editable
            editor?.isEditable = editable
            editor?.allowsUndo = editable
        }
        guard wraps != content.inputWrap, let editor, let scroll else { return }
        wraps = content.inputWrap
        editor.isHorizontallyResizable = !wraps
        editor.autoresizingMask = wraps ? [.width] : []
        editor.textContainer?.widthTracksTextView = wraps
        editor.textContainer?.containerSize = NSSize(
            width: wraps ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scroll.hasHorizontalScroller = !wraps
        editorLayoutDirty = true
    }
}

extension ShellTextInput {
    @discardableResult
    func measure(frame: CGRect, clip: CGRect, opacity: CGFloat) -> CGRect {
        let visible = frame.intersection(clip)
        onScreen = !visible.isNull && !visible.isEmpty && opacity > 0
        return visible
    }

    func layout(frame: CGRect, clip: CGRect, opacity: CGFloat, preservingFocus: Bool = false) {
        guard !presentsTransiently else { return }
        let visible = measure(frame: frame, clip: clip, opacity: opacity)
        view.isHidden = !onScreen
        view.alphaValue = opacity
        guard !view.isHidden else {
            if !preservingFocus, surface?.focused == handle { surface?.blurDeclaredFocus() }
            return
        }
        view.frame = visible
        let inner = CGRect(
            origin: CGPoint(x: frame.minX - visible.minX, y: frame.minY - visible.minY),
            size: frame.size
        )
        field?.frame = inner
        if scroll?.frame != inner { editorLayoutDirty = true }
        scroll?.frame = inner
        if let editor, let scroll {
            editor.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if wraps {
                editor.frame.size.width = scroll.contentSize.width
            } else if editorLayoutDirty {
                editor.sizeToFit()
                editor.frame.size.width = max(editor.frame.width, scroll.contentSize.width)
            }
            editorLayoutDirty = false
        }
    }

    @discardableResult
    func setPresentsTransiently(_ transient: Bool) -> Bool {
        guard presentsTransiently != transient else { return false }
        presentsTransiently = transient
        if transient {
            view.isHidden = false
            view.alphaValue = 0
        }
        return true
    }

    func focusApplied() {
        pendingFocus = false
    }

    func focus(in window: NSWindow) {
        guard focusState == .idle else {
            if editing { focusApplied() }
            return
        }
        focusState = .acquiring
        defer { if focusState == .acquiring { focusState = .idle } }
        if window.makeFirstResponder(responder) { focusApplied() }
    }

    func beganEditing() {
        guard !editing else { return }
        focusState = .editing
        pendingFocus = false
        lastChange = text
        if !isPinned { surface?.recordDeclaredFocus(handle) }
        emit(capture.content.inputFocusAction, kind: .textFocus, focused: true)
    }

    func endedEditing() {
        guard editing else { return }
        changed()
        focusState = .idle
        emit(capture.content.inputFocusAction, kind: .textFocus, focused: false)
        if !isPinned, surface?.focused == handle { surface?.blurDeclaredFocus() }
    }

    func changed() {
        guard editable, !hasMarkedText else { return }
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
        if !isPinned, surface?.focused == handle { surface?.blurDeclaredFocus() }
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

    fileprivate func replace(_ text: String, preserveSelection: Bool = false) {
        guard self.text != text else { return }
        let selection = preserveSelection ? textEditor?.selectedRange() : nil
        field?.stringValue = text
        if let textEditor { textEditor.string = text }
        editorLayoutDirty = true
        if !editable, let scroll {
            editor?.setSelectedRange(NSRange(location: 0, length: 0))
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
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
        if let onText {
            onText(event)
            return
        }
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
        case "v": if editable { editor.paste(nil) }
        case "x": if editable { editor.cut(nil) }
        case "a": editor.selectAll(nil)
        case "z":
            guard editable else { return true }
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

    func textView(_: NSTextView, shouldChangeTextIn _: NSRange, replacementString _: String?) -> Bool {
        editable
    }

    func readOnlyState(key: UInt64) -> ShellReadOnlyInputState? {
        guard !editable, let editor, let scroll else { return nil }
        return ShellReadOnlyInputState(
            key: key,
            selection: editor.selectedRange(),
            origin: scroll.contentView.bounds.origin,
            focused: view.window?.firstResponder === editor
        )
    }

    func restoreReadOnlyState(_ state: ShellReadOnlyInputState) {
        guard !editable, let editor, let scroll else { return }
        let end = editor.string.utf16.count
        let location = min(state.selection.location, end)
        editor.setSelectedRange(NSRange(location: location, length: min(state.selection.length, end - location)))
        scroll.contentView.scroll(to: state.origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        if state.focused, let window = view.window { focus(in: window) }
    }
}

extension ShellTextInput {
    var isPinned: Bool {
        onText != nil
    }

    convenience init(handle: ElementHandle, surface: ShellWidgetSurface, multiline: Bool) {
        self.init(handle: handle, surface: surface, capture: surface.capture(handle), multiline: multiline, onText: nil)
    }

    func requestFocus() {
        guard !isPinned else {
            view.window?.makeFirstResponder(responder)
            return
        }
        surface?.focusTextInput(self)
    }

    convenience init(pinnedIn surface: ShellWidgetSurface, onText: @escaping @MainActor (ShellEvent) -> Void) {
        let capture = ShellPointerCapture(
            handle: .none,
            content: Content(),
            anchor: ShellAnchor(frame: .zero, level: .normal),
            origin: .zero,
            sequence: 0,
            event: ShellEvent()
        )
        self.init(handle: .none, surface: surface, capture: capture, multiline: false, onText: onText)
    }

    func rebind(_ handle: ElementHandle) {
        guard let surface else { return }
        self.handle = handle
        capture = surface.capture(handle)
    }

    func unbind() {
        handle = .none
    }

    func setText(_ text: String) {
        let limited = String(text.prefix(maximum))
        replace(limited)
        lastChange = limited
    }

    func place(_ frame: CGRect) {
        view.isHidden = false
        view.alphaValue = 1
        view.frame = frame
        field?.frame = CGRect(origin: .zero, size: frame.size)
    }
}
