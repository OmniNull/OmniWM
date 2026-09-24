// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreFoundation
import Foundation
import Observation

@MainActor
@Observable
final class GlobalWindowCornerPreferences {
    enum State: Equatable {
        case systemDefault
        case custom(Double)
        case mixed
        case malformed
        case outOfRange
    }

    @MainActor
    struct Operations {
        let copyMultiple: @MainActor () -> [String: Any]
        let setMultiple: @MainActor ([String: Any], [String]) -> Void
        let synchronize: @MainActor () -> Bool
        let isForced: @MainActor (String) -> Bool

        static var live: Operations {
            Operations(
                copyMultiple: {
                    let values = CFPreferencesCopyMultiple(
                        GlobalWindowCornerPreferences.keys as CFArray,
                        kCFPreferencesAnyApplication,
                        kCFPreferencesCurrentUser,
                        kCFPreferencesAnyHost
                    )
                    return values as NSDictionary as? [String: Any] ?? [:]
                },
                setMultiple: { values, removedKeys in
                    let valuesToSet: CFDictionary? = values.isEmpty ? nil : values as CFDictionary
                    let keysToRemove: CFArray? = removedKeys.isEmpty ? nil : removedKeys as CFArray
                    CFPreferencesSetMultiple(
                        valuesToSet,
                        keysToRemove,
                        kCFPreferencesAnyApplication,
                        kCFPreferencesCurrentUser,
                        kCFPreferencesAnyHost
                    )
                },
                synchronize: {
                    CFPreferencesSynchronize(
                        kCFPreferencesAnyApplication,
                        kCFPreferencesCurrentUser,
                        kCFPreferencesAnyHost
                    )
                },
                isForced: { key in
                    UserDefaults.standard.objectIsForced(forKey: key, inDomain: UserDefaults.globalDomain)
                }
            )
        }
    }

    static let standardWindowKey = "NSConvolutionOverride1"
    static let panelWindowKey = "NSConvolutionOverride2"
    static let keys = [standardWindowKey, panelWindowKey]
    static let defaultDraftRadius = 16.0
    static let squareStoredRadius = 0.01
    static let radiusRange = 0.0 ... 64.0
    static let relaunchMessage = String(localized: "Fully quit and reopen affected apps to apply.")

    private(set) var state: State = .systemDefault
    private(set) var draftRadius = defaultDraftRadius
    private(set) var isManaged = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    let isSupported: Bool

    @ObservationIgnored private let operations: Operations
    @ObservationIgnored private var isEditingSlider = false
    @ObservationIgnored private var lastConfirmedObservation: ConfirmedObservation?
    @ObservationIgnored private var hasRefreshFailure = false

    init(
        operations: Operations = .live,
        isSupported: Bool = GlobalWindowCornerPreferences.systemSupportsFeature
    ) {
        self.operations = operations
        self.isSupported = isSupported
        refresh()
    }

    func refresh() {
        guard operations.synchronize() else {
            reportFailure(
                String(localized: "Couldn’t refresh the macOS window corner setting."),
                isRefreshFailure: true
            )
            return
        }

        let managed = Self.keys.contains(where: operations.isForced)
        let snapshot = readSnapshot()
        let observation = ConfirmedObservation(snapshot: snapshot, isManaged: managed)
        if hasRefreshFailure || lastConfirmedObservation.map({ !$0.semanticallyEquals(observation) }) == true {
            clearFeedback()
        }
        isManaged = managed
        load(snapshot: snapshot)
        lastConfirmedObservation = observation
    }

    func chooseSystemDefault() {
        apply(values: [:], removedKeys: Self.keys, expected: .systemDefault)
    }

    func chooseCustom() {
        setCustomRadius(draftRadius)
    }

    func beginSliderEditing() {
        isEditingSlider = true
    }

    func updateDraftRadius(_ radius: Double) {
        guard radius.isFinite else { return }
        draftRadius = min(Self.radiusRange.upperBound, max(Self.radiusRange.lowerBound, radius))
    }

    func sliderValueChanged(_ radius: Double) {
        updateDraftRadius(radius)
        guard !isEditingSlider else { return }
        setCustomRadius(draftRadius)
    }

    func endSliderEditing() {
        guard isEditingSlider else { return }
        isEditingSlider = false
        setCustomRadius(draftRadius)
    }

    func cancelSliderEditing() {
        isEditingSlider = false
    }

