// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct WindowMark: Equatable, Sendable {
    let name: String
    let token: WindowToken
}

@MainActor
final class WindowMarkRegistry {
    enum SetResult: Equatable {
        case inserted
        case unchanged
        case duplicate
        case invalidName
    }

    enum LookupResult: Equatable {
        case found(WindowToken)
        case unknown
        case invalidName
    }

    enum RemoveResult: Equatable {
        case removed
        case unknown
        case invalidName
    }

    enum RekeyResult: Equatable {
        case rekeyed
        case unchanged
        case noMarks
        case conflict
    }

    private struct NameKey: Hashable {
        let name: String

        init(_ name: String) {
            self.name = name
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name.utf8.elementsEqual(rhs.name.utf8)
        }

        func hash(into hasher: inout Hasher) {
            if name.utf8.withContiguousStorageIfAvailable({
                hasher.combine(bytes: UnsafeRawBufferPointer($0))
            }) == nil {
                var text = name
                text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
            }
        }
    }

    private var tokenByName: [NameKey: WindowToken] = [:]
    private var namesByToken: [WindowToken: Set<NameKey>] = [:]
    private var orderedMarks: [WindowMark] = []
    private var needsOrdering = false

    var marks: [WindowMark] {
        _read {
            if needsOrdering { orderMarks() }
            yield orderedMarks
        }
    }

    private func orderMarks() {
        orderedMarks.removeAll(keepingCapacity: true)
        orderedMarks.reserveCapacity(tokenByName.count)
        for (key, token) in tokenByName {
            orderedMarks.append(WindowMark(name: key.name, token: token))
        }
        orderedMarks.sort { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        needsOrdering = false
    }

    func isValidName(_ rawName: String) -> Bool {
        Self.normalizedName(rawName) != nil
    }

    func set(_ rawName: String, for token: WindowToken) -> SetResult {
        guard let name = Self.normalizedName(rawName) else { return .invalidName }
        let key = NameKey(name)
        if let existingToken = tokenByName[key] {
            return existingToken == token ? .unchanged : .duplicate
        }

        tokenByName[key] = token
        namesByToken[token, default: []].insert(key)
        needsOrdering = true
        return .inserted
    }

    func lookup(_ rawName: String) -> LookupResult {
        guard let name = Self.normalizedName(rawName) else { return .invalidName }
        guard let token = tokenByName[NameKey(name)] else { return .unknown }
        return .found(token)
    }

    func remove(_ rawName: String) -> RemoveResult {
        guard let name = Self.normalizedName(rawName) else { return .invalidName }
        let key = NameKey(name)
        guard let token = tokenByName.removeValue(forKey: key) else { return .unknown }
        remove(key, from: token)
        needsOrdering = true
        return .removed
    }

    func names(for token: WindowToken) -> [String] {
        (namesByToken[token] ?? [])
            .map(\.name)
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    func rekey(from oldToken: WindowToken, to newToken: WindowToken) -> RekeyResult {
        guard oldToken != newToken else { return .unchanged }
        guard let names = namesByToken[oldToken], !names.isEmpty else { return .noMarks }
        guard names.allSatisfy({ tokenByName[$0] == oldToken }) else { return .conflict }

        namesByToken.removeValue(forKey: oldToken)
        for name in names {
            tokenByName[name] = newToken
        }
        namesByToken[newToken, default: []].formUnion(names)
        needsOrdering = true
        return .rekeyed
    }

    func retire(_ token: WindowToken) {
        guard let names = namesByToken.removeValue(forKey: token) else { return }
        for name in names {
            tokenByName.removeValue(forKey: name)
        }
        needsOrdering = true
    }

    private func remove(_ name: NameKey, from token: WindowToken) {
        namesByToken[token]?.remove(name)
        if namesByToken[token]?.isEmpty == true {
            namesByToken.removeValue(forKey: token)
        }
    }

    private static func normalizedName(_ rawName: String) -> String? {
        let scalars = rawName.unicodeScalars
        guard let first = scalars.first, let last = scalars.last else { return nil }
        let spaces = CharacterSet.whitespacesAndNewlines
        let name = spaces.contains(first) || spaces.contains(last)
            ? rawName.trimmingCharacters(in: spaces) : rawName
        guard !name.isEmpty,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return nil
        }
        return name
    }
}
