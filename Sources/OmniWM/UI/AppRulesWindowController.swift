// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class AppRulesWindowController: NSObject, NSWindowDelegate {
    static let shared = AppRulesWindowController()

    private let presenter = HostedWindowPresenter()
    private let editorState = AppRulesEditorState()

    func show(settings: SettingsStore, controller: WMController) {
        presenter.present(
            title: String(localized: "App Rules"),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            contentSize: NSSize(width: 1140, height: 870),
            minSize: NSSize(width: 880, height: 680),
            configure: { window in
                window.titlebarAppearsTransparent = true
                window.delegate = self
            },
            onWillClose: { [weak self] in
                self?.editorState.isDirty = false
            },
            content: {
                AppRulesView(settings: settings, controller: controller, editorState: editorState)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
        )
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editorState.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard unsaved changes?")
        alert
            .informativeText =
            String(localized: "You have unsaved changes to this app rule. Closing the window will discard them.")
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            editorState.isDirty = false
            return true
        }
        return false
    }
}
