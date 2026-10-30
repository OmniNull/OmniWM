// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import SwiftUI
import Synchronization
import XCTest

@MainActor
final class SettingsDomainOwnerTests: XCTestCase {
    func testImportRetainsDomainIdentityAndPropertySpecificObservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let focus = settings.focus
        let niri = settings.niri
        let bar = settings.workspaceBar
        let workspaces = settings.workspaces
        let observed = Mutex(0)
        withObservationTracking {
            _ = settings.focus.followsMouse
        } onChange: {
            observed.withLock { $0 += 1 }
        }
        settings.focus.raiseOnMouseFocus.toggle()
        XCTAssertEqual(observed.withLock { $0 }, 0)
        var values = settings.toExport()
        values.focus.followsMouse.toggle()
        values.niri.visibleContainerCount = 4
        values.workspaceBar.showLabels.toggle()
        let savedBeforeImport = try Data(contentsOf: settings.settingsFileURL)

        settings.applyExport(values)

        XCTAssertTrue(settings.focus === focus)
        XCTAssertTrue(settings.niri === niri)
        XCTAssertTrue(settings.workspaceBar === bar)
        XCTAssertTrue(settings.workspaces === workspaces)
        XCTAssertEqual(observed.withLock { $0 }, 1)
        XCTAssertEqual(settings.toExport(), values)
        XCTAssertEqual(try Data(contentsOf: settings.settingsFileURL), savedBeforeImport)
        settings.focus.followsMouse.toggle()
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(contentsOf: settings.settingsFileURL)), settings.toExport())
    }

    func testDomainBindingTracksImportsAndPersistsEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let binding = Bindable(settings.focus).followsMouse
        var values = settings.toExport()
        values.focus.followsMouse = true
        settings.applyExport(values)
        XCTAssertTrue(binding.wrappedValue)

        binding.wrappedValue = false

        XCTAssertFalse(settings.focus.followsMouse)
        XCTAssertEqual(
            try SettingsTOMLCodec.decode(Data(contentsOf: settings.settingsFileURL)),
            settings.toExport()
        )
    }

    func testWorkspaceOwnerKeepsIndependentObservationAndImportNormalization() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let observed = Mutex(0)
        withObservationTracking {
            _ = settings.workspaces.configurations
        } onChange: {
            observed.withLock { $0 += 1 }
        }
        let binding = Bindable(settings.workspaces).defaultLayoutType
        binding.wrappedValue = .dwindle
        XCTAssertEqual(observed.withLock { $0 }, 0)
        var values = settings.toExport()
        let inherited = WorkspaceConfiguration(name: "2", layoutType: .defaultLayout)
        let explicit = WorkspaceConfiguration(name: "1", layoutType: .niri)
        values.workspaceConfigurations = [inherited, explicit, inherited]

        settings.applyExport(values)

        XCTAssertEqual(observed.withLock { $0 }, 1)
        XCTAssertEqual(settings.workspaces.configurations, [explicit, inherited])
        XCTAssertEqual(settings.workspaces.configuredNames(), ["1", "2"])
        XCTAssertEqual(settings.workspaces.layoutType(for: "2"), .dwindle)
        XCTAssertEqual(settings.workspaces.layoutType(for: "1"), .niri)
        XCTAssertEqual(settings.workspaces.layoutType(for: "3"), .dwindle)
        XCTAssertEqual(settings.workspaces.displayName(for: "3"), "3")
        binding.wrappedValue = .niri
        XCTAssertEqual(settings.workspaces.layoutType(for: "2"), .niri)
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(contentsOf: settings.settingsFileURL)), settings.toExport())
    }

    func testFullyVisibleHoverSettingImportsAndPersistsEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let focus = settings.focus
        var imported = settings.toExport()
        imported.focus.followsMouseOnlyFullyVisible = true
        settings.applyExport(imported)
        XCTAssertTrue(settings.focus === focus)
        XCTAssertTrue(focus.followsMouseOnlyFullyVisible)
        focus.followsMouseOnlyFullyVisible = false
        let saved = try SettingsTOMLCodec.decode(Data(contentsOf: settings.settingsFileURL))
        XCTAssertFalse(saved.focus.followsMouseOnlyFullyVisible)
        focus.followsMouseOnlyFullyVisible = true
        XCTAssertTrue(try SettingsTOMLCodec.decode(Data(contentsOf: settings.settingsFileURL))
            .focus.followsMouseOnlyFullyVisible)
    }

    private func makeSettings(directory: URL) -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false)
        )
    }
}
