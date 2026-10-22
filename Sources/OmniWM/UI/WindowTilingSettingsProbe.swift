// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreFoundation
import Foundation
import Observation

@MainActor
@Observable
final class WindowTilingSettingsProbe {
    enum Setting: CaseIterable, Equatable {
        case screenEdges
        case menuBar
        case optionKey

        var preferenceKey: String {
            switch self {
            case .screenEdges: "EnableTilingByEdgeDrag"
            case .menuBar: "EnableTopTilingByEdgeDrag"
            case .optionKey: "EnableTilingOptionAccelerator"
            }
        }

        var localizedName: String {
            switch self {
            case .screenEdges: String(localized: "Drag windows to screen edges to tile")
            case .menuBar: String(localized: "Drag windows to menu bar to fill screen")
            case .optionKey: String(localized: "Hold ⌥ key while dragging windows to tile")
            }
        }
    }

    static let desktopAndDockSettingsURLString = "x-apple.systempreferences:com.apple.Desktop-Settings.extension"

    private static let windowManagerDomain = "com.apple.WindowManager"

    private(set) var enabledSettings: [Setting] = []

    private let preferenceReader: @MainActor (String, String) -> Any?
    private let domainSynchronizer: @MainActor (String) -> Void
    private let urlOpener: @MainActor (URL) -> Void

    init(
        preferenceReader: @MainActor @escaping (String, String) -> Any? = { key, domain in
            let preferenceKey: CFString = key as NSString
            let applicationID: CFString = domain as NSString
            return CFPreferencesCopyAppValue(preferenceKey, applicationID)
        },
        domainSynchronizer: @MainActor @escaping (String) -> Void = { domain in
            let applicationID: CFString = domain as NSString
            CFPreferencesAppSynchronize(applicationID)
        },
        urlOpener: @MainActor @escaping (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.preferenceReader = preferenceReader
        self.domainSynchronizer = domainSynchronizer
        self.urlOpener = urlOpener
    }

    func refresh() {
        domainSynchronizer(Self.windowManagerDomain)
        enabledSettings = Setting.allCases.filter { setting in
            Self.booleanValue(preferenceReader(setting.preferenceKey, Self.windowManagerDomain)) ?? true
        }
    }

    func openDesktopAndDockSettings() {
        guard let url = URL(string: Self.desktopAndDockSettingsURLString) else { return }
        urlOpener(url)
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        return number.boolValue
    }
}
