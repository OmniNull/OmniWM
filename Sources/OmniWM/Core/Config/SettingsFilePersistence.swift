// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
final class SettingsFilePersistence {
    nonisolated static let defaultDirectoryURL = OmniWMStoragePaths.live.configDirectory
    nonisolated static let fileName = "settings.luau"

    let directoryURL: URL
    let fileURL: URL

    private let deferSaves: Bool
    private let monitorProvider: () -> [Monitor]
    let confirmation = SettingsFormulaConfirmation()
    let observation: SettingsFileObservation
    private struct Save {
        let revision: UInt64
        let export: SettingsExport
        let prepared: SettingsFileEdit?
        let origins: SettingsListOrigins
    }

    private var saveRevision: UInt64 = 0
    private var pendingSave: Save?
    private var activeOrigins: SettingsListOrigins?
    private var formulaAfterSave: (export: SettingsExport, origins: SettingsListOrigins)?
    private var saveTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    private var readingFiles: SettingsFileVersions?
    private var files: SettingsFileVersions = [:]
    let fieldSources = SettingsFieldSources()
    private var document: SettingsFileDocument? {
        didSet { fieldSources.document = document?.luau }
    }

    private var appliedExport: SettingsExport?
    func recordAppliedExport(_ export: SettingsExport) {
        appliedExport = export
    }

    private var writeBlockNotice: SettingsConfigNotice?
    var applyFormulaValues: (@MainActor (SettingsExport, _ committed: Bool) -> Void)?
    private var onExternalChange: (@MainActor (SettingsFileLoadOutcome) -> Void)?
    private var onSaveNotice: (@MainActor (SettingsConfigNotice?) -> Void)?

    init(
        directory: URL = SettingsFilePersistence.defaultDirectoryURL,
        startWatching: Bool = true,
        deferSaves: Bool = true,
        monitorProvider: @escaping () -> [Monitor] = Monitor.current
    ) {
        directoryURL = directory
        fileURL = Self.settingsURL(in: directory)
        self.deferSaves = deferSaves
        self.monitorProvider = monitorProvider
        observation = SettingsFileObservation(directoryURL: directoryURL, fileURL: fileURL)
        observation.onPossibleChange = { [weak self] url in self?.observeChange(affectedBy: url) }

        if startWatching { observation.start() }
    }

    var settingsWritesBlocked: Bool {
        writeBlockNotice != nil
    }

    func permitsWorkspaceLayoutEdit(for id: UUID) -> Bool {
        guard document?.luau?.hasFormulas == true, confirmation.canPresent?() != true,
              !fieldSources.sites(for: [.workspaces], member: .row(id.uuidString), leaves: ["layoutType"]).isEmpty
        else { return true }
        rejectEdit(SettingsFileEdit.formulaRequiresConfirmation, restore: false)
        return false
    }

    func retainFailedIPCState() {
        guard let document, !document.hasLiteral(at: ["general", "ipcEnabled"]) else { return }
        appliedExport?.ipcEnabled = false
    }

    func setExternalChangeHandler(_ handler: @escaping @MainActor (SettingsFileLoadOutcome) -> Void) {
        onExternalChange = handler
    }

    func setSaveNoticeHandler(_ handler: @escaping @MainActor (SettingsConfigNotice?) -> Void) {
        onSaveNotice = handler
    }

    func load() -> SettingsExport {
        loadOutcome().export ?? SettingsExport.defaults()
    }

    func loadOutcome() -> SettingsFileLoadOutcome {
        do {
            try SettingsFileAccess.ensureDirectoryExists(at: directoryURL)
            let targetURL = try SettingsFileAccess.settingsTarget(for: fileURL)
            guard FileManager.default.fileExists(atPath: targetURL.path)
            else { return try createDefaults(at: targetURL) }
            return try readDocument(at: targetURL, initial: true)
        } catch {
            let reason = error.localizedDescription
            let notice = SettingsConfigNotice.persistenceWriteBlocked(reason: reason)
            writeBlockNotice = notice
            Log.config.error("Failed to load \(fileURL.path): \(reason)")
            return SettingsFileLoadOutcome(
                export: SettingsExport.defaults(),
                notice: notice
            )
        }
    }

