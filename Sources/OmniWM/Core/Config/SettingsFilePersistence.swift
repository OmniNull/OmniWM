// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
final class SettingsFilePersistence {
    nonisolated static let defaultDirectoryURL = OmniWMStoragePaths.live.configDirectory
    nonisolated static let fileName = "settings.toml"
    nonisolated static let corruptFileName = "settings.toml.corrupt"
    nonisolated static let secondaryCorruptFileName = "settings.toml.corrupt.1"
    nonisolated static let corruptFileNames = [corruptFileName, secondaryCorruptFileName]
    nonisolated static let preVersionOneFileName = "settings.toml.pre-v1"
    nonisolated static let secondaryPreVersionOneFileName = "settings.toml.pre-v1.1"
    nonisolated static let preVersionOneFileNames = [preVersionOneFileName, secondaryPreVersionOneFileName]
    nonisolated static func migrationBackupFileNames(for targetVersion: Int) -> [String] {
        let primary = "settings.toml.pre-v\(targetVersion)"
        return [primary, "\(primary).1"]
    }

    nonisolated static var fileURL: URL {
        defaultDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    let directoryURL: URL
    let fileURL: URL

    private let deferSaves: Bool
    private let monitorProvider: () -> [Monitor]
    private let observation: SettingsFileObservation
    private var pendingExport: SettingsExport?
    private var saveScheduled = false
    private var lastWrittenFingerprint: SettingsFileAccess.Fingerprint?
    private var lastObservedFingerprint: SettingsFileAccess.Fingerprint?
    private var lastRejectedFingerprint: SettingsFileAccess.Fingerprint?
    private var lastPersistedExport: SettingsExport?
    private var writeBlockNotice: SettingsConfigNotice?
    private var onExternalChange: (@MainActor (SettingsFileLoadOutcome) -> Void)?
    private var onSaveNotice: (@MainActor (SettingsConfigNotice) -> Void)?

    init(
        directory: URL = SettingsFilePersistence.defaultDirectoryURL,
        startWatching: Bool = true,
        deferSaves: Bool = true,
        monitorProvider: @escaping () -> [Monitor] = Monitor.current
    ) {
        directoryURL = directory
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.deferSaves = deferSaves
        self.monitorProvider = monitorProvider
        observation = SettingsFileObservation(directoryURL: directoryURL, fileURL: fileURL)
        observation.attach(to: self)

        if startWatching {
            observation.start()
        }
    }

    var settingsWritesBlocked: Bool {
        writeBlockNotice != nil
    }

    func setExternalChangeHandler(_ handler: @escaping @MainActor (SettingsFileLoadOutcome) -> Void) {
        onExternalChange = handler
    }

    func setSaveNoticeHandler(_ handler: @escaping @MainActor (SettingsConfigNotice) -> Void) {
        onSaveNotice = handler
    }

    func load() -> SettingsExport {
        loadOutcome().export ?? SettingsExport.defaults()
    }

    func loadOutcome() -> SettingsFileLoadOutcome {
        do {
            try SettingsFileAccess.ensureDirectoryExists(at: directoryURL)
            let targetURL = try SettingsFileAccess.settingsTarget(for: fileURL)
            guard FileManager.default.fileExists(atPath: targetURL.path) else {
                writeBlockNotice = nil
                let defaults = SettingsExport.defaults()
                let notice = try saveImmediately(defaults, to: targetURL)
                return SettingsFileLoadOutcome(export: defaults, notice: notice)
            }

            let contents = try SettingsFileAccess.readContents(at: targetURL)
            return decodeContents(
                contents,
                at: targetURL,
                fallback: SettingsExport.defaults(),
                isInitialLoad: true
            )
        } catch {
            let reason = SettingsTOMLCodec.diagnosticDescription(for: error)
            let notice = SettingsConfigNotice.persistenceWriteBlocked(reason: reason)
            writeBlockNotice = notice
            report("Failed to load \(fileURL.path): \(reason)")
            return SettingsFileLoadOutcome(
                export: SettingsExport.defaults(),
                notice: notice
            )
        }
    }

    func save(_ export: SettingsExport) {
        do {
            if let notice = try saveImmediately(export) {
                onSaveNotice?(notice)
            }
        } catch {
            report("Failed to save \(fileURL.path): \(error.localizedDescription)")
        }
    }

    @discardableResult
    func saveImmediately(_ export: SettingsExport) throws -> SettingsConfigNotice? {
        do {
            if let reason = writeBlockNotice?.blockingReason {
                throw SettingsFilePersistenceError.writesBlocked(reason)
            }
            try SettingsFileAccess.ensureDirectoryExists(at: directoryURL)
            let targetURL = try SettingsFileAccess.settingsTarget(for: fileURL)
            return try saveImmediately(export, to: targetURL)
        } catch {
            if writeBlockNotice == nil {
                let reason = SettingsTOMLCodec.diagnosticDescription(for: error)
                writeBlockNotice = .persistenceWriteBlocked(reason: reason)
            }
            if let writeBlockNotice {
                onSaveNotice?(writeBlockNotice)
            }
            throw error
        }
    }

    private func saveImmediately(_ export: SettingsExport, to targetURL: URL) throws -> SettingsConfigNotice? {
        let observedFingerprint = SettingsFileAccess.currentFingerprint(at: fileURL)
        if let fingerprint = observedFingerprint,
           fingerprint == lastObservedFingerprint,
           export == lastPersistedExport
        {
            observation.refresh(for: fingerprint)
            return nil
        }

        let transaction = SettingsFileWriteTransaction(
            directoryURL: directoryURL, fileURL: fileURL, targetURL: targetURL
        )
        let outcome = transaction.perform(export) { data in
            try persist(data, at: targetURL, export: export)
        }
        switch outcome {
        case let .saved(notice):
            return notice
        case let .failed(failure):
            if let notice = failure.notice { writeBlockNotice = notice }
            if let diagnostic = failure.diagnostic { report(diagnostic) }
            throw failure.error
        }
    }

    func scheduleSave(_ export: @autoclosure () -> SettingsExport) {
        if !deferSaves {
            pendingExport = nil
            save(export())
            return
        }

        pendingExport = export()
        guard !saveScheduled else { return }
        saveScheduled = true

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            saveScheduled = false
            flushNow()
        }
    }

