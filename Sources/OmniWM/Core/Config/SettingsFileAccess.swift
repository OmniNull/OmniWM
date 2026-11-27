// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

enum SettingsFileAccess {
    struct Fingerprint: Equatable, Sendable {
        let deviceID: UInt64
        let inode: UInt64
        let modificationTimeNanoseconds: Int64
        let statusChangeTimeNanoseconds: Int64
        let fileSize: UInt64
    }

    struct Contents {
        let data: Data
        let fingerprint: Fingerprint
    }

    private static let nanosecondsPerSecond: Int64 = 1_000_000_000

    static func ensureDirectoryExists(at directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    static func readContents(at targetURL: URL) throws -> Contents {
        let handle = try FileHandle(forReadingFrom: targetURL)
        defer {
            try? handle.close()
        }

        let data = try handle.readToEnd() ?? Data()

        var statBuffer = stat()
        guard Darwin.fstat(handle.fileDescriptor, &statBuffer) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return Contents(
            data: data,
            fingerprint: Self.fingerprint(from: statBuffer)
        )
    }

    static func readContents(at targetURL: URL, maximumBytes: Int) throws -> Contents {
        let descriptor = targetURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        guard status.st_size <= maximumBytes else { throw POSIXError(.EFBIG) }
        let original = fingerprint(from: status)
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        while let chunk = try handle.read(upToCount: max(1, Int(status.st_size) + 1 - data.count)), !chunk.isEmpty {
            guard chunk.count <= maximumBytes - data.count else { throw POSIXError(.EFBIG) }
            guard chunk.count <= Int(status.st_size) - data.count else { throw POSIXError(.ESTALE) }
            data.append(chunk)
        }
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fingerprint(from: status) == original else { throw POSIXError(.ESTALE) }
        return Contents(data: data, fingerprint: original)
    }

    static func currentFingerprint(at fileURL: URL) -> Fingerprint? {
        try? fileFingerprint(at: fileURL)
    }

    static func fileFingerprint(at fileURL: URL, followingLinks: Bool = true) throws -> Fingerprint {
        var statBuffer = stat()
        let result = fileURL.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.fstatat(AT_FDCWD, path, &statBuffer, followingLinks ? 0 : AT_SYMLINK_NOFOLLOW)
        }

        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Self.fingerprint(from: statBuffer)
    }

    private static func fingerprint(from statBuffer: stat) -> Fingerprint {
        Fingerprint(
            deviceID: UInt64(statBuffer.st_dev),
            inode: UInt64(statBuffer.st_ino),
            modificationTimeNanoseconds: nanoseconds(from: statBuffer.st_mtimespec),
            statusChangeTimeNanoseconds: nanoseconds(from: statBuffer.st_ctimespec),
            fileSize: UInt64(statBuffer.st_size)
        )
    }

    private static func nanoseconds(from timestamp: timespec) -> Int64 {
        Int64(timestamp.tv_sec) * nanosecondsPerSecond + Int64(timestamp.tv_nsec)
    }

    static func settingsTarget(for url: URL) throws -> URL {
        var fileStatus = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.lstat(path, &fileStatus)
        }

        guard result == 0 else {
            let code = errno
            guard code != ENOENT else { return url }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        let fileType = fileStatus.st_mode & S_IFMT
        guard fileType == S_IFLNK else {
            guard fileType == S_IFREG else { throw POSIXError(.EFTYPE) }
            return url
        }

        let resolvedURL: URL
        do {
            resolvedURL = try canonicalURL(for: url)
        } catch let error as POSIXError where error.code == .ENOENT {
            throw SettingsFilePersistenceError.danglingSettingsSymlink(url.path)
        }
        var targetStatus = stat()
        let targetResult = resolvedURL.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.lstat(path, &targetStatus)
        }

        guard targetResult == 0 else {
            let code = errno
            if code == ENOENT {
                throw SettingsFilePersistenceError.danglingSettingsSymlink(url.path)
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard targetStatus.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        return resolvedURL
    }

    static func canonicalURL(for url: URL) throws -> URL {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileReadInvalidFileName) }
            errno = 0
            guard let resolvedPath = Darwin.realpath(path, nil) else {
                let code = errno
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            defer { Darwin.free(resolvedPath) }
            return URL(
                fileURLWithFileSystemRepresentation: resolvedPath,
                isDirectory: false,
                relativeTo: nil
            )
        }
    }

    static func existingData(at targetURL: URL) throws -> Data? {
        var fileStatus = stat()
        let result = targetURL.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.lstat(path, &fileStatus)
        }

        guard result == 0 else {
            let code = errno
            guard code == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            return nil
        }

        guard fileStatus.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        return try readContents(at: targetURL).data
    }

    private static func writeExclusive(_ data: Data, to url: URL, synchronize: Bool = true) throws {
        let fileDescriptor = url.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            if synchronize { try handle.synchronize() }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    static func createAtomically(_ data: Data, at targetURL: URL) throws {
        let temporary = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".settings-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeExclusive(data, to: temporary)
        try FileManager.default.linkItem(at: temporary, to: targetURL)
    }

    static func writeAtomically(_ data: Data, at targetURL: URL) throws {
        try data.write(to: targetURL, options: .atomic)
    }

    private static func restrictToOwner(_ url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> CInt in
            var status = stat()
            guard let path, fstatat(AT_FDCWD, path, &status, 0) == 0 else { return -1 }
            guard status.st_mode & (S_IRWXG | S_IRWXO) != 0 else { return 0 }
            return Darwin.chmod(path, status.st_mode & S_IRWXU)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func replacePrivately(_ data: Data, at targetURL: URL) throws {
        let directory = targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: S_IRWXU]
        )
        try restrictToOwner(directory)
        let temporary = directory.appendingPathComponent(".\(targetURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try writeExclusive(data, to: temporary, synchronize: false)
            let renamed = temporary.withUnsafeFileSystemRepresentation { source in
                targetURL.withUnsafeFileSystemRepresentation { target in
                    guard let source, let target else { return CInt(-1) }
                    return Darwin.rename(source, target)
                }
            }
            guard renamed == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

struct SettingsFileEdit {
    let target: URL
    let previous: SettingsFileAccess.Fingerprint?
    let patch: SettingsSourceEdit
    var modules: SettingsFileVersions = [:]

    static let formulaRequiresConfirmation = SettingsLuauError(
        message: "Changing a formula requires confirmation in Settings. Edit the file directly or choose the value in the Settings window."
    )

    func verify(at fileURL: URL, originalSource: Data?, approved: Bool) throws {
        if patch.question != nil, !approved {
            throw Self.formulaRequiresConfirmation
        }
        guard modules.isCurrent else { throw SettingsLuauError.changedHelper }
        if let revision = previous {
            let current = try SettingsFileAccess.readContents(
                at: target,
                maximumBytes: ConfigScriptLoader.sourceLimit
            )
            guard current.fingerprint == revision, current.data == originalSource else {
                throw SettingsLuauError(
                    message: "\(fileURL.lastPathComponent) was edited externally. Read the latest file before saving."
                )
            }
        }
        guard SettingsFileAccess.currentFingerprint(at: fileURL) == previous,
              try SettingsFileAccess.settingsTarget(for: fileURL) == target
        else {
            throw SettingsLuauError(
                message: "\(fileURL.lastPathComponent) changed during this edit. Try again with the latest file."
            )
        }
    }
}
