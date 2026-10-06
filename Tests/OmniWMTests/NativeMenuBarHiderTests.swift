// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Observation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class NativeMenuBarHiderTests: XCTestCase {
    @MainActor
    private final class Fixture {
        enum WriteFailure {
            case before, after, ignored
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var data: Data
        var writes = 0
        var failure: WriteFailure?
        var failRead = false
        var beforeWrite: (() throws -> Void)?

        var journal: URL {
            root.appendingPathComponent("visibility.json")
        }

        init(
            _ flags: [String: Bool] = ["a": true, "b": false, "other": true],
            menuItemLocations: [String: [[String: Any]]] = [:]
        ) throws {
            var entries: [[String: Any]] = []
            for (bundleID, allowed) in flags.sorted(by: { $0.key < $1.key }) {
                let location: [String: Any] = ["bundle": ["_0": bundleID]]
                entries.append(location)
                entries.append([
                    "location": location,
                    "isAllowed": allowed,
                    "menuItemLocations": menuItemLocations[bundleID] ?? [location],
                    "unknown": ["preserved": 42]
                ])
            }
            entries.append(["adhocBinary": ["_0": "file:///unchanged"]])
            entries.append(["isAllowed": true, "metadata": "untouched"])
            data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        }

        func hider() -> NativeMenuBarHider {
            NativeMenuBarHider(preferences: NativeMenuBarPreferences(read: { [self] in
                if failRead { throw NativeMenuBarPreferencesError.unavailable }
                return data
            }, write: { [self] changed in
                try beforeWrite?()
                writes += 1
                if failure == .before { throw NativeMenuBarPreferencesError.writeFailed }
                if failure != .ignored { data = changed }
                if failure == .after { throw NativeMenuBarPreferencesError.writeFailed }
            }), journalURL: journal)
        }

        func allowed(_ bundleID: String) throws -> Bool? {
            try NativeMenuBarApplications(data: data).isAllowed(bundleID)
        }

        func externalChange(_ allowed: Bool, for bundleID: String) throws {
            var applications = try NativeMenuBarApplications(data: data)
            applications.setAllowed(allowed, for: bundleID)
            data = try applications.encoded()
        }

        func recovery() throws -> [String: Bool] {
            try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: journal))
        }

        func entry(_ bundleID: String) throws -> [String: Any] {
            let entries = try XCTUnwrap(PropertyListSerialization
                .propertyList(from: data, format: nil) as? [[String: Any]])
            let index = try XCTUnwrap(stride(from: 0, to: entries.count, by: 2).first {
                (entries[$0]["bundle"] as? [String: String])?["_0"] == bundleID
            })
            return entries[index + 1]
        }
    }

    private func fixture(
        _ flags: [String: Bool] = ["a": true, "b": false, "other": true],
        menuItemLocations: [String: [[String: Any]]] = [:]
    ) throws -> Fixture {
        let fixture = try Fixture(flags, menuItemLocations: menuItemLocations)
        let root = fixture.root
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return fixture
    }

    func testCaptureHideRevealRehideAndDropPreserveBothOriginalStates() throws {
        let fixture = try fixture()
        let hider = fixture.hider()
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["a", "b"], hiddenBundleIDs: []))
        XCTAssertTrue(hider.isRevealed("a"))
        XCTAssertTrue(hider.isRevealed("b"))
        XCTAssertEqual(try fixture.recovery(), ["b": false])
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["a", "b"], hiddenBundleIDs: ["a", "b"]))
        XCTAssertEqual(try fixture.allowed("a"), false)
        XCTAssertEqual(try fixture.allowed("b"), false)
        XCTAssertEqual(try fixture.recovery(), ["a": true])
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["a", "b"], hiddenBundleIDs: ["a"]))
        XCTAssertTrue(hider.isRevealed("b"))
        XCTAssertFalse(hider.isRevealed("a"))
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["a", "b"], hiddenBundleIDs: ["a", "b"]))
        hider.drop()
        XCTAssertEqual(try fixture.allowed("a"), true)
        XCTAssertEqual(try fixture.allowed("b"), false)
        XCTAssertEqual(try fixture.recovery(), [:])
    }

    func testSystemSettingsAllowanceKeepsUserChoiceWhileOmniWMHides() throws {
        let fixture = try fixture(["a": true, "b": false, "com.apple.controlcenter": true])
        let hider = fixture.hider()
        XCTAssertEqual(hider.systemSettingsAllowance(), ["a": true, "b": false])

        XCTAssertTrue(hider.apply(configuredBundleIDs: ["a", "b"], hiddenBundleIDs: ["a", "b"]))

        XCTAssertEqual(try fixture.allowed("a"), false)
        XCTAssertEqual(hider.systemSettingsAllowance(), ["a": true, "b": false])
    }

    func testSystemSettingsAllowanceRestoresAvailabilityAfterRefusedRead() throws {
        let fixture = try fixture()
        fixture.failRead = true
        let hider = fixture.hider()
        XCTAssertFalse(hider.available)

        fixture.failRead = false
        let changes = Mutex(0)
        withObservationTracking {
            _ = hider.available
        } onChange: {
            changes.withLock { $0 += 1 }
        }

        XCTAssertEqual(hider.systemSettingsAllowance(), ["a": true, "b": false, "other": true])
        XCTAssertTrue(hider.available)
        XCTAssertEqual(changes.withLock { $0 }, 1)
    }

    func testRemovingOneConfiguredAppRestoresOnlyThatApp() throws {
        let fixture = try fixture(["a": true, "b": true])
        let hider = fixture.hider()
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["a", "b"], hiddenBundleIDs: ["a", "b"]))
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["b"], hiddenBundleIDs: ["b"]))
        XCTAssertEqual(try fixture.allowed("a"), true)
        XCTAssertEqual(try fixture.allowed("b"), false)
        XCTAssertEqual(try fixture.recovery(), ["b": true])
        hider.drop()
    }

    func testIdenticalRefreshDoesNotWritePreferencesAgain() throws {
        let fixture = try fixture()
        let hider = fixture.hider()
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))
        XCTAssertEqual(fixture.writes, 1)
        hider.drop()
    }

    func testObservedExternalChangeBecomesRestorationBaseline() throws {
        let fixture = try fixture()
        let hider = fixture.hider()
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["b"], hiddenBundleIDs: ["b"]))
        try fixture.externalChange(true, for: "b")
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["b"], hiddenBundleIDs: ["b"]))
        hider.drop()
        XCTAssertEqual(try fixture.allowed("b"), true)
    }

    func testExternalChangeDuringRevealIsPreservedOnDrop() throws {
        let fixture = try fixture()
        let hider = fixture.hider()
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["a"], hiddenBundleIDs: []))
        try fixture.externalChange(false, for: "a")
        hider.drop()
        XCTAssertEqual(try fixture.allowed("a"), false)
    }

    func testRecoveryRestoresOverridesAfterRestartEvenWhenDisabled() throws {
        let fixture = try fixture()
        let hider = fixture.hider()
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["a", "b"], hiddenBundleIDs: ["a"]))
        let restarted = fixture.hider()
        restarted.drop()
        XCTAssertEqual(try fixture.allowed("a"), true)
        XCTAssertEqual(try fixture.allowed("b"), false)
        XCTAssertEqual(try fixture.recovery(), [:])
    }

    func testRecoveryBeforeNativeWriteDoesNotChangeOriginal() throws {
        let fixture = try fixture()
        fixture.failure = .before
        XCTAssertFalse(fixture.hider().apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))
        XCTAssertEqual(try fixture.recovery(), ["a": true])
        fixture.failure = nil
        fixture.hider().drop()
        XCTAssertEqual(try fixture.allowed("a"), true)
        XCTAssertEqual(try fixture.recovery(), [:])
    }

    func testRecoveryIsSavedBeforeNativeMutation() throws {
        let fixture = try fixture()
        fixture.beforeWrite = {
            XCTAssertEqual(try fixture.recovery(), ["a": true, "b": false])
        }
        XCTAssertTrue(fixture.hider().apply(configuredBundleIDs: ["a", "b"], hiddenBundleIDs: ["a"]))
    }

    func testJournalFailurePreventsNativeWrite() throws {
        let fixture = try fixture()
        try Data().write(to: fixture.root)
        XCTAssertFalse(fixture.hider().apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))
        XCTAssertEqual(fixture.writes, 0)
        XCTAssertEqual(try fixture.allowed("a"), true)
    }

    func testCorruptRecoveryJournalPreventsNewOverrides() throws {
        let fixture = try fixture()
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data("bad journal".utf8).write(to: fixture.journal)
        XCTAssertFalse(fixture.hider().apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))
        XCTAssertEqual(fixture.writes, 0)
    }

    func testWriteFailureAfterCommitRetainsOriginalForSameSessionRestore() throws {
        let fixture = try fixture()
        let hider = fixture.hider()
        fixture.failure = .after
        XCTAssertFalse(hider.apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))
        XCTAssertEqual(try fixture.allowed("a"), false)
        fixture.failure = nil
        hider.drop()
        XCTAssertEqual(try fixture.allowed("a"), true)
        XCTAssertEqual(try fixture.recovery(), [:])
    }

    func testVerificationReadFailureRetainsOriginalForRestore() throws {
        let fixture = try fixture()
        let hider = fixture.hider()
        fixture.beforeWrite = { fixture.failRead = true }
        XCTAssertFalse(hider.apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))
        XCTAssertEqual(try fixture.allowed("a"), false)
        fixture.beforeWrite = nil
        fixture.failRead = false
        hider.drop()
        XCTAssertEqual(try fixture.allowed("a"), true)
        XCTAssertEqual(try fixture.recovery(), [:])
    }

    func testDisabledControllerRecoversInterruptedSessionOnSetup() throws {
        let fixture = try fixture()
        XCTAssertTrue(fixture.hider().apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))
        let settings = WindowAdmissionTestSupport.controller(prefix: "HiddenBarNativeRecovery").settings
        settings.hiddenBar.enabled = false
        let controller = HiddenBarController(settings: settings, hider: fixture.hider())
        controller.setup()
        XCTAssertEqual(try fixture.allowed("a"), true)
        XCTAssertEqual(try fixture.recovery(), [:])
        controller.cleanup()
    }

    func testFailedRestoreRetainsRecoveryUntilSuccessfulRestore() throws {
        let fixture = try fixture()
        let hider = fixture.hider()
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))
        fixture.failure = .before
        hider.drop()
        XCTAssertEqual(try fixture.allowed("a"), false)
        XCTAssertEqual(try fixture.recovery(), ["a": true])
        fixture.failure = nil
        hider.drop()
        XCTAssertEqual(try fixture.allowed("a"), true)
        XCTAssertEqual(try fixture.recovery(), [:])
    }

    func testFailedReadRetainsRecovery() throws {
        let fixture = try fixture()
        let hider = fixture.hider()
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))
        fixture.failRead = true
        hider.drop()
        XCTAssertEqual(try fixture.recovery(), ["a": true])
        fixture.failRead = false
        hider.drop()
        XCTAssertEqual(try fixture.allowed("a"), true)
    }

    func testIgnoredWriteDoesNotReportSuccessfulReveal() throws {
        let fixture = try fixture()
        fixture.failure = .ignored
        let hider = fixture.hider()
        XCTAssertFalse(hider.apply(configuredBundleIDs: ["b"], hiddenBundleIDs: []))
        XCTAssertFalse(hider.isRevealed("b"))
        XCTAssertEqual(try fixture.allowed("b"), false)
    }

    func testUnknownAppDoesNotCreateNativeEntryOrReportReveal() throws {
        let fixture = try fixture()
        let original = fixture.data
        let hider = fixture.hider()
        XCTAssertFalse(hider.apply(configuredBundleIDs: ["missing"], hiddenBundleIDs: []))
        XCTAssertFalse(hider.isRevealed("missing"))
        XCTAssertEqual(fixture.data, original)
        XCTAssertEqual(fixture.writes, 0)
    }

    func testProtectedHostsAndOwnBundleStayUnchanged() throws {
        let own = Bundle.main.bundleIdentifier ?? "com.barut.OmniWM"
        let protected = HiddenBarSettingsPolicy.protectedSystemHostBundleIDs.union([own])
        let fixture = try fixture(Dictionary(uniqueKeysWithValues: protected.map { ($0, true) }))
        let original = fixture.data
        XCTAssertTrue(fixture.hider().apply(configuredBundleIDs: protected, hiddenBundleIDs: protected))
        XCTAssertEqual(fixture.data, original)
        XCTAssertEqual(fixture.writes, 0)
    }

    func testUnrelatedEntriesAndMetadataSurviveAllVisibilityChanges() throws {
        let fixture = try fixture()
        let original = try PropertyListSerialization.propertyList(from: fixture.data, format: nil) as? NSArray
        let hider = fixture.hider()
        XCTAssertTrue(hider.apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))
        let changed = try PropertyListSerialization.propertyList(from: fixture.data, format: nil) as? [[String: Any]]
        XCTAssertEqual(changed?[1]["unknown"] as? [String: Int], ["preserved": 42])
        XCTAssertEqual(try fixture.allowed("other"), true)
        hider.drop()
        XCTAssertEqual(
            try PropertyListSerialization.propertyList(from: fixture.data, format: nil) as? NSArray,
            original
        )
    }

    func testMalformedNativeDataIsUnavailableAndNeverWritten() throws {
        let fixture = try fixture()
        fixture.data = try PropertyListSerialization.data(
            fromPropertyList: [["bundle": ["_0": "a"]]],
            format: .binary,
            options: 0
        )
        let hider = fixture.hider()
        XCTAssertFalse(hider.available)
        XCTAssertFalse(hider.apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))
        XCTAssertEqual(fixture.writes, 0)
    }

    func testNonBooleanAllowedValueIsRejected() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            ["bundle": ["_0": "a"]], ["isAllowed": 1]
        ], format: .binary, options: 0)
        XCTAssertThrowsError(try NativeMenuBarApplications(data: data))
    }

    func testDefaultHiderHasNoLiveSideEffects() {
        let hider = NativeMenuBarHider()
        XCTAssertFalse(hider.available)
        XCTAssertFalse(hider.apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))
        hider.drop()
    }

    func testVerifiedOwnerRepairsMembershipAndRestoresOriginalVisibility() throws {
        let existing: [[String: Any]] = [
            ["adhocBinary": ["_0": ["relative": "file:///previous/OmniWM"]]],
            ["bundle": ["_0": "a.helper"]]
        ]
        let fixture = try fixture(menuItemLocations: ["a": existing])
        let unrelated = try fixture.entry("other") as NSDictionary
        let hider = fixture.hider()

        XCTAssertTrue(hider.apply(
            configuredBundleIDs: ["a"],
            hiddenBundleIDs: ["a"],
            verifiedMenuItemBundleIDs: ["a"]
        ))

        let repaired = try fixture.entry("a")
        XCTAssertEqual(try fixture.allowed("a"), false)
        XCTAssertEqual(try fixture.recovery(), ["a": true])
        XCTAssertEqual(repaired["menuItemLocations"] as? NSArray, (existing + [["bundle": ["_0": "a"]]]) as NSArray)
        XCTAssertEqual(repaired["unknown"] as? [String: Int], ["preserved": 42])
        XCTAssertEqual(try fixture.entry("other") as NSDictionary, unrelated)

        hider.drop()

        XCTAssertEqual(try fixture.allowed("a"), true)
        XCTAssertEqual(try fixture.recovery(), [:])
        XCTAssertTrue(try NativeMenuBarApplications(data: fixture.data).hasMenuItemLocation("a"))
    }

    func testUnverifiedConfiguredAppKeepsHelperMembership() throws {
        let fixture = try fixture(["a": false], menuItemLocations: ["a": [["bundle": ["_0": "a.helper"]]]])
        let original = fixture.data

        XCTAssertTrue(fixture.hider().apply(configuredBundleIDs: ["a"], hiddenBundleIDs: ["a"]))

        XCTAssertEqual(fixture.data, original)
        XCTAssertEqual(fixture.writes, 0)
    }

    func testUnconfiguredAndProtectedAppsCannotReceiveMembershipRepair() throws {
        let system = "com.apple.controlcenter"
        let fixture = try fixture(
            ["a": true, "other": true, system: true],
            menuItemLocations: ["other": [], system: []]
        )
        let original = fixture.data

        XCTAssertTrue(fixture.hider().apply(
            configuredBundleIDs: ["a", system],
            hiddenBundleIDs: [],
            verifiedMenuItemBundleIDs: ["a", "other", system]
        ))

        XCTAssertEqual(fixture.data, original)
        XCTAssertEqual(fixture.writes, 0)
    }

    func testMetadataOnlyRepairWritesOnceAndPreservesOriginallyHiddenState() throws {
        let fixture = try fixture(["a": false], menuItemLocations: ["a": []])
        let hider = fixture.hider()

        for _ in 0 ..< 2 {
            XCTAssertTrue(hider.apply(
                configuredBundleIDs: ["a"],
                hiddenBundleIDs: ["a"],
                verifiedMenuItemBundleIDs: ["a"]
            ))
        }

        XCTAssertTrue(try NativeMenuBarApplications(data: fixture.data).hasMenuItemLocation("a"))
        XCTAssertEqual(fixture.writes, 1)
        hider.drop()
        XCTAssertEqual(try fixture.allowed("a"), false)
        XCTAssertEqual(try fixture.recovery(), [:])
    }

    func testIgnoredMetadataOnlyRepairDoesNotReportSuccess() throws {
        let fixture = try fixture(["a": false], menuItemLocations: ["a": []])
        fixture.failure = .ignored

        XCTAssertFalse(fixture.hider().apply(
            configuredBundleIDs: ["a"],
            hiddenBundleIDs: ["a"],
            verifiedMenuItemBundleIDs: ["a"]
        ))

        XCTAssertFalse(try NativeMenuBarApplications(data: fixture.data).hasMenuItemLocation("a"))
        XCTAssertEqual(try fixture.allowed("a"), false)
    }
}
