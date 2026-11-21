// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CryptoKit
import Darwin
import Foundation

enum AppThemeFileWriter {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ text: String) -> String {
        digest(Data(text.utf8))
    }

    private static let readChunk = 65536

    static func read(_ url: URL, display: String? = nil) throws -> Data? {
        let name = display ?? url.path
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let error = errno
            var entry = stat()
            if error == ENOENT, lstat(url.path, &entry) != 0 { return nil }
            if error == ENOENT { throw AppThemeOutputError.notRegularFile(name) }
            throw AppThemeEngineError.unreadable(name, String(cString: strerror(error)))
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AppThemeEngineError.unreadable(name, String(cString: strerror(errno)))
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw AppThemeOutputError.notRegularFile(name) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: readChunk)
        while true {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw AppThemeEngineError.unreadable(name, String(cString: strerror(errno)))
            }
            guard count > 0 else { return data }
            data.append(contentsOf: chunk[0 ..< count])
        }
    }

    static func writeAtomically(
        _ data: Data,
        to url: URL,
        mode requested: mode_t? = nil,
        beforeReplace: () throws -> Void = {}
    ) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var mode: mode_t = 0o644
        var info = stat()
        if lstat(url.path, &info) == 0 {
            mode = info.st_mode & 0o777
        }
        if let requested { mode = requested }
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).omniwm-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try write(data, to: descriptor)
            guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            close(descriptor)
        } catch {
            close(descriptor)
            unlink(temporary.path)
            throw error
        }
        do {
            try beforeReplace()
        } catch {
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(temporary.path)
            throw failure
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }
}
