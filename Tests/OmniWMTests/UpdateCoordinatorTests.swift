// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

private let installedCanaryTag = "canary-20261024-0439-40061526227-1"
private let nextCanaryTag = "canary-20261025-0437-40161156174-1"

private func makeRelease(_ tag: String, published: Double, draft: Bool = false) -> GitHubRelease {
    GitHubRelease(
        tagName: tag,
        name: tag,
        body: "Release notes",
        releasePageURL: URL(string: "https://github.com/OmniNull/OmniWM/releases/tag/\(tag)")!,
        publishedAt: Date(timeIntervalSince1970: published),
        isPrerelease: tag.hasPrefix("canary-") || tag.hasPrefix("beta-"),
        isDraft: draft
    )
}

private func canaryArchive() -> ReleaseArchive? {
    let url = URL(string: ReleaseArchive.downloadPrefix + "\(nextCanaryTag)/OmniWM-canary-\(nextCanaryTag).zip")!
    return ReleaseArchive(
        name: url.lastPathComponent, url: url, digest: "sha256:" + String(repeating: "a", count: 64), tag: nextCanaryTag
    )
}

final class GitHubReleaseUpdateTests: XCTestCase {
    func testCanaryComparesEmbeddedTagWithoutInstalledReleaseRecord() {
        let newer = makeRelease(nextCanaryTag, published: 100)
        XCTAssertTrue(newer.isNewer(than: installedCanaryTag))
        XCTAssertFalse(newer.isNewer(than: nextCanaryTag))
        XCTAssertFalse(makeRelease(installedCanaryTag, published: 900).isNewer(than: nextCanaryTag))
        XCTAssertEqual(newer.homebrewUpdateCommand, "brew upgrade --cask omniwm@canary")
        XCTAssertEqual(newer.skipKey, nextCanaryTag)
    }

    func testCanaryRerunsUseNumericAttemptOrderAndAcceptLegacyTags() {
        let newer = makeRelease("canary-20261025-0437-40161156174-10", published: 100)
        XCTAssertTrue(newer.isNewer(than: "canary-20261025-0437-40161156174-9"))
        XCTAssertTrue(newer.isNewer(than: "canary-20261025-0437"))
        XCTAssertTrue(makeRelease("canary-20261026-0437", published: 200).isNewer(than: newer.tagName))
    }

    func testStableKeepsNumericComparisonAndRejectsCrossChannelUpdates() {
        let stable = makeRelease("v0.7.10", published: 100)
        let canary = makeRelease(nextCanaryTag, published: 200)
        XCTAssertTrue(stable.isNewer(than: "0.7.9"))
        XCTAssertFalse(stable.isNewer(than: "0.7.10"))
        XCTAssertFalse(stable.isNewer(than: "0.7.11"))
        XCTAssertFalse(stable.isNewer(than: installedCanaryTag))
        XCTAssertFalse(canary.isNewer(than: "0.7.6"))
        XCTAssertFalse(canary.isNewer(than: "canary-invalid"))
        XCTAssertFalse(makeRelease(nextCanaryTag, published: 300, draft: true).isNewer(than: installedCanaryTag))
        XCTAssertEqual(stable.homebrewUpdateCommand, "brew upgrade omniwm")
        XCTAssertEqual(stable.skipKey, "0.7.10")
    }

    func testBundleChannelComesFromExplicitCanaryMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, tag) in [nil, installedCanaryTag, "v0.7.6", "canary-invalid"].enumerated() {
            let bundleURL = directory.appendingPathComponent("Test\(index).app")
            let contents = bundleURL.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info = ["CFBundleIdentifier": "app.test.\(UUID().uuidString)", "CFBundleShortVersionString": "0.7.6"]
            info["OMNIWMCanaryTag"] = tag
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let bundle = try XCTUnwrap(Bundle(url: bundleURL))
            XCTAssertEqual(bundle.appVersion, "0.7.6")
            XCTAssertEqual(bundle.canaryReleaseTag, tag == installedCanaryTag ? tag : nil)
        }
    }
}

