// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

struct ShellResourceReceivedFile: Sendable {
    let file: URL
    let directory: URL
    let size: UInt64

    static func copy(_ path: String, directory: URL, root: URL, operation: ShellResourceOperation) throws -> Self {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\0"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw ShellResourceFailure("received file path must stay within its action directory") }
        let (input, size) = try openInput(parts, directory: directory)
        defer { try? input.close() }
        let folder = root.appendingPathComponent("temporary", isDirectory: true).appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let url = folder.appendingPathComponent("payload")
            guard FileManager.default
                .createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else {
                throw ShellResourceFailure("could not create received resource backing")
            }
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            var remaining = size
            while remaining > 0 {
                guard operation.isActive else { throw ShellResourceFailure("resource action was cancelled") }
                let bytes = try input.read(upToCount: Int(min(65_536, remaining))) ?? Data()
                guard !bytes.isEmpty else { throw ShellResourceFailure("received file changed during import") }
                try output.write(contentsOf: bytes)
                remaining -= UInt64(bytes.count)
            }
            return Self(file: url, directory: folder, size: size)
        } catch {
            remove(folder)
            throw error
        }
    }

    private static func openInput(_ parts: [Substring], directory: URL) throws -> (FileHandle, UInt64) {
        var descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { if descriptor >= 0 { _ = Darwin.close(descriptor) } }
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (index + 1 == parts.count ? O_NONBLOCK : O_DIRECTORY)
            let next = openat(descriptor, String(part), flags)
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            _ = Darwin.close(descriptor)
            descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw ShellResourceFailure("received file is not a regular file")
        }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        descriptor = -1
        return (input, UInt64(info.st_size))
    }

    static func remove(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        catch { Log.shell.error("Could not remove received shell file: \(error.localizedDescription)") }
    }
}
