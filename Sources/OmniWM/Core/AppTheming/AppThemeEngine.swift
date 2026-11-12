// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum AppThemeEngineError: Error, Equatable, LocalizedError {
    case changedOutsideOmniWM([String])
    case unreadableTemplate(String)
    case notText(String)
    case sharedOutput(path: String, owner: String)

    var errorDescription: String? {
        switch self {
        case let .changedOutsideOmniWM(paths):
            String(
                localized: "\(paths.joined(separator: ", ")) has changes OmniWM didn’t make. Review and replace it to continue."
            )
        case let .unreadableTemplate(path):
            String(localized: "The template \(path) can’t be read")
        case let .notText(path):
            String(localized: "\(path) isn’t a UTF-8 text file")
        case let .sharedOutput(path, owner):
            String(localized: "\(path) is already written by \(owner). Choose another output file.")
        }
    }
}

struct AppThemeEngine: Sendable {
    let policy: AppThemeOutputPolicy
    let store: AppThemeStateStore
    let environment: AppThemeEnvironment
    var now: @Sendable () -> Date = { Date() }
    var willReplace: @Sendable (URL) -> Void = { _ in }

    static var live: AppThemeEngine {
        AppThemeEngine(
            policy: .live(),
            store: AppThemeStateStore(
                directory: OmniWMStoragePaths.live.stateDirectory.appendingPathComponent("app-theming")
            ),
            environment: .live
        )
    }

    struct Rendered: Equatable {
        let url: URL
        let display: String
        let before: Data?
        let after: Data
        let ownedText: String
        let currentOwnedText: String?
    }

    func run(_ job: AppThemeJob) -> AppThemeRunReport {
        guard job.targets.contains(where: { job.enabled.contains($0.id) }) else { return AppThemeRunReport() }
        do {
            return try store.withLock { runLocked(job) }
        } catch {
            var report = AppThemeRunReport()
            for target in job.targets {
                report.results[target.id] = AppThemeResult(
                    date: now(),
                    outcome: .failed,
                    message: error.localizedDescription
                )
            }
            return report
        }
    }

    private func runLocked(_ job: AppThemeJob) -> AppThemeRunReport {
        var state = store.load()
        var report = AppThemeRunReport()
        var changed: [String: Bool] = [:]
        var claimed: [String: String] = [:]
        var created: Set<String> = []
        for target in job.targets where job.enabled.contains(target.id) {
            do {
                try claim(target, in: &claimed)
                let (names, newFiles) = try write(target, job: job, state: &state, backups: &report.backups)
                changed[target.id] = !names.isEmpty
                if newFiles { created.insert(target.id) }
                report.results[target.id] = AppThemeResult(
                    date: now(),
                    outcome: names.isEmpty ? .unchanged : .updated,
                    message: names.isEmpty
                        ? String(localized: "Already up to date")
                        : String(localized: "Wrote \(names.joined(separator: ", "))")
                )
            } catch let AppThemeEngineError.changedOutsideOmniWM(paths) {
                let approved = target.outputs.contains { output in
                    (try? policy.destination(for: output.path)).map { job.takeOver[$0.path] != nil } ?? false
                }
                if approved { report.reviewAgain.append(target.id) }
                report.results[target.id] = AppThemeResult(
                    date: now(),
                    outcome: .conflict,
                    message: AppThemeEngineError.changedOutsideOmniWM(paths).localizedDescription,
                    conflictPaths: paths
                )
            } catch {
                report.results[target.id] = AppThemeResult(
                    date: now(),
                    outcome: .failed,
                    message: error.localizedDescription
                )
            }
        }
        reload(job, changed: changed, created: created, state: &state, report: &report)
        state.results.merge(report.results) { $1 }
        try? store.save(state)
        return report
    }

    private func claim(_ target: AppThemeTarget, in claimed: inout [String: String]) throws {
        let paths = target.outputs.compactMap { try? policy.destination(for: $0.path).path }
        if let path = paths.first(where: { claimed[$0] != nil }), let owner = claimed[path] {
            throw AppThemeEngineError.sharedOutput(path: policy.display(URL(fileURLWithPath: path)), owner: owner)
        }
        for path in paths {
            claimed[path] = target.name
        }
    }