    func flushNow() {
        guard let export = pendingExport else { return }
        pendingExport = nil
        save(export)
    }

    func reloadIfChanged() -> SettingsExport? {
        reloadOutcomeIfChanged()?.export
    }

    func reloadOutcomeIfChanged() -> SettingsFileLoadOutcome? {
        do {
            let targetURL = try SettingsFileAccess.settingsTarget(for: fileURL)
            guard FileManager.default.fileExists(atPath: targetURL.path) else {
                report("Ignoring external reload because \(fileURL.path) no longer exists.")
                return nil
            }
            let contents = try SettingsFileAccess.readContents(at: targetURL)
            return decodeContents(
                contents,
                at: targetURL,
                fallback: lastPersistedExport ?? SettingsExport.defaults(),
                isInitialLoad: false
            )
        } catch {
            let reason = SettingsTOMLCodec.diagnosticDescription(for: error)
            report("Ignoring invalid external settings edit at \(fileURL.path): \(reason)")
            return nil
        }
    }

    private func decodeContents(
        _ contents: SettingsFileAccess.Contents,
        at targetURL: URL,
        fallback: SettingsExport,
        isInitialLoad: Bool
    ) -> SettingsFileLoadOutcome {
        do {
            let result = try SettingsTOMLCodec.decodeForLoad(contents.data)
            try OverviewInputSettingsValidation.validate(
                mouseButton: result.export.overview.mouseButton,
                hyperTrigger: result.export.systemHyperTrigger,
                hotkeyBindings: result.export.hotkeyBindings
            )
            try GestureSettingsValidation.validate(result.export, monitorProvider: monitorProvider)
            guard let migration = result.migration else {
                writeBlockNotice = nil
                lastObservedFingerprint = contents.fingerprint
                lastRejectedFingerprint = nil
                lastPersistedExport = result.export
                observation.refresh(for: contents.fingerprint)
                return SettingsFileLoadOutcome(export: result.export, notice: nil)
            }
            return rewriteMigratedContents(
                result,
                migration: migration,
                contents: contents,
                targetURL: targetURL
            )
        } catch {
            return applyRejectedContents(error, contents: contents, fallback: fallback, isInitialLoad: isInitialLoad)
        }
    }

