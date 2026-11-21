// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CryptoKit
import Foundation
import Security
import Synchronization

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
    case relaunchUnavailable(Int32)

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
        case let .relaunchUnavailable(status):
            return String(
                localized: "The update is installed, but OmniWM could not prepare to reopen (error \(status)). Quit OmniWM and open it again to finish."
            )
        }
    }
}

@MainActor
final class AppSelfUpdater: AppUpdateInstalling {
    private let bundleURL: URL
    private let session: URLSession
    private let updateRequirement: Result<String, any Error>
    private let processIdentifier: Int32
    private let opener: URL
    private let terminate: () -> Void
    private(set) var relaunchObserver: NSObjectProtocol?
    private(set) var suspendedRelaunch: pid_t = 0

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
        updateRequirement = Result { try requirement() }
        self.processIdentifier = processIdentifier
        self.opener = opener
        self.terminate = terminate
    }

    var canInstall: Bool {
        FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: bundleURL.path)
            && acceptsReleaseSignature
    }

    private var acceptsReleaseSignature: Bool {
        guard let requirementText = try? updateRequirement.get() else { return false }
        let flags = kSecCSBasicValidateOnly | SecCSFlags.noNetworkAccess.rawValue
        return Self.signatureStatus(of: bundleURL, requirement: requirementText, flags: flags) == errSecSuccess
    }

    func isInstalled(_ release: GitHubRelease) -> Bool {
        let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let version = info?["OMNIWMCanaryTag"] as? String ?? info?["CFBundleShortVersionString"] as? String
        return version.map(release.matches(installedVersion:)) ?? false
    }

    func install(_ release: GitHubRelease) async throws {
        guard let archive = release.archive else { throw AppSelfUpdateError.missingArchive }
        let requirementText = try updateRequirement.get()
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundleURL, create: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        let zip = try await download(archive, into: staging)
        let app = try await Self.extract(zip, into: staging)
        try await Self.verify(app, matches: release, requirement: requirementText)
        try Task.checkCancellation()
        _ = try FileManager.default.replaceItemAt(bundleURL, withItemAt: app)
    }

    func relaunch() throws {
        suspendedRelaunch = try Self.spawnSuspended(
            opener, arguments: ["-n", bundleURL.path, "--args", AppRelaunch.argument, String(processIdentifier)]
        )
        if relaunchObserver == nil {
            relaunchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeRelaunch() }
            }
        }
        scheduleOnMainRunLoop { [self] in
            terminate()
            abandonRelaunch()
        }
    }

    func resumeRelaunch() {
        guard suspendedRelaunch > 0 else { return }
        kill(suspendedRelaunch, SIGCONT)
        suspendedRelaunch = 0
    }

    private func abandonRelaunch() {
        if suspendedRelaunch > 0 {
            kill(suspendedRelaunch, SIGKILL)
            var status: Int32 = 0
            while waitpid(suspendedRelaunch, &status, 0) < 0, errno == EINTR {}
            suspendedRelaunch = 0
        }
        relaunchObserver.map(NotificationCenter.default.removeObserver)
        relaunchObserver = nil
    }

    private nonisolated static func spawnSuspended(_ executable: URL, arguments: [String]) throws -> pid_t {
        func check(_ status: Int32) throws {
            if status != 0 { throw AppSelfUpdateError.relaunchUnavailable(status) }
        }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var hangup = sigset_t()
        var unblocked = sigset_t()
        sigemptyset(&hangup)
        sigaddset(&hangup, SIGHUP)
        sigemptyset(&unblocked)
        try check(posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        )))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(posix_spawnattr_setsigdefault(&attributes, &hangup))
        try check(posix_spawnattr_setsigmask(&attributes, &unblocked))
        var pointers = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        var child: pid_t = 0
        try check(posix_spawn(&child, executable.path, nil, &attributes, &pointers, environ))
        return child
    }

    private func download(_ archive: ReleaseArchive, into staging: URL) async throws -> URL {
        let (temporary, response) = try await session.download(from: archive.url)
        let zip = staging.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: temporary, to: zip)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ... 299).contains(status) else { throw AppSelfUpdateError.badStatus(status) }
        guard try await Self.sha256(of: zip) == archive.sha256 else { throw AppSelfUpdateError.digestMismatch }
        return zip
    }

    @concurrent
    nonisolated static func sha256(of file: URL) async throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @concurrent
    nonisolated static func extract(
        _ zip: URL,
        into staging: URL,
        using ditto: URL = URL(fileURLWithPath: "/usr/bin/ditto")
    ) async throws -> URL {
        let destination = staging.appendingPathComponent("extracted")
        let process = Process()
        process.executableURL = ditto
        process.arguments = ["-x", "-k", zip.path, destination.path]
        let pending = Mutex<Process?>(process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try pending.withLock { process in
                        guard let process else { throw CancellationError() }
                        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                        try process.run()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            pending.withLock { process in
                if process?.isRunning == true { process?.terminate() }
                process = nil
            }
        }
        try Task.checkCancellation()
        guard status == 0 else { throw AppSelfUpdateError.extractionFailed(status) }
        let app = destination.appendingPathComponent("OmniWM.app")
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
            throw AppSelfUpdateError.missingApp
        }
        return app
    }

    @concurrent
    nonisolated static func verify(_ app: URL, matches release: GitHubRelease, requirement: String) async throws {
        let bundle = Bundle(url: app)
        let version = bundle?.canaryReleaseTag ?? bundle?.appVersion ?? ""
        guard release.matches(installedVersion: version) else {
            throw AppSelfUpdateError.versionMismatch(version)
        }
        let flags = kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode
        let status = signatureStatus(of: app, requirement: requirement, flags: flags)
        guard status == errSecSuccess else { throw AppSelfUpdateError.untrustedSignature(status) }
    }

    private nonisolated static func signatureStatus(of app: URL, requirement: String, flags: UInt32) -> OSStatus {
        var code: SecStaticCode?
        var compiled: SecRequirement?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        if status == errSecSuccess {
            status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        }
        if status == errSecSuccess, let code, let compiled {
            status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: flags), compiled)
        }
        return status
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

public enum AppRelaunch {
    static let argument = "--relaunched-after"

    public static func awaitPredecessor(arguments: [String] = CommandLine.arguments) {
        guard let flag = arguments.firstIndex(of: argument), arguments.indices.contains(flag + 1),
              let predecessor = pid_t(arguments[flag + 1]), predecessor > 0
        else { return }
        guard awaitExit(of: predecessor) else {
            Log.diagnostics.error("OmniWM could not wait for the copy it replaced (pid \(predecessor)) to quit")
            exit(EXIT_FAILURE)
        }
    }

    static func awaitExit(of process: pid_t) -> Bool {
        let queue = kqueue()
        guard queue >= 0 else { return false }
        defer { close(queue) }
        var change = kevent(
            ident: UInt(process), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: NOTE_EXIT, data: 0, udata: nil
        )
        var event = kevent()
        while true {
            if kevent(queue, &change, 1, &event, 1, nil) > 0 {
                return event.flags & UInt16(EV_ERROR) == 0 || event.data == Int(ESRCH)
            }
            if errno != EINTR { return errno == ESRCH }
        }
    }
}
