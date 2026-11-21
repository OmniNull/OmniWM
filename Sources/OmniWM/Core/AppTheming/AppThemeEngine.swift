// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum AppThemeEngineError: Error, Equatable, LocalizedError {
    case changedOutsideOmniWM([String])
    case unreadableTemplate(String)
    case notText(String)
    case sharedOutput(path: String, owner: String)
    case unreadable(String, String)
    case blockedGhosttySelection([String])

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
        case let .unreadable(path, reason):
            String(localized: "\(path) can’t be read: \(reason)")
        case let .blockedGhosttySelection(paths):
            String(
                localized: "\(paths.joined(separator: ", ")) sets a theme but is outside the folders OmniWM writes. Comment that line out yourself."
            )
        }
    }
}

struct AppThemeCancelled: Error {}

enum FileWrite {
    case unchanged
    case replaced(previousOwner: String?, previousPending: String?)
}

struct AppThemeEngine: Sendable {
    let policy: AppThemeOutputPolicy
    let store: AppThemeStateStore
    let environment: AppThemeEnvironment
    var now: @Sendable () -> Date = { Date() }
    var willReplace: @Sendable (URL) -> Void = { _ in }
    var willLock: @Sendable () -> Void = {}

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
        guard job.targets.contains(where: { job.enabled.contains($0) }) else { return AppThemeRunReport() }
        willLock()
        do {
            return try store.withLock { try runLocked(job) }
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

    private func runLocked(_ job: AppThemeJob) throws -> AppThemeRunReport {
        guard job.targets.contains(where: { job.enabled.contains($0) }) else { return AppThemeRunReport() }
        var state = try store.load()
        var report = AppThemeRunReport()
        report.stored = state.results
        commitSelection(of: job, into: &report)
        let roots = policy.resolvedRoots()
        var changed: [String: Bool] = [:]
        var claimed: [String: String] = [:]
        var created: Set<String> = []
        for target in job.targets where job.enabled.contains(target) {
            do {
                try claim(target, in: &claimed, roots: roots)
                let (names, newFiles) = try write(
                    target,
                    job: job,
                    roots: roots,
                    state: &state,
                    backups: &report.backups
                )
                changed[target.id] = !names.isEmpty
                if newFiles { created.insert(target.id) }
                report.results[target.id] = AppThemeResult(
                    date: now(),
                    outcome: names.isEmpty ? .unchanged : .updated,
                    message: names.isEmpty
                        ? String(localized: "Already up to date")
                        : String(localized: "Wrote \(names.joined(separator: ", "))")
                )
            } catch is AppThemeCancelled {
                continue
            } catch let AppThemeEngineError.changedOutsideOmniWM(paths) {
                if wasApproved(target, job: job, roots: roots) { report.reviewAgain.append(target.id) }
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

    private func wasApproved(_ target: AppThemeTarget, job: AppThemeJob, roots: AppThemeOutputPolicy.Roots) -> Bool {
        target.outputs.contains { output in
            (try? policy.destination(for: output.path, roots: roots)).map { job.takeOver[$0.path] != nil } ?? false
        }
    }

    private func claim(
        _ target: AppThemeTarget,
        in claimed: inout [String: String],
        roots: AppThemeOutputPolicy.Roots
    ) throws {
        let paths = target.outputs.compactMap { try? policy.destination(for: $0.path, roots: roots).path }
        if let path = paths.first(where: { claimed[$0] != nil }), let owner = claimed[path] {
            throw AppThemeEngineError.sharedOutput(path: policy.display(URL(fileURLWithPath: path)), owner: owner)
        }
        if let path = paths.enumerated().first(where: { paths[..<$0.offset].contains($0.element) })?.element {
            throw AppThemeEngineError.sharedOutput(path: policy.display(URL(fileURLWithPath: path)), owner: target.name)
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
            guard let action = target.reload, let wrote = changed[target.id], job.enabled.contains(target) else {
                return false
            }
            return wrote || state.reloadPending.contains(target.id) || job.forceReload.contains(target.id)
                || (action.runsAfterTerminals && (terminalsChanged || job.appearanceChanged))
        }
        var outcomes: [AppThemeReloadAction: AppThemeReloadOutcome] = [:]
        for target in needed {
            guard let action = target.reload, job.enabled.contains(target) else { continue }
            state.reloadPending.insert(target.id)
            try? store.save(state)
            let reloader = AppThemeReloader(environment: environment) { job.enabled.contains(target) }
            let outcome = outcomes[action] ?? reloader.reload(
                action,
                newFiles: needed.contains { $0.reload == action && created.contains($0.id) }
            )
            outcomes[action] = outcome
            if outcome.succeeded { state.reloadPending.remove(target.id) }
            report.results[target.id]?.reload = outcome.message
            report.results[target.id]?.reloadFailed = !outcome.succeeded
        }
        report.ghosttyThemesChanged = job.targets.contains { target in
            target.reload == .ghostty && job.enabled.contains(target)
                && (changed[target.id] == true || job.forceReload.contains(target.id))
        }
    }

    private static func isReviewed(_ item: Rendered, _ job: AppThemeJob) -> Bool {
        guard let before = item.before, let reviewed = job.takeOver[item.url.path] else { return false }
        return AppThemeFileWriter.digest(before) == reviewed
    }

    func render(
        _ output: AppThemeOutput,
        job: AppThemeJob,
        roots: AppThemeOutputPolicy.Roots? = nil
    ) throws -> Rendered {
        let dark = switch output.variant {
        case .current: job.dark
        case .light: false
        case .dark: true
        }
        let source = dark ? output.darkTemplate ?? output.template : output.template
        let text = try AppThemeTemplate.render(templateText(source), palette: job.palette, dark: dark)
        let url = try policy.destination(for: output.path, roots: roots)
        let display = policy.display(url)
        let before = try AppThemeFileWriter.read(url, display: display)
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
            guard let data = try AppThemeFileWriter.read(url, display: path) else {
                throw AppThemeEngineError.unreadableTemplate(path)
            }
            guard let text = String(data: data, encoding: .utf8) else { throw AppThemeEngineError.notText(path) }
            return text
        }
    }
}

extension AppThemeEngine {
    private struct Replaced {
        let item: Rendered
        let owned: String?
        let pending: String?
    }

    private func write(
        _ target: AppThemeTarget,
        job: AppThemeJob,
        roots: AppThemeOutputPolicy.Roots,
        state: inout AppThemeState,
        backups: inout [URL]
    ) throws -> (names: [String], newFiles: Bool) {
        let rendered = try target.outputs.map { try render($0, job: job, roots: roots) }
        let conflicts = rendered.filter { item in
            guard item.before != item.after, let current = item.currentOwnedText else { return false }
            let digest = AppThemeFileWriter.digest(current)
            let owned = state.owned[item.url.path] == digest || state.pending[item.url.path] == digest
            return !owned && !Self.isReviewed(item, job)
        }
        guard conflicts.isEmpty else { throw AppThemeEngineError.changedOutsideOmniWM(conflicts.map(\.display)) }
        var written: [String] = []
        var replaced: [Replaced] = []
        do {
            for item in rendered {
                if case let .replaced(owner, pending) = try write(
                    item, of: target, job: job, state: &state, backups: &backups
                ) {
                    replaced.append(Replaced(item: item, owned: owner, pending: pending))
                    written.append(item.url.lastPathComponent)
                }
            }
        } catch {
            for previous in replaced.reversed() {
                restore(previous.item, owned: previous.owned, pending: previous.pending, state: &state)
            }
            try? store.save(state)
            throw error
        }
        return (written, rendered.contains { $0.before == nil })
    }

    private func write(
        _ item: Rendered,
        of target: AppThemeTarget,
        job: AppThemeJob,
        state: inout AppThemeState,
        backups: inout [URL]
    ) throws -> FileWrite {
        let digest = AppThemeFileWriter.digest(item.ownedText)
        let path = item.url.path
        if item.before == item.after {
            if state.owned[path] != digest || state.pending[path] != nil {
                state.owned[path] = digest
                state.pending[path] = nil
                try store.save(state)
            }
            return .unchanged
        }
        let previous = state.owned[path]
        let previousPending = state.pending[path]
        let backup = try item.before.flatMap { before in
            Self.isReviewed(item, job) ? try store.backup(before, of: item.url, date: now()) : nil
        }
        state.pending[path] = digest
        if target.reload != nil { state.reloadPending.insert(target.id) }
        try store.save(state)
        do {
            try replace(item.url, with: item.after, expecting: item.before, display: item.display) {
                job.enabled.contains(target)
            }
        } catch {
            if let backup { try? FileManager.default.removeItem(at: backup) }
            state.pending[path] = previousPending
            try store.save(state)
            throw error
        }
        if let backup { backups.append(backup) }
        state.owned[path] = digest
        state.pending[path] = nil
        do {
            try store.save(state)
        } catch {
            restore(item, owned: previous, pending: previousPending, state: &state)
            throw error
        }
        return .replaced(previousOwner: previous, previousPending: previousPending)
    }

    private func restore(_ item: Rendered, owned: String?, pending: String?, state: inout AppThemeState) {
        guard (try? restore(item.url, display: item.display, to: item.before, from: item.after)) != nil else { return }
        state.owned[item.url.path] = owned
        state.pending[item.url.path] = pending
    }
}