@MainActor
final class UpdateCoordinatorTests: XCTestCase {
    private final class ReleaseStub: GitHubReleaseFetching {
        let release: GitHubRelease?
        let expectedCanary: Bool

        init(_ release: GitHubRelease?, expectedCanary: Bool) {
            self.release = release
            self.expectedCanary = expectedCanary
        }

        func fetchLatestRelease(forCanary: Bool) async throws -> GitHubRelease? {
            XCTAssertEqual(forCanary, expectedCanary)
            return release
        }
    }

    private var retainedCoordinators: [UpdateCoordinator] = []

    private final class WindowStub: UpdateWindowControlling {
        var onWindowClosedWithoutAction: (() -> Void)?
        var configuration: UpdatePopupConfiguration?
        var onEvent: (() -> Void)?
        var alertTitle: String?

        func show(configuration: UpdatePopupConfiguration) {
            self.configuration = configuration
            onEvent?()
        }

        func close(markingActionHandled: Bool) {}
    }

    private final class InstallerStub: AppUpdateInstalling {
        var canInstall = true
        var failure: Error?
        var relaunchFailure: Error?
        var suspends = false
        var installed = false
        var events: [String] = []
        var onInstall: (() -> Void)?
        var onRelaunch: (() -> Void)?
        var onFinish: (() -> Void)?
        var gates: [CheckedContinuation<Void, Never>] = []

        func isInstalled(_ release: GitHubRelease) -> Bool {
            installed
        }

        func install(_ release: GitHubRelease) async throws {
            events.append("install")
            defer { onFinish?() }
            onInstall?()
            if suspends {
                await withCheckedContinuation { gates.append($0) }
            } else {
                await Task.yield()
            }
            try Task.checkCancellation()
            if let failure { throw failure }
            installed = true
        }

        func relaunch() throws {
            events.append("relaunch")
            onRelaunch?()
            if let relaunchFailure { throw relaunchFailure }
        }
    }

    func testInstallIsOfferedOnlyForWritableBundleWithVerifiedArchive() async throws {
        let archive = canaryArchive()
        let offers: [String: (ReleaseArchive?, Bool)] = [
            "archive and writable": (archive, true),
            "no archive": (nil, true),
            "read-only bundle": (archive, false)
        ]
        for (name, (archive, writable)) in offers {
            let window = WindowStub()
            let shown = expectation(description: name)
            window.onEvent = { shown.fulfill() }
            let installer = InstallerStub()
            installer.canInstall = writable
            let (coordinator, _) = makeCoordinator(window: window, canary: true, archive: archive, installer: installer)
            coordinator.checkForUpdatesManually()
            await fulfillment(of: [shown], timeout: 2)
            XCTAssertEqual(window.configuration?.installUpdate != nil, name == "archive and writable", name)
        }
    }

    func testInstallRelaunchesOnlyAfterSuccessReportsFailuresAndCanBeRetried() async throws {
        let modes: [String: ([String], [String])] = [
            "install fails": (["install"], ["install", "install"]),
            "relaunch fails": (["install", "relaunch"], ["install", "relaunch", "relaunch"]),
            "quit cancelled": (["install", "relaunch"], ["install", "relaunch", "relaunch"])
        ]
        for (mode, (first, retried)) in modes {
            let window = WindowStub()
            let installer = InstallerStub()
            installer.failure = mode == "install fails" ? AppSelfUpdateError.digestMismatch : nil
            installer.relaunchFailure = mode == "relaunch fails" ? AppSelfUpdateError.missingApp : nil
            let install = try await showInstall(window: window, installer: installer)
            let signals = mode == "relaunch fails" ? 2 : 1

            for expectedEvents in [first, retried] {
                window.alertTitle = nil
                let finished = expectation(description: mode)
                finished.expectedFulfillmentCount = signals
                window.onEvent = { finished.fulfill() }
                installer.onRelaunch = { finished.fulfill() }
                install()
                install()
                await fulfillment(of: [finished], timeout: 2)
                XCTAssertEqual(installer.events, expectedEvents, mode)
                XCTAssertEqual(window.alertTitle, mode == "quit cancelled" ? nil : "Could Not Install Update", mode)
            }
        }
    }

