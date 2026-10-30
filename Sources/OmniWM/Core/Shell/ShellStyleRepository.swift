// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellStyleFile: Equatable, Sendable {
    let path: String
    let data: Data
    let executable: Bool
}

struct ShellStylePayload: Equatable, Sendable {
    let name: String
    let source: String
    let files: [ShellStyleFile]
}

struct ShellStyleListing: Equatable, Sendable, Identifiable {
    let name: String
    let manifest: ShellStyleManifest
    let revision: String?
    let previews: [URL]

    init(name: String, manifest: ShellStyleManifest, folder: URL, revision: String? = nil) throws {
        guard manifest.name == name else {
            throw ShellStyleInstaller.Failure("\(name): the manifest name must match its folder")
        }
        self.name = name
        self.manifest = manifest
        self.revision = revision
        previews = manifest.previews.map { folder.appending(path: "\(ShellStyleRepository.previewsFolder)/\($0)") }
    }

    var id: String {
        name
    }
}

struct ShellStyleRepository: Equatable, ShellStyleSource {
    static let previewsFolder = "previews"
    static let current = checkout()

    let folder: URL

    var source: String {
        "checkout:" + folder.path
    }

    static func checkout(executable: URL? = Bundle.main.executableURL) -> Self? {
        guard let executable, executable.standardizedFileURL.path.contains("/.build/") else { return nil }
        var directory = executable.standardizedFileURL.deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            let styles = directory.appendingPathComponent("styles", isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: styles.path)
            {
                return Self(folder: styles)
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    func styles() throws -> [ShellStyleListing] {
        try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .map { style in
            guard let manifest = try ShellStyleManifest.load(in: style) else {
                throw ShellStyleInstaller.Failure("\(style.lastPathComponent) has no \(ShellStyleManifest.fileName)")
            }
            return try ShellStyleListing(name: style.lastPathComponent, manifest: manifest, folder: style)
        }
    }

    func payload(for listing: ShellStyleListing) throws -> ShellStylePayload {
        ShellStylePayload(name: listing.name, source: source, files: try files(of: listing.name))
    }

    func files(of name: String) throws -> [ShellStyleFile] {
        let root = folder.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey]
        var unreadable: (any Error)?
        guard let entries = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                unreadable = error
                return false
            }
        ) else { throw ShellStyleInstaller.Failure("\(name) cannot be read") }
        var files: [ShellStyleFile] = []
        for case let url as URL in entries {
            let path = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            let values = try url.resourceValues(forKeys: Set(keys))
            if path == Self.previewsFolder, values.isDirectory == true {
                entries.skipDescendants()
            } else if values.isSymbolicLink == true || values.isDirectory != true && values.isRegularFile != true {
                throw ShellStyleInstaller.Failure("\(name)/\(path) is not a regular file")
            } else if values.isRegularFile == true {
                files.append(ShellStyleFile(
                    path: path, data: try Data(contentsOf: url), executable: values.isExecutable == true
                ))
            }
        }
        if let unreadable {
            throw ShellStyleInstaller.Failure("\(name) cannot be read: \(unreadable.localizedDescription)")
        }
        return files.sorted { $0.path < $1.path }
    }
}
