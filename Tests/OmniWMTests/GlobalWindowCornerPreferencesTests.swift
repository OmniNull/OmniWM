// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class GlobalWindowCornerPreferencesTests: XCTestCase {
    func testInitializationReadsWithoutWriting() {
        let fixture = Fixture()
        let preferences = fixture.makePreferences()

        XCTAssertEqual(preferences.state, .systemDefault)
        XCTAssertEqual(preferences.draftRadius, GlobalWindowCornerPreferences.defaultDraftRadius)
        XCTAssertEqual(fixture.writeRecords.count, 0)
        XCTAssertEqual(fixture.synchronizeCount, 1)
        XCTAssertEqual(fixture.copyMultipleCount, 1)

        fixture.resetEvents()
        preferences.refresh()

        XCTAssertEqual(fixture.writeRecords.count, 0)
        XCTAssertEqual(fixture.synchronizeCount, 1)
        XCTAssertEqual(fixture.copyMultipleCount, 1)
    }

    func testEqualFractionalValuesDecodeAsCustom() {
        let fixture = Fixture()
        fixture.setBoth(12.25)

        let preferences = fixture.makePreferences()

        XCTAssertEqual(preferences.state, .custom(12.25))
        XCTAssertEqual(preferences.draftRadius, 12.25)
    }

    func testSquareSentinelDecodesAsZero() {
        let fixture = Fixture()
        fixture.setBoth(GlobalWindowCornerPreferences.squareStoredRadius)

        let preferences = fixture.makePreferences()

        XCTAssertEqual(preferences.state, .custom(0))
        XCTAssertEqual(preferences.draftRadius, 0)
    }

    func testMissingOrDifferentPairDecodesAsMixed() {
        let fixture = Fixture()
        fixture.set(12, for: GlobalWindowCornerPreferences.standardWindowKey)
        let preferences = fixture.makePreferences()
        XCTAssertEqual(preferences.state, .mixed)

        fixture.set(8, for: GlobalWindowCornerPreferences.panelWindowKey)
        preferences.refresh()
        XCTAssertEqual(preferences.state, .mixed)
    }

    func testMalformedPairIsDistinctFromMixedPair() {
        let fixture = Fixture()
        fixture.set("12", for: GlobalWindowCornerPreferences.standardWindowKey)
        fixture.set(12, for: GlobalWindowCornerPreferences.panelWindowKey)

        let preferences = fixture.makePreferences()

        XCTAssertEqual(preferences.state, .malformed)
    }

    func testBooleanValuesAreMalformed() {
        let fixture = Fixture()
        fixture.set(NSNumber(value: true), for: GlobalWindowCornerPreferences.standardWindowKey)
        fixture.set(NSNumber(value: true), for: GlobalWindowCornerPreferences.panelWindowKey)

        let preferences = fixture.makePreferences()

        XCTAssertEqual(preferences.state, .malformed)
    }

    func testEqualValuesOutsideSupportedRangeAreReportedSeparately() {
        for radius in [0.0, -1.0, 64.5] {
            let fixture = Fixture()
            fixture.setBoth(radius)

            let preferences = fixture.makePreferences()

            XCTAssertEqual(preferences.state, .outOfRange, "radius \(radius)")
        }
    }

    func testManagedPreferencePreventsMutationAfterFreshRecheck() {
        let fixture = Fixture()
        fixture.forcedKeys.insert(GlobalWindowCornerPreferences.panelWindowKey)
        let preferences = fixture.makePreferences()
        fixture.resetEvents()

        preferences.chooseCustom()

        XCTAssertTrue(preferences.isManaged)
        XCTAssertEqual(fixture.writeRecords.count, 0)
        XCTAssertEqual(fixture.synchronizeCount, 1)
        XCTAssertEqual(fixture.copyMultipleCount, 1)
        XCTAssertEqual(preferences.errorMessage, "This setting is managed by your organization.")
    }

    func testRefreshSynchronizesBeforeUpdatingManagedState() {
        let fixture = Fixture()
        let preferences = fixture.makePreferences()
        fixture.resetEvents()
        fixture.forcePanelOnNextSynchronize = true

        preferences.refresh()

        XCTAssertTrue(preferences.isManaged)
        XCTAssertEqual(fixture.synchronizeCount, 1)
        XCTAssertEqual(fixture.copyMultipleCount, 1)
    }

    func testPreferenceBecomingManagedDuringPreflightPreventsMutation() {
        let fixture = Fixture()
        let preferences = fixture.makePreferences()
        fixture.resetEvents()
        fixture.forcePanelOnNextSynchronize = true

        preferences.chooseCustom()

        XCTAssertTrue(preferences.isManaged)
        XCTAssertEqual(fixture.writeRecords.count, 0)
        XCTAssertEqual(fixture.synchronizeCount, 1)
        XCTAssertEqual(fixture.copyMultipleCount, 1)
        XCTAssertEqual(preferences.errorMessage, "This setting is managed by your organization.")
    }

    func testUnsupportedOSRejectsMutationWithoutWriting() {
        let fixture = Fixture()
        let preferences = fixture.makePreferences(isSupported: false)
        fixture.resetEvents()

        preferences.chooseCustom()

        XCTAssertEqual(fixture.writeRecords.count, 0)
        XCTAssertEqual(fixture.synchronizeCount, 0)
        XCTAssertEqual(preferences.errorMessage, "App window corner controls require macOS 26.4 or later.")
    }

    func testSquareWritesSentinelToBothKeysAndVerifiesReadback() throws {
        let fixture = Fixture()
        let preferences = fixture.makePreferences()
        fixture.resetEvents()

        preferences.setCustomRadius(0)

        XCTAssertEqual(preferences.state, .custom(0))
        XCTAssertEqual(try fixture.doubleValue(for: GlobalWindowCornerPreferences.standardWindowKey), 0.01)
        XCTAssertEqual(try fixture.doubleValue(for: GlobalWindowCornerPreferences.panelWindowKey), 0.01)
        XCTAssertEqual(fixture.writeRecords.count, 1)
        XCTAssertEqual(fixture.writeRecords[0].setKeys, Set(GlobalWindowCornerPreferences.keys))
        XCTAssertTrue(fixture.writeRecords[0].removedKeys.isEmpty)
        XCTAssertEqual(fixture.synchronizeCount, 2)
        XCTAssertEqual(fixture.copyMultipleCount, 2)
        XCTAssertEqual(preferences.successMessage, GlobalWindowCornerPreferences.relaunchMessage)
        XCTAssertNil(preferences.errorMessage)
    }

    func testCustomWritePreservesFractionalRadius() throws {
        let fixture = Fixture()
        let preferences = fixture.makePreferences()
        fixture.resetEvents()

        preferences.setCustomRadius(17.5)

        XCTAssertEqual(preferences.state, .custom(17.5))
        XCTAssertEqual(try fixture.doubleValue(for: GlobalWindowCornerPreferences.standardWindowKey), 17.5)
        XCTAssertEqual(try fixture.doubleValue(for: GlobalWindowCornerPreferences.panelWindowKey), 17.5)
        XCTAssertEqual(fixture.writeRecords.count, 1)
        XCTAssertEqual(fixture.synchronizeCount, 2)
        XCTAssertEqual(fixture.copyMultipleCount, 2)
    }

    func testSystemDefaultRemovesBothKeysTogether() {
        let fixture = Fixture()
        fixture.setBoth(12)
        let preferences = fixture.makePreferences()
        fixture.resetEvents()

        preferences.chooseSystemDefault()

        XCTAssertEqual(preferences.state, .systemDefault)
        XCTAssertEqual(fixture.writeRecords.count, 1)
        XCTAssertTrue(fixture.writeRecords[0].setKeys.isEmpty)
        XCTAssertEqual(fixture.writeRecords[0].removedKeys, Set(GlobalWindowCornerPreferences.keys))
        XCTAssertEqual(fixture.synchronizeCount, 2)
        XCTAssertEqual(fixture.copyMultipleCount, 2)
        XCTAssertEqual(preferences.successMessage, GlobalWindowCornerPreferences.relaunchMessage)
    }

    func testSliderDraftWritesOnlyOnceWhenEditingEnds() {
        let fixture = Fixture()
        fixture.setBoth(12)
        let preferences = fixture.makePreferences()
        fixture.resetEvents()

        preferences.beginSliderEditing()
        preferences.sliderValueChanged(8)
        preferences.sliderValueChanged(4)
        preferences.sliderValueChanged(0)

        XCTAssertEqual(fixture.writeRecords.count, 0)
        XCTAssertEqual(fixture.synchronizeCount, 0)
        XCTAssertEqual(preferences.draftRadius, 0)

        preferences.endSliderEditing()
        preferences.endSliderEditing()

        XCTAssertEqual(fixture.writeRecords.count, 1)
        XCTAssertEqual(fixture.synchronizeCount, 2)
        XCTAssertEqual(fixture.copyMultipleCount, 2)
        XCTAssertEqual(preferences.state, .custom(0))
    }

    func testKeyboardSliderChangeCommitsImmediatelyOutsidePointerEditing() {
        let fixture = Fixture()
        fixture.setBoth(12)
        let preferences = fixture.makePreferences()
        fixture.resetEvents()

        preferences.sliderValueChanged(12.5)

        XCTAssertEqual(preferences.state, .custom(12.5))
        XCTAssertEqual(fixture.writeRecords.count, 1)
        XCTAssertEqual(fixture.synchronizeCount, 2)
        XCTAssertEqual(fixture.copyMultipleCount, 2)
    }

    func testCancelledSliderEditingAllowsRefreshToReplaceDraft() {
        let fixture = Fixture()
        fixture.setBoth(12)
        let preferences = fixture.makePreferences()
        fixture.resetEvents()

        preferences.beginSliderEditing()
        preferences.updateDraftRadius(4)
        preferences.cancelSliderEditing()
        fixture.setBoth(20)
        preferences.refresh()

        XCTAssertEqual(preferences.state, .custom(20))
        XCTAssertEqual(preferences.draftRadius, 20)
        XCTAssertEqual(fixture.writeRecords.count, 0)
        XCTAssertEqual(fixture.synchronizeCount, 1)
        XCTAssertEqual(fixture.copyMultipleCount, 1)
    }

    func testPreflightSynchronizationFailureDoesNotWrite() throws {
        let fixture = Fixture()
        fixture.setBoth(8.5)
        let preferences = fixture.makePreferences()
        fixture.synchronizeResults = [false]
        fixture.resetEvents(preservingSynchronizeResults: true)

        preferences.setCustomRadius(24)

        XCTAssertEqual(preferences.state, .custom(8.5))
        XCTAssertEqual(try fixture.doubleValue(for: GlobalWindowCornerPreferences.standardWindowKey), 8.5)
        XCTAssertEqual(try fixture.doubleValue(for: GlobalWindowCornerPreferences.panelWindowKey), 8.5)
        XCTAssertEqual(fixture.writeRecords.count, 0)
        XCTAssertEqual(fixture.synchronizeCount, 1)
        XCTAssertEqual(fixture.copyMultipleCount, 0)
        XCTAssertNil(preferences.successMessage)
        XCTAssertEqual(
            preferences.errorMessage,
            "Couldn’t refresh the macOS window corner setting, so no change was made."
        )
    }

    func testPostwriteSynchronizationFailureDoesNotRollback() throws {
        let fixture = Fixture()
        fixture.setBoth(8.5)
        let preferences = fixture.makePreferences()
        fixture.synchronizeResults = [true, false]
        fixture.resetEvents(preservingSynchronizeResults: true)

        preferences.setCustomRadius(24)

        XCTAssertEqual(preferences.state, .custom(8.5))
        XCTAssertEqual(preferences.draftRadius, 8.5)
        XCTAssertEqual(try fixture.doubleValue(for: GlobalWindowCornerPreferences.standardWindowKey), 24)
        XCTAssertEqual(try fixture.doubleValue(for: GlobalWindowCornerPreferences.panelWindowKey), 24)
        XCTAssertEqual(fixture.writeRecords.count, 1)
        XCTAssertEqual(fixture.synchronizeCount, 2)
        XCTAssertEqual(fixture.copyMultipleCount, 1)
        XCTAssertEqual(
            preferences.errorMessage,
            "macOS could not confirm the window corner change. Its current value is unknown."
        )
    }

    func testReadbackConflictLoadsObservedValuesWithoutRollback() throws {
        let fixture = Fixture()
        fixture.setBoth(7.5)
        let preferences = fixture.makePreferences()
        fixture.corruptNextWrite = true
        fixture.resetEvents()

        preferences.setCustomRadius(20)

        XCTAssertEqual(preferences.state, .custom(17))
        XCTAssertEqual(try fixture.doubleValue(for: GlobalWindowCornerPreferences.standardWindowKey), 17)
        XCTAssertEqual(try fixture.doubleValue(for: GlobalWindowCornerPreferences.panelWindowKey), 17)
        XCTAssertEqual(fixture.writeRecords.count, 1)
        XCTAssertEqual(fixture.synchronizeCount, 2)
        XCTAssertEqual(fixture.copyMultipleCount, 2)
        XCTAssertEqual(
            preferences.errorMessage,
            "The macOS window corner setting differs from the requested value. The current value was reloaded."
        )
    }

    func testSemanticReadbackAcceptsEquivalentCFNumberRepresentation() throws {
        let fixture = Fixture()
        let preferences = fixture.makePreferences()
        fixture.normalizeNextWriteToInteger = true
        fixture.resetEvents()

        preferences.setCustomRadius(12)

        XCTAssertEqual(preferences.state, .custom(12))
        XCTAssertEqual(try fixture.doubleValue(for: GlobalWindowCornerPreferences.standardWindowKey), 12)
        XCTAssertEqual(fixture.writeRecords.count, 1)
        XCTAssertEqual(fixture.synchronizeCount, 2)
        XCTAssertNil(preferences.errorMessage)
        XCTAssertEqual(preferences.successMessage, GlobalWindowCornerPreferences.relaunchMessage)
    }

    func testRefreshSynchronizationFailurePreservesLastConfirmedState() {
        let fixture = Fixture()
        fixture.setBoth(8.5)
        let preferences = fixture.makePreferences()
        fixture.setBoth(24)
        fixture.synchronizeResults = [false]
        fixture.resetEvents(preservingSynchronizeResults: true)

        preferences.refresh()

        XCTAssertEqual(preferences.state, .custom(8.5))
        XCTAssertEqual(preferences.draftRadius, 8.5)
        XCTAssertEqual(fixture.writeRecords.count, 0)
        XCTAssertEqual(fixture.synchronizeCount, 1)
        XCTAssertEqual(fixture.copyMultipleCount, 0)
        XCTAssertEqual(preferences.errorMessage, "Couldn’t refresh the macOS window corner setting.")
    }

    func testSuccessfulRefreshClearsRecoveredRefreshFailure() {
        let fixture = Fixture()
        fixture.setBoth(8.5)
        let preferences = fixture.makePreferences()
        fixture.synchronizeResults = [false, true]
        fixture.resetEvents(preservingSynchronizeResults: true)

        preferences.refresh()
        XCTAssertEqual(preferences.errorMessage, "Couldn’t refresh the macOS window corner setting.")

        preferences.refresh()

        XCTAssertNil(preferences.errorMessage)
        XCTAssertEqual(preferences.state, .custom(8.5))
    }

    func testAuthoritativeManagedStateChangeClearsPriorFailure() {
        let fixture = Fixture()
        fixture.forcedKeys.insert(GlobalWindowCornerPreferences.panelWindowKey)
        let preferences = fixture.makePreferences()
        preferences.chooseCustom()
        XCTAssertNotNil(preferences.errorMessage)

        fixture.forcedKeys.removeAll()
        preferences.refresh()

        XCTAssertFalse(preferences.isManaged)
        XCTAssertNil(preferences.errorMessage)
    }

    func testBooleanToNumericRefreshClearsPriorFailure() {
        let fixture = Fixture()
        fixture.set(NSNumber(value: true), for: GlobalWindowCornerPreferences.standardWindowKey)
        fixture.set(NSNumber(value: true), for: GlobalWindowCornerPreferences.panelWindowKey)
        let preferences = fixture.makePreferences()
        preferences.setCustomRadius(.nan)
        XCTAssertNotNil(preferences.errorMessage)

        fixture.setBoth(1)
        preferences.refresh()

        XCTAssertEqual(preferences.state, .custom(1))
        XCTAssertNil(preferences.errorMessage)
    }

    func testMalformedBooleanToNumericChangeClearsPriorFailure() {
        let fixture = Fixture()
        fixture.set(NSNumber(value: true), for: GlobalWindowCornerPreferences.standardWindowKey)
        fixture.set(NSNumber(value: false), for: GlobalWindowCornerPreferences.panelWindowKey)
        let preferences = fixture.makePreferences()
        preferences.setCustomRadius(.nan)
        XCTAssertEqual(preferences.state, .malformed)
        XCTAssertNotNil(preferences.errorMessage)

        fixture.set(NSNumber(value: 1), for: GlobalWindowCornerPreferences.standardWindowKey)
        preferences.refresh()

        XCTAssertEqual(preferences.state, .malformed)
        XCTAssertNil(preferences.errorMessage)
    }

    func testRadiusFormattingPreservesVisibleFractionPrecision() {
        let separator = Locale.current.decimalSeparator ?? "."
        XCTAssertEqual(AppWindowCornerRadiusFormatting.string(for: 0), "Square")
        XCTAssertEqual(AppWindowCornerRadiusFormatting.string(for: 12.25), "12\(separator)25 pt")
        XCTAssertEqual(AppWindowCornerRadiusFormatting.string(for: 12.345_678), "12\(separator)3457 pt")
    }

    func testInvalidCustomRadiusDoesNotWrite() {
        for radius in [-0.5, 0.005, 64.5, .infinity, .nan] {
            let fixture = Fixture()
            let preferences = fixture.makePreferences()
            fixture.resetEvents()

            preferences.setCustomRadius(radius)

            XCTAssertEqual(fixture.writeRecords.count, 0, "radius \(radius)")
            XCTAssertEqual(fixture.synchronizeCount, 0, "radius \(radius)")
            XCTAssertEqual(preferences.errorMessage, "Choose Square or a corner radius from 0.01 to 64 points.")
        }
    }
}

