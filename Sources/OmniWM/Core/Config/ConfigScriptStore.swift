// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost
import Synchronization

enum ConfigScriptStoreValue: Equatable, Sendable, Codable {
    case boolean(Bool)
    case number(Double)
    case string(String)
    case list([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = try .list(container.decode([String].self))
        }
    }

    init(_ value: omni_config_store_value) throws(ConfigScriptError) {
        let items = UnsafeBufferPointer(start: value.items, count: value.items == nil ? 0 : value.count)
        switch value.kind {
        case OMNI_CONFIG_STORE_BOOLEAN:
            self = .boolean(value.boolean)
        case OMNI_CONFIG_STORE_NUMBER:
            self = .number(value.number)
        case OMNI_CONFIG_STORE_STRING where items.count == 1:
            self = try .string(Self.text(items[0]))
        case OMNI_CONFIG_STORE_LIST where items.count == value.count && items.count <= ConfigScriptStore.listLimit:
            var list: [String] = []
            list.reserveCapacity(items.count)
            for item in items {
                try list.append(Self.text(item))
            }
            self = .list(list)
        default:
            throw ConfigScriptError(line: nil, message: "Unsupported store value.")
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.boolean(left), .boolean(right)): left == right
        case let (.number(left), .number(right)): left.bitPattern == right.bitPattern
        case let (.string(left), .string(right)): sameBytes(left, right)
        case let (.list(left), .list(right)): sameBytes(left, right)
        default: false
        }
    }

    private static func sameBytes(_ left: [String], _ right: [String]) -> Bool {
        left.withUnsafeBufferPointer { lhs in
            right.withUnsafeBufferPointer { rhs in
                guard lhs.count == rhs.count else { return false }
                guard lhs.baseAddress != rhs.baseAddress else { return true }
                for index in lhs.indices where !sameBytes(lhs[index], rhs[index]) {
                    return false
                }
                return true
            }
        }
    }

    private static func sameBytes(_ left: String, _ right: String) -> Bool {
        let compared = left.utf8.withContiguousStorageIfAvailable { lhs in
            right.utf8.withContiguousStorageIfAvailable { rhs in
                lhs.count == rhs.count && (lhs.isEmpty || lhs.baseAddress == rhs.baseAddress
                    || memcmp(lhs.baseAddress!, rhs.baseAddress!, lhs.count) == 0)
            }
        }
        return (compared ?? nil) ?? left.utf8.elementsEqual(right.utf8)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .boolean(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .list(value): try container.encode(value)
        }
    }

    static func textBytes(of raw: omni_config_store_value) -> Int {
        guard raw.kind == OMNI_CONFIG_STORE_STRING || raw.kind == OMNI_CONFIG_STORE_LIST, let items = raw.items else {
            return 0
        }
        return UnsafeBufferPointer(start: items, count: raw.count).reduce(0) { $0 + $1.length }
    }

    var textBytes: Int {
        switch self {
        case .boolean,
             .number: 0
        case let .string(value): value.utf8.count
        case let .list(value): value.reduce(0) { $0 + $1.utf8.count }
        }
    }

    var isWithinLimits: Bool {
        switch self {
        case .boolean: true
        case let .number(value): value.isFinite
        case let .string(value): value.utf8.count <= ConfigScriptStore.stringLimit
        case let .list(value):
            value.count <= ConfigScriptStore.listLimit
                && value.allSatisfy { $0.utf8.count <= ConfigScriptStore.stringLimit }
        }
    }

    func write(to read: inout omni_config_store_read) -> Bool {
        var offset = 0
        switch self {
        case let .boolean(value):
            read.value.kind = OMNI_CONFIG_STORE_BOOLEAN
            read.value.boolean = value
        case let .number(value):
            read.value.kind = OMNI_CONFIG_STORE_NUMBER
            read.value.number = value
        case let .string(value):
            guard Self.copy(value, into: &read, at: 0, offset: &offset) else { return false }
            read.value.kind = OMNI_CONFIG_STORE_STRING
            read.value.count = 1
        case let .list(values):
            guard values.count <= ConfigScriptStore.listLimit else { return false }
            for index in values.indices {
                guard Self.copy(values[index], into: &read, at: index, offset: &offset) else { return false }
            }
            read.value.kind = OMNI_CONFIG_STORE_LIST
            read.value.count = values.count
        }
        read.value.items = UnsafePointer(read.items)
        return true
    }

    private static func copy(
        _ text: String, into read: inout omni_config_store_read, at index: Int, offset: inout Int
    ) -> Bool {
        let count = text.utf8.count
        guard let bytes = read.bytes, let items = read.items, count <= read.capacity - offset else { return false }
        let start = bytes + offset
        UnsafeMutableRawBufferPointer(start: start, count: count).copyBytes(from: text.utf8)
        items[index] = omni_config_span(data: start, length: count)
        offset += count
        return true
    }

    private static func text(_ span: omni_config_span) throws(ConfigScriptError) -> String {
        let bytes = UnsafeRawBufferPointer(start: span.data, count: span.length)
        guard let text = String(validating: bytes, as: UTF8.self) else {
            throw ConfigScriptError(line: nil, message: "Store text must be valid UTF-8.")
        }
        return text
    }
}

enum ConfigScriptStoreError: Error, Equatable {
    case corrupt
    case tooLarge
    case unreadable(String)
    case unwritable(String)

