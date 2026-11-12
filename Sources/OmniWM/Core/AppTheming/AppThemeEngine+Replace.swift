// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension AppThemeEngine {
    func commitSelection(of job: AppThemeJob, into report: inout AppThemeRunReport) {
        let ghostty = AppThemeBuiltIn.ghostty.id
        guard !job.selection.isEmpty, job.enabled.contains(ghostty) else { return }
        do {
            report.backups += try commit(job.selection) { job.enabled.contains(ghostty) }
        } catch is AppThemeCancelled {
            return
        } catch AppThemeEngineError.changedOutsideOmniWM {
            report.reviewAgain.append(AppThemeService.ghosttySelectionReview)
        } catch {
            report.selectionProblem = error.localizedDescription
        }
    }

    func commit(_ changes: [AppThemeChange], isCurrent: () -> Bool = { true }) throws -> [URL] {
        let currents = try changes.map { try AppThemeFileWriter.read($0.url) }
        let stale = zip(changes, currents).filter { change, current in
            current.map(AppThemeFileWriter.digest) != change.beforeDigest
        }
        guard stale.isEmpty else { throw AppThemeEngineError.changedOutsideOmniWM(stale.map(\.0.display)) }
        var backups: [URL] = []
        for (change, current) in zip(changes, currents) {
            let backup = try current.map { try store.backup($0, of: change.url, date: now()) }
            do {
                try replace(
                    change.url,
                    with: Data(change.after.utf8),
                    expecting: current,
                    display: change.display,
                    isCurrent: isCurrent
                )
            } catch {
                if let backup { try? FileManager.default.removeItem(at: backup) }
                throw error
            }
            if let backup { backups.append(backup) }
        }
        return backups
    }

    func restore(_ item: Rendered) throws {
        guard let before = item.before else {
            guard try AppThemeFileWriter.read(item.url, display: item.display) == item.after else {
                throw AppThemeEngineError.changedOutsideOmniWM([item.display])
            }
            guard unlink(item.url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return
        }
        try replace(item.url, with: before, expecting: item.after, display: item.display) { true }
    }

    func replace(
        _ url: URL,
        with data: Data,
        expecting current: Data?,
        display: String,
        isCurrent: () -> Bool
    ) throws {
        try AppThemeFileWriter.writeAtomically(data, to: url) {
            willReplace(url)
            guard isCurrent() else { throw AppThemeCancelled() }
            guard try AppThemeFileWriter.read(url, display: display) == current else {
                throw AppThemeEngineError.changedOutsideOmniWM([display])
            }
        }
    }
}
