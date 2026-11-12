// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

private let identifier = "test.omniwm.selfupdate"
private let newTag = "canary-20261025-0437-40161156174-1"

@MainActor
final class AppSelfUpdaterTests: XCTestCase {
    private final class ZipProtocol: URLProtocol {
        static let body = Mutex(Data())
        static let status = Mutex(200)

        override static func canInit(with request: URLRequest) -> Bool {
            true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            let status = Self.status.withLock { $0 }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body.withLock { $0 })
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testArchiveAcceptsOnlyTheReleaseAppAssetWithASha256Digest() {
        let digest = "sha256:" + String(repeating: "f", count: 64)
        let canaryName = "OmniWM-canary-\(newTag).zip"
        let canaryURL = URL(string: ReleaseArchive.downloadPrefix + "\(newTag)/\(canaryName)")!
        XCTAssertNotNil(ReleaseArchive(name: canaryName, url: canaryURL, digest: digest, tag: newTag))

        let name = "OmniWM-v0.7.7.zip"
        let url = URL(string: ReleaseArchive.downloadPrefix + "v0.7.7/\(name)")!
        XCTAssertNotNil(ReleaseArchive(name: name, url: url, digest: digest, tag: "v0.7.7"))
        XCTAssertNil(ReleaseArchive(
            name: name,
            url: URL(string: "https://evil.example/\(name)")!,
            digest: digest,
            tag: "v0.7.7"
        ))
        XCTAssertNil(ReleaseArchive(name: "GhosttyKit.xcframework-v0.7.7.zip", url: url, digest: digest, tag: "v0.7.7"))
        XCTAssertNil(ReleaseArchive(name: name, url: url, digest: digest, tag: "v0.7.6"))
        XCTAssertNil(ReleaseArchive(name: name, url: url, digest: nil, tag: "v0.7.7"))
        XCTAssertNil(ReleaseArchive(name: name, url: url, digest: "sha256:abc", tag: "v0.7.7"))
        XCTAssertNil(ReleaseArchive(
            name: name,
            url: url,
            digest: "md5:" + String(repeating: "f", count: 64),
            tag: "v0.7.7"
        ))
    }

    func testInstallReplacesBundleWithVerifiedDownload() async throws {
        let installed = try makeApp(in: "installed", tag: "canary-20261024-0439-40061526227-1")
        let (release, session) = try await publish(makeApp(in: "build", tag: newTag))
        defer { session.invalidateAndCancel() }

        let requirementRead = Flag()
        let updater = AppSelfUpdater(bundleURL: installed, session: session) {
            if requirementRead.value { throw AppSelfUpdateError.untrustedSignature(100_002) }
            requirementRead.value = true
            return "identifier \"\(identifier)\""
        }
        XCTAssertTrue(updater.canInstall)
        XCTAssertFalse(updater.isInstalled(release))
        try await updater.install(release)
        XCTAssertTrue(updater.isInstalled(release))
        XCTAssertTrue(updater.canInstall, "the running app's requirement is gone once its bundle was replaced")

        XCTAssertEqual(tag(of: installed), newTag)
    }

    func testInstallLeavesBundleAloneWhenDownloadFailsAnyCheck() async throws {
        let oldTag = "canary-20261024-0439-40061526227-1"
        let installed = try makeApp(in: "installed", tag: oldTag)
        let (release, session) = try await publish(makeApp(in: "build", tag: newTag))
        defer { session.invalidateAndCancel() }
        let otherDigest = "sha256:" + String(repeating: "0", count: 64)
        var wrongDigest = release
        wrongDigest.archive = ReleaseArchive(
            name: "OmniWM-canary-\(newTag).zip",
            url: release.archive!.url,
            digest: otherDigest,
            tag: newTag
        )
        let wrongVersion = GitHubRelease(
            tagName: "canary-20261026-0437-40161156174-1", name: nil, body: "",
            releasePageURL: release.releasePageURL, publishedAt: Date(), isPrerelease: true, archive: release.archive
        )

        let ours = "identifier \"\(identifier)\""
        let cases: [String: (GitHubRelease, String)] = [
            "digestMismatch": (wrongDigest, ours),
            "versionMismatch": (wrongVersion, ours),
            "badStatus": (release, ours),
            "untrustedSignature": (release, "identifier \"someone.else\""),
            "notarization": (release, ours + " and notarized")
        ]
        for (name, (offered, requirement)) in cases {
            ZipProtocol.status.withLock { $0 = name == "badStatus" ? 404 : 200 }
            defer { ZipProtocol.status.withLock { $0 = 200 } }
            let updater = AppSelfUpdater(bundleURL: installed, session: session) { requirement }
            do {
                try await updater.install(offered)
                XCTFail("\(name) mismatch installed the update")
            } catch let error as AppSelfUpdateError {
                let expected = name == "notarization" ? "untrustedSignature" : name
                XCTAssertTrue(String(describing: error).hasPrefix(expected), "\(name): \(error)")
            } catch {
                XCTFail("\(name): unexpected \(error)")
            }
            XCTAssertEqual(tag(of: installed), oldTag, name)
        }
    }

