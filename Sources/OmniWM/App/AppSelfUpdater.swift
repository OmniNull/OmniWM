// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CryptoKit
import Foundation
import Security

struct ReleaseArchive: Equatable {
    static let downloadPrefix = "https://github.com/OmniNull/OmniWM/releases/download/"

    let url: URL
    let sha256: String

    init?(name: String, url: URL, digest: String?, tag: String) {
        let expectedName = GitHubRelease.isCanaryTag(tag) ? "OmniWM-canary-\(tag).zip" : "OmniWM-\(tag).zip"
        guard name == expectedName,
              url.absoluteString == Self.downloadPrefix + "\(tag)/\(name)",
              let digest, digest.hasPrefix("sha256:")
        else { return nil }
        let hex = String(digest.dropFirst("sha256:".count)).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        self.url = url
        sha256 = hex
    }
}

@MainActor
protocol AppUpdateInstalling: AnyObject {
    var canInstall: Bool { get }
    func isInstalled(_ release: GitHubRelease) -> Bool
    func install(_ release: GitHubRelease) async throws
    func relaunch() throws
}

enum AppSelfUpdateError: LocalizedError {
    case missingArchive
    case badStatus(Int)
    case digestMismatch
    case extractionFailed(Int32)
    case missingApp
    case versionMismatch(String)
    case untrustedSignature(Int32)

    var errorDescription: String? {
        switch self {
        case .missingArchive:
            return String(localized: "This release has no OmniWM download to install.")
        case let .badStatus(statusCode):
            return String(localized: "GitHub returned HTTP \(statusCode) while downloading the update.")
        case .digestMismatch:
            return String(localized: "The downloaded update does not match the checksum GitHub published for it.")
        case let .extractionFailed(status):
            return String(localized: "The downloaded update could not be unpacked (ditto exited with \(status)).")
        case .missingApp:
            return String(localized: "The downloaded update does not contain OmniWM.app.")
        case let .versionMismatch(version):
            return String(
                localized: "The downloaded update contains version \(version), not the release that was offered."
            )
        case let .untrustedSignature(status):
            return String(
                localized: "The downloaded update is not signed and notarized like this copy of OmniWM (error \(status))."
            )
        }
    }
}

@MainActor
final class AppSelfUpdater: AppUpdateInstalling {
    private let bundleURL: URL
    private let session: URLSession
    private let requirement: () throws -> String
    private let processIdentifier: Int32
    private let opener: URL
    private let terminate: () -> Void
    private(set) var relaunchSignal: FileHandle?

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        session: URLSession = .shared,
        requirement: @escaping () throws -> String = AppSelfUpdater.runningAppRequirement,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        opener: URL = URL(fileURLWithPath: "/usr/bin/open"),
        terminate: @escaping () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.bundleURL = bundleURL
        self.session = session
        self.requirement = requirement
        self.processIdentifier = processIdentifier
        self.opener = opener
        self.terminate = terminate
    }

    var canInstall: Bool {
        FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: bundleURL.path)
    }

    func isInstalled(_ release: GitHubRelease) -> Bool {
        let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let version = info?["OMNIWMCanaryTag"] as? String ?? info?["CFBundleShortVersionString"] as? String
        return version.map(release.matches(installedVersion:)) ?? false
    }

    func install(_ release: GitHubRelease) async throws {
        guard let archive = release.archive else { throw AppSelfUpdateError.missingArchive }
        let requirementText = try requirement()
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundleURL, create: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        let zip = try await download(archive, into: staging)
        let app = try await Self.extract(zip, into: staging)
        try Self.verify(app, matches: release, requirement: requirementText)
        try Task.checkCancellation()
        _ = try FileManager.default.replaceItemAt(bundleURL, withItemAt: app)
    }

    func relaunch() throws {
        if relaunchSignal == nil {
            let script = """
            read -r _ || exit 0
            while kill -0 "$1" 2>/dev/null; do sleep 0.1; done
            exec "$3" "$2"
            """
            let input = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script, "sh", String(processIdentifier), bundleURL.path, opener.path]
            process.standardInput = input
            try process.run()
            relaunchSignal = input.fileHandleForWriting
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.confirmRelaunch() }
            }
        }
        terminate()
    }

    func confirmRelaunch() {
        try? relaunchSignal?.write(contentsOf: Data("\n".utf8))
    }

    private func download(_ archive: ReleaseArchive, into staging: URL) async throws -> URL {
        let (temporary, response) = try await session.download(from: archive.url)
        let zip = staging.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: temporary, to: zip)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ... 299).contains(status) else { throw AppSelfUpdateError.badStatus(status) }
        guard try Self.sha256(of: zip) == archive.sha256 else { throw AppSelfUpdateError.digestMismatch }
        return zip
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @concurrent
    private nonisolated static func extract(_ zip: URL, into staging: URL) async throws -> URL {
        let destination = staging.appendingPathComponent("extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, destination.path]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else { throw AppSelfUpdateError.extractionFailed(status) }
        let app = destination.appendingPathComponent("OmniWM.app")
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
            throw AppSelfUpdateError.missingApp
        }
        return app
    }

    nonisolated static func verify(_ app: URL, matches release: GitHubRelease, requirement: String) throws {
        let bundle = Bundle(url: app)
        let version = bundle?.canaryReleaseTag ?? bundle?.appVersion ?? ""
        guard release.matches(installedVersion: version) else {
            throw AppSelfUpdateError.versionMismatch(version)
        }

        var code: SecStaticCode?
        var compiled: SecRequirement?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        if status == errSecSuccess {
            status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        }
        if status == errSecSuccess, let code, let compiled {
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
            status = SecStaticCodeCheckValidity(code, flags, compiled)
        }
        guard status == errSecSuccess else { throw AppSelfUpdateError.untrustedSignature(status) }
    }

    nonisolated static func runningAppRequirement() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var designated: SecRequirement?
        var text: CFString?
        var status = SecCodeCopySelf([], &code)
        if status == errSecSuccess, let code { status = SecCodeCopyStaticCode(code, [], &staticCode) }
        if status == errSecSuccess, let staticCode {
            status = SecCodeCopyDesignatedRequirement(staticCode, [], &designated)
        }
        if status == errSecSuccess, let designated { status = SecRequirementCopyString(designated, [], &text) }
        guard status == errSecSuccess, let text else { throw AppSelfUpdateError.untrustedSignature(status) }
        return notarized(text as String)
    }

    nonisolated static func notarized(_ designatedRequirement: String) -> String {
        "(\(designatedRequirement)) and notarized"
    }
}
