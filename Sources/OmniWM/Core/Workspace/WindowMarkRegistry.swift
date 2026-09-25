// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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
        let utf8: [UInt8]

        init(_ name: String) {
            utf8 = Array(name.utf8)
        }
    }

    private var tokenByName: [NameKey: WindowToken] = [:]
    private var nameByKey: [NameKey: String] = [:]
    private var namesByToken: [WindowToken: Set<NameKey>] = [:]

    var marks: [WindowMark] {
        nameByKey
            .compactMap { key, name in
                tokenByName[key].map { WindowMark(name: name, token: $0) }
            }
            .sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
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
        nameByKey[key] = name
        namesByToken[token, default: []].insert(key)
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
        nameByKey.removeValue(forKey: key)
        remove(key, from: token)
        return .removed
    }

    func names(for token: WindowToken) -> [String] {
        (namesByToken[token] ?? [])
            .compactMap { nameByKey[$0] }
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
        return .rekeyed
    }

    func retire(_ token: WindowToken) {
        guard let names = namesByToken.removeValue(forKey: token) else { return }
        for name in names {
            tokenByName.removeValue(forKey: name)
            nameByKey.removeValue(forKey: name)
        }
    }

    private func remove(_ name: NameKey, from token: WindowToken) {
        namesByToken[token]?.remove(name)
        if namesByToken[token]?.isEmpty == true {
            namesByToken.removeValue(forKey: token)
        }
    }

    private static func normalizedName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return nil
        }
        return name
    }
}