    func createSettingsFileIfMissing() throws -> SettingsFileLoadOutcome? {
        try SettingsFileAccess.ensureDirectoryExists(at: directoryURL)
        let target = try SettingsFileAccess.settingsTarget(for: fileURL)
        guard !FileManager.default.fileExists(atPath: target.path) else { return nil }
        return try createDefaults(at: target)
    }

    private func createDefaults(at target: URL) throws -> SettingsFileLoadOutcome {
        let defaults = SettingsExport.defaults()
        let candidate = try SettingsFileDocument(SettingsFileDocument.initialSource(defaults, at: fileURL), at: fileURL)
        try persist(candidate, at: target, export: defaults, creating: true)
        return SettingsFileLoadOutcome(export: candidate.export, notice: nil)
    }
}

extension SettingsFilePersistence {
    func save(_ export: SettingsExport, origins: SettingsListOrigins = [:]) {
        do {
            let notice = try saveImmediately(export, origins: origins)
            onSaveNotice?(notice)
        } catch {
            Log.config.error("Failed to save \(fileURL.path): \(error.localizedDescription)")
        }
    }

    @discardableResult
    func saveImmediately(_ export: SettingsExport, origins: SettingsListOrigins = [:]) throws -> SettingsConfigNotice? {
        do {
            guard let edit = try prepareEdit(export, origins: origins) else { return nil }
            try commit(edit, document: SettingsFileDocument(edit.patch.source, at: fileURL), export: export)
            return nil
        } catch {
            rejectEdit(error)
            throw error
        }
    }

    private func prepareEdit(_ export: SettingsExport, origins: SettingsListOrigins) throws -> SettingsFileEdit? {
        if let reason = writeBlockNotice?.blockingReason {
            throw SettingsFilePersistenceError.writesBlocked(reason)
        }
        try SettingsFileAccess.ensureDirectoryExists(at: directoryURL)
        let target = try SettingsFileAccess.settingsTarget(for: fileURL)
        let fingerprint = SettingsFileAccess.currentFingerprint(at: fileURL)
        if fingerprint == nil {
            guard document == nil else {
                throw SettingsLuauError(
                    message: "\(fileURL.lastPathComponent) has been removed. Restore it before changing settings."
                )
            }
            return try SettingsFileEdit(
                target: target,
                previous: nil,
                patch: SettingsSourceEdit(
                    source: SettingsFileDocument.initialSource(export, at: fileURL),
                    question: nil,
                    expected: nil
                )
            )
        }
        guard let document, files[fileURL]?.targetFingerprint == fingerprint, document.modules.isCurrent else {
            if deferSaves {
                observeChange()
                throw SettingsLuauError(message: "The settings files changed. Checking the new contents before saving.")
            }
            let contents = try SettingsFileAccess.readContents(at: target, maximumBytes: ConfigScriptLoader.sourceLimit)
            let latest = try SettingsFileDocument(contents.data, at: fileURL)
            try Self.validate(latest.export, monitorProvider: monitorProvider)
            throw SettingsLuauError(
                message: "\(fileURL.lastPathComponent) changed. Read the latest file before saving."
            )
        }
        guard appliedExport != export || !origins.isEmpty else { return nil }
        let patch = try document.edit(from: appliedExport ?? document.export, to: export, origins: origins)
        guard patch.source != document.source else { return nil }
        return SettingsFileEdit(target: target, previous: fingerprint, patch: patch, modules: document.modules)
    }

