// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

enum SettingsLuauFixture {
    static func fields(_ export: SettingsExport = .defaults()) throws -> [String: SettingsLuauValue] {
        try record(SettingsLuauValue.fields(of: export))
    }

    static func fields(in data: Data) throws -> [String: SettingsLuauValue] {
        try record(LuauTableDocument(SettingsLuauDocument.read(data, at: nil)).sourceValue)
    }

    private static func record(_ value: SettingsLuauValue) throws -> [String: SettingsLuauValue] {
        guard case let .record(fields) = value else { throw SettingsLuauError(message: "Expected a settings record") }
        return fields
    }

    static func source(_ fields: [String: SettingsLuauValue]) -> Data {
        Data(("return " + SettingsLuauValue.record(fields).literal()).utf8)
    }

    static func editing(_ source: Data, to desired: SettingsExport) throws -> Data {
        let document = try SettingsLuauDocument(source)
        let patch = try document.edit(from: document.export, to: desired)
        XCTAssertNil(patch.question)
        return patch.source
    }

    static func assertRequiredFields(
        _ keys: [String],
        in section: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let components = section.split(separator: ".").map(String.init)
        let defaults = try SettingsLuauValue.fields(of: .defaults())
        let original = HyperKeyModifiers(carbonMask: KeySymbolMapper.hyperModifiers) ?? .default
        defer { KeySymbolMapper.setHyperKeyModifiers(original) }
        for key in keys {
            var values = defaults
            values.set(nil, at: (components + [key])[...])
            XCTAssertThrowsError(
                try SettingsFileModel(from: SettingsLuauDecoder(value: values)),
                key,
                file: file,
                line: line
            ) { error in
                guard case let DecodingError.keyNotFound(missing, context) = error else {
                    return XCTFail(String(describing: error), file: file, line: line)
                }
                XCTAssertEqual(missing.stringValue, key, file: file, line: line)
                XCTAssertEqual(context.codingPath.map(\.stringValue), components, file: file, line: line)
            }
            XCTAssertEqual(
                try SettingsLuauDocument.decode(values, fields: [:]),
                .defaults(),
                key,
                file: file,
                line: line
            )
        }
    }

    static func number(_ value: Double) -> SettingsLuauValue {
        Int64(exactly: value).map(SettingsLuauValue.integer) ?? .number(value)
    }

    static func decode(_ data: Data) throws -> SettingsExport {
        try SettingsLuauDocument(data).export
    }
}
