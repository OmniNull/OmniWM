// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellAsset: Hashable, Sendable {
    static let prefix = "@omni-asset:"

    let folder: URL
    let path: String

    var url: URL {
        folder.appendingPathComponent(path)
    }

    enum Failure: Error, CustomStringConvertible {
        case invalid(String)

        var description: String {
            switch self {
            case let .invalid(message): message
            }
        }
    }

    init(_ source: String, packages: [String: URL]) throws {
        guard source.hasPrefix(Self.prefix),
              let separator = source.dropFirst(Self.prefix.count).firstIndex(of: "/")
        else { throw Failure.invalid("invalid qualified asset reference") }
        let package = String(source[source.index(source.startIndex, offsetBy: Self.prefix.count) ..< separator])
        let path = String(source[source.index(after: separator)...])
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !package.isEmpty, package != ".", package != "..", !package.contains("\0"),
              !path.hasPrefix("~"), !path.contains("\0"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw Failure.invalid("asset paths must stay inside their source package") }
        guard let folder = packages[package] else {
            throw Failure.invalid("asset package \(package) is not loaded")
        }
        self.folder = folder
        self.path = path
    }

    func revision(limit: Int) throws -> ShellAssetRevision {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let file = url.resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else {
            throw Failure.invalid("asset paths must stay inside their source package")
        }
        guard let fingerprint = SettingsFileAccess.currentFingerprint(at: file) else {
            throw Failure.invalid("asset \(path) could not be read")
        }
        guard fingerprint.fileSize <= UInt64(limit) else {
            throw Failure.invalid("asset \(path) is larger than \(limit) bytes")
        }
        return ShellAssetRevision(url: file, fingerprint: fingerprint)
    }
}

struct ShellAssetRevision: Equatable, Sendable {
    let url: URL
    let fingerprint: SettingsFileAccess.Fingerprint
}
