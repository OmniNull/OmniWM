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

    struct Rendered: Equatable {
        let url: URL
        let display: String
        let before: Data?
        let after: Data
        let ownedText: String
        let currentOwnedText: String?
    }

    func run(_ job: AppThemeJob) -> AppThemeRunReport {
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
        for target in job.targets {
            do {
                let paths = target.outputs.compactMap { try? policy.destination(for: $0.path).path }
                if let path = paths.first(where: { claimed[$0] != nil }), let owner = claimed[path] {
                    throw AppThemeEngineError.sharedOutput(
                        path: policy.display(URL(fileURLWithPath: path)),
                        owner: owner
                    )
                }
                for path in paths {
                    claimed[path] = target.name
                }
                let (names, newFiles) = try write(target, job: job, state: &state)
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
        let terminalsChanged = job.targets.contains { $0.isTerminal && changed[$0.id] == true }
        let ordered = job.targets.enumerated()
            .sorted { ($0.element.reload?.phase ?? 0, $0.offset) < ($1.element.reload?.phase ?? 0, $1.offset) }
            .map(\.element)
        for target in ordered {
            guard let action = target.reload, let wrote = changed[target.id] else { continue }
            let needed = wrote || state.reloadPending.contains(target.id) || job.forceReload.contains(target.id)
                || (action.runsAfterTerminals && (terminalsChanged || job.appearanceChanged))
            guard needed else { continue }
            state.reloadPending.insert(target.id)
            try? store.save(state)
            let outcome = AppThemeReloader(environment: environment)
                .reload(action, newFiles: created.contains(target.id))
            if outcome.succeeded { state.reloadPending.remove(target.id) }
            report.results[target.id]?.reload = outcome.message
            report.results[target.id]?.reloadFailed = !outcome.succeeded
        }
        report.ghosttyThemesChanged = job.targets.contains { target in
            target.reload == .ghostty && (changed[target.id] == true || job.forceReload.contains(target.id))
        }
        state.results.merge(report.results) { $1 }
        try? store.save(state)
        return report
    }

    private func write(
        _ target: AppThemeTarget,
        job: AppThemeJob,
        state: inout AppThemeState
    ) throws -> (names: [String], newFiles: Bool) {
        let rendered = try target.outputs.map { try render($0, job: job) }
        let conflicts = rendered.filter { item in
            guard item.before != item.after, let current = item.currentOwnedText else { return false }
            let digest = AppThemeFileWriter.digest(current)
            let owned = state.owned[item.url.path] == digest || state.pending[item.url.path] == digest
            return !owned && !job.takeOver.contains(item.url.path)
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
            state.pending[path] = digest
            if target.reload != nil { state.reloadPending.insert(target.id) }
            try store.save(state)
            try AppThemeFileWriter.writeAtomically(item.after, to: item.url)
            state.owned[path] = digest
            state.pending[path] = nil
            try store.save(state)
            written.append(item.url.lastPathComponent)
        }
        return (written, rendered.contains { $0.before == nil })
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
