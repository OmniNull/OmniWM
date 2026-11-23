// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation

@Observable @MainActor
final class SettingsFormulaConfirmation {
    struct Question: Identifiable {
        let id = UUID()
        let message: String
        let fileURL: URL?
    }

    private(set) var question: Question?
    @ObservationIgnored var canPresent: (() -> Bool)?
    @ObservationIgnored private var respond: ((Bool) -> Void)?

    func present(_ message: String, replace: @escaping () -> Void) {
        discard()
        respond = { if $0 { replace() } }
        question = Question(message: message, fileURL: nil)
    }

    func confirm(_ request: ShellLuauConfirmation) async throws -> Bool {
        guard canPresent?() == true else { throw request }
        discard()
        return await withCheckedContinuation { continuation in
            respond = { continuation.resume(returning: $0) }
            question = Question(message: request.message, fileURL: request.url)
        }
    }

    func answer(_ id: UUID, replace shouldReplace: Bool) {
        guard question?.id == id else { return }
        let action = respond
        question = nil
        respond = nil
        action?(shouldReplace)
    }

    func discard() {
        if let question { answer(question.id, replace: false) }
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