@MainActor
private final class Fixture {
    struct WriteRecord {
        let setKeys: Set<String>
        let removedKeys: Set<String>
    }

    var forcedKeys: Set<String> = []
    var synchronizeResults: [Bool] = []
    var corruptNextWrite = false
    var normalizeNextWriteToInteger = false
    var forcePanelOnNextSynchronize = false
    private(set) var copyMultipleCount = 0
    private(set) var writeRecords: [WriteRecord] = []
    private(set) var synchronizeCount = 0
    private var values: [String: Any] = [:]

    func set(_ value: Any, for key: String) {
        values[key] = value
    }

    func setBoth(_ radius: Double) {
        for key in GlobalWindowCornerPreferences.keys {
            values[key] = NSNumber(value: radius)
        }
    }

    func doubleValue(for key: String) throws -> Double {
        try XCTUnwrap(values[key] as? NSNumber).doubleValue
    }

    func value(for key: String) -> Any? {
        values[key]
    }

    func makePreferences(isSupported: Bool = true) -> GlobalWindowCornerPreferences {
        GlobalWindowCornerPreferences(
            operations: GlobalWindowCornerPreferences.Operations(
                copyMultiple: { [self] in
                    copyMultipleCount += 1
                    return values
                },
                setMultiple: { [self] newValues, removedKeys in
                    writeRecords.append(WriteRecord(
                        setKeys: Set(newValues.keys),
                        removedKeys: Set(removedKeys)
                    ))
                    if corruptNextWrite {
                        corruptNextWrite = false
                        setBoth(17)
                        return
                    }
                    if normalizeNextWriteToInteger {
                        normalizeNextWriteToInteger = false
                        for key in removedKeys {
                            values.removeValue(forKey: key)
                        }
                        for key in newValues.keys {
                            values[key] = NSNumber(value: Int32(12))
                        }
                        return
                    }
                    for key in removedKeys {
                        values.removeValue(forKey: key)
                    }
                    for (key, value) in newValues {
                        values[key] = value
                    }
                },
                synchronize: { [self] in
                    synchronizeCount += 1
                    if forcePanelOnNextSynchronize {
                        forcePanelOnNextSynchronize = false
                        forcedKeys.insert(GlobalWindowCornerPreferences.panelWindowKey)
                    }
                    return synchronizeResults.isEmpty ? true : synchronizeResults.removeFirst()
                },
                isForced: { [self] key in
                    forcedKeys.contains(key)
                }
            ),
            isSupported: isSupported
        )
    }

    func resetEvents(preservingSynchronizeResults: Bool = false) {
        copyMultipleCount = 0
        writeRecords = []
        synchronizeCount = 0
        if !preservingSynchronizeResults {
            synchronizeResults = []
        }
    }
}
