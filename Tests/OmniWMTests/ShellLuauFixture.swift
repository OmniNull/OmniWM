// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

enum ShellLuauFixture {
    static func table(at url: URL) throws -> [String: SettingsLuauValue] {
        try table(ShellLuauDocument.load(at: url).value)
    }

    static func table(_ text: String) throws -> [String: SettingsLuauValue] {
        try table(ShellLuauDocument(Data(text.utf8)).value)
    }

    private static func table(_ value: SettingsLuauValue) throws -> [String: SettingsLuauValue] {
        guard case let .record(fields) = value else { throw SettingsLuauError(message: "Expected a shell table.") }
        return fields
    }

    static func editing(_ changes: [([String], SettingsLuauValue?)], in source: String) throws -> String {
        let edit = try ShellLuauDocument(Data(source.utf8)).editing(changes)
        XCTAssertNil(edit.question)
        return String(decoding: edit.source, as: UTF8.self)
    }
}