    private func commit(
        _ edit: SettingsFileEdit,
        document candidate: SettingsFileDocument,
        export: SettingsExport,
        approved: Bool = false
    ) throws {
        try Self.validate(candidate.export, monitorProvider: monitorProvider)
        try edit.verify(at: fileURL, originalSource: document?.source, approved: approved)
        guard candidate.modules.isCurrent else { throw SettingsLuauError.changedHelper }
        if case let .toml(previous)? = document, try previous.backUpBeforeFirstEdit(at: edit.target) {
            try edit.verify(at: fileURL, originalSource: previous.source, approved: approved)
        }
        try persist(candidate, at: edit.target, export: export, creating: edit.previous == nil)
    }

    private func rejectEdit(_ error: Error, restore: Bool = true) {
        let notice: SettingsConfigNotice
        if error is POSIXError || error is CocoaError {
            notice = .persistenceWriteBlocked(reason: error.localizedDescription)
            writeBlockNotice = notice
        } else {
            notice = .invalidRejected(reason: error.localizedDescription)
        }
        if restore, let appliedExport, onExternalChange != nil {
            onExternalChange?(SettingsFileLoadOutcome(export: appliedExport, notice: notice))
        } else {
            onSaveNotice?(notice)
        }
    }

    func editList(at path: [String], keeping indices: [Int?], _ edit: () -> Void) {
        let prior = activeOrigins
        activeOrigins = SettingsListIdentity.composing(prior ?? [:], with: [path: indices])
        defer { activeOrigins = prior }
        edit()
    }

    func scheduleSave(_ export: @autoclosure () -> SettingsExport) {
        scheduleSave(export(), originsSincePending: activeOrigins ?? [:])
    }

    private func scheduleSave(_ desired: SettingsExport, originsSincePending: SettingsListOrigins) {
        let pending = pendingSave?.prepared?.patch.question == nil ? pendingSave?.origins : nil
        let origins = SettingsListIdentity.composing(pending ?? [:], with: originsSincePending)
        if formulaAfterSave != nil, desired == pendingSave?.export { return }
        formulaAfterSave = nil
        if confirmation.question != nil {
            guard desired != appliedExport || !origins.isEmpty else { return }
            confirmation.discard()
        }
        if document?.luau?.hasFormulas == true, confirmation.canPresent?() == true {
            do {
                guard let edit = try prepareEdit(desired, origins: origins) else {
                    pendingSave = nil
                    return
                }
                if edit.patch.question != nil {
                    if let pendingSave, pendingSave.prepared?.patch.question == nil {
                        formulaAfterSave = (desired, originsSincePending)
                        applyFormulaValues?(pendingSave.export, false)
                        return
                    }
                    if let appliedExport { applyFormulaValues?(appliedExport, false) }
                }
                queue(desired, prepared: edit, origins: origins)
                return
            } catch {
                rejectEdit(error)
                return
            }
        }
        queue(desired, origins: origins)
    }

