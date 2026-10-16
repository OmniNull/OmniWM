// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

enum SettingsFileAccess {
    struct Fingerprint: Equatable {
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

    private enum BackupSlotState {
        case absent
        case matching
        case occupied
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

    static func currentFingerprint(at fileURL: URL) -> Fingerprint? {
        var statBuffer = stat()
        let result = fileURL.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.fstatat(AT_FDCWD, path, &statBuffer, 0)
        }

        guard result == 0 else { return nil }
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

    static func secureBackup(
        _ data: Data,
        in directoryURL: URL,
        fileNames: [String],
        exhaustedError: SettingsFilePersistenceError
    ) throws -> URL {
        var firstAbsentURL: URL?
        for fileName in fileNames {
            let slotURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
            switch Self.backupSlotState(at: slotURL, matching: data) {
            case .matching:
                return slotURL
            case .absent:
                if firstAbsentURL == nil {
                    firstAbsentURL = slotURL
                }
            case .occupied:
                break
            }
        }

        guard let firstAbsentURL else {
            throw exhaustedError
        }
        try Self.writeExclusive(data, to: firstAbsentURL)
        return firstAbsentURL
    }

    private static func backupSlotState(at url: URL, matching expectedData: Data) -> BackupSlotState {
        let fileDescriptor = url.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        }

        guard fileDescriptor >= 0 else {
            return errno == ENOENT ? .absent : .occupied
        }

        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
        }

        var fileStatus = stat()
        guard Darwin.fstat(fileDescriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG
        else {
            return .occupied
        }
        do {
            return (try handle.readToEnd() ?? Data()) == expectedData ? .matching : .occupied
        } catch {
            return .occupied
        }
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
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
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    static func writeAtomically(_ data: Data, at targetURL: URL) throws {
        try data.write(to: targetURL, options: .atomic)
    }
}
