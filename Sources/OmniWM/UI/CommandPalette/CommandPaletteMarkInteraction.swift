// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
enum CommandPaletteMarkNamePrompt {
    static let title = "Mark focused window"
    static let message = "Enter a name you can search for in the Windows palette."
    static let fieldLabel = "Window mark name"
    static let confirmTitle = "Set Mark"
    static let cancelTitle = "Cancel"

    static func requestName(initialValue: String? = nil) -> String? {
        let nameField = NSTextField(string: initialValue ?? "")
        nameField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        nameField.placeholderString = fieldLabel
        nameField.setAccessibilityLabel(fieldLabel)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = nameField
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return nameField.stringValue
    }
}

@MainActor
enum CommandPaletteMarkRemovalPrompt {
    static let title = "Remove a window mark"
    static let message = "Choose which mark to remove from this window."
    static let fieldLabel = "Window mark to remove"
    static let confirmTitle = "Remove Mark"
    static let cancelTitle = "Cancel"

    static func requestName(from markNames: [String]) -> String? {
        guard !markNames.isEmpty else { return nil }

        let namePicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        namePicker.addItems(withTitles: markNames)
        namePicker.setAccessibilityLabel(fieldLabel)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = namePicker
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        alert.window.initialFirstResponder = namePicker

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return namePicker.titleOfSelectedItem
    }
}

@MainActor
struct CommandPaletteMarkInteraction {
    enum Outcome: Equatable {
        case marked(String)
        case alreadyMarked(String)
        case duplicateName(String)
        case invalidName
        case noFocusedWindow
        case staleWindow
        case cancelled
        case removed(String)
        case noSelectedWindow
        case noMarks
        case staleMark
    }

    let focusedWindowToken: WindowToken?
    let isEligibleWindow: (WindowToken) -> Bool
    let requestName: () -> String?
    let chooseRemovalName: ([String]) -> String?
    let namesForWindow: (WindowToken) -> [String]
    let lookupMark: (String) -> WindowMarkRegistry.LookupResult
    let setMark: (WindowToken, String) -> WindowMarkRegistry.SetResult
    let removeMark: (String) -> WindowMarkRegistry.RemoveResult

    func setFocusedWindowMark() -> Outcome {
        guard let focusedWindowToken else { return .noFocusedWindow }
        guard isEligibleWindow(focusedWindowToken) else { return .staleWindow }
        guard let name = requestName() else { return .cancelled }
        guard isEligibleWindow(focusedWindowToken) else { return .staleWindow }
        let feedbackName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        switch setMark(focusedWindowToken, name) {
        case .inserted:
            return .marked(feedbackName)
        case .unchanged:
            return .alreadyMarked(feedbackName)
        case .duplicate:
            return .duplicateName(feedbackName)
        case .invalidName:
            return .invalidName
        }
    }

    func removeMarkFromSelectedWindow(_ token: WindowToken?) -> Outcome {
        guard let token else { return .noSelectedWindow }
        guard isEligibleWindow(token) else { return .staleWindow }
        let markNames = namesForWindow(token)
        guard !markNames.isEmpty else { return .noMarks }
        guard let name = chooseRemovalName(markNames) else { return .cancelled }

        guard isEligibleWindow(token),
              markNames.contains(name),
              namesForWindow(token).contains(name)
        else {
            return .staleMark
        }

        switch lookupMark(name) {
        case let .found(markedToken) where markedToken == token:
            break
        case .invalidName:
            return .invalidName
        case .found,
             .unknown:
            return .staleMark
        }

        switch removeMark(name) {
        case .removed:
            return .removed(name)
        case .unknown:
            return .staleMark
        case .invalidName:
            return .invalidName
        }
    }
}
