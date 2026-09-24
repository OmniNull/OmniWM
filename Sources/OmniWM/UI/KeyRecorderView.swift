// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import SwiftUI

struct KeyRecorderView: NSViewRepresentable {
    let accessibilityLabel: String
    var allowsBareKeys: Bool = false
    var isHyperActive: () -> Bool = { false }
    let onCapture: (KeyBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context _: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.recordingAccessibilityLabel = accessibilityLabel
        view.allowsBareKeys = allowsBareKeys
        view.isHyperActive = isHyperActive
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.updateAccessibility()
        return view
    }

    func updateNSView(_ nsView: KeyRecorderNSView, context _: Context) {
        nsView.recordingAccessibilityLabel = accessibilityLabel
        nsView.allowsBareKeys = allowsBareKeys
        nsView.isHyperActive = isHyperActive
        nsView.updateAccessibility()
    }
}

enum KeyRecorderBindingResolver {
    static func binding(
        keyCode: UInt32,
        modifiers: UInt32,
        hyperActive: Bool,
        allowsBareKeys: Bool
    ) -> KeyBinding? {
        if hyperActive, isHyperTriggerKey(keyCode) {
            return nil
        }

        let resolvedModifiers = hyperActive ? modifiers | KeySymbolMapper.hyperModifiers : modifiers
        let requiresModifier = !isSpecialKey(keyCode)
        guard allowsBareKeys || !requiresModifier || resolvedModifiers != 0 else { return nil }

        return KeyBinding(keyCode: keyCode, modifiers: resolvedModifiers)
    }

    private static func isHyperTriggerKey(_ keyCode: UInt32) -> Bool {
        keyCode == UInt32(kVK_CapsLock) || keyCode == CapsLockHyperMapping.f18KeyCode
    }

    private static func isSpecialKey(_ keyCode: UInt32) -> Bool {
        (keyCode >= UInt32(kVK_F1) && keyCode <= UInt32(kVK_F12)) ||
            keyCode == UInt32(kVK_F13) || keyCode == UInt32(kVK_F14) ||
            keyCode == UInt32(kVK_F15) || keyCode == UInt32(kVK_F16) ||
            keyCode == UInt32(kVK_F17) || keyCode == UInt32(kVK_F18) ||
            keyCode == UInt32(kVK_F19) || keyCode == UInt32(kVK_F20)
    }
}

class KeyRecorderNSView: NSView {
    var onCapture: ((KeyBinding) -> Void)?
    var onCancel: (() -> Void)?
    var recordingAccessibilityLabel = String(localized: "Recording hotkey")
    var allowsBareKeys = false
    var isHyperActive: () -> Bool = { false }

    private let label = NSTextField(labelWithString: String(localized: "Press keys..."))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        layer?.cornerRadius = 4
        focusRingType = .exterior

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        addSubview(label)

        updateAccessibility()

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func updateAccessibility() {
        setAccessibilityRole(.group)
        setAccessibilityLabel(recordingAccessibilityLabel)
        setAccessibilityValue("Recording. Press a key combination.")
        setAccessibilityHelp("Press a key combination. Press Escape to cancel recording.")
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startRecording()
        } else {
            stopRecording()
        }
    }

    private func startRecording() {
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            if window.makeFirstResponder(self) {
                NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
            }
        }
    }

    private func stopRecording() {}

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            onCancel?()
            return true
        }

        guard event.type != .keyUp else { return false }
        guard let binding = binding(from: event) else { return false }

        stopRecording()
        onCapture?(binding)
        return true
    }

    private func binding(from event: NSEvent) -> KeyBinding? {
        guard event.type != .flagsChanged else { return nil }

        return KeyRecorderBindingResolver.binding(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiersFromNSEvent(event),
            hyperActive: isHyperActive(),
            allowsBareKeys: allowsBareKeys
        )
    }

    private func carbonModifiersFromNSEvent(_ event: NSEvent) -> UInt32 {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags

        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }

        return modifiers
    }

    override func keyDown(with event: NSEvent) {
        guard !handleKeyEvent(event) else { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        guard !handleKeyEvent(event) else { return }
        super.keyUp(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        return handleKeyEvent(event)
    }

    override var acceptsFirstResponder: Bool {
        true
    }
}