    private func rewriteMigratedContents(
        _ result: SettingsTOMLDecodeResult,
        migration: SettingsMigrationReport,
        contents: SettingsFileAccess.Contents,
        targetURL: URL
    ) -> SettingsFileLoadOutcome {
        let transaction = SettingsFileWriteTransaction(
            directoryURL: directoryURL, fileURL: fileURL, targetURL: targetURL
        )
        switch transaction.executeMigration(
            originalData: contents.data,
            decoded: result,
            export: result.export,
            migration: migration,
            persist: { data in try persist(data, at: targetURL, export: result.export) }
        ) {
        case let .migrated(notice):
            return SettingsFileLoadOutcome(export: result.export, notice: notice)
        case let .blocked(failure):
            let notice = failure.notice(for: migration)
            writeBlockNotice = notice
            lastObservedFingerprint = contents.fingerprint
            lastPersistedExport = result.export
            observation.refresh(for: contents.fingerprint)
            report(
                "Applied migrated settings from \(fileURL.path) in memory, but left the file untouched and blocked writes: \(failure.reason)"
            )
            for message in migration.messages {
                let diagnostic = "Settings migration: \(message)"
                Log.config.notice(diagnostic)
            }
            return SettingsFileLoadOutcome(export: result.export, notice: notice)
        }
    }

    private func applyRejectedContents(
        _ error: Error,
        contents: SettingsFileAccess.Contents,
        fallback: SettingsExport,
        isInitialLoad: Bool
    ) -> SettingsFileLoadOutcome {
        if let codecError = error as? SettingsTOMLCodecError,
           case let .unsupportedSchemaVersion(found, supported) = codecError
        {
            let notice = SettingsConfigNotice.unsupportedVersion(found: found, supported: supported)
            let reason = notice.blockingReason ?? "Unsupported settings schema."
            writeBlockNotice = notice
            lastObservedFingerprint = contents.fingerprint
            lastRejectedFingerprint = nil
            if lastPersistedExport == nil {
                lastPersistedExport = fallback
            }
            observation.refresh(for: contents.fingerprint)
            report("Refusing unsupported settings at \(fileURL.path): \(reason) Writes are blocked.")
            return SettingsFileLoadOutcome(export: isInitialLoad ? fallback : nil, notice: notice)
        }
        let reason = SettingsTOMLCodec.diagnosticDescription(for: error)
        writeBlockNotice = nil
        lastRejectedFingerprint = contents.fingerprint
        report("Ignoring invalid settings at \(fileURL.path): \(reason)")
        return SettingsFileLoadOutcome(export: nil, notice: .invalidRejected(reason: reason))
    }
}

extension SettingsFilePersistence {
    func handlePossibleSettingsFileChange() {
        let observedFingerprint = SettingsFileAccess.currentFingerprint(at: fileURL)
        observation.refresh(for: observedFingerprint)

        if observedFingerprint == lastWrittenFingerprint {
            lastObservedFingerprint = observedFingerprint
            return
        }

        guard observedFingerprint != lastObservedFingerprint else { return }
        guard observedFingerprint != lastRejectedFingerprint else { return }
        guard let outcome = reloadOutcomeIfChanged() else { return }
        if outcome.export != nil {
            pendingExport = nil
        }
        onExternalChange?(outcome)
    }

    private func persist(_ data: Data, at targetURL: URL, export: SettingsExport) throws {
        try SettingsFileAccess.writeAtomically(data, at: targetURL)
        writeBlockNotice = nil
        let fingerprint = SettingsFileAccess.currentFingerprint(at: fileURL)
        lastWrittenFingerprint = fingerprint
        lastObservedFingerprint = fingerprint
        lastRejectedFingerprint = nil
        lastPersistedExport = export
        observation.refresh(for: fingerprint)
    }

    private func report(_ message: String) {
        Log.config.error(message)
    }
}
