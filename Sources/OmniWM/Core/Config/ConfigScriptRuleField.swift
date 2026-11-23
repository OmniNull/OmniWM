// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC
import OmniWMScriptHost

enum ConfigScriptRuleField: String, CaseIterable {
    case id
    case bundleId
    case appNameSubstring
    case titleSubstring
    case titleRegex
    case axRole
    case axSubrole
    case layout
    case assignToWorkspace
    case assignToWorkspaceForAllWindows
    case initialContainerPrimarySpan
    case minWidth
    case minHeight
    case scratchpad

    enum Kind {
        case string
        case uuid
        case layout
        case boolean
        case number
        case integer
    }

    var kind: Kind {
        switch self {
        case .id: .uuid
        case .layout: .layout
        case .assignToWorkspaceForAllWindows: .boolean
        case .initialContainerPrimarySpan,
             .minWidth,
             .minHeight: .number
        case .scratchpad: .integer
        case .bundleId,
             .appNameSubstring,
             .titleSubstring,
             .titleRegex,
             .axRole,
             .axSubrole,
             .assignToWorkspace: .string
        }
    }

    static func decode(
        _ fields: UnsafeBufferPointer<omni_config_field>,
        ordinal: UInt32
    ) throws(ConfigScriptError) -> AppRule {
        var values: [Self: omni_config_field] = [:]
        values.reserveCapacity(fields.count)
        for field in fields {
            let name = try string(field.name)
            guard let key = Self(rawValue: name) else { throw invalid("Unknown rule field '\(name)'.") }
            guard key.accepts(field) else { throw invalid("Invalid value type for rule field '\(name)'.") }
            values[key] = field
        }
        func text(_ key: Self) throws(ConfigScriptError) -> String? {
            guard let field = values[key] else { return nil }
            return try string(field.string_value)
        }
        let ruleID = try identifier(try text(.id), ordinal: ordinal)
        let layoutName = try text(.layout) ?? IPCRuleLayout.auto.rawValue
        guard let layout = IPCRuleLayout(rawValue: layoutName)
        else { throw invalid("Invalid rule layout '\(layoutName)'.") }
        let definition = try IPCRuleDefinition(
            bundleId: text(.bundleId) ?? "",
            appNameSubstring: text(.appNameSubstring),
            titleSubstring: text(.titleSubstring),
            titleRegex: text(.titleRegex),
            axRole: text(.axRole),
            axSubrole: text(.axSubrole),
            layout: layout,
            assignToWorkspace: text(.assignToWorkspace),
            assignToWorkspaceForAllWindows: values[.assignToWorkspaceForAllWindows]?.bool_value,
            initialContainerPrimarySpan: values[.initialContainerPrimarySpan]?.number_value,
            minWidth: values[.minWidth]?.number_value,
            minHeight: values[.minHeight]?.number_value,
            scratchpad: values[.scratchpad].flatMap { Int(exactly: $0.number_value) }
        )
        let errors = IPCRuleValidator.validate(definition).messages
        guard errors.isEmpty else { throw invalid(errors.joined(separator: ". ")) }
        return IPCRuleProjection.appRule(from: definition, id: ruleID)
    }

    private func accepts(_ field: omni_config_field) -> Bool {
        switch kind {
        case .string,
             .uuid,
             .layout: field.kind == OMNI_CONFIG_STRING
        case .boolean: field.kind == OMNI_CONFIG_BOOLEAN
        case .number: field.kind == OMNI_CONFIG_NUMBER
        case .integer: field.kind == OMNI_CONFIG_NUMBER && Int(exactly: field.number_value) != nil
        }
    }

    private static func identifier(_ value: String?, ordinal: UInt32) throws(ConfigScriptError) -> UUID {
        if let value {
            guard let id = UUID(uuidString: value) else { throw invalid("Invalid rule UUID '\(value)'.") }
            return id
        }
        return UUID(uuid: (
            0xC6, 0x63, 0xEB, 0x29, 0xE9, 0x2E, 0x83, 0x08, 0x8F, 0x3B, 0xEF, 0x50,
            UInt8(truncatingIfNeeded: ordinal >> 24), UInt8(truncatingIfNeeded: ordinal >> 16),
            UInt8(truncatingIfNeeded: ordinal >> 8), UInt8(truncatingIfNeeded: ordinal)
        ))
    }

    private static func string(_ span: omni_config_span) throws(ConfigScriptError) -> String {
        let bytes = UnsafeRawBufferPointer(start: span.data, count: span.length)
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw invalid("Rule names and string values must be valid UTF-8.")
        }
        return value
    }

    private static func invalid(_ message: String) -> ConfigScriptError {
        ConfigScriptError(line: nil, message: message)
    }
}
