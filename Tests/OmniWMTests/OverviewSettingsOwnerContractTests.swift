// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import SwiftUI
import Synchronization
import XCTest

private final class OverviewSettingsChanges: Sendable {
    private let values = Mutex<[String]>([])

    func append(_ value: String) {
        values.withLock { $0.append(value) }
    }

    func snapshot() -> [String] {
        values.withLock { $0 }
    }
}

@MainActor
final class OverviewSettingsOwnerContractTests: XCTestCase {
    func testDirectColorWritesStayAtomicAndIndependentWhileSavingRawValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let changes = OverviewSettingsChanges()
        withObservationTracking {
            _ = settings.overview.backdropColor.red
            _ = settings.overview.backdropColor.green
            _ = settings.overview.backdropColor.blue
            _ = settings.overview.backdropColor.alpha
        } onChange: {
            changes.append("backdrop")
        }
        let rawColor = SettingsColor(red: -2, green: 3, blue: 0.25, alpha: 0.4)

        settings.overview.normalBorderColor = rawColor
        XCTAssertEqual(changes.snapshot(), [])
        settings.overview.backdropColor = rawColor
        settings.overview.zoom = 9

        XCTAssertEqual(changes.snapshot(), ["backdrop"])
        XCTAssertEqual(settings.overview.backdropColor, rawColor)
        XCTAssertEqual(settings.overview.normalBorderColor, rawColor)
        XCTAssertEqual(settings.overview.zoom, 9)
        XCTAssertEqual(try saved(settings), settings.toExport())
    }

    func testImportPreservesFiveValueNotificationOrderAndDefersPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        settings.overview.zoom = 1.25
        let originalData = try Data(contentsOf: settings.settingsFileURL)
        let changes = OverviewSettingsChanges()
        observeAll(settings, changes: changes)
        var values = settings.toExport()
        values.overview.zoom = .nan
        values.overview.backdrop = SettingsColor(red: -1, green: 2, blue: .nan, alpha: .infinity)
        values.overview.windowBorders.normal.alpha = 0.25
        values.overview.windowBorders.hovered.blue = 0.5
        values.overview.windowBorders.selected.green = 0.75

        settings.applyExport(values)

        XCTAssertEqual(changes.snapshot(), ["zoom", "backdrop", "normal", "hovered", "selected"])
        XCTAssertEqual(settings.overview.zoom, SettingsExport.defaults().overview.zoom)
        XCTAssertEqual(settings.overview.backdropColor, SettingsColor(red: 0, green: 1, blue: 0.08, alpha: 0))
        XCTAssertEqual(try Data(contentsOf: settings.settingsFileURL), originalData)
        settings.overview.zoom = 1.25
        XCTAssertEqual(try saved(settings), settings.toExport())
    }

    func testRetainedZoomBindingReadsImportedValuesAndReleasesSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        weak var weakSettings: SettingsStore?
        var binding: Binding<Double>?
        do {
            let settings = makeSettings(directory: directory)
            weakSettings = settings
            binding = Binding(
                get: { [settings] in settings.overview.zoom },
                set: { [settings] in settings.overview.zoom = $0 }
            )
            var values = settings.toExport()
            values.overview.zoom = 1.4
            settings.applyExport(values)
            XCTAssertEqual(binding?.wrappedValue, 1.4)
        }
        XCTAssertNotNil(weakSettings)
        binding?.wrappedValue = 4
        XCTAssertEqual(binding?.wrappedValue, 4)
        do {
            let settings = try XCTUnwrap(weakSettings)
            XCTAssertEqual(try saved(settings), settings.toExport())
        }
        binding = nil
        XCTAssertNil(weakSettings)
    }

    private func observeAll(_ settings: SettingsStore, changes: OverviewSettingsChanges) {
        observe(settings, \.overview.zoom, label: "zoom", changes: changes)
        observe(settings, \.overview.backdropColor, label: "backdrop", changes: changes)
        observe(settings, \.overview.normalBorderColor, label: "normal", changes: changes)
        observe(settings, \.overview.hoveredBorderColor, label: "hovered", changes: changes)
        observe(settings, \.overview.selectedBorderColor, label: "selected", changes: changes)
    }

    private func observe<Value>(
        _ settings: SettingsStore, _ keyPath: KeyPath<SettingsStore, Value>,
        label: String, changes: OverviewSettingsChanges
    ) {
        withObservationTracking {
            _ = settings[keyPath: keyPath]
        } onChange: {
            changes.append(label)
        }
    }

    private func saved(_ settings: SettingsStore) throws -> SettingsExport {
        try SettingsLuauDocument(Data(contentsOf: settings.settingsFileURL)).export
    }

    private func makeSettings(directory: URL) -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: true
        )
    }
}