    func setCustomRadius(_ radius: Double) {
        guard radius.isFinite,
              Self.radiusRange.contains(radius),
              radius == 0 || radius >= Self.squareStoredRadius
        else {
            reportFailure(String(localized: "Choose Square or a corner radius from 0.01 to 64 points."))
            return
        }

        let storedRadius = radius == 0 ? Self.squareStoredRadius : radius
        let values = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, NSNumber(value: storedRadius)) })
        apply(values: values, removedKeys: [], expected: .custom(radius))
    }

    private func apply(values: [String: Any], removedKeys: [String], expected: State) {
        guard isSupported else {
            reportFailure(String(localized: "App window corner controls require macOS 26.4 or later."))
            return
        }
        guard operations.synchronize() else {
            reportFailure(String(localized: "Couldn’t refresh the macOS window corner setting, so no change was made."))
            return
        }

        let previous = readSnapshot()
        isManaged = Self.keys.contains(where: operations.isForced)
        guard !isManaged else {
            load(snapshot: previous)
            lastConfirmedObservation = ConfirmedObservation(snapshot: previous, isManaged: true)
            reportFailure(String(localized: "This setting is managed by your organization."))
            return
        }

        operations.setMultiple(values, removedKeys)
        guard operations.synchronize() else {
            load(snapshot: previous)
            lastConfirmedObservation = ConfirmedObservation(snapshot: previous, isManaged: false)
            reportFailure(
                String(localized: "macOS could not confirm the window corner change. Its current value is unknown.")
            )
            return
        }

        let confirmed = readSnapshot()
        load(snapshot: confirmed)
        lastConfirmedObservation = ConfirmedObservation(snapshot: confirmed, isManaged: false)
        guard Self.decode(confirmed) == expected else {
            reportFailure(
                String(
                    localized: "The macOS window corner setting differs from the requested value. The current value was reloaded."
                )
            )
            return
        }

        clearFeedback()
        successMessage = Self.relaunchMessage
    }

    private func reportFailure(_ message: String, isRefreshFailure: Bool = false) {
        errorMessage = message
        successMessage = nil
        hasRefreshFailure = isRefreshFailure
    }

    private func clearFeedback() {
        errorMessage = nil
        successMessage = nil
        hasRefreshFailure = false
    }

    private func readSnapshot() -> Snapshot {
        Snapshot(values: operations.copyMultiple())
    }

    private func load(snapshot: Snapshot) {
        state = Self.decode(snapshot)
        guard !isEditingSlider, case let .custom(radius) = state else { return }
        draftRadius = radius
    }

    private static func decode(_ snapshot: Snapshot) -> State {
        let standardValue = snapshot.values[standardWindowKey] ?? nil
        let panelValue = snapshot.values[panelWindowKey] ?? nil

        switch (standardValue, panelValue) {
        case (nil, nil):
            return .systemDefault
        case (nil, _),
             (_, nil):
            return .mixed
        case let (standard?, panel?):
            guard let standardRadius = numericValue(standard),
                  let panelRadius = numericValue(panel)
            else {
                return .malformed
            }
            guard standardRadius == panelRadius else { return .mixed }
            guard standardRadius >= squareStoredRadius,
                  standardRadius <= radiusRange.upperBound
            else {
                return .outOfRange
            }
            return .custom(standardRadius == squareStoredRadius ? 0 : standardRadius)
        }
    }

    private static func numericValue(_ value: Any) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID()
        else {
            return nil
        }
        var result = 0.0
        guard CFNumberGetValue(number, .doubleType, &result), result.isFinite else { return nil }
        return result
    }

    private static var systemSupportsFeature: Bool {
        if #available(macOS 26.4, *) {
            true
        } else {
            false
        }
    }
}

extension GlobalWindowCornerPreferences {
    @MainActor
    private struct Snapshot {
        let values: [String: Any]

        func semanticallyEquals(_ other: Snapshot) -> Bool {
            SemanticValue(values[GlobalWindowCornerPreferences.standardWindowKey])
                == SemanticValue(other.values[GlobalWindowCornerPreferences.standardWindowKey])
                && SemanticValue(values[GlobalWindowCornerPreferences.panelWindowKey])
                == SemanticValue(other.values[GlobalWindowCornerPreferences.panelWindowKey])
        }
    }

    @MainActor
    private enum SemanticValue: Equatable {
        case absent
        case number(Double)
        case malformed(CFTypeID, String)

        init(_ value: Any?) {
            guard let value else {
                self = .absent
                return
            }
            if let number = GlobalWindowCornerPreferences.numericValue(value) {
                self = .number(number)
                return
            }
            self = .malformed(CFGetTypeID(value as CFTypeRef), String(reflecting: value))
        }
    }

    @MainActor
    private struct ConfirmedObservation {
        let snapshot: Snapshot
        let isManaged: Bool

        func semanticallyEquals(_ other: ConfirmedObservation) -> Bool {
            isManaged == other.isManaged
                && snapshot.semanticallyEquals(other.snapshot)
        }
    }
}