    func testDecliningDuringInstallCancelsTheRelaunch() async throws {
        for action in ["not now", "skip", "close", "release page"] {
            let window = WindowStub()
            let installer = InstallerStub()
            installer.suspends = true
            let install = try await showInstall(window: window, installer: installer)
            let configuration = try XCTUnwrap(window.configuration)

            let started = expectation(description: "\(action) started")
            installer.onInstall = { started.fulfill() }
            install()
            await fulfillment(of: [started], timeout: 2)
            switch action {
            case "not now": configuration.notNow()
            case "skip": configuration.skipThisVersion()
            case "release page": configuration.openReleasePage()
            default: window.onWindowClosedWithoutAction?()
            }

            let finished = expectation(description: "\(action) finished")
            installer.onFinish = { finished.fulfill() }
            window.onEvent = nil
            installer.gates.removeFirst().resume()
            await fulfillment(of: [finished], timeout: 2)
            installer.onFinish = nil
            XCTAssertEqual(installer.events, ["install"], action)
            XCTAssertNil(window.alertTitle, action)

            let relaunched = expectation(description: "\(action) retried")
            installer.onRelaunch = { relaunched.fulfill() }
            installer.suspends = false
            installer.onInstall = nil
            window.onEvent = nil
            install()
            await fulfillment(of: [relaunched], timeout: 2)
            XCTAssertEqual(installer.events, ["install", "install", "relaunch"], action)
        }
    }

    func testInstallAfterADeclineStartsWhileTheDeclinedOneIsStillFinishing() async throws {
        let window = WindowStub()
        let installer = InstallerStub()
        installer.suspends = true
        let install = try await showInstall(window: window, installer: installer)
        let configuration = try XCTUnwrap(window.configuration)
        window.onEvent = nil

        for name in ["declined", "retried"] {
            let started = expectation(description: "\(name) started")
            installer.onInstall = { started.fulfill() }
            install()
            await fulfillment(of: [started], timeout: 2)
            if name == "declined" { configuration.notNow() }
        }
        installer.onInstall = nil

        let declinedFinished = expectation(description: "declined finished")
        installer.onFinish = { declinedFinished.fulfill() }
        installer.gates.removeFirst().resume()
        await fulfillment(of: [declinedFinished], timeout: 2)
        installer.onFinish = nil
        install()
        XCTAssertEqual(installer.events, ["install", "install"])

        let relaunched = expectation(description: "relaunched")
        installer.onRelaunch = { relaunched.fulfill() }
        installer.gates.removeFirst().resume()
        await fulfillment(of: [relaunched], timeout: 2)
        XCTAssertEqual(installer.events, ["install", "install", "relaunch"])
        XCTAssertNil(window.alertTitle)
    }

    private func showInstall(window: WindowStub, installer: InstallerStub) async throws -> () -> Void {
        let shown = expectation(description: "shown")
        window.onEvent = { shown.fulfill() }
        let (coordinator, _) = makeCoordinator(
            window: window, canary: true, archive: canaryArchive(), installer: installer
        )
        coordinator.checkForUpdatesManually()
        await fulfillment(of: [shown], timeout: 2)
        retainedCoordinators.append(coordinator)
        return try XCTUnwrap(window.configuration?.installUpdate)
    }

