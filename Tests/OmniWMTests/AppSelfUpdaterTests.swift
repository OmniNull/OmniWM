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
        try XCTSkipIf(getuid() == 0, "root writes through read-only permissions")
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
            await fulfillment(of: [stopped], timeout: 5)
        }
    }

    func testRequirementAlwaysDemandsNotarization() throws {
        XCTAssertEqual(AppSelfUpdater.notarized("anchor apple"), "(anchor apple) and notarized")
        XCTAssertTrue(try AppSelfUpdater.runningAppRequirement().hasSuffix(") and notarized"))
    }

    func testRelaunchOpensOnlyAfterTerminationIsConfirmedAndTheOldProcessExits() async throws {
        let opener = root.appendingPathComponent("open.sh")
        let opened = root.appendingPathComponent("opened")
        try "#!/bin/sh\necho \"$1\" > \"\(opened.path)\"\n".write(to: opener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        let app = root.appendingPathComponent("OmniWM.app")
        let target = Process()
        target.executableURL = URL(fileURLWithPath: "/bin/cat")
        target.standardInput = Pipe()
        try target.run()
        defer { target.terminate() }
        let relaunchReturned = Flag()
        let terminated = Flag()
        var onTerminate: () -> Void = {}
        let updater = AppSelfUpdater(
            bundleURL: app, processIdentifier: target.processIdentifier, opener: opener,
            terminate: {
                XCTAssertTrue(relaunchReturned.value, "terminate ran inside relaunch")
                terminated.value = true
                onTerminate()
            }
        )

        for confirmed in [false, true] {
            relaunchReturned.value = false
            terminated.value = false
            let quitReturned = expectation(description: "quit returned")
            onTerminate = { quitReturned.fulfill() }
            try updater.relaunch()
            relaunchReturned.value = true
            XCTAssertFalse(terminated.value)
            let helper = try XCTUnwrap(updater.relaunchHelper)
            XCTAssertTrue(helper.isRunning)
            let exited = expectation(description: "helper exited")
            helper.terminationHandler = { _ in exited.fulfill() }

            if confirmed {
                updater.confirmRelaunch()
                await fulfillment(of: [quitReturned], timeout: 5)
                XCTAssertFalse(FileManager.default.fileExists(atPath: opened.path))
                target.terminate()
                target.waitUntilExit()
            } else {
                await fulfillment(of: [quitReturned], timeout: 5)
            }
            await fulfillment(of: [exited], timeout: 5)
            XCTAssertNil(updater.relaunchHelper)
            XCTAssertNil(updater.relaunchSignal)
            XCTAssertEqual(FileManager.default.fileExists(atPath: opened.path), confirmed)
        }
        XCTAssertEqual(try String(contentsOf: opened, encoding: .utf8), app.path + "\n")
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
