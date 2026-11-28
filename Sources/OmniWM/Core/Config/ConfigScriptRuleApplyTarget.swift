// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import OmniWMScriptHost

enum ConfigScriptRuleApplyTarget: Equatable, Sendable {
    case focused
    case window(WindowToken, session: ConfigScriptSession)
    case pid(pid_t)

    init(_ field: UnsafePointer<omni_config_field>?) throws(ConfigScriptError) {
        guard let field else {
            self = .focused
            return
        }
        let name = String(decoding: Self.bytes(field.pointee.name), as: UTF8.self)
        switch name {
        case "windowId":
            let id = field.pointee.string_value
            guard field.pointee.kind == OMNI_CONFIG_STRING,
                  let decoded = ConfigScriptWindowID.decode(Self.bytes(id)),
                  decoded.token.pid > 0,
                  let windowId = UInt32(exactly: decoded.token.windowId), windowId > 0
            else {
                throw ConfigScriptError(line: nil, message: "Expected a Flex window ID.")
            }
            self = .window(decoded.token, session: decoded.session)
        case "pid":
            guard field.pointee.kind == OMNI_CONFIG_NUMBER,
                  let pid = pid_t(exactly: field.pointee.number_value), pid > 0
            else {
                throw ConfigScriptError(line: nil, message: "Expected a positive integer PID.")
            }
            self = .pid(pid)
        default:
            throw ConfigScriptError(line: nil, message: "A rule target takes exactly one field: windowId or pid.")
        }
    }

    private static func bytes(_ span: omni_config_span) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: span.data, count: span.length)
    }
}

extension ConfigScriptStage {
    static let ruleApplyCallback: omni_config_rule_apply_callback = { context, field, location, error, capacity in
        dispatch(into: context, at: location, error: error, capacity: capacity) {
            () throws(ConfigScriptError) in try .ruleApply(ConfigScriptRuleApplyTarget(field))
        }
    }
}
