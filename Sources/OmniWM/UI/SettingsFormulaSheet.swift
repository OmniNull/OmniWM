// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct SettingsFormulaSheet: ViewModifier {
    let settings: SettingsStore
    @State private var openError: String?

    func body(content: Content) -> some View {
        let confirmation = settings.formulaConfirmation
        let presented = confirmation.question?.id
        content.sheet(item: Binding(
            get: { confirmation.question },
            set: { if $0 == nil, let presented { confirmation.answer(presented, replace: false) } }
        )) { question in
            VStack(alignment: .leading, spacing: 16) {
                Text("Replace calculated settings?")
                    .font(.headline)
                ScrollView {
                    Text(verbatim: question.message)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let openError { Text(verbatim: openError).foregroundStyle(.red) }
                HStack {
                    Button("Edit Settings File") {
                        do {
                            _ = try SettingsFileWorkflow.perform(.open, settings: settings)
                            confirmation.answer(question.id, replace: false)
                        } catch {
                            openError = error.localizedDescription
                        }
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { confirmation.answer(question.id, replace: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Replace", role: .destructive) { confirmation.answer(question.id, replace: true) }
                }
            }
            .onAppear { openError = nil }
            .padding(20)
            .frame(width: 500, height: 320)
        }
    }
}