    func testInstallIsOfferedOnlyWhenTheInstalledBundleMeetsTheUpdateRequirement() throws {
        let installed = try makeApp(in: "installed", tag: newTag)
        let ours = "identifier \"\(identifier)\""
        let offers = [ours: true, ours + " and notarized": false, "identifier \"someone.else\"": false]
        for (requirement, offered) in offers {
            XCTAssertEqual(AppSelfUpdater(bundleURL: installed) { requirement }.canInstall, offered, requirement)
        }
        XCTAssertFalse(AppSelfUpdater(bundleURL: installed) { throw AppSelfUpdateError.untrustedSignature(-1) }
            .canInstall)
    }

    func testInstallIsNotOfferedWhenTheBundleOrItsFolderIsReadOnly() throws {
        guard getuid() != 0 else { throw MissingTestPrerequisite("root writes through read-only permissions") }
        let installed = try makeApp(in: "installed", tag: newTag)
        let ours = "identifier \"\(identifier)\""
        XCTAssertTrue(AppSelfUpdater(bundleURL: installed) { ours }.canInstall)
        for target in [installed, installed.deletingLastPathComponent()] {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
            XCTAssertFalse(AppSelfUpdater(bundleURL: installed) { ours }.canInstall, target.lastPathComponent)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
    }

    func testCancellingStopsExtractionBeforeAndAfterTheToolStarts() async throws {
        let fifo = root.appendingPathComponent("started")
        let hold = root.appendingPathComponent("hold")
        try run("/usr/bin/mkfifo", fifo.path)
        try run("/usr/bin/mkfifo", hold.path)
        defer { release(hold) }
        let zip = root.appendingPathComponent("update.zip")
        let block = "exec /bin/cat \"\(hold.path)\""
        let scripts = [(false, block), (true, "echo started > \"\(fifo.path)\"\n\(block)")]
        for (launched, script) in scripts {
            let tool = root.appendingPathComponent("ditto-\(launched).sh")
            try "#!/bin/sh\n\(script)\n".write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            let extraction = Task { try await AppSelfUpdater.extract(zip, into: root, using: tool) }
            if launched {
                _ = try await Task.detached { try FileHandle(forReadingFrom: fifo).readToEnd() }.value
            }
            extraction.cancel()
            let stopped = expectation(description: "launched \(launched): extraction stopped")
            Task {
                do {
                    _ = try await extraction.value
                    XCTFail("launched \(launched): extraction finished")
                } catch is CancellationError {
                } catch {
                    XCTFail("launched \(launched): unexpected \(error)")
                }
                stopped.fulfill()
            }
            await fulfillment(of: [stopped], timeout: failureBound)
        }
    }

    func testRequirementAlwaysDemandsNotarization() throws {
        XCTAssertEqual(AppSelfUpdater.notarized("anchor apple"), "(anchor apple) and notarized")
        XCTAssertTrue(try AppSelfUpdater.runningAppRequirement().hasSuffix(") and notarized"))
    }

    func testRelaunchOpensANewInstanceOnlyWhenTerminationIsConfirmed() async throws {
        let opener = root.appendingPathComponent("open.sh")
        let opened = root.appendingPathComponent("opened")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(opened.path)\"\n"
            .write(to: opener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        let app = root.appendingPathComponent("OmniWM.app")
        let processIdentifier: pid_t = 4242

        for confirmed in [false, true] {
            let relaunchReturned = Flag()
            let quitReturned = expectation(description: "quit returned")
            var parked: pid_t = 0
            var updater: AppSelfUpdater?
            updater = AppSelfUpdater(
                bundleURL: app, processIdentifier: processIdentifier, opener: opener,
                terminate: {
                    XCTAssertTrue(relaunchReturned.value, "terminate ran inside relaunch")
                    XCTAssertNotNil(updater?.relaunchObserver)
                    parked = updater?.suspendedRelaunch ?? 0
                    if confirmed { updater?.resumeRelaunch() }
                    quitReturned.fulfill()
                }
            )
            let relaunching = try XCTUnwrap(updater)
            try relaunching.relaunch()
            XCTAssertEqual(getpgid(relaunching.suspendedRelaunch), relaunching.suspendedRelaunch)
            relaunchReturned.value = true
            await fulfillment(of: [quitReturned], timeout: failureBound)
            XCTAssertNil(relaunching.relaunchObserver)
            XCTAssertEqual(relaunching.suspendedRelaunch, 0)
            XCTAssertGreaterThan(parked, 0)
            var status: Int32 = -1
            if confirmed {
                XCTAssertEqual(waitpid(parked, &status, 0), parked)
                XCTAssertEqual(status, EXIT_SUCCESS)
            } else {
                XCTAssertEqual(waitpid(parked, &status, WNOHANG), -1, "the vetoed opener was not reaped")
                XCTAssertEqual(errno, ECHILD)
            }
            XCTAssertEqual(FileManager.default.fileExists(atPath: opened.path), confirmed)
        }
        XCTAssertEqual(
            try String(contentsOf: opened, encoding: .utf8),
            ["-n", app.path, "--args", AppRelaunch.argument, String(processIdentifier)].map { $0 + "\n" }.joined()
        )
    }

    func testRelaunchReportsASpawnFailureWithoutQuitting() throws {
        let updater = AppSelfUpdater(
            bundleURL: root.appendingPathComponent("OmniWM.app"),
            opener: root.appendingPathComponent("missing-open"),
            terminate: { XCTFail("quit although the relaunch could not be prepared") }
        )
        XCTAssertThrowsError(try updater.relaunch()) { error in
            guard case let .relaunchUnavailable(status) = error as? AppSelfUpdateError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(status, ENOENT)
        }
        XCTAssertNil(updater.relaunchObserver)
        XCTAssertEqual(updater.suspendedRelaunch, 0)
    }

    func testRelaunchedInstanceWaitsForThePredecessorToExit() async throws {
        let predecessor = Process()
        predecessor.executableURL = URL(fileURLWithPath: "/bin/cat")
        let input = Pipe()
        predecessor.standardInput = input
        try predecessor.run()
        defer { if predecessor.isRunning { predecessor.terminate() } }
        let waiting = expectation(description: "about to wait")
        let returned = expectation(description: "wait returned")
        let identifier = predecessor.processIdentifier
        DispatchQueue.global().async {
            waiting.fulfill()
            XCTAssertTrue(AppRelaunch.awaitExit(of: identifier))
            XCTAssertTrue(Self.hasExited(identifier), "the wait returned before the predecessor exited")
            returned.fulfill()
        }
        await fulfillment(of: [waiting], timeout: failureBound)
        try input.fileHandleForWriting.close()
        await fulfillment(of: [returned], timeout: failureBound)
        predecessor.waitUntilExit()
        XCTAssertTrue(AppRelaunch.awaitExit(of: identifier))
    }

    private nonisolated static func hasExited(_ process: pid_t) -> Bool {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(process), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else { return errno == ECHILD }
        return info.si_pid == process
    }

    func testStartupWithoutARelaunchArgumentDoesNotWait() {
        AppRelaunch.awaitPredecessor(arguments: ["OmniWM"])
        AppRelaunch.awaitPredecessor(arguments: ["OmniWM", AppRelaunch.argument])
        AppRelaunch.awaitPredecessor(arguments: ["OmniWM", AppRelaunch.argument, "not-a-pid"])
        AppRelaunch.awaitPredecessor(arguments: ["OmniWM", AppRelaunch.argument, "0"])
        AppRelaunch.awaitPredecessor(arguments: ["OmniWM", AppRelaunch.argument, "-1"])
    }

    private final class Flag {
        var value = false
    }

    private func release(_ fifo: URL) {
        let writer = open(fifo.path, O_WRONLY | O_NONBLOCK)
        if writer >= 0 { close(writer) }
    }

    private func tag(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["OMNIWMCanaryTag"] as? String
    }

    private func makeApp(in directory: String, tag: String) throws -> URL {
        let app = root.appendingPathComponent(directory).appendingPathComponent("OmniWM.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("OmniWM").path)
        let info: [String: String] = [
            "CFBundleExecutable": "OmniWM", "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": "0.7.7", "OMNIWMCanaryTag": tag
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", identifier, app.path)
        return app
    }

    private func publish(_ app: URL) async throws -> (GitHubRelease, URLSession) {
        let zip = root.appendingPathComponent("update.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zip.path)
        try ZipProtocol.body.withLock { $0 = try Data(contentsOf: zip) }
        let name = "OmniWM-canary-\(newTag).zip"
        let url = URL(string: ReleaseArchive.downloadPrefix + "\(newTag)/\(name)")!
        var release = GitHubRelease(
            tagName: newTag, name: newTag, body: "", releasePageURL: url, publishedAt: Date(), isPrerelease: true
        )
        let digest = try await AppSelfUpdater.sha256(of: zip)
        release.archive = ReleaseArchive(name: name, url: url, digest: "sha256:" + digest, tag: newTag)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZipProtocol.self]
        return (release, URLSession(configuration: configuration))
    }

    private func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, tool)
    }
}
