// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

struct AppThemeState: Codable, Equatable {
    var owned: [String: String] = [:]
    var pending: [String: String] = [:]
    var reloadPending: Set<String> = []
    var results: [String: AppThemeResult] = [:]
}

struct AppThemeStateStore: Sendable {
    static let backupLimit = 20

    let directory: URL

    var stateURL: URL {
        directory.appendingPathComponent("state.json")
    }

    var backupsDirectory: URL {
        directory.appendingPathComponent("backups", isDirectory: true)
    }

    func load() throws -> AppThemeState {
        guard let data = try AppThemeFileWriter.read(stateURL) else { return AppThemeState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(AppThemeState.self, from: data)
        } catch {
            throw AppThemeEngineError.unreadable(stateURL.path, String(localized: "it isn’t valid app theming state"))
        }
    }

    func save(_ state: AppThemeState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try AppThemeFileWriter.writeAtomically(encoder.encode(state), to: stateURL)
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("run.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    func backup(_ data: Data, of url: URL, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupsDirectory.path)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let source = "\(url.deletingLastPathComponent().lastPathComponent)-\(url.lastPathComponent)"
        let name = "\(formatter.string(from: date))-\(UUID().uuidString)-\(source)"
        let destination = backupsDirectory.appendingPathComponent(name)
        try AppThemeFileWriter.writeAtomically(data, to: destination, mode: 0o600) {
            guard try AppThemeFileWriter.read(destination) == nil else {
                throw POSIXError(.EEXIST)
            }
        }
        pruneBackups()
        return destination
    }

    private func pruneBackups() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path)) ?? []
        let visible = names.filter { !$0.hasPrefix(".") }.sorted()
        for name in visible.dropLast(Self.backupLimit) {
            try? FileManager.default.removeItem(at: backupsDirectory.appendingPathComponent(name))
        }
    }
}
