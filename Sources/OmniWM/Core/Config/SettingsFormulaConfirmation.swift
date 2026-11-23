// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation

@Observable @MainActor
final class SettingsFormulaConfirmation {
    struct Question: Identifiable {
        let id = UUID()
        let message: String
    }

    private(set) var question: Question?
    @ObservationIgnored var canPresent: (() -> Bool)?
    @ObservationIgnored private var replace: (() -> Void)?

    func present(_ message: String, replace: @escaping () -> Void) {
        self.replace = replace
        question = Question(message: message)
    }

    func answer(_ id: UUID, replace shouldReplace: Bool) {
        guard question?.id == id else { return }
        let action = replace
        discard()
        if shouldReplace { action?() }
    }

    func discard() {
        guard question != nil else { return }
        question = nil
        replace = nil
    }
}

extension SettingsStore {
    func connectFormulaEdits(to persistence: SettingsFilePersistence) {
        persistence.applyFormulaValues = { [weak self, weak persistence] export, committed in
            guard let self else { return }
            applyExport(export, restoringDraft: !committed)
            if committed {
                persistence?.recordAppliedExport(toExport())
                onConfirmedSettingsEdit?()
            }
        }
    }
}