    func testCanaryPopupCopiesCanaryCommandAndSkipsOnlyItsExactRelease() async throws {
        let window = WindowStub()
        let shown = expectation(description: "Canary update shown")
        window.onEvent = { shown.fulfill() }
        var command: String?
        let (coordinator, runtime) = makeCoordinator(window: window, canary: true, copiedCommand: { command = $0 })

        coordinator.checkForUpdatesManually()
        await fulfillment(of: [shown], timeout: 2)

        let configuration = try XCTUnwrap(window.configuration)
        XCTAssertEqual(configuration.currentVersion, installedCanaryTag)
        XCTAssertEqual(configuration.latestVersion, nextCanaryTag)
        configuration.copyCommand()
        XCTAssertEqual(command, "brew upgrade --cask omniwm@canary")
        configuration.skipThisVersion()
        XCTAssertEqual(runtime.updaterSkippedReleaseTag, nextCanaryTag)

        window.onEvent = nil
        window.configuration = nil
        coordinator.checkForUpdatesManually()
        XCTAssertEqual(window.configuration?.latestVersion, nextCanaryTag)
    }

    func testStablePopupKeepsStableChannelAndCommand() async throws {
        let window = WindowStub()
        let shown = expectation(description: "Stable update shown")
        window.onEvent = { shown.fulfill() }
        let (coordinator, _) = makeCoordinator(window: window, canary: false)

        coordinator.checkForUpdatesManually()
        await fulfillment(of: [shown], timeout: 2)

        XCTAssertEqual(window.configuration?.latestVersion, "0.7.7")
        XCTAssertEqual(window.configuration?.homebrewUpdateCommand, "brew upgrade omniwm")
    }

    func testMissingPublishedCanaryShowsUpToDateWithoutPopup() async {
        let window = WindowStub()
        let checked = expectation(description: "No Canary update available")
        window.onEvent = { checked.fulfill() }
        let (coordinator, _) = makeCoordinator(window: window, canary: true, noRelease: true)

        coordinator.checkForUpdatesManually()
        await fulfillment(of: [checked], timeout: 2)

        XCTAssertEqual(window.alertTitle, "You're Up to Date")
        XCTAssertNil(window.configuration)
    }

    func testInstalledVersionChangeInvalidatesCachedCanaryUpdate() async {
        let window = WindowStub()
        let shown = expectation(description: "Canary update shown")
        window.onEvent = { shown.fulfill() }
        var installedVersion = installedCanaryTag
        let (coordinator, _) = makeCoordinator(
            window: window, canary: true, currentVersion: { installedVersion }
        )
        coordinator.checkForUpdatesManually()
        await fulfillment(of: [shown], timeout: 2)

        installedVersion = nextCanaryTag
        window.configuration = nil
        let checked = expectation(description: "Installed Canary is up to date")
        window.onEvent = { checked.fulfill() }
        coordinator.checkForUpdatesManually()
        await fulfillment(of: [checked], timeout: 2)

        XCTAssertEqual(window.alertTitle, "You're Up to Date")
        XCTAssertNil(window.configuration)
    }

    private func makeCoordinator(
        window: WindowStub, canary: Bool, noRelease: Bool = false,
        currentVersion: (() -> String?)? = nil, copiedCommand: @escaping (String) -> Void = { _ in },
        archive: ReleaseArchive? = nil, installer: InstallerStub = InstallerStub()
    ) -> (UpdateCoordinator, RuntimeStateStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let runtime = RuntimeStateStore(directory: directory, deferSaves: false)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: runtime, autosaveEnabled: false
        )
        var release = makeRelease(canary ? nextCanaryTag : "v0.7.7", published: 200)
        release.archive = archive
        let service = ReleaseStub(noRelease ? nil : release, expectedCanary: canary)
        return (UpdateCoordinator(
            settings: settings, runtimeState: runtime, releaseService: service,
            currentVersionProvider: currentVersion ?? { canary ? installedCanaryTag : "0.7.6" },
            windowController: window,
            infoAlertPresenter: { title, _ in window.alertTitle = title
                window.onEvent?()
            },
            openURL: { _ in }, copyCommandToPasteboard: copiedCommand, installer: installer
        ), runtime)
    }
}