    private func queue(_ export: SettingsExport, prepared: SettingsFileEdit? = nil, origins: SettingsListOrigins) {
        saveRevision &+= 1
        let next = Save(revision: saveRevision, export: export, prepared: prepared, origins: origins)
        guard deferSaves else {
            writeSynchronously(next)
            return
        }
        pendingSave = next
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor [weak self] in await self?.writePendingEdits() }
    }

    private func writeSynchronously(_ save: Save) {
        guard let edit = save.prepared else {
            self.save(save.export, origins: save.origins)
            return
        }
        do {
            try finish(save, edit: edit, candidate: SettingsFileDocument(edit.patch.source, at: fileURL))
            onSaveNotice?(nil)
        } catch {
            rejectEdit(error, restore: edit.patch.question == nil)
            handlePossibleSettingsFileChange()
        }
    }

    private func finish(_ save: Save, edit: SettingsFileEdit, candidate: SettingsFileDocument) throws {
        guard let luau = candidate.luau,
              let (question, values) = try save.prepared?.patch.preview(luau, applying: save.export)
        else {
            try commit(edit, document: candidate, export: save.export)
            return
        }
        guard confirmation.canPresent != nil else { return }
        guard SettingsFileAccess.currentFingerprint(at: fileURL) == edit.previous, edit.modules.isCurrent,
              candidate.modules.isCurrent
        else {
            throw SettingsLuauError(
                message: "settings.luau changed before confirmation. Try again with the latest file."
            )
        }
        confirmation.present(question) { [weak self] in
            guard let self else { return }
            do {
                try commit(edit, document: candidate, export: values, approved: true)
                applyFormulaValues?(values, true)
                onSaveNotice?(nil)
            } catch {
                rejectEdit(error, restore: false)
                handlePossibleSettingsFileChange()
            }
        }
    }

    private func writePendingEdits() async {
        defer { if !Task.isCancelled { saveTask = nil } }
        while let save = pendingSave, !Task.isCancelled {
            do {
                if let edit = try save.prepared ?? prepareEdit(save.export, origins: save.origins) {
                    let result = try await SettingsFileEvaluator.shared.evaluate(edit.patch.source, at: fileURL)
                    guard !Task.isCancelled, save.revision == pendingSave?.revision else { continue }
                    try finish(save, edit: edit, candidate: SettingsFileDocument(result))
                }
                onSaveNotice?(nil)
            } catch {
                guard !Task.isCancelled, save.revision == pendingSave?.revision else { continue }
                formulaAfterSave = nil
                rejectEdit(error, restore: save.prepared?.patch.question == nil)
                if save.prepared?.patch.question != nil { handlePossibleSettingsFileChange() }
            }
            if save.revision == pendingSave?.revision {
                pendingSave = nil
                if let desired = formulaAfterSave {
                    formulaAfterSave = nil
                    scheduleSave(desired.export, originsSincePending: desired.origins)
                }
            }
        }
    }

    func flushNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let save = pendingSave else { return }
        pendingSave = nil
        writeSynchronously(save)
        if let desired = formulaAfterSave {
            formulaAfterSave = nil
            scheduleSave(desired.export, originsSincePending: desired.origins)
        }
    }
}

extension SettingsFilePersistence {
    func reloadIfChanged() -> SettingsExport? {
        reloadOutcomeIfChanged()?.export
    }

    func reloadOutcomeIfChanged() -> SettingsFileLoadOutcome? {
        do {
            let targetURL = try SettingsFileAccess.settingsTarget(for: fileURL)
            guard FileManager.default.fileExists(atPath: targetURL.path) else {
                Log.config.error("Ignoring external reload because \(fileURL.path) no longer exists.")
                return nil
            }
            return try readDocument(at: targetURL, initial: false)
        } catch {
            let reason = error.localizedDescription
            return SettingsFileLoadOutcome(export: nil, notice: .invalidRejected(reason: reason))
        }
    }

    private func readDocument(at target: URL, initial: Bool) throws -> SettingsFileLoadOutcome {
        let contents = try SettingsFileAccess.readContents(at: target, maximumBytes: ConfigScriptLoader.sourceLimit)
        if contents.fingerprint != files[fileURL]?.targetFingerprint || !files.isCurrent { confirmation.discard() }
        let load: SettingsFileLoad
        if initial, let cached = Self.takeLaunchLoad(at: fileURL, fingerprint: contents.fingerprint) {
            load = cached
        } else {
            load = SettingsFileLoad(contents.data, at: fileURL)
        }
        return accept(load, fingerprint: contents.fingerprint, initial: initial)
    }

