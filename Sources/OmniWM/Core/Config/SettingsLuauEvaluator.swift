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
    let result: Result<LuauTableDocument.Evaluation, any Error>
}

extension SettingsLuauError {
    static let changedHelper =
        Self(message: "A settings helper was edited externally. Read the latest file before saving.")
}

actor SettingsFileEvaluator {
    static let shared = SettingsFileEvaluator()
    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.settings", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func read(_ url: URL, fingerprint: SettingsFileAccess.Fingerprint) -> Result<SettingsFileInput, any Error> {
        Result {
            let target = try SettingsFileAccess.settingsTarget(for: url)
            let contents = try SettingsFileAccess.readContents(at: target, maximumBytes: ConfigScriptLoader.sourceLimit)
            guard contents.fingerprint == fingerprint else { throw POSIXError(.ESTALE) }
            return try evaluate(contents.data, at: url)
        }
    }

    func evaluate(_ data: Data, at url: URL) throws -> SettingsFileInput {
        try Task.checkCancellation()
        return try SettingsFileInput.read(data, at: url)
    }
}