    private func reload(
        _ job: AppThemeJob,
        changed: [String: Bool],
        created: Set<String>,
        state: inout AppThemeState,
        report: inout AppThemeRunReport
    ) {
        let terminalsChanged = job.targets.contains { $0.isTerminal && changed[$0.id] == true }
        let ordered = job.targets.enumerated()
            .sorted { ($0.element.reload?.phase ?? 0, $0.offset) < ($1.element.reload?.phase ?? 0, $1.offset) }
            .map(\.element)
        let needed = ordered.filter { target in
            guard let action = target.reload, let wrote = changed[target.id], job.enabled.contains(target.id) else {
                return false
            }
            return wrote || state.reloadPending.contains(target.id) || job.forceReload.contains(target.id)
                || (action.runsAfterTerminals && (terminalsChanged || job.appearanceChanged))
        }
        var outcomes: [AppThemeReloadAction: AppThemeReloadOutcome] = [:]
        for target in needed {
            guard let action = target.reload else { continue }
            state.reloadPending.insert(target.id)
            try? store.save(state)
            let outcome = outcomes[action] ?? AppThemeReloader(environment: environment).reload(
                action,
                newFiles: needed.contains { $0.reload == action && created.contains($0.id) }
            )
            outcomes[action] = outcome
            if outcome.succeeded { state.reloadPending.remove(target.id) }
            report.results[target.id]?.reload = outcome.message
            report.results[target.id]?.reloadFailed = !outcome.succeeded
        }
        report.ghosttyThemesChanged = job.targets.contains { target in
            target.reload == .ghostty && job.enabled.contains(target.id)
                && (changed[target.id] == true || job.forceReload.contains(target.id))
        }
    }

    private func write(
        _ target: AppThemeTarget,
        job: AppThemeJob,
        state: inout AppThemeState,
        backups: inout [URL]
    ) throws -> (names: [String], newFiles: Bool) {
        let rendered = try target.outputs.map { try render($0, job: job) }
        let conflicts = rendered.filter { item in
            guard item.before != item.after, let current = item.currentOwnedText else { return false }
            let digest = AppThemeFileWriter.digest(current)
            let owned = state.owned[item.url.path] == digest || state.pending[item.url.path] == digest
            return !owned && !Self.isReviewed(item, job)
        }
        guard conflicts.isEmpty else { throw AppThemeEngineError.changedOutsideOmniWM(conflicts.map(\.display)) }
        var written: [String] = []
        for item in rendered {
            let digest = AppThemeFileWriter.digest(item.ownedText)
            let path = item.url.path
            if item.before == item.after {
                if state.owned[path] != digest || state.pending[path] != nil {
                    state.owned[path] = digest
                    state.pending[path] = nil
                    try store.save(state)
                }
                continue
            }
            let backup = try item.before.flatMap { before in
                Self.isReviewed(item, job) ? try store.backup(before, of: item.url, date: now()) : nil
            }
            state.pending[path] = digest
            if target.reload != nil { state.reloadPending.insert(target.id) }
            try store.save(state)
            willReplace(item.url)
            guard try AppThemeFileWriter.read(item.url) == item.before else {
                if let backup { try? FileManager.default.removeItem(at: backup) }
                state.pending[path] = nil
                try store.save(state)
                throw AppThemeEngineError.changedOutsideOmniWM([item.display])
            }
            if let backup { backups.append(backup) }
            try AppThemeFileWriter.writeAtomically(item.after, to: item.url)
            state.owned[path] = digest
            state.pending[path] = nil
            try store.save(state)
            written.append(item.url.lastPathComponent)
        }
        return (written, rendered.contains { $0.before == nil })
    }

    private static func isReviewed(_ item: Rendered, _ job: AppThemeJob) -> Bool {
        guard let before = item.before, let reviewed = job.takeOver[item.url.path] else { return false }
        return AppThemeFileWriter.digest(before) == reviewed
    }

    func render(_ output: AppThemeOutput, job: AppThemeJob) throws -> Rendered {
        let dark = switch output.variant {
        case .current: job.dark
        case .light: false
        case .dark: true
        }
        let source = dark ? output.darkTemplate ?? output.template : output.template
        let text = try AppThemeTemplate.render(templateText(source), palette: job.palette, dark: dark)
        let url = try policy.destination(for: output.path)
        let display = policy.display(url)
        let before = try AppThemeFileWriter.read(url)
        let existingText = try before.map { data in
            guard let text = String(data: data, encoding: .utf8) else { throw AppThemeEngineError.notText(display) }
            return text
        }
        guard let keys = output.table else {
            return Rendered(
                url: url,
                display: display,
                before: before,
                after: Data(text.utf8),
                ownedText: text,
                currentOwnedText: existingText
            )
        }
        let existing = existingText ?? ""
        let table = AppThemeTOMLTable(keys: keys)
        let body = text.hasSuffix("\n") ? text : text + "\n"
        let current = table.current(in: existing)
        let after = current == body ? existing : try table.replacing(in: existing, with: body, path: display)
        let owner = current ?? (before == nil || Self.isBlank(existing) ? nil : "")
        return Rendered(
            url: url,
            display: display,
            before: before,
            after: Data(after.utf8),
            ownedText: body,
            currentOwnedText: owner
        )
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }

    private func templateText(_ source: AppThemeTemplateSource) throws -> String {
        switch source {
        case let .text(text):
            return text
        case let .file(path):
            let url = URL(fileURLWithPath: policy.expand(path))
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard size <= AppThemeTemplate.maximumBytes else {
                throw AppThemeTemplateError.tooLarge(bytes: size)
            }
            guard let data = try? Data(contentsOf: url) else { throw AppThemeEngineError.unreadableTemplate(path) }
            guard let text = String(data: data, encoding: .utf8) else { throw AppThemeEngineError.notText(path) }
            return text
        }
    }
}
