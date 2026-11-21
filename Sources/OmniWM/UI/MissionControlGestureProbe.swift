// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreFoundation
import Foundation
import Observation

@MainActor
@Observable
final class MissionControlGestureProbe {
    enum Status: Equatable {
        case enabled
        case disabled
        case unknown
    }

    static let trackpadSettingsURLString = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"

    private static let dockDomain = "com.apple.dock"
    private static let builtInTrackpadDomain = "com.apple.AppleMultitouchTrackpad"
    private static let bluetoothTrackpadDomain = "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    private static let missionControlGestureKey = "showMissionControlGestureEnabled"
    private static let verticalSwipeKeys = [
        "TrackpadThreeFingerVertSwipeGesture",
        "TrackpadFourFingerVertSwipeGesture"
    ]
    private static let preferenceDomains = [dockDomain, builtInTrackpadDomain, bluetoothTrackpadDomain]
    private static let trackpadDomains = [builtInTrackpadDomain, bluetoothTrackpadDomain]

    private(set) var status: Status = .unknown

    private let preferenceReader: @MainActor (String, String) -> Any?
    private let domainSynchronizer: @MainActor (String) -> Void
    private let urlOpener: @MainActor (URL) -> Void

    init(
        preferenceReader: @MainActor @escaping (String, String) -> Any? = MissionControlGestureProbe.readPreference,
        domainSynchronizer: @MainActor @escaping (String) -> Void = MissionControlGestureProbe.synchronizePreferences,
        urlOpener: @MainActor @escaping (URL) -> Void = MissionControlGestureProbe.openURL
    ) {
        self.preferenceReader = preferenceReader
        self.domainSynchronizer = domainSynchronizer
        self.urlOpener = urlOpener
    }

    static func readPreference(_ key: String, in domain: String) -> Any? {
        let preferenceKey: CFString = key as NSString
        let applicationID: CFString = domain as NSString
        return CFPreferencesCopyAppValue(preferenceKey, applicationID)
    }

    static func synchronizePreferences(in domain: String) {
        let applicationID: CFString = domain as NSString
        CFPreferencesAppSynchronize(applicationID)
    }

    static func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func refresh() {
        for domain in Self.preferenceDomains {
            domainSynchronizer(domain)
        }

        if let enabled = Self.booleanValue(
            preferenceReader(Self.missionControlGestureKey, Self.dockDomain)
        ) {
            status = enabled ? .enabled : .disabled
            return
        }

        var foundNonnegativeValue = false
        for domain in Self.trackpadDomains {
            for key in Self.verticalSwipeKeys {
                guard let value = Self.integerValue(preferenceReader(key, domain)), value >= 0 else { continue }
                if value > 0 {
                    status = .enabled
                    return
                }
                foundNonnegativeValue = true
            }
        }
        status = foundNonnegativeValue ? .disabled : .unknown
    }

    func shouldWarn(axis: WorkspaceSwipeAxis, fingerCount: GestureFingerCount) -> Bool {
        guard status == .enabled, axis == .vertical else { return false }
        return fingerCount == .three || fingerCount == .four
    }

    func openTrackpadSettings() {
        guard let url = URL(string: Self.trackpadSettingsURLString) else { return }
        urlOpener(url)
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.boolValue
    }

    private static func integerValue(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number)
        else {
            return nil
        }
        var result: Int64 = 0
        guard CFNumberGetValue(number, .sInt64Type, &result) else { return nil }
        return result
    }
}
