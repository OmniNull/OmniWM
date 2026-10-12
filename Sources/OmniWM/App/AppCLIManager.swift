// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum AppCLIExposureStatus: Equatable {
    case homebrewManaged(linkURL: URL)
    case appManaged(linkURL: URL, directoryOnPath: Bool)
    case notInstalled(linkURL: URL, directoryOnPath: Bool)
    case conflict(existingURL: URL)
}

enum AppCLIInstallResult: Equatable {
    case installed(linkURL: URL, directoryOnPath: Bool)
    case alreadyInstalled(linkURL: URL, directoryOnPath: Bool)
    case removed(linkURL: URL)
    case notInstalled(linkURL: URL)
    case homebrewManaged(linkURL: URL)
}

enum AppCLIInstallError: LocalizedError, Equatable {
    case bundledCLIMissing(URL)
    case conflictingInstall(URL)
    case cannotRemoveNonManagedInstall(URL)

    var errorDescription: String? {
        switch self {
        case let .bundledCLIMissing(url):
            return "Bundled omniwmctl was not found at \(url.path). Reinstall OmniWM to restore the CLI."
        case let .conflictingInstall(url):
            return "Another file already exists at \(url.path). Move or remove it before installing OmniWM's CLI link."
        case let .cannotRemoveNonManagedInstall(url):
            return "OmniWM will only remove the CLI link it created. The existing file at \(url.path) is managed elsewhere."
        }
    }
}

final class AppCLIManager {
    private let fileManager: FileManager
    private let environmentProvider: () -> [String: String]
    private let bundleURLProvider: () -> URL
    private let homeDirectoryURLProvider: () -> URL
    private let homebrewLinkURLsProvider: () -> [URL]

    init(
        fileManager: FileManager = .default,
        environmentProvider: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        bundleURLProvider: @escaping () -> URL = { Bundle.main.bundleURL },
        homeDirectoryURLProvider: @escaping () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        homebrewLinkURLsProvider: @escaping () -> [URL] = {
            [
                URL(fileURLWithPath: "/opt/homebrew/bin/omniwmctl"),
                URL(fileURLWithPath: "/usr/local/bin/omniwmctl")
            ]
        }
    ) {
        self.fileManager = fileManager
        self.environmentProvider = environmentProvider
        self.bundleURLProvider = bundleURLProvider
        self.homeDirectoryURLProvider = homeDirectoryURLProvider
        self.homebrewLinkURLsProvider = homebrewLinkURLsProvider
    }

    var bundledCLIURL: URL {
        bundleURLProvider()
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("omniwmctl", isDirectory: false)
    }

    func exposureStatus() -> AppCLIExposureStatus {
        if let homebrewLink = homebrewLinkURL() {
            return .homebrewManaged(linkURL: homebrewLink)
        }

        let linkURL = preferredUserLinkURL()
        let directoryOnPath = isDirectoryOnPATH(linkURL.deletingLastPathComponent())
        if fileManager.fileExists(atPath: linkURL.path) {
            if symlinkResolvesToBundledCLI(at: linkURL) {
                return .appManaged(linkURL: linkURL, directoryOnPath: directoryOnPath)
            }
            return .conflict(existingURL: linkURL)
        }

        return .notInstalled(linkURL: linkURL, directoryOnPath: directoryOnPath)
    }

    func installCLIToPATH() throws -> AppCLIInstallResult {
        guard fileManager.isExecutableFile(atPath: bundledCLIURL.path) else {
            throw AppCLIInstallError.bundledCLIMissing(bundledCLIURL)
        }

        switch exposureStatus() {
        case let .homebrewManaged(linkURL):
            return .homebrewManaged(linkURL: linkURL)
        case let .appManaged(linkURL, directoryOnPath):
            return .alreadyInstalled(linkURL: linkURL, directoryOnPath: directoryOnPath)
        case let .conflict(existingURL):
            throw AppCLIInstallError.conflictingInstall(existingURL)
        case let .notInstalled(linkURL, directoryOnPath):
            let directoryURL = linkURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: bundledCLIURL)
            return .installed(linkURL: linkURL, directoryOnPath: directoryOnPath)
        }
    }

    func removeInstalledCLI() throws -> AppCLIInstallResult {
        switch exposureStatus() {
        case let .homebrewManaged(linkURL):
            return .homebrewManaged(linkURL: linkURL)
        case let .notInstalled(linkURL, _):
            return .notInstalled(linkURL: linkURL)
        case let .conflict(existingURL):
            throw AppCLIInstallError.cannotRemoveNonManagedInstall(existingURL)
        case let .appManaged(linkURL, _):
            try fileManager.removeItem(at: linkURL)
            return .removed(linkURL: linkURL)
        }
    }

    private func homebrewLinkURL() -> URL? {
        homebrewCandidateLinkURLs().first(where: symlinkResolvesToBundledCLI(at:))
    }

    private func homebrewCandidateLinkURLs() -> [URL] {
        let candidates = homebrewLinkURLsProvider()
        return Array(NSOrderedSet(array: candidates)) as? [URL] ?? candidates
    }

    private func preferredUserLinkURL() -> URL {
        preferredUserBinDirectory()
            .appendingPathComponent("omniwmctl", isDirectory: false)
    }

    private func preferredUserBinDirectory() -> URL {
        let homeDirectory = homeDirectoryURLProvider().standardizedFileURL
        let pathDirectories = pathDirectoriesFromEnvironment()
            .filter { isWithinHomeDirectory($0, homeDirectory: homeDirectory) }
        let fallbacks = [
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent("bin", isDirectory: true)
        ]

        for directory in pathDirectories + fallbacks where isUserWritableDirectory(directory) {
            return directory
        }

        return fallbacks[0]
    }

    private func pathDirectoriesFromEnvironment() -> [URL] {
        let pathValue = environmentProvider()["PATH"] ?? ""
        return pathValue
            .split(separator: ":")
            .map { String($0) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
    }

    private func isDirectoryOnPATH(_ directory: URL) -> Bool {
        pathDirectoriesFromEnvironment().contains { $0.standardizedFileURL.path == directory.standardizedFileURL.path }
    }

    private func isUserWritableDirectory(_ directory: URL) -> Bool {
        if fileManager.fileExists(atPath: directory.path) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return false
            }
            return fileManager.isWritableFile(atPath: directory.path)
        }

        return isWithinHomeDirectory(
            directory.deletingLastPathComponent(),
            homeDirectory: homeDirectoryURLProvider()
        )
    }

    private func isWithinHomeDirectory(_ directory: URL, homeDirectory: URL) -> Bool {
        directory.standardizedFileURL.pathComponents.starts(with: homeDirectory.standardizedFileURL.pathComponents)
    }

    private func symlinkResolvesToBundledCLI(at url: URL) -> Bool {
        guard let resolvedURL = resolvedSymlinkDestination(at: url) else { return false }
        return resolvedURL.standardizedFileURL.path == bundledCLIURL.standardizedFileURL.path
    }

    private func resolvedSymlinkDestination(at url: URL) -> URL? {
        guard let destinationPath = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }

        let destinationURL: URL
        if destinationPath.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destinationPath, isDirectory: false)
        } else {
            destinationURL = url.deletingLastPathComponent()
                .appendingPathComponent(destinationPath, isDirectory: false)
        }
        return destinationURL.standardizedFileURL
    }
}
