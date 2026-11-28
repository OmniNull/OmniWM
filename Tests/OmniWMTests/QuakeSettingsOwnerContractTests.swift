// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import SwiftUI
import Synchronization
import XCTest

private final class QuakeSettingsChanges: Sendable {
    private let values = Mutex<[String]>([])

    func append(_ value: String) {
        values.withLock { $0.append(value) }
    }

    func snapshot() -> [String] {
        values.withLock { $0 }
    }
}

@MainActor
final class QuakeSettingsOwnerContractTests: XCTestCase {
    func testDirectWritesNormalizeDimensionsAndBlurWhilePreservingRawAppearanceValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let changes = QuakeSettingsChanges()
        observe(settings, \.quakeTerminal.widthPercent, label: "width", changes: changes)
        observe(settings, \.quakeTerminal.opacity, label: "opacity", changes: changes)

        settings.quakeTerminal.widthPercent = 200
        XCTAssertEqual(changes.snapshot(), ["width"])
        settings.quakeTerminal.heightPercent = -.infinity
        settings.quakeTerminal.backgroundBlurRadius = Int.max
        settings.quakeTerminal.animationDuration = -0.25
        settings.quakeTerminal.opacity = 1.5

        XCTAssertEqual(changes.snapshot(), ["width", "opacity"])
        XCTAssertEqual(settings.quakeTerminal.widthPercent, 100)
        XCTAssertEqual(settings.quakeTerminal.heightPercent, 50)
        XCTAssertEqual(settings.quakeTerminal.backgroundBlurRadius, 100)
        XCTAssertEqual(settings.quakeTerminal.animationDuration, -0.25)
        XCTAssertEqual(settings.quakeTerminal.opacity, 1.5)
        XCTAssertEqual(try saved(settings), settings.toExport())
        settings.quakeTerminal.widthPercent = .nan
        settings.quakeTerminal.backgroundBlurRadius = Int.min
        XCTAssertEqual(settings.quakeTerminal.widthPercent, 50)
        XCTAssertEqual(settings.quakeTerminal.backgroundBlurRadius, 0)
        XCTAssertEqual(try saved(settings), settings.toExport())
    }

    func testImportKeepsFieldOrderOptionalFallbacksAndSaveGate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        preparePriorValues(settings)
        let originalData = try Data(contentsOf: settings.settingsFileURL)
        let changes = QuakeSettingsChanges()
        observeAll(settings, changes: changes)

        settings.applyExport(importValues(settings))

        XCTAssertEqual(changes.snapshot(), [
            "enabled", "position", "width", "height", "duration", "autoHide",
            "opacity", "effect", "blur", "monitor"
        ])
        XCTAssertEqual(settings.quakeTerminal.widthPercent, 50)
        XCTAssertEqual(settings.quakeTerminal.heightPercent, 50)
        XCTAssertEqual(settings.quakeTerminal.opacity, 1)
        XCTAssertEqual(settings.quakeTerminal.backgroundBlurRadius, 0)
        XCTAssertEqual(settings.quakeTerminal.monitorMode, .focusedWindow)
        XCTAssertEqual(try Data(contentsOf: settings.settingsFileURL), originalData)
        settings.quakeTerminal.enabled = true
        XCTAssertEqual(try saved(settings), settings.toExport())
    }

    func testDisabledAutosaveAndImportsLeaveCustomRuntimeFrameOwnedBySettingsStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory, autosaveEnabled: false)
        let originalData = try Data(contentsOf: settings.settingsFileURL)
        let frame = CGRect(x: 25, y: 30, width: 640, height: 480)
        settings.quakeTerminalUseCustomFrame = true
        settings.quakeTerminalCustomFrame = frame

        settings.quakeTerminal.widthPercent = 75
        settings.applyExport(importValues(settings))

        XCTAssertTrue(settings.quakeTerminalUseCustomFrame)
        XCTAssertEqual(settings.quakeTerminalCustomFrame, frame)
        XCTAssertEqual(try Data(contentsOf: settings.settingsFileURL), originalData)
        settings.resetQuakeTerminalCustomFrame()
        XCTAssertFalse(settings.quakeTerminalUseCustomFrame)
        XCTAssertNil(settings.quakeTerminalCustomFrame)
    }

    func testSectionBindingReadsImportedAndNormalizedWidth() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let binding = Bindable(settings.quakeTerminal).widthPercent
        var values = settings.toExport()
        values.quakeTerminal.widthPercent = 75
        settings.applyExport(values)
        XCTAssertEqual(binding.wrappedValue, 75)

        binding.wrappedValue = .infinity
        XCTAssertEqual(binding.wrappedValue, 50)
    }

    private func preparePriorValues(_ settings: SettingsStore) {
        settings.quakeTerminal.widthPercent = 60
        settings.quakeTerminal.heightPercent = 70
        settings.quakeTerminal.opacity = 0.5
        settings.quakeTerminal.backgroundBlurRadius = 40
        settings.quakeTerminal.monitorMode = .mainMonitor
    }

    private func importValues(_ settings: SettingsStore) -> SettingsExport {
        var values = settings.toExport()
        values.quakeTerminal = .init(
            enabled: false, position: .left, widthPercent: .nan, heightPercent: .infinity,
            animationDuration: 0.8, autoHide: true, opacity: nil, backgroundEffect: .glassClear,
            backgroundBlurRadius: nil, monitorMode: nil
        )
        return values
    }

    private func observeAll(_ settings: SettingsStore, changes: QuakeSettingsChanges) {
        observe(settings, \.quakeTerminal.enabled, label: "enabled", changes: changes)
        observe(settings, \.quakeTerminal.position, label: "position", changes: changes)
        observe(settings, \.quakeTerminal.widthPercent, label: "width", changes: changes)
        observe(settings, \.quakeTerminal.heightPercent, label: "height", changes: changes)
        observe(settings, \.quakeTerminal.animationDuration, label: "duration", changes: changes)
        observe(settings, \.quakeTerminal.autoHide, label: "autoHide", changes: changes)
        observe(settings, \.quakeTerminal.opacity, label: "opacity", changes: changes)
        observe(settings, \.quakeTerminal.backgroundEffect, label: "effect", changes: changes)
        observe(settings, \.quakeTerminal.backgroundBlurRadius, label: "blur", changes: changes)
        observe(settings, \.quakeTerminal.monitorMode, label: "monitor", changes: changes)
    }

    private func observe<Value>(
        _ settings: SettingsStore, _ keyPath: KeyPath<SettingsStore, Value>,
        label: String, changes: QuakeSettingsChanges
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

    private func makeSettings(directory: URL, autosaveEnabled: Bool = true) -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: autosaveEnabled
        )
    }
}
