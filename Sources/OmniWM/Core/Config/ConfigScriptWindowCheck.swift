// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

struct ConfigScriptWorkspaceID: Equatable, Sendable {
    private let bits: UInt128

    init(_ id: WorkspaceDescriptor.ID) {
        bits = withUnsafeBytes(of: id.uuid) { $0.loadUnaligned(as: UInt128.self) }
    }

    init?(text: UnsafeRawBufferPointer) {
        let capacity = MemoryLayout<uuid_string_t>.size
        guard text.count == capacity - 1 else { return nil }
        var bits: UInt128 = 0
        let status = withUnsafeTemporaryAllocation(of: CChar.self, capacity: capacity) { buffer in
            UnsafeMutableRawBufferPointer(buffer).copyMemory(from: text)
            buffer.initializeElement(at: text.count, to: 0)
            return withUnsafeMutableBytes(of: &bits) { storage in
                storage.withMemoryRebound(to: UInt8.self) { uuid_parse(buffer.baseAddress, $0.baseAddress) }
            }
        }
        guard status == 0 else { return nil }
        self.bits = bits
    }

    var id: WorkspaceDescriptor.ID {
        UUID(uuid: withUnsafeBytes(of: bits) { $0.loadUnaligned(as: uuid_t.self) })
    }
}

enum ConfigScriptWindowCheck: Equatable, Sendable {
    case fromEdge
    case focus(targetOf: ConfigScriptWorkspaceID?, nativeFullscreen: Bool)

    static func focus(fields: UnsafeBufferPointer<omni_config_field>) throws(ConfigScriptError) -> Self {
        var targetOf: ConfigScriptWorkspaceID?
        var nativeFullscreen = false
        for field in fields {
            if field.named("targetOf") {
                guard field.kind == OMNI_CONFIG_STRING else { throw wrongType(field) }
                let text = UnsafeRawBufferPointer(start: field.string_value.data, count: field.string_value.length)
                guard let id = ConfigScriptWorkspaceID(text: text) else {
                    throw failure("targetOf must be a workspace ID, such as a workspace row's or event's id.")
                }
                targetOf = id
            } else if field.named("nativeFullscreen") {
                guard field.kind == OMNI_CONFIG_BOOLEAN else { throw wrongType(field) }
                nativeFullscreen = field.bool_value
            } else {
                throw failure("Unknown focus field '\(field.nameText)'.")
            }
        }
        return .focus(targetOf: targetOf, nativeFullscreen: nativeFullscreen)
    }

    private static func wrongType(_ field: omni_config_field) -> ConfigScriptError {
        failure("Focus field '\(field.nameText)' has the wrong type.")
    }

    private static func failure(_ message: String) -> ConfigScriptError {
        ConfigScriptError(line: nil, message: message)
    }
}

extension omni_config_field {
    func named(_ expected: StaticString) -> Bool {
        let actual = UnsafeRawBufferPointer(start: name.data, count: name.length)
        return expected.withUTF8Buffer { actual.elementsEqual(UnsafeRawBufferPointer($0)) }
    }

    var nameText: String {
        String(decoding: UnsafeRawBufferPointer(start: name.data, count: name.length), as: UTF8.self)
    }
}
