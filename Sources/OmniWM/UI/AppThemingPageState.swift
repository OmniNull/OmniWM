// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation

@MainActor @Observable
final class AppThemingPageState {
    private(set) var paths: [String: [String]] = [:]
    private(set) var ghosttyStatus = AppThemeGhosttyStatus.selected
    private(set) var backupFolder = ""

    @ObservationIgnored private let perform: AppThemeService.Perform
    @ObservationIgnored private let deliver: AppThemeService.Deliver
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var reviewGeneration: UInt64 = 0

    init(
        perform: @escaping AppThemeService.Perform = AppThemeService.performOnWorkerQueue,
        deliver: @escaping AppThemeService.Deliver = AppThemeService.deliverOnMain
    ) {
        self.perform = perform
        self.deliver = deliver
    }

    func invalidateReview() {
        reviewGeneration &+= 1
    }

    func review(
        _ preview: AppThemePreview,
        target: AppThemeTarget? = nil,
        completion: @escaping @MainActor @Sendable (Result<[AppThemeChange], Error>) -> Void
    ) {
        invalidateReview()
        let current = reviewGeneration
        let engine = preview.engine
        let values = preview.values
        let dark = preview.dark
        let palette = preview.palette()
        let deliver = deliver
        perform { [weak self] in
            let preview = AppThemePreview(engine: engine, values: values, dark: dark) { palette }
            let result = Result {
                if let target { return try preview.changes(for: target, onlyExisting: true) }
                return try preview.ghosttySelectionChanges()
            }
            deliver { [weak self] in
                guard let self, current == reviewGeneration else { return }
                completion(result)
            }
        }
    }

    func refresh(_ engine: AppThemeEngine, targets: [AppThemeTarget]) {
        generation &+= 1
        let current = generation
        let deliver = deliver
        perform { [weak self] in
            let policy = engine.policy
            let roots = policy.resolvedRoots()
            let paths = Dictionary(targets.map { target in
                (target.id, target.outputs.map { output in
                    (try? policy.destination(for: output.path, roots: roots)).map(policy.display) ?? output.path
                })
            }) { first, _ in first }
            let status = AppThemePreview(engine: engine, values: SettingsExport.AppTheming(), dark: false) { nil }
                .ghosttySelectionStatus()
            let folder = policy.display(engine.store.backupsDirectory)
            deliver { [weak self] in
                guard let self, current == generation else { return }
                self.paths = paths
                ghosttyStatus = status
                backupFolder = folder
            }
        }
    }
}
