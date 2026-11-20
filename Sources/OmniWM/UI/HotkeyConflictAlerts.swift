// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct HotkeyConflictAlerts: ViewModifier {
    @Binding var conflictAlert: ConflictAlert?
    @Binding var captureRejection: String?
    let settings: SettingsStore
    let onReplaced: () -> Void
    let onCancelled: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(item: $conflictAlert) { alert in
                Alert(
                    title: Text("Hotkey Conflict"),
                    message: Text(alert.message),
                    primaryButton: .destructive(Text("Replace")) {
                        HotkeyBindingEditor.applyConflictResolution(alert, settings: settings)
                        onReplaced()
                    },
                    secondaryButton: .cancel {
                        onCancelled()
                    }
                )
            }
            .alert(
                "Hotkey Conflict",
                isPresented: Binding(get: { captureRejection != nil }, set: { if !$0 { captureRejection = nil } }),
                presenting: captureRejection
            ) { _ in
                Button("OK", role: .cancel) {}
                    .id("OK")
            } message: { message in
                Text(message)
            }
    }
}