    var message: String {
        switch self {
        case .corrupt: "The saved store isn't valid; omniwm.store.clear() starts it over."
        case .tooLarge: "The store would exceed \(ConfigScriptStore.byteLimit / 1024) KiB once saved."
        case let .unreadable(reason): "The saved store can't be read: \(reason)"
        case let .unwritable(reason): "The store can't be saved: \(reason)"
        }
    }
}

final class ConfigScriptStore: Sendable {
    struct Snapshot: Equatable, Sendable {
        var values: [String: ConfigScriptStoreValue] = [:]
        var bytes = 0
    }

    static let keyLimit = 128
    static let keyLength = 64
    static let stringLimit = Int(OMNI_CONFIG_STORE_STRING_LIMIT)
    static let listLimit = Int(OMNI_CONFIG_STORE_LIST_LIMIT)
    static let byteLimit = Int(OMNI_CONFIG_STORE_BYTE_LIMIT)

    let fileURL: URL
    private let state = Mutex<Result<Snapshot, ConfigScriptStoreError>?>(nil)

    init(fileURL: URL = OmniWMStoragePaths.live.stateDirectory.appendingPathComponent("script-store.json")) {
        self.fileURL = fileURL
    }

    func committed() -> Result<Snapshot, ConfigScriptStoreError> {
        state.withLock { state in
            if let state, case .success = state { return state }
            let loaded = Self.read(fileURL)
            if case .success = loaded { state = loaded }
            return loaded
        }
    }

    func commit(_ snapshot: Snapshot) throws(ConfigScriptStoreError) {
        if case let .success(current) = committed(), current == snapshot { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(snapshot.values)
        } catch {
            throw .unwritable(error.localizedDescription)
        }
        guard data.count <= Self.byteLimit else { throw .tooLarge }
        do {
            try SettingsFileAccess.replacePrivately(data, at: fileURL)
        } catch {
            throw .unwritable(error.localizedDescription)
        }
        state.withLock { $0 = .success(snapshot) }
    }

    static func key(_ span: omni_config_span) throws(ConfigScriptError) -> String {
        let bytes = UnsafeRawBufferPointer(start: span.data, count: span.length)
        guard isValidKey(bytes) else {
            throw ConfigScriptError(
                line: nil,
                message: "Store keys need 1 to \(keyLength) letters, digits, '.', '_' or '-'."
            )
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func isValidKey(_ bytes: some Collection<UInt8>) -> Bool {
        (1 ... keyLength).contains(bytes.count) && bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "A") ... UInt8(ascii: "Z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "."),
                 UInt8(ascii: "_"),
                 UInt8(ascii: "-"): true
            default: false
            }
        }
    }

    private static func read(_ url: URL) -> Result<Snapshot, ConfigScriptStoreError> {
        let data: Data
        do {
            data = try SettingsFileAccess.readContents(at: url, maximumBytes: byteLimit).data
        } catch let error as POSIXError where error.code == .ENOENT {
            return .success(Snapshot())
        } catch let error as POSIXError where error.code == .EFBIG {
            return .failure(.corrupt)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        guard let values = try? JSONDecoder().decode([String: ConfigScriptStoreValue].self, from: data),
              values.count <= keyLimit
        else { return .failure(.corrupt) }
        var bytes = 0
        for (key, value) in values {
            guard isValidKey(key.utf8), value.isWithinLimits else { return .failure(.corrupt) }
            bytes += key.utf8.count + value.textBytes
        }
        guard bytes <= byteLimit else { return .failure(.corrupt) }
        return .success(Snapshot(values: values, bytes: bytes))
    }
}

struct ConfigScriptStoreStage {
    var snapshot: ConfigScriptStore.Snapshot
    private(set) var location: omni_config_location?

    init(snapshot: ConfigScriptStore.Snapshot, replacingAt location: omni_config_location? = nil) {
        self.snapshot = snapshot
        self.location = location
    }

    mutating func set(
        _ key: String, to raw: omni_config_store_value, at site: omni_config_location
    ) throws(ConfigScriptError) {
        let previous = snapshot.values[key]
        guard previous != nil || snapshot.values.count < ConfigScriptStore.keyLimit else {
            throw ConfigScriptError(line: nil, message: "The store holds at most \(ConfigScriptStore.keyLimit) keys.")
        }
        let bytes = snapshot.bytes - (previous.map { key.utf8.count + $0.textBytes } ?? 0)
            + key.utf8.count + ConfigScriptStoreValue.textBytes(of: raw)
        guard bytes <= ConfigScriptStore.byteLimit else {
            throw ConfigScriptError(
                line: nil,
                message: "The store holds at most \(ConfigScriptStore.byteLimit / 1024) KiB of keys and text."
            )
        }
        let value = try ConfigScriptStoreValue(raw)
        guard previous != value else { return }
        snapshot.values[key] = value
        snapshot.bytes = bytes
        location = location ?? site
    }

    mutating func clear(_ key: String, at site: omni_config_location) {
        guard let previous = snapshot.values.removeValue(forKey: key) else { return }
        snapshot.bytes -= key.utf8.count + previous.textBytes
        location = location ?? site
    }

    mutating func clearAll(at site: omni_config_location) {
        guard !snapshot.values.isEmpty else { return }
        snapshot = ConfigScriptStore.Snapshot()
        location = location ?? site
    }
}
