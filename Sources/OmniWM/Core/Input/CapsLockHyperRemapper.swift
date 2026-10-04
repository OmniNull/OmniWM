// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
import IOKit.hidsystem

struct HIDKeyboardModifierMapping: Equatable {
    let source: UInt64
    let destination: UInt64
}

enum CapsLockHyperMapping {
    static let capsLockSource: UInt64 = 0x700000039
    static let f18Destination: UInt64 = 0x70000006D
    static let f18KeyCode = UInt32(kVK_F18)
    static let userKeyMappingKey = "UserKeyMapping"
    private static let sourceKey = "HIDKeyboardModifierMappingSrc"
    private static let destinationKey = "HIDKeyboardModifierMappingDst"

    static let omniMapping = HIDKeyboardModifierMapping(
        source: capsLockSource,
        destination: f18Destination
    )

    static func applying(to mappings: [HIDKeyboardModifierMapping]) -> [HIDKeyboardModifierMapping] {
        mappings.filter { $0.source != capsLockSource } + [omniMapping]
    }

    static func restoring(
        current: [HIDKeyboardModifierMapping],
        original: [HIDKeyboardModifierMapping]
    ) -> [HIDKeyboardModifierMapping] {
        var restored = current.filter { $0 != omniMapping }
        if !restored.contains(where: { $0.source == capsLockSource }) {
            restored.append(contentsOf: original.filter { $0.source == capsLockSource && $0 != omniMapping })
        }
        return restored
    }

    static func mappings(fromPropertyValue value: Any?) -> [HIDKeyboardModifierMapping]? {
        guard let value else { return [] }
        guard let entries = value as? [[String: Any]] else { return nil }
        var mappings: [HIDKeyboardModifierMapping] = []
        mappings.reserveCapacity(entries.count)
        for entry in entries {
            guard let source = entry[sourceKey] as? UInt64,
                  let destination = entry[destinationKey] as? UInt64
            else { return nil }
            mappings.append(HIDKeyboardModifierMapping(source: source, destination: destination))
        }
        return mappings
    }

    static func propertyValue(for mappings: [HIDKeyboardModifierMapping]) -> CFArray {
        mappings.map { [sourceKey: $0.source, destinationKey: $0.destination] } as CFArray
    }
}

final class CapsLockHyperRemapper {
    private let readUserKeyMapping: () -> Any?
    private let writeUserKeyMapping: (CFArray) -> Bool
    private var originalMappings: [HIDKeyboardModifierMapping]?

    init(
        readUserKeyMapping: @escaping () -> Any? = {
            IOHIDEventSystemClientCopyProperty(
                IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault),
                CapsLockHyperMapping.userKeyMappingKey as CFString
            )
        },
        writeUserKeyMapping: @escaping (CFArray) -> Bool = {
            IOHIDEventSystemClientSetProperty(
                IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault),
                CapsLockHyperMapping.userKeyMappingKey as CFString,
                $0
            )
        }
    ) {
        self.readUserKeyMapping = readUserKeyMapping
        self.writeUserKeyMapping = writeUserKeyMapping
    }

    func apply() -> Bool {
        if originalMappings != nil { return true }
        guard let currentMappings = readMappings(),
              writeMappings(CapsLockHyperMapping.applying(to: currentMappings))
        else { return false }
        originalMappings = currentMappings
        return true
    }

    func restore() {
        guard let originalMappings,
              let currentMappings = readMappings(),
              writeMappings(CapsLockHyperMapping.restoring(current: currentMappings, original: originalMappings))
        else { return }
        self.originalMappings = nil
    }

    private func readMappings() -> [HIDKeyboardModifierMapping]? {
        CapsLockHyperMapping.mappings(fromPropertyValue: readUserKeyMapping())
    }

    private func writeMappings(_ mappings: [HIDKeyboardModifierMapping]) -> Bool {
        writeUserKeyMapping(CapsLockHyperMapping.propertyValue(for: mappings))
    }
}
