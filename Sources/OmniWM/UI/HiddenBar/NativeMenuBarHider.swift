// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class NativeMenuBarHider {
    private struct Ownership {
        var original: Bool
        var applied: Bool
        var pending: Bool?

        mutating func observe(_ current: Bool) {
            if current != applied, current != pending {
                original = current
            }
            applied = current
            pending = nil
        }
    }

    private static let logger = Logger(subsystem: "com.barut.OmniWM", category: "HiddenBar")
    private let preferences: NativeMenuBarPreferences?
    private let journalURL: URL?
    @ObservationIgnored private var ownership: [String: Ownership] = [:]
    @ObservationIgnored private var journalLoaded = false
    @ObservationIgnored private var verifiedVisibility: [String: Bool] = [:]
    private(set) var available = false

    init(preferences: NativeMenuBarPreferences? = nil, journalURL: URL? = nil) {
        self.preferences = preferences
        self.journalURL = journalURL
        refreshAvailability()
    }

    static func live(in stateDirectory: URL) -> NativeMenuBarHider {
        NativeMenuBarHider(
            preferences: .live,
            journalURL: stateDirectory.appendingPathComponent("hidden-bar-visibility.json")
        )
    }

    func refreshAvailability() {
        guard let preferences else { return }
        do {
            _ = try NativeMenuBarApplications(data: preferences.read())
            available = true
        } catch {
            available = false
        }
    }

    func isRevealed(_ bundleID: String) -> Bool {
        verifiedVisibility[bundleID] == true
    }

    @discardableResult
    func apply(
        configuredBundleIDs: Set<String>,
        hiddenBundleIDs: Set<String>,
        verifiedMenuItemBundleIDs: Set<String> = []
    ) -> Bool {
        guard let preferences, let journalURL else { return false }
        verifiedVisibility.removeAll(keepingCapacity: true)
        do {
            try loadJournal(from: journalURL)
            let configured = Set(HiddenBarSettingsPolicy.normalizedBundleIDs(
                Array(configuredBundleIDs),
                additionalProtectedBundleIDs: [Bundle.main.bundleIdentifier ?? "com.barut.OmniWM"]
            ))
            let verifiedMenuItemBundleIDs = verifiedMenuItemBundleIDs.intersection(configured)
            guard !configured.isEmpty || !ownership.isEmpty else { return true }
            var applications = try NativeMenuBarApplications(data: preferences.read())
            var planned = ownership
            var desired: [String: Bool] = [:]
            var recovery = ownership.mapValues(\.original)
            var needsWrite = try applications.registerMenuItemLocations(verifiedMenuItemBundleIDs)
            for bundleID in Set(ownership.keys).union(configured) {
                guard let current = applications.isAllowed(bundleID) else { continue }
                var entry = planned[bundleID] ?? Ownership(original: current, applied: current)
                entry.observe(current)
                let allowed = configured.contains(bundleID) ? !hiddenBundleIDs.contains(bundleID) : entry.original
                desired[bundleID] = allowed
                recovery[bundleID] = current != entry.original || allowed != entry.original ? entry.original : nil
                if current != allowed {
                    needsWrite = true
                    entry.pending = allowed
                    applications.setAllowed(allowed, for: bundleID)
                }
                planned[bundleID] = entry
            }
            try saveJournal(recovery, to: journalURL)
            ownership = planned
            if needsWrite {
                try preferences.write(applications.encoded())
            }
            try finishUpdate(
                (visibility: desired, menuItemBundleIDs: verifiedMenuItemBundleIDs),
                configured: configured,
                preferences: preferences,
                recovery: recovery,
                journalURL: journalURL
            )
            available = true
            return configured.allSatisfy { verifiedVisibility[$0] == !hiddenBundleIDs.contains($0) }
        } catch {
            verifiedVisibility.removeAll(keepingCapacity: true)
            Self.logger
                .error("Native menu bar visibility update failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func finishUpdate(
        _ expected: (visibility: [String: Bool], menuItemBundleIDs: Set<String>),
        configured: Set<String>,
        preferences: NativeMenuBarPreferences,
        recovery: [String: Bool],
        journalURL: URL
    ) throws {
        let verified = try NativeMenuBarApplications(data: preferences.read())
        var recovery = recovery
        var complete = expected.menuItemBundleIDs.allSatisfy(verified.hasMenuItemLocation)
        for (bundleID, allowed) in expected.visibility {
            guard let current = verified.isAllowed(bundleID) else {
                complete = false
                continue
            }
            ownership[bundleID]?.applied = current
            ownership[bundleID]?.pending = nil
            guard current == allowed else {
                complete = false
                continue
            }
            if current == ownership[bundleID]?.original {
                recovery.removeValue(forKey: bundleID)
            }
            if configured.contains(bundleID) {
                verifiedVisibility[bundleID] = current
            } else {
                ownership.removeValue(forKey: bundleID)
            }
        }
        try saveJournal(recovery, to: journalURL)
        guard complete else { throw NativeMenuBarPreferencesError.writeFailed }
    }

    func drop() {
        apply(configuredBundleIDs: [], hiddenBundleIDs: [])
    }

    func systemSettingsAllowance() -> [String: Bool] {
        guard let preferences else { return [:] }
        guard let applications = try? NativeMenuBarApplications(data: preferences.read()) else {
            available = false
            return [:]
        }
        available = true
        let bundleIDs = HiddenBarSettingsPolicy.normalizedBundleIDs(
            applications.bundleIDs,
            additionalProtectedBundleIDs: [Bundle.main.bundleIdentifier ?? "com.barut.OmniWM"]
        )
        var allowance: [String: Bool] = [:]
        for bundleID in bundleIDs {
            allowance[bundleID] = ownership[bundleID]?.original ?? applications.isAllowed(bundleID)
        }
        return allowance
    }

    private func loadJournal(from url: URL) throws {
        guard !journalLoaded else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            ownership = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: url))
                .mapValues { Ownership(original: $0, applied: !$0) }
        }
        journalLoaded = true
    }

    private func saveJournal(_ entries: [String: Bool], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(entries)
        if FileManager.default.fileExists(atPath: url.path), try Data(contentsOf: url) == data { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
