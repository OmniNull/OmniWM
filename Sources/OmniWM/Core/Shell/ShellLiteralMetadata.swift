// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMMetadata

enum ShellLiteralMetadata {
    static func read(_ data: Data, filename: String) throws -> SettingsLuauValue {
        do {
            return try SettingsLuauValue.decodeJSON(
                LuauLiteralMetadata.json(data, filename: filename),
                shellNumbers: false
            )
        } catch {
            throw ShellScriptFailure(kind: .compile, message: error.localizedDescription)
        }
    }

    static func fields(_ data: Data, filename: String) throws -> [String: SettingsLuauValue] {
        guard case let .record(fields) = try read(data, filename: filename) else {
            throw ShellScriptFailure(
                kind: .compile,
                message: "\(filename):1: metadata must return a table with named fields"
            )
        }
        return fields
    }
}
