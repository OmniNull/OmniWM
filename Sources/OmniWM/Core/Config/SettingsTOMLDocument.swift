// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

struct SettingsTOMLDocument {
    let source: Data
    let values: SettingsLuauValue
    let export: SettingsExport

    init(source: Data, values: SettingsLuauValue) throws {
        self.source = source
        self.values = values
        do {
            export = try SettingsFileModel.decode(values)
        } catch {
            throw SettingsLuauError(message: SettingsLuauError.diagnosticDescription(for: error, root: "settings.toml"))
        }
    }

    static func read(_ source: Data) throws -> SettingsLuauValue {
        var fields: [String: SettingsLuauValue]
        do {
            fields = try TOMLDecoder().decode([String: SettingsLuauValue].self, from: source)
        } catch let error as TOMLDecodingError {
            throw SettingsLuauError(message: "settings.toml: \(error.description)")
        }
        if let version = fields.removeValue(forKey: "schemaVersion") {
            guard case .integer(5) = version else {
                throw SettingsLuauError(message: "settings.toml: expected legacy schemaVersion 5.")
            }
            if case var .record(theming)? = fields["appTheming"] {
                theming.removeValue(forKey: "herdr")
                fields["appTheming"] = .record(theming)
            }
        }
        return .record(fields)
    }

    static func initialSource(_ export: SettingsExport) throws -> Data {
        let active = HyperKeyModifiers(carbonMask: KeySymbolMapper.hyperModifiers) ?? .default
        KeySymbolMapper.setHyperKeyModifiers(export.hyperKeyModifiers)
        defer { KeySymbolMapper.setHyperKeyModifiers(active) }
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let source = try encoder.encode(SettingsFileModel(export: export))
        guard source.count <= ConfigScriptLoader.sourceLimit else {
            throw SettingsLuauError(message: "settings.toml exceeds the settings file size limit.")
        }
        return source
    }

    func backUpBeforeFirstEdit(at file: URL) throws -> Bool {
        let backup = file.appendingPathExtension("before-omniwm-edit")
        let manager = FileManager.default
        if manager.fileExists(atPath: backup.path) {
            let attributes = try manager.attributesOfItem(atPath: backup.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: backup.path])
            }
            return false
        }
        try SettingsFileAccess.createAtomically(source, at: backup)
        return true
    }
}
