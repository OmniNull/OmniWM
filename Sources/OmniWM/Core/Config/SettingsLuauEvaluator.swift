// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

typealias SettingsFileVersions = [URL: ConfigScriptFileVersion]

extension Dictionary where Key == URL, Value == ConfigScriptFileVersion {
    var isCurrent: Bool {
        allSatisfy { ConfigScriptFileVersion(at: $0.key) == $0.value }
    }
}

struct SettingsLuauInput: Sendable {
    let source: Data
    let modules: SettingsFileVersions
    let result: Result<SettingsLuauDocument.Evaluation, any Error>
}

struct SettingsLuauLoad {
    let modules: SettingsFileVersions
    let result: Result<SettingsLuauDocument, any Error>

    init(_ input: SettingsLuauInput) {
        self.init(.success(input))
    }

    init(_ read: Result<SettingsLuauInput, any Error>) {
        modules = (try? read.get().modules) ?? [:]
        result = read.flatMap { input in Result { try SettingsLuauDocument(input) } }
    }
}

extension SettingsLuauError {
    static let changedHelper =
        Self(message: "A settings helper was edited externally. Read the latest file before saving.")
}

actor SettingsLuauEvaluator {
    static let shared = SettingsLuauEvaluator()
    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.settings.luau", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func read(_ url: URL, fingerprint: SettingsFileAccess.Fingerprint) -> Result<SettingsLuauInput, any Error> {
        Result {
            let target = try SettingsFileAccess.settingsTarget(for: url)
            let contents = try SettingsFileAccess.readContents(at: target, maximumBytes: ConfigScriptLoader.sourceLimit)
            guard contents.fingerprint == fingerprint else { throw POSIXError(.ESTALE) }
            return try evaluate(contents.data, at: url)
        }
    }

    func evaluate(_ data: Data, at url: URL) throws -> SettingsLuauInput {
        try Task.checkCancellation()
        return SettingsLuauDocument.read(data, at: url)
    }
}