    private func accept(
        _ load: SettingsFileLoad, fingerprint: SettingsFileAccess.Fingerprint, initial: Bool = false
    ) -> SettingsFileLoadOutcome {
        let result = load.result.flatMap { candidate in
            Result {
                try Self.validate(candidate.export, monitorProvider: monitorProvider)
                return candidate
            }
        }
        var inputs = load.modules
        if case .failure = result, let document {
            for url in document.modules.keys where inputs[url] == nil { inputs[url] = ConfigScriptFileVersion(at: url) }
        }
        inputs[fileURL] = .target(fingerprint)
        files = inputs
        observation.refresh(files: inputs.mapValues(\.targetFingerprint))
        guard inputs.isCurrent else {
            observeChange()
            return SettingsFileLoadOutcome(export: nil, notice: nil)
        }
        switch result {
        case let .success(candidate):
            let changed = initial || document?.export != candidate.export
            document = candidate
            if changed { appliedExport = candidate.export }
            writeBlockNotice = nil
            return SettingsFileLoadOutcome(export: changed ? candidate.export : nil, notice: nil)
        case let .failure(error):
            let reason = error.localizedDescription
            writeBlockNotice = .persistenceWriteBlocked(reason: reason)
            Log.config.error("Rejected settings at \(fileURL.path): \(reason)")
            return SettingsFileLoadOutcome(export: nil, notice: .invalidRejected(reason: reason))
        }
    }
}

extension SettingsFilePersistence {
    private func observeChange(affectedBy url: URL? = nil) {
        guard let changed = changedFiles(affectedBy: url), changed != readingFiles,
              let fingerprint = changed[fileURL]?.targetFingerprint else { return }
        observeTask?.cancel()
        readingFiles = changed
        let entry = fileURL
        observeTask = Task { @MainActor [weak self] in
            let result = await SettingsFileEvaluator.shared.read(entry, fingerprint: fingerprint)
            guard !Task.isCancelled, let self else { return }
            readingFiles = nil
            guard changed.isCurrent else {
                observeChange()
                return
            }
            publish(accept(SettingsFileLoad(result), fingerprint: fingerprint))
        }
    }

    private func changedFiles(affectedBy event: URL? = nil) -> SettingsFileVersions? {
        var current = files
        let affected = event.map(observation.filesAffected(by:)) ?? Set(files.keys).union([fileURL])
        for url in affected
            where url == fileURL || files[url] != nil { current[url] = ConfigScriptFileVersion(at: url) }
        observation.refresh(files: current.mapValues(\.targetFingerprint))
        guard current != files else { return nil }
        formulaAfterSave = nil
        confirmation.discard()
        if current[fileURL]?.targetFingerprint == nil {
            observeTask?.cancel()
            readingFiles = nil
            files = current
            if document != nil || writeBlockNotice != nil {
                let reason = "\(fileURL.lastPathComponent) is missing. Restore the file or create a new settings file."
                writeBlockNotice = .persistenceWriteBlocked(reason: reason)
                onSaveNotice?(.invalidRejected(reason: reason))
            }
            return nil
        }
        return current
    }

    func handlePossibleSettingsFileChange() {
        guard changedFiles() != nil, let outcome = reloadOutcomeIfChanged() else { return }
        publish(outcome)
    }

    private func publish(_ outcome: SettingsFileLoadOutcome) {
        if outcome.export != nil {
            saveTask?.cancel()
            saveTask = nil
            pendingSave = nil
        }
        onExternalChange?(outcome)
    }

    private func persist(
        _ candidate: SettingsFileDocument,
        at targetURL: URL,
        export: SettingsExport,
        creating: Bool
    ) throws {
        if creating {
            try SettingsFileAccess.createAtomically(candidate.source, at: targetURL)
        } else {
            try SettingsFileAccess.writeAtomically(candidate.source, at: targetURL)
        }
        writeBlockNotice = nil
        document = candidate
        files = candidate.modules
        files[fileURL] = ConfigScriptFileVersion(at: fileURL)
        appliedExport = export
        observation.refresh(files: files.mapValues(\.targetFingerprint))
        if !candidate.modules.isCurrent { observeChange() }
    }
}
