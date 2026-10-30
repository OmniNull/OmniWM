// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CryptoKit
import Darwin
import Foundation

enum ShellStyleInstaller {
    struct Failure: LocalizedError, Equatable {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }

    struct Receipt: Codable, Equatable, Sendable {
        let source: String
        let version: String
        let files: [String: String]
    }

    static let receiptName = ".omniwm-style.json"
    static let backupsFolder = ".backups"
    private static let stagingPrefix = ".install-"

    static func hasChanges(in folder: URL, from receipt: Receipt) throws -> Bool {
        let files = try ShellStyleRepository(folder: folder.deletingLastPathComponent())
            .files(of: folder.lastPathComponent)
        return Dictionary(uniqueKeysWithValues: files.map { ($0.path, digest($0.data)) }) != receipt.files
    }

    static func receipt(in folder: URL) throws -> Receipt? {
        guard let data = try SettingsFileAccess.existingData(at: folder.appendingPathComponent(receiptName)) else {
            return nil
        }
        return try JSONDecoder().decode(Receipt.self, from: data)
    }

    @discardableResult
    static func install(
        _ payload: ShellStylePayload, into shell: URL, replacing: Bool, day: String = ShellDefaults.today
    ) throws -> URL? {
        let manifest = try validate(payload)
        let target = shell.appendingPathComponent(payload.name, isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: target.path)
        guard !exists || replacing else { throw Failure("\(payload.name) is already in your shell folder") }
        let backups = exists ? try backupsFolder(in: shell) : nil
        let staging = shell.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try write(payload, version: manifest.version, into: staging)
            try rename(staging, to: target, flags: exists ? RENAME_SWAP : RENAME_EXCL)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        guard let backups else { return nil }
        let backup = backupURL(for: payload.name, in: backups, day: day)
        do {
            try rename(staging, to: backup, flags: RENAME_EXCL)
            return backup
        } catch {
            Log.shell.error("Kept the previous \(payload.name) at \(staging.path): \(error.localizedDescription)")
            return staging
        }
    }

    @discardableResult
    static func remove(_ name: String, from shell: URL, day: String = ShellDefaults.today) throws -> URL {
        let target = shell.appendingPathComponent(name, isDirectory: true)
        guard ShellProfiles.isStyleName(name), FileManager.default.fileExists(atPath: target.path) else {
            throw Failure("\(name) is not installed")
        }
        let backup = backupURL(for: name, in: try backupsFolder(in: shell), day: day)
        try rename(target, to: backup, flags: RENAME_EXCL)
        return backup
    }

    @discardableResult
    static func validate(_ payload: ShellStylePayload) throws -> ShellStyleManifest {
        let name = payload.name, files = payload.files
        guard ShellProfiles.isStyleName(name) else { throw Failure("\(name) is not a valid style name") }
        var paths: Set<String> = []
        var folders: Set<String> = []
        for file in files {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") }) else {
                throw Failure("\(name) has an invalid path \(file.path)")
            }
            let key = file.path.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(key).inserted else { throw Failure("\(name)/\(file.path) appears twice") }
            folders.formUnion(components.indices.dropLast().map { components[...$0].joined(separator: "/") }
                .map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        }
        if let clash = paths.intersection(folders).first {
            throw Failure("\(name)/\(clash) is both a file and a folder")
        }
        guard let data = files.first(where: { $0.path == ShellStyleManifest.fileName })?.data else {
            throw Failure("\(name) has no \(ShellStyleManifest.fileName)")
        }
        let manifest = try ShellStyleManifest.parse(data)
        guard manifest.name == name else { throw Failure("\(name): its manifest names \(manifest.name)") }
        return manifest
    }

    private static func write(_ payload: ShellStylePayload, version: String, into folder: URL) throws {
        var hashes: [String: String] = [:]
        for file in payload.files {
            let url = folder.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try file.data.write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: file.executable ? 0o755 : 0o644], ofItemAtPath: url.path
            )
            hashes[file.path] = digest(file.data)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Receipt(source: payload.source, version: version, files: hashes))
            .write(to: folder.appendingPathComponent(receiptName), options: .withoutOverwriting)
    }

    private static func backupsFolder(in shell: URL) throws -> URL {
        let backups = shell.appendingPathComponent(backupsFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        return backups
    }

    private static func backupURL(for name: String, in backups: URL, day: String) -> URL {
        var target = backups.appendingPathComponent("\(name)-\(day)", isDirectory: true)
        var copy = 1
        while FileManager.default.fileExists(atPath: target.path) {
            copy += 1
            target = backups.appendingPathComponent("\(name)-\(day)-\(copy)", isDirectory: true)
        }
        return target
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func rename(_ source: URL, to target: URL, flags: Int32) throws {
        guard renamex_np(source.path, target.path, UInt32(flags)) == 0 else {
            throw Failure(
                "\(target.lastPathComponent) could not be moved into place: \(String(cString: strerror(errno)))"
            )
        }
    }
}
