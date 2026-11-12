// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum AppThemeOutputError: Error, Equatable, LocalizedError {
    case notAbsolute(String)
    case parentReference(String)
    case outsideAllowedFolders(String)
    case protectedFolder(String)
    case notRegularFile(String)

    var errorDescription: String? {
        switch self {
        case let .notAbsolute(path):
            String(localized: "\(path) must be a full path starting with / or ~/")
        case let .parentReference(path):
            String(localized: "\(path) must not contain .. or . folders")
        case let .outsideAllowedFolders(path):
            String(
                localized: "\(path) is outside ~/.config and ~/Library/Application Support, so OmniWM won’t write it"
            )
        case let .protectedFolder(path):
            String(localized: "\(path) is in a folder OmniWM never writes app themes to")
        case let .notRegularFile(path):
            String(localized: "\(path) is not a regular file, so OmniWM won’t replace it")
        }
    }
}

struct AppThemeOutputPolicy: Equatable, Sendable {
    let home: URL
    let allowedRoots: [URL]
    let protectedFolders: [URL]

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AppThemeOutputPolicy {
        let configHome = base("XDG_CONFIG_HOME", ".config", environment: environment, home: home)
        let stateHome = base("XDG_STATE_HOME", ".local/state", environment: environment, home: home)
        let roots = [
            configHome,
            home.appendingPathComponent(".config", isDirectory: true),
            home.appendingPathComponent("Library/Application Support", isDirectory: true)
        ]
        let omniwm = ["omniwm", "omniwm-dev"].flatMap { name in
            [configHome, stateHome, home.appendingPathComponent(".config", isDirectory: true)]
                .map { $0.appendingPathComponent(name, isDirectory: true) }
        }
        return AppThemeOutputPolicy(
            home: home,
            allowedRoots: roots.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
            protectedFolders: omniwm + [
                home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
                home.appendingPathComponent(".ssh", isDirectory: true)
            ]
        )
    }

    var configHome: URL {
        allowedRoots[0]
    }

    static func configHome(environment: [String: String], home: URL) -> URL {
        base("XDG_CONFIG_HOME", ".config", environment: environment, home: home)
    }

    private static func base(_ key: String, _ fallback: String, environment: [String: String], home: URL) -> URL {
        guard let value = environment[key], value.hasPrefix("/") else {
            return home.appendingPathComponent(fallback, isDirectory: true)
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    func expand(_ path: String) -> String {
        if path == "~" { return home.path }
        guard path.hasPrefix("~/") else { return path }
        return home.path + "/" + path.dropFirst(2)
    }

    func display(_ url: URL) -> String {
        for base in [home.path, Self.resolve(home).path] where url.path.hasPrefix(base + "/") {
            return "~/" + url.path.dropFirst(base.count + 1)
        }
        return url.path
    }

    struct Roots: Sendable {
        let allowed: [URL]
        let protected: [URL]
    }

    func resolvedRoots() -> Roots {
        Roots(allowed: ([home] + allowedRoots).map(Self.resolve), protected: protectedFolders.map(Self.resolve))
    }

    func destination(for path: String, roots known: Roots? = nil) throws -> URL {
        let expanded = expand(path)
        guard expanded.hasPrefix("/") else { throw AppThemeOutputError.notAbsolute(path) }
        let components = expanded.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == ".." || $0 == "." }), !components.isEmpty else {
            throw AppThemeOutputError.parentReference(path)
        }
        let lexical = URL(fileURLWithPath: "/" + components.joined(separator: "/"))
        guard allowedRoots.contains(where: { Self.contains($0, lexical) }) else {
            throw AppThemeOutputError.outsideAllowedFolders(path)
        }
        guard !protectedFolders.contains(where: { Self.contains($0, lexical) }) else {
            throw AppThemeOutputError.protectedFolder(path)
        }
        let resolved = Self.resolve(lexical)
        let roots = known ?? resolvedRoots()
        guard roots.allowed.contains(where: { Self.contains($0, resolved) }) else {
            throw AppThemeOutputError.outsideAllowedFolders(path)
        }
        guard !roots.protected.contains(where: { Self.contains($0, resolved) }) else {
            throw AppThemeOutputError.protectedFolder(path)
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw AppThemeOutputError.notRegularFile(path)
        }
        return resolved
    }

    static func contains(_ folder: URL, _ url: URL) -> Bool {
        let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return url.path.hasPrefix(base)
    }

    static func resolve(_ url: URL) -> URL {
        var existing = url
        var remainder: [String] = []
        while existing.path != "/", (try? existing.checkResourceIsReachable()) != true,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: existing.path)) == nil
        {
            remainder.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let real = realpath(existing.path, nil) else { return url }
        defer { free(real) }
        return remainder.reduce(URL(fileURLWithPath: String(cString: real))) { $0.appendingPathComponent($1) }
    }
}
