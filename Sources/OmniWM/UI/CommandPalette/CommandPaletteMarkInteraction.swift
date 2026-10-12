// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
private enum CommandPaletteMarkModal {
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let wasActive = NSApp.isActive
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if !wasActive {
            if let frontmostApp,
               frontmostApp.processIdentifier != NSRunningApplication.current.processIdentifier,
               !frontmostApp.isTerminated,
               frontmostApp.activate(options: [])
            {
                return response
            }
            NSApp.deactivate()
        }
        return response
    }
}

@MainActor
enum CommandPaletteMarkNamePrompt {
    static let title = String(localized: "Mark window")
    static let message = String(localized: "Enter a name you can search for in the Windows palette.")
    static let fieldLabel = String(localized: "Window mark name")
    static let confirmTitle = String(localized: "Set Mark")
    static let cancelTitle = String(localized: "Cancel")

    static func requestName(initialValue: String? = nil) -> String? {
        let nameField = NSTextField(string: initialValue ?? "")
        nameField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        nameField.placeholderString = fieldLabel
        nameField.setAccessibilityLabel(fieldLabel)

        guard CommandPaletteMarkModal.run(makeAlert(nameField: nameField)) == .alertFirstButtonReturn else {
            return nil
        }
        return nameField.stringValue
    }

    static func makeAlert(nameField: NSTextField) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = nameField
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle).keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = nameField
        return alert
    }
}

@MainActor
enum CommandPaletteMarkRemovalPrompt {
    static let title = String(localized: "Remove a window mark")
    static let message = String(localized: "Choose which mark to remove from this window.")
    static let fieldLabel = String(localized: "Window mark to remove")
    static let confirmTitle = String(localized: "Remove Mark")
    static let cancelTitle = String(localized: "Cancel")

    static func requestName(from markNames: [String]) -> String? {
        guard !markNames.isEmpty else { return nil }

        let namePicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        namePicker.addItems(withTitles: markNames)
        namePicker.setAccessibilityLabel(fieldLabel)

        guard CommandPaletteMarkModal.run(makeAlert(namePicker: namePicker)) == .alertFirstButtonReturn else {
            return nil
        }
        return namePicker.titleOfSelectedItem
    }

    static func makeAlert(namePicker: NSPopUpButton) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = namePicker
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle).keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = namePicker
        return alert
    }
}

@MainActor
struct CommandPaletteMarkInteraction {
    enum Outcome: Equatable {
        case marked(String)
        case alreadyMarked(String)
        case duplicateName(String)
        case invalidName
        case staleWindow
        case cancelled
        case removed(String)
        case noSelectedWindow
        case noMarks
        case staleMark
    }

    let selectedWindowToken: WindowToken?
    let isEligibleWindow: (WindowToken) -> Bool
    let requestName: () -> String?
    let chooseRemovalName: ([String]) -> String?
    let namesForWindow: (WindowToken) -> [String]
    let lookupMark: (String) -> WindowMarkRegistry.LookupResult
    let setMark: (WindowToken, String) -> WindowMarkRegistry.SetResult
    let removeMark: (String) -> WindowMarkRegistry.RemoveResult

    func setSelectedWindowMark() -> Outcome {
        guard let selectedWindowToken else { return .noSelectedWindow }
        guard isEligibleWindow(selectedWindowToken) else { return .staleWindow }
        guard let name = requestName() else { return .cancelled }
        guard isEligibleWindow(selectedWindowToken) else { return .staleWindow }
        let feedbackName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        switch setMark(selectedWindowToken, name) {
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
