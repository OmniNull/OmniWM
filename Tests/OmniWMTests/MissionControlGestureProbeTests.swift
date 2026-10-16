// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class MissionControlGestureProbeTests: XCTestCase {
    private let dockDomain = "com.apple.dock"
    private let builtInDomain = "com.apple.AppleMultitouchTrackpad"
    private let bluetoothDomain = "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    private let authoritativeKey = "showMissionControlGestureEnabled"
    private let threeFingerKey = "TrackpadThreeFingerVertSwipeGesture"
    private let fourFingerKey = "TrackpadFourFingerVertSwipeGesture"

    func testAuthoritativeBooleanEnablesAndDisablesProbe() {
        let fixture = Fixture()
        fixture.set(NSNumber(value: true), key: authoritativeKey, domain: dockDomain)
        let probe = fixture.makeProbe()

        probe.refresh()
        XCTAssertEqual(probe.status, .enabled)

        fixture.set(NSNumber(value: false), key: authoritativeKey, domain: dockDomain)
        probe.refresh()
        XCTAssertEqual(probe.status, .disabled)
    }

    func testAuthoritativeFalseOverridesStalePositiveFallback() {
        let fixture = Fixture()
        fixture.set(NSNumber(value: false), key: authoritativeKey, domain: dockDomain)
        fixture.set(NSNumber(value: 2), key: threeFingerKey, domain: builtInDomain)
        fixture.set(NSNumber(value: 2), key: fourFingerKey, domain: bluetoothDomain)
        let probe = fixture.makeProbe()

        probe.refresh()

        XCTAssertEqual(probe.status, .disabled)
    }

    func testEveryTrackpadDomainAndFingerKeyCanEnableFallback() {
        let addresses = [
            Address(key: threeFingerKey, domain: builtInDomain),
            Address(key: fourFingerKey, domain: builtInDomain),
            Address(key: threeFingerKey, domain: bluetoothDomain),
            Address(key: fourFingerKey, domain: bluetoothDomain)
        ]

        for address in addresses {
            let fixture = Fixture()
            fixture.set(NSNumber(value: 2), key: address.key, domain: address.domain)
            let probe = fixture.makeProbe()

            probe.refresh()

            XCTAssertEqual(probe.status, .enabled, "\(address.domain)/\(address.key)")
        }
    }

    func testZeroFallbackDisablesWhenNoPositiveValueExists() {
        let fixture = Fixture()
        fixture.set(NSNumber(value: 0), key: threeFingerKey, domain: builtInDomain)
        fixture.set(NSNumber(value: -1), key: fourFingerKey, domain: bluetoothDomain)
        let probe = fixture.makeProbe()

        probe.refresh()

        XCTAssertEqual(probe.status, .disabled)
    }

    func testMalformedAuthoritativeValueFallsBackToTrackpadDomains() {
        let fixture = Fixture()
        fixture.set(NSNumber(value: 1), key: authoritativeKey, domain: dockDomain)
        fixture.set(NSNumber(value: 2), key: fourFingerKey, domain: bluetoothDomain)
        let probe = fixture.makeProbe()

        probe.refresh()

        XCTAssertEqual(probe.status, .enabled)
    }

    func testMalformedAndNegativeFallbackValuesProduceUnknownStatus() {
        let fixture = Fixture()
        fixture.set("true", key: authoritativeKey, domain: dockDomain)
        fixture.set(NSNumber(value: true), key: threeFingerKey, domain: builtInDomain)
        fixture.set(NSNumber(value: 2.0), key: fourFingerKey, domain: builtInDomain)
        fixture.set("2", key: threeFingerKey, domain: bluetoothDomain)
        fixture.set(NSNumber(value: -1), key: fourFingerKey, domain: bluetoothDomain)
        let probe = fixture.makeProbe()

        probe.refresh()

        XCTAssertEqual(probe.status, .unknown)
    }

    func testUnavailablePreferencesProduceUnknownStatus() {
        let probe = Fixture().makeProbe()

        probe.refresh()

        XCTAssertEqual(probe.status, .unknown)
    }

    func testRefreshSynchronizesEveryDomainBeforeReading() {
        let fixture = Fixture()
        fixture.set(NSNumber(value: true), key: authoritativeKey, domain: dockDomain)
        let probe = fixture.makeProbe()

        probe.refresh()

        XCTAssertEqual(
            Array(fixture.events.prefix(3)),
            [.synchronize(dockDomain), .synchronize(builtInDomain), .synchronize(bluetoothDomain)]
        )
        XCTAssertEqual(fixture.events.dropFirst(3).first, .read(authoritativeKey, dockDomain))
    }

    func testRepeatedRefreshUsesCurrentPreferenceValues() {
        let fixture = Fixture()
        let probe = fixture.makeProbe()

        probe.refresh()
        XCTAssertEqual(probe.status, .unknown)

        fixture.set(NSNumber(value: 2), key: threeFingerKey, domain: builtInDomain)
        probe.refresh()
        XCTAssertEqual(probe.status, .enabled)

        fixture.set(nil, key: threeFingerKey, domain: builtInDomain)
        fixture.set(NSNumber(value: 0), key: fourFingerKey, domain: bluetoothDomain)
        probe.refresh()
        XCTAssertEqual(probe.status, .disabled)
    }

    func testWarningRequiresEnabledVerticalThreeOrFourFingerGesture() {
        let fixture = Fixture()
        fixture.set(NSNumber(value: true), key: authoritativeKey, domain: dockDomain)
        let probe = fixture.makeProbe()
        probe.refresh()

        XCTAssertFalse(probe.shouldWarn(axis: .vertical, fingerCount: .two))
        XCTAssertTrue(probe.shouldWarn(axis: .vertical, fingerCount: .three))
        XCTAssertTrue(probe.shouldWarn(axis: .vertical, fingerCount: .four))
        XCTAssertFalse(probe.shouldWarn(axis: .horizontal, fingerCount: .three))
        XCTAssertFalse(probe.shouldWarn(axis: .horizontal, fingerCount: .four))
    }

    func testWarningIsHiddenForDisabledAndUnknownStatus() {
        let disabledFixture = Fixture()
        disabledFixture.set(NSNumber(value: false), key: authoritativeKey, domain: dockDomain)
        let disabledProbe = disabledFixture.makeProbe()
        disabledProbe.refresh()

        XCTAssertFalse(disabledProbe.shouldWarn(axis: .vertical, fingerCount: .three))

        let unknownProbe = Fixture().makeProbe()
        unknownProbe.refresh()

        XCTAssertFalse(unknownProbe.shouldWarn(axis: .vertical, fingerCount: .four))
    }

    func testDisabledWorkspaceSwipeStillWarnsWhenCollisionForcesEffectiveAxisVertical() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissionControlGestureProbeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        settings.gestures.scrollEnabled = true
        settings.gestures.fingerCount = .three
        settings.gestures.workspaceSwipeEnabled = false
        settings.gestures.workspaceSwipeFingerCount = .three
        settings.gestures.workspaceSwipeAxis = .horizontal

        let fixture = Fixture()
        fixture.set(NSNumber(value: true), key: authoritativeKey, domain: dockDomain)
        let probe = fixture.makeProbe()
        probe.refresh()

        XCTAssertTrue(settings.gestures.workspaceSwipeAxisLockedToVertical)
        XCTAssertEqual(settings.gestures.effectiveWorkspaceSwipeAxis, .vertical)
        XCTAssertTrue(probe.shouldWarn(
            axis: settings.gestures.effectiveWorkspaceSwipeAxis,
            fingerCount: settings.gestures.workspaceSwipeFingerCount
        ))
    }

    func testSettingsPaneRefreshesProbeOnAppearanceAndAppReactivation() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissionControlGestureProbeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let controller = WMController(settings: settings)
        let fixture = Fixture()
        fixture.set(NSNumber(value: false), key: authoritativeKey, domain: dockDomain)
        let probe = fixture.makeProbe()
        let hostingView = NSHostingView(rootView: MouseTrackpadSettingsTab(
            settings: settings,
            controller: controller,
            missionControlGestureProbe: probe
        ).environment(SettingsNavigationModel()))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        XCTAssertEqual(probe.status, .disabled)

        fixture.set(NSNumber(value: true), key: authoritativeKey, domain: dockDomain)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        XCTAssertEqual(probe.status, .enabled)
        withExtendedLifetime(window) {}
    }

    func testOpenTrackpadSettingsHandsExactURLToOpener() throws {
        let fixture = Fixture()
        let probe = fixture.makeProbe()

        probe.openTrackpadSettings()

        let opened = try XCTUnwrap(fixture.openedURLs.first)
        XCTAssertEqual(fixture.openedURLs.count, 1)
        XCTAssertEqual(opened.absoluteString, MissionControlGestureProbe.trackpadSettingsURLString)
    }
}

@MainActor
private final class Fixture {
    var events: [Event] = []
    var openedURLs: [URL] = []
    private var values: [Address: Any] = [:]

    func set(_ value: Any?, key: String, domain: String) {
        let address = Address(key: key, domain: domain)
        if let value {
            values[address] = value
        } else {
            values.removeValue(forKey: address)
        }
    }

    func makeProbe() -> MissionControlGestureProbe {
        MissionControlGestureProbe(
            preferenceReader: { [self] key, domain in
                events.append(.read(key, domain))
                return values[Address(key: key, domain: domain)]
            },
            domainSynchronizer: { [self] domain in
                events.append(.synchronize(domain))
            },
            urlOpener: { [self] url in
                openedURLs.append(url)
            }
        )
    }
}

private struct Address: Hashable {
    let key: String
    let domain: String
}

private enum Event: Equatable {
    case synchronize(String)
    case read(String, String)
}
