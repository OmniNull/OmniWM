// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost

struct ConfigScriptWindowDestination: Equatable, Sendable {
    let target: WindowDisplayTarget
    let column: Int?
    let fromEdge: Bool

    private enum Field: String {
        case display
        case neighbor
        case of
        case fromEdge
        case column
    }

    init(fields: UnsafeBufferPointer<omni_config_field>) throws(ConfigScriptError) {
        var display: Monitor.ID?
        var neighbor: Direction?
        var source: Monitor.ID?
        var fromEdge: Bool?
        var column: Int?
        for field in fields {
            let name = String(decoding: Self.bytes(field.name), as: UTF8.self)
            switch Field(rawValue: name) {
            case .display: display = try Self.display(field, name)
            case .of: source = try Self.display(field, name)
            case .neighbor:
                guard let direction = Direction(rawValue: try Self.text(field, name)) else {
                    throw Self.failure("neighbor must be \"left\", \"right\", \"up\" or \"down\".")
                }
                neighbor = direction
            case .fromEdge:
                guard field.kind == OMNI_CONFIG_BOOLEAN else { throw Self.wrongType(name) }
                fromEdge = field.bool_value
            case .column:
                guard field.kind == OMNI_CONFIG_NUMBER else { throw Self.wrongType(name) }
                guard let value = Int(exactly: field.number_value), value >= 1 else {
                    throw Self.failure("column must be a whole number of at least 1.")
                }
                column = value
            case nil:
                throw Self.failure("Unknown window destination field '\(name)'.")
            }
        }
        switch (display, neighbor) {
        case let (display?, nil):
            guard source == nil, fromEdge == nil else { throw Self.failure("of and fromEdge need neighbor.") }
            target = .display(display)
        case let (nil, neighbor?):
            guard fromEdge != true || source != nil else { throw Self.failure("fromEdge needs of.") }
            target = .neighbor(neighbor, of: source)
        default:
            throw Self.failure("A window destination needs either display or neighbor.")
        }
        self.column = column
        self.fromEdge = fromEdge == true
    }

    private static func bytes(_ span: omni_config_span) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: span.data, count: span.length)
    }

    private static func text(_ field: omni_config_field, _ name: String) throws(ConfigScriptError) -> String {
        guard field.kind == OMNI_CONFIG_STRING else { throw wrongType(name) }
        return String(decoding: bytes(field.string_value), as: UTF8.self)
    }

    private static func display(_ field: omni_config_field, _ name: String) throws(ConfigScriptError) -> Monitor.ID {
        let text = try text(field, name)
        guard let id = UInt32(text), String(id) == text else {
            throw failure("\(name) must be a display ID from monitors, such as \"69734208\".")
        }
        return Monitor.ID(displayId: id)
    }

    private static func wrongType(_ name: String) -> ConfigScriptError {
        failure("Window destination field '\(name)' has the wrong type.")
    }

    private static func failure(_ message: String) -> ConfigScriptError {
        ConfigScriptError(line: nil, message: message)
    }
}
