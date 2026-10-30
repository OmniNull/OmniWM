// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreServices
import Darwin
import Foundation
import Observation
@testable import OmniWM
import Synchronization
import TOML
import XCTest

@MainActor
final class ShellConfigurationCoordinatorTests: XCTestCase {
    func testObservingBundledShellKeepsFileDescriptorsAvailable() async throws {
        let shell = try fixture()
        defer { try? FileManager.default.removeItem(at: shell) }
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        let inputs = try ShellConfigurationInputs(directory: shell, config: coordinator.config)
        XCTAssertGreaterThan(inputs.paths.count, 256)
        let before = openDescriptorCount()

        coordinator.startObserving()
        defer { coordinator.stopObserving() }

        XCTAssertLessThanOrEqual(openDescriptorCount() - before, 16)
        XCTAssertFalse(try Data(contentsOf: shell.appendingPathComponent("shell.toml")).isEmpty)
        try await coordinator.set(45, key: "height")
        XCTAssertEqual(try load(shell).barOverride?.settings.height, 45)
        XCTAssertNil(coordinator.metadataError)
    }

    private func openDescriptorCount() -> Int {
        (0 ..< min(getdtablesize(), 4096)).filter { fcntl($0, F_GETFD) >= 0 }.count
    }

    func testNewNestedSourcesAndAtomicReplacementsRefreshWithoutLiveShellHost() async throws {
        let shell = try fixture()
        defer { try? FileManager.default.removeItem(at: shell) }
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        await coordinator.flush()
        let file = shell.appendingPathComponent("lib/nested/new.luau")

        for change in 0 ..< 3 {
            let changed = expectation(description: "Nested source change \(change)")
            withObservationTracking { _ = coordinator.revision } onChange: { changed.fulfill() }
            switch change {
            case 0:
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("before".utf8).write(to: file)
            case 1:
                try Data("after".utf8).write(to: file, options: .atomic)
            default:
                try FileManager.default.removeItem(at: file.deletingLastPathComponent())
            }
            await fulfillment(of: [changed], timeout: 5)
            await coordinator.flush()
            XCTAssertNil(coordinator.metadataError)
        }
    }

    func testSymlinkedSourcesOutsideTheShellTreeRefreshWithoutLiveShellHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = try SettingsFileAccess.canonicalURL(for: root)
        let shell = directory.appendingPathComponent("config/shell")
        let external = directory.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        _ = try ShellStyleFixture.prepare(into: shell)
        _ = try ShellProfiles.select("lake", in: shell)
        let target = external.appendingPathComponent("source.luau")
        try Data("before".utf8).write(to: target)
        let link = shell.appendingPathComponent("linked-source.luau")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var watchedRoots: [String] = []
        let observation = ShellDirectoryObservation(startStream: { stream in
            watchedRoots = FSEventStreamCopyPathsBeingWatched(stream) as? [String] ?? []
            return FSEventStreamStart(stream)
        }) {}
        observation.sync(paths: [link], recursivePaths: [link])
        XCTAssertEqual(watchedRoots, [external.path])
        observation.cancel()
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        let inputs = try ShellConfigurationInputs(directory: shell, config: coordinator.config)
        XCTAssertTrue(inputs.paths.contains { $0.path == link.path })
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        try await coordinator.refresh()

        for atomic in [false, true] {
            let changed = expectation(description: "External symlink target edit, atomic=\(atomic)")
            withObservationTracking { _ = coordinator.revision } onChange: { changed.fulfill() }
            try Data("after-\(atomic)".utf8).write(to: target, options: atomic ? .atomic : [])
            await fulfillment(of: [changed], timeout: 5)
            await coordinator.flush()
            XCTAssertNil(coordinator.metadataError)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        }
    }

    func testDirectoryObservationRefreshesAndRetriesWhenStreamCreationFails() async throws {
        let shell = try fixture()
        defer { try? FileManager.default.removeItem(at: shell) }
        var attempts = 0
        var changes = 0
        let refreshed = expectation(description: "Periodic refresh after stream creation failure")
        let observation = ShellDirectoryObservation(createStream: { _, _ in
            attempts += 1
            return nil
        }) {
            changes += 1
            if changes == 1 { refreshed.fulfill() }
        }
        let before = openDescriptorCount()
        observation.sync(paths: [shell], recursivePaths: [shell])
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertGreaterThanOrEqual(attempts, 2)
        XCTAssertLessThanOrEqual(openDescriptorCount() - before, 16)
        observation.cancel()
        let stopped = changes
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(changes, stopped)
    }

    func testDirectoryObservationRecoversAfterStreamStartFailure() async throws {
        let shell = try fixture()
        defer { try? FileManager.default.removeItem(at: shell) }
        let file = shell.appendingPathComponent("shell.toml")
        var attempts = 0
        var changed: XCTestExpectation? = expectation(description: "Refresh while restarting the event stream")
        let observation = ShellDirectoryObservation(startStream: { stream in
            attempts += 1
            return attempts > 1 && FSEventStreamStart(stream)
        }) {
            changed?.fulfill()
            changed = nil
        }
        defer { observation.cancel() }
        observation.sync(paths: [file], recursivePaths: [file])
        await fulfillment(of: [try XCTUnwrap(changed)], timeout: 5)
        XCTAssertGreaterThanOrEqual(attempts, 2)

        changed = expectation(description: "Native file event after stream recovery")
        try Data("profile = 'default'\n".utf8).write(to: file, options: .atomic)
        await fulfillment(of: [try XCTUnwrap(changed)], timeout: 5)
    }

    func testDirectoryObservationFallsBackBeforeExceedingRootBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try (0 ..< 32).map { index in
            let directory = root.appendingPathComponent(String(index))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        var attempts = 0
        var refreshed = false
        let fallback = expectation(description: "Periodic refresh with too many independent roots")
        let observation = ShellDirectoryObservation(createStream: { _, _ in
            attempts += 1
            return nil
        }) {
            if !refreshed { fallback.fulfill()
                refreshed = true
            }
        }
        defer { observation.cancel() }
        let before = openDescriptorCount()
        observation.sync(paths: directories, recursivePaths: directories)
        await fulfillment(of: [fallback], timeout: 5)
        XCTAssertEqual(attempts, 0)
        XCTAssertLessThanOrEqual(openDescriptorCount() - before, 16)
    }

    func testDirectoryObservationReplacesAndCancelsRootsWithoutLeakingDescriptors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let changed = expectation(description: "Events after cancellation")
        changed.isInverted = true
        let observation = ShellDirectoryObservation { changed.fulfill() }
        let before = openDescriptorCount()
        for index in 0 ..< 32 {
            let directory = index.isMultiple(of: 2) ? first : second
            observation.sync(paths: [directory], recursivePaths: [directory])
        }
        XCTAssertLessThanOrEqual(openDescriptorCount() - before, 16)
        observation.cancel()
        try Data("after cancel".utf8).write(to: second.appendingPathComponent("new.luau"))
        await fulfillment(of: [changed], timeout: 0.5)
        XCTAssertLessThanOrEqual(openDescriptorCount() - before, 16)
    }

    func testNativeIslandEditsPersistWithoutEnablingAnyShellSurface() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("shell")
        _ = try ShellStyleFixture.prepare(into: shell)
        _ = try ShellProfiles.select("lake", in: shell)
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        let initial = try XCTUnwrap(coordinator.config.island).components
        let addedID = try await coordinator.island(.add(
            widget: "world-clock", options: ["label": .string("Toronto"), "zone": .string("America/Toronto")]
        ))
        let added = try XCTUnwrap(addedID)
        try await coordinator.island(.move(id: added, index: 1))
        try await coordinator.island(.enable(id: added, value: false))
        try await coordinator.island(.set(id: added, key: "seconds", value: .bool(true)))
        try await coordinator.island(.rootSetting(key: "width", value: .number(540)))
        let persisted = try load(shell)
        let components = try XCTUnwrap(persisted.island).components
        XCTAssertEqual(components.first?.id, added)
        XCTAssertEqual(Array(components.dropFirst()), initial)
        XCTAssertFalse(components[0].enabled)
        XCTAssertNil(components[0].options["provider"])
        XCTAssertNil(components[0].capabilities)
        XCTAssertEqual(components[0].options["seconds"], .bool(true))
        XCTAssertEqual(
            try ShellServiceValue.decode(try XCTUnwrap(persisted.widgetSettings["lake"])).fields?["width"]?.number,
            540
        )
        try await coordinator.island(.remove(id: added))
        XCTAssertEqual(coordinator.config.island?.components, initial)
        XCTAssertFalse(coordinator.isSaving)
        await coordinator.flush()
    }

    func testPreviewingDefaultKeepsLakeSelectedAndSupportsItsSimpleIsland() async throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        _ = try ShellStyleFixture.prepare(into: shell)
        _ = try ShellProfiles.select("lake", in: shell)
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        let before = try Data(contentsOf: shell.appendingPathComponent("shell.toml"))
        let defaultProfile = try await coordinator.previewConfig(profile: "default")
        XCTAssertEqual(defaultProfile.profile, "default")
        XCTAssertEqual(defaultProfile.island?.root, "focus-ribbon")
        XCTAssertEqual(coordinator.config.profile, "lake")
        XCTAssertEqual(try Data(contentsOf: shell.appendingPathComponent("shell.toml")), before)
        try await coordinator.selectProfile("default")
        try await coordinator.set("main", key: "displays", table: "island")
        XCTAssertEqual(coordinator.config.island?.root, "focus-ribbon")
        XCTAssertEqual(coordinator.config.island?.displays, .main)
        XCTAssertNil(coordinator.catalog?.settings)
        let lake = try await coordinator.previewConfig(profile: "lake")
        XCTAssertEqual(lake.island?.root, "lake")
    }

    func testFailedPersistenceDoesNotPublishOrModifyTheEffectiveIsland() async throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        _ = try ShellStyleFixture.prepare(into: shell)
        _ = try ShellProfiles.select("lake", in: shell)
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        let initial = coordinator.config
        var publications = 0
        coordinator.onSave = { _ in publications += 1 }
        let attempts = Mutex(0)
        coordinator.writer = ShellIslandConfigWriter(shellDirectory: shell, writeFile: { data, url in
            XCTAssertFalse(Thread.isMainThread)
            let fail = attempts.withLock { value in value += 1
                return value == 1
            }
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try SettingsFileAccess.writeAtomically(data, at: url)
        }, reloadReady: {})
        do {
            _ = try await coordinator.island(.add(widget: "world-clock", options: [:]))
            XCTFail("The first persistence attempt must fail")
        } catch {}
        XCTAssertEqual(coordinator.config, initial)
        XCTAssertEqual(try load(shell), initial)
        XCTAssertEqual(publications, 0)
        _ = try await coordinator.island(.add(widget: "world-clock", options: [:]))
        XCTAssertEqual(coordinator.config.island?.components.count, (initial.island?.components.count ?? 0) + 1)
        XCTAssertEqual(publications, 1)
        XCTAssertFalse(coordinator.isSaving)
    }

    func testQueuedProfileAndIslandEditsPublishOnlyAfterTheirOrderedWrites() async throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        _ = try ShellStyleFixture.prepare(into: shell)
        _ = try ShellProfiles.select("lake", in: shell)
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        let entered = expectation(description: "island write started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        coordinator.writer = ShellIslandConfigWriter(shellDirectory: shell, writeFile: { data, url in
            entered.fulfill()
            release.wait()
            try SettingsFileAccess.writeAtomically(data, at: url)
        }, reloadReady: {})
        let initialCount = coordinator.config.island?.components.count
        let island = Task { try await coordinator.island(.add(widget: "world-clock", options: [:])) }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(coordinator.isSaving)
        XCTAssertEqual(coordinator.config.island?.components.count, initialCount)
        let switched = Task { try await coordinator.selectProfile("default") }
        release.signal()
        _ = try await island.value
        _ = try await switched.value
        XCTAssertEqual(coordinator.config.profile, "default")
        let lake = try await coordinator.previewConfig(profile: "lake")
        XCTAssertEqual(lake.island?.components.count, (initialCount ?? 0) + 1)
        await coordinator.flush()
        XCTAssertFalse(coordinator.isSaving)
    }

    func testWidgetSchemaFollowsTheEffectiveSourceFolder() async throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        let own = shell.appendingPathComponent("widgets/clock")
        let inherited = shell.appendingPathComponent("default/widgets/clock")
        for folder in [own, inherited] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("function render(ctx) return ui.box{} end".utf8)
                .write(to: folder.appendingPathComponent("init.luau"))
        }
        try Data("[options.date]\ntype = 'boolean'\ndefault = true\n".utf8)
            .write(to: inherited.appendingPathComponent("settings.toml"))
        let loader = ShellConfigurationCatalogLoader()
        let directories = [shell, shell.appendingPathComponent("default")]
        let overridden = try await loader.settings(widgets: ["clock"], directories: directories)
        XCTAssertNil(overridden["clock"])
        try FileManager.default.removeItem(at: own.appendingPathComponent("init.luau"))
        let resolved = try await loader.settings(widgets: ["clock"], directories: directories)
        XCTAssertEqual(resolved["clock"]?.options["date"]?.defaultValue, .bool(true))
    }

    func testDeferredExternalReloadSurvivesNoChangeAndFailedPersistence() async throws {
        for fail in [false, true] {
            let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: shell) }
            _ = try ShellStyleFixture.prepare(into: shell)
            _ = try ShellProfiles.select("lake", in: shell)
            let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
            try await coordinator.refresh()
            let entered = expectation(description: "persistence operation entered")
            let observed = expectation(description: "deferred external edit published")
            observed.assertForOverFulfill = true
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            var publications = 0
            coordinator.onSave = { config in
                XCTAssertEqual(config.barOverride?.settings.height, 48)
                publications += 1
                observed.fulfill()
            }
            let operation = Task {
                try await coordinator.editFile { _ in
                    XCTAssertFalse(Thread.isMainThread)
                    entered.fulfill()
                    release.wait()
                    if fail { throw CocoaError(.fileWriteNoPermission) }
                    return false
                }
            }
            await fulfillment(of: [entered], timeout: 5)
            _ = try ShellProfiles.setValue(
                48,
                at: ShellProfiles.key("workspaceBar", of: "lake") + ["height"],
                in: shell
            )
            XCTAssertTrue(try XCTUnwrap(coordinator.writer).deferReloadIfWriting())
            release.signal()
            do {
                let changed = try await operation.value
                XCTAssertFalse(fail)
                XCTAssertFalse(changed)
            } catch {
                XCTAssertTrue(fail)
                XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
            }
            await coordinator.flush()
            XCTAssertEqual(coordinator.config.barOverride?.settings.height, 48)
            XCTAssertFalse(coordinator.isSaving)
            XCTAssertEqual(publications, 1)
            await fulfillment(of: [observed], timeout: 5)
        }
    }

    func testScalarEditsReuseMetadataUntilAnExplicitSourceRefresh() async throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        _ = try ShellStyleFixture.prepare(into: shell)
        _ = try ShellProfiles.select("lake", in: shell)
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        let clock = try XCTUnwrap(coordinator.widgetSchemas["clock"])
        let catalog = try XCTUnwrap(coordinator.catalog)
        let root = try XCTUnwrap(catalog.settings)
        let component = try XCTUnwrap(catalog.descriptors["world-clock"])
        try Data("[options.date]\ntype = 'number'\ndefault = 5\n".utf8)
            .write(to: clock.folder.appendingPathComponent("settings.toml"))
        try Data("[options.width]\ntype = 'number'\ndefault = 100\nmin = 0\nmax = 200\nstep = 20\n".utf8)
            .write(to: root.folder.appendingPathComponent("settings.toml"))
        try Data("views = []\n".utf8).write(to: component.folder.appendingPathComponent("component.toml"))

        try await coordinator.set(44, key: "height")
        try await coordinator.setWidgetValue(.bool(false), widget: "clock", key: "date")
        try await coordinator.island(.rootSetting(key: "width", value: .number(540)))
        XCTAssertEqual(coordinator.widgetSchemas["clock"], clock)
        XCTAssertEqual(coordinator.catalog, catalog)
        XCTAssertNil(coordinator.metadataError)

        try await coordinator.refresh()
        XCTAssertEqual(coordinator.widgetSchemas["clock"]?.options["date"]?.kind, .number)
        XCTAssertEqual(coordinator.catalog?.settings?.options["width"]?.maximum, 200)
        XCTAssertNil(coordinator.catalog?.descriptors["world-clock"])
        XCTAssertNotNil(coordinator.catalog?.entries.first { $0.widget == "world-clock" }?.error)
        let saved = try Data(contentsOf: shell.appendingPathComponent("shell.toml"))
        do {
            try await coordinator.setWidgetValue(.bool(true), widget: "clock", key: "date")
            XCTFail("The refreshed number option must reject a boolean")
        } catch {}
        do {
            try await coordinator.island(.rootSetting(key: "width", value: .number(540)))
            XCTFail("The refreshed maximum must reject 540")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: shell.appendingPathComponent("shell.toml")), saved)
    }

    func testUnchangedRefreshKeepsPreviewRevisionMetadataAndPublication() async throws {
        let shell = try fixture()
        defer { try? FileManager.default.removeItem(at: shell) }
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        let initialRevision = coordinator.revision
        let catalog = try XCTUnwrap(coordinator.catalog)
        let schemas = coordinator.widgetSchemas
        let layout = coordinator.barLayout
        var publications = 0
        coordinator.onSave = { _ in publications += 1 }
        for _ in 0 ..< 3 { try await coordinator.refresh() }
        XCTAssertEqual(coordinator.revision, initialRevision)
        XCTAssertEqual(coordinator.catalog, catalog)
        XCTAssertEqual(coordinator.widgetSchemas, schemas)
        XCTAssertEqual(coordinator.barLayout, layout)
        XCTAssertEqual(publications, 0)
    }

    func testLoadedPageAndProfilePreviewReusePreparedValues() async throws {
        let shell = try fixture()
        defer { try? FileManager.default.removeItem(at: shell) }
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.ensureLoaded()
        let defaultProfile = try await coordinator.previewConfig(profile: "default")
        let revision = coordinator.revision
        try Data("not valid = [".utf8).write(to: shell.appendingPathComponent("shell.toml"))
        try await coordinator.ensureLoaded()
        let cached = try await coordinator.previewConfig(profile: "default")
        XCTAssertEqual(cached, defaultProfile)
        XCTAssertEqual(coordinator.revision, revision)
        do {
            try await coordinator.refresh()
            XCTFail("An explicit refresh must report the broken configuration")
        } catch {}
        XCTAssertEqual(coordinator.revision, revision)
    }

    func testScalarSavePublishesOnceWithoutInvalidatingAgainOnRefresh() async throws {
        let shell = try fixture()
        defer { try? FileManager.default.removeItem(at: shell) }
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        let revision = coordinator.revision
        var publications = 0
        coordinator.onSave = { _ in publications += 1 }
        try await coordinator.set(46, key: "height")
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(coordinator.revision, revision + 1)
        try await coordinator.refresh()
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(coordinator.revision, revision + 1)
        XCTAssertEqual(coordinator.barLayout?.profile, "lake")
    }

    func testCompletedWritePublishesAfterTheLiveHostAdoptsTheSavedValue() async throws {
        let shell = try fixture()
        defer { try? FileManager.default.removeItem(at: shell) }
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        var publications = 0
        coordinator.onSave = { _ in publications += 1 }
        let written = expectation(description: "configuration written before reload")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        coordinator.writer = ShellIslandConfigWriter(shellDirectory: shell, writeFile: { data, url in
            try SettingsFileAccess.writeAtomically(data, at: url)
            written.fulfill()
            release.wait()
        }, reloadReady: {})
        let edit = Task { try await coordinator.island(.rootSetting(key: "width", value: .number(540))) }
        await fulfillment(of: [written], timeout: 5)
        coordinator.adopt(try load(shell))
        XCTAssertEqual(publications, 0)
        release.signal()
        _ = try await edit.value
        XCTAssertEqual(publications, 1)
        try await coordinator.refresh()
        XCTAssertEqual(publications, 1)
    }

    func testSourceAndAssetEditsRefreshWithNoLiveShellHost() async throws {
        for path in ["lib/sample.luau", "shaders/sample.metal", "assets/sample.png"] {
            let shell = try fixture()
            defer { try? FileManager.default.removeItem(at: shell) }
            let file = shell.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("before".utf8).write(to: file)
            let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
            try await coordinator.refresh()
            coordinator.startObserving()
            defer { coordinator.stopObserving() }
            try await coordinator.refresh()
            let revision = coordinator.revision
            let changed = expectation(description: "Source content revision published for " + path)
            withObservationTracking { _ = coordinator.revision } onChange: { changed.fulfill() }
            try Data("after-content".utf8).write(to: file)
            await fulfillment(of: [changed], timeout: 5)
            await coordinator.flush()
            XCTAssertEqual(coordinator.revision, revision + 1)
            XCTAssertNil(coordinator.metadataError)
        }
    }

    func testObservedShellDirectoryLinksRetargetAndKeepReloading() async throws {
        for suffix in ["", "shell"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let config = root.appendingPathComponent("config")
            let aliases = root.appendingPathComponent("aliases")
            for directory in [config, aliases] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let first = root.appendingPathComponent("targets/A").appendingPathComponent(suffix)
            let second = root.appendingPathComponent("targets/B").appendingPathComponent(suffix)
            for directory in [first, second] {
                _ = try ShellStyleFixture.prepare(into: directory)
                _ = try ShellProfiles.select("lake", in: directory)
            }
            let heightKey = ShellProfiles.key("workspaceBar", of: "lake") + ["height"]
            _ = try ShellProfiles.setValue(41, at: heightKey, in: first)
            _ = try ShellProfiles.setValue(47, at: heightKey, in: second)
            let intermediate = aliases.appendingPathComponent("current")
            try FileManager.default.createSymbolicLink(atPath: intermediate.path, withDestinationPath: "../targets/A")
            let link = config.appendingPathComponent("current")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../aliases/current")
            let shell = link.appendingPathComponent(suffix)
            let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
            try await coordinator.refresh()
            coordinator.startObserving()
            defer { coordinator.stopObserving() }
            try await coordinator.refresh()
            XCTAssertEqual(coordinator.config.barOverride?.settings.height, 41)

            try await expectObservedBarHeight(42, from: coordinator) {
                _ = try ShellProfiles.setValue(42, at: heightKey, in: first)
            }
            try await expectObservedBarHeight(47, from: coordinator) {
                try replaceDirectoryLink(intermediate, destination: "../targets/B")
            }
            try await expectObservedBarHeight(49, from: coordinator) {
                _ = try ShellProfiles.setValue(49, at: heightKey, in: second)
            }
            try await expectObservedBarHeight(42, from: coordinator) {
                try replaceDirectoryLink(link, destination: "../targets/A")
            }
            try await expectObservedBarHeight(43, from: coordinator) {
                _ = try ShellProfiles.setValue(43, at: heightKey, in: first)
            }
        }
    }

    func testObservedDirectoryLinksRecoverAfterRepairingTheNewTarget() async throws {
        for profile in [false, true] {
            let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("OmniWMPR1005-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let shell = root.appendingPathComponent("config/shell")
            let firstRoot = root.appendingPathComponent("targets/A")
            let secondRoot = root.appendingPathComponent("targets/B")
            for directory in [firstRoot, secondRoot] + (profile ? [shell] : []) {
                _ = try ShellStyleFixture.prepare(into: directory)
                _ = try ShellProfiles.select("lake", in: directory)
            }
            let first = profile ? firstRoot.appendingPathComponent("lake") : firstRoot
            let second = profile ? secondRoot.appendingPathComponent("lake") : secondRoot
            let link = profile ? shell.appendingPathComponent("lake") : shell
            if profile { try FileManager.default.removeItem(at: link) }
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
            let heightKey = profile ? ["workspaceBar", "height"] : ShellProfiles
                .key("workspaceBar", of: "lake") + ["height"]
            _ = try ShellProfiles.setValue(41, at: heightKey, in: first)
            _ = try ShellProfiles.setValue(47, at: heightKey, in: second)
            let file = second.appendingPathComponent("shell.toml")
            let repaired = try Data(contentsOf: file)
            try Data("broken = [".utf8).write(to: file)
            let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
            try await coordinator.refresh()
            coordinator.startObserving()
            defer { coordinator.stopObserving() }
            try await coordinator.refresh()
            XCTAssertEqual(coordinator.config.barOverride?.settings.height, 41)

            let failed = expectation(description: "Retargeted configuration error published")
            failed.assertForOverFulfill = false
            withObservationTracking { _ = coordinator.metadataError } onChange: { failed.fulfill() }
            try replaceDirectoryLink(link, destination: second.path)
            await fulfillment(of: [failed], timeout: 3)
            await coordinator.flush()
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertNotNil(coordinator.metadataError)
            XCTAssertEqual(coordinator.config.barOverride?.settings.height, 41)

            try await expectObservedBarHeight(47, from: coordinator) {
                try repaired.write(to: file)
            }
            try await expectObservedBarHeight(49, from: coordinator) {
                _ = try ShellProfiles.setValue(49, at: heightKey, in: second)
            }
        }
    }

    func testObservedProfileSwitchRecoversAfterRepairingAnUnselectedLinkedProfile() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("OmniWMPR1005-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("config/shell")
        let external = root.appendingPathComponent("external")
        for directory in [shell, external] {
            _ = try ShellStyleFixture.prepare(into: directory)
            _ = try ShellProfiles.select("lake", in: directory)
        }
        let target = external.appendingPathComponent("lake")
        _ = try ShellProfiles.setValue(47, at: ["workspaceBar", "height"], in: target)
        let file = target.appendingPathComponent("shell.toml")
        let repaired = try Data(contentsOf: file)
        try Data("broken = [".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(
            at: shell.appendingPathComponent("alternate"), withDestinationURL: target
        )
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        try await coordinator.refresh()

        let failed = expectation(description: "New profile configuration error published")
        failed.assertForOverFulfill = false
        withObservationTracking { _ = coordinator.metadataError } onChange: { failed.fulfill() }
        _ = try ShellProfiles.select("alternate", in: shell)
        await fulfillment(of: [failed], timeout: 3)
        await coordinator.flush()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNotNil(coordinator.metadataError)
        XCTAssertEqual(coordinator.config.profile, "lake")
        try await expectObservedBarHeight(47, from: coordinator) {
            try repaired.write(to: file)
        }
        XCTAssertEqual(coordinator.config.profile, "alternate")
        try await expectObservedBarHeight(49, from: coordinator) {
            _ = try ShellProfiles.setValue(49, at: ["workspaceBar", "height"], in: target)
        }
    }

    func testObservedShellLinkParentReplacementRebindsWithoutContentChanges() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("OmniWMPR1005-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("config")
        let shell = parent.appendingPathComponent("shell")
        let first = root.appendingPathComponent("targets/A")
        let second = root.appendingPathComponent("targets/B")
        for directory in [first, second] {
            _ = try ShellStyleFixture.prepare(into: directory)
            _ = try ShellProfiles.select("lake", in: directory)
        }
        let heightKey = ShellProfiles.key("workspaceBar", of: "lake") + ["height"]
        _ = try ShellProfiles.setValue(41, at: heightKey, in: first)
        _ = try ShellProfiles.setValue(47, at: heightKey, in: second)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: shell, withDestinationURL: first)
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        try await coordinator.refresh()
        let revision = coordinator.revision

        try FileManager.default.moveItem(at: parent, to: root.appendingPathComponent("retired"))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: shell, withDestinationURL: first)
        try await coordinator.refresh()
        try await Task.sleep(for: .milliseconds(600))
        await coordinator.flush()
        XCTAssertEqual(coordinator.revision, revision)
        try await expectObservedBarHeight(47, from: coordinator) {
            try replaceDirectoryLink(shell, destination: second.path)
        }
        try await expectObservedBarHeight(49, from: coordinator) {
            _ = try ShellProfiles.setValue(49, at: heightKey, in: second)
        }
    }

    func testObservedSchemaAndConfigurationEditsUpdateTheirOwners() async throws {
        let shell = try fixture()
        defer { try? FileManager.default.removeItem(at: shell) }
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        try await coordinator.refresh()
        let clock = try XCTUnwrap(coordinator.widgetSchemas["clock"])
        let changed = expectation(description: "Schema edit published")
        withObservationTracking { _ = coordinator.revision } onChange: { changed.fulfill() }
        try Data("[options.date]\ntype = 'number'\ndefault = 5\n".utf8)
            .write(to: clock.folder.appendingPathComponent("settings.toml"))
        await fulfillment(of: [changed], timeout: 5)
        await coordinator.flush()
        XCTAssertEqual(coordinator.widgetSchemas["clock"]?.options["date"]?.kind, .number)
        let published = expectation(description: "External configuration applied")
        coordinator.onSave = { config in
            XCTAssertEqual(config.barOverride?.settings.height, 47)
            published.fulfill()
        }
        _ = try ShellProfiles.setValue(47, at: ShellProfiles.key("workspaceBar", of: "lake") + ["height"], in: shell)
        await fulfillment(of: [published], timeout: 5)
        await coordinator.flush()
        XCTAssertEqual(coordinator.config.barOverride?.settings.height, 47)
    }

    func testFirstImplicitProfileEditUsesTheDiskSelectedStyle() async throws {
        let shell = try fixture()
        defer { try? FileManager.default.removeItem(at: shell) }
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.set(45, key: "height")
        XCTAssertEqual(coordinator.config.profile, "lake")
        XCTAssertEqual(coordinator.config.barOverride?.settings.height, 45)
        var problems: [String] = []
        let defaultStyle = try XCTUnwrap(ShellConfig.load(
            profile: "default",
            shellDirectory: shell,
            problems: &problems
        ))
        XCTAssertNotEqual(defaultStyle.barOverride?.settings.height, 45)
    }

    func testComponentSourceRemovalAndRestorationRefreshTheCatalog() async throws {
        let shell = try fixture()
        defer { try? FileManager.default.removeItem(at: shell) }
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        let descriptor = try XCTUnwrap(coordinator.catalog?.descriptors["world-clock"])
        let file = descriptor.folder.appendingPathComponent("component.luau")
        let original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try await coordinator.refresh()
        XCTAssertNil(coordinator.catalog?.descriptors["world-clock"])
        try original.write(to: file)
        try await coordinator.refresh()
        XCTAssertNotNil(coordinator.catalog?.descriptors["world-clock"])
    }

    func testFirstRootConfigurationWriteDoesNotInvalidateAgainOnRefresh() async throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        XCTAssertFalse(FileManager.default.fileExists(atPath: shell.appendingPathComponent("shell.toml").path))
        let revision = coordinator.revision
        try await coordinator.set(43, key: "height")
        XCTAssertEqual(coordinator.revision, revision + 1)
        try await coordinator.refresh()
        XCTAssertEqual(coordinator.revision, revision + 1)
    }

    func testSavingRewritesOnlyTheProfilesLayoutKeysAndResetRestoresTheProfile() async throws {
        let shell = try barFixture()
        try writeBarFile("""
        # my shell
        profile = "default"
        profiles.default.trailing = [
            "clock",
            "mine",
        ]

        [weather]
        city = "Toronto"
        """, to: "shell.toml", in: shell)
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        let initial = try XCTUnwrap(coordinator.barLayout)
        XCTAssertTrue(initial.customized)
        XCTAssertEqual(initial.trailing, ["clock", "mine"])

        try await coordinator.editBar {
            $0.remove("mine")
            $0.add("weather", to: .leading)
        }
        XCTAssertEqual(try parsedBarConfiguration(shell), [
            "profile": .string("default"),
            "profiles": .table(["default": .table([
                "leading": .array([.string("workspaces"), .string("weather")]),
                "center": .array([]),
                "trailing": .array([.string("clock")])
            ])]),
            "weather": .table(["city": .string("Toronto")])
        ])
        let saved = try XCTUnwrap(coordinator.barLayout)
        XCTAssertEqual(saved.leading, ["workspaces", "weather"])
        XCTAssertEqual(saved.trailing, ["clock"])

        try await coordinator.resetBarLayout()
        XCTAssertEqual(try parsedBarConfiguration(shell), [
            "profile": .string("default"),
            "weather": .table(["city": .string("Toronto")])
        ])
        let reset = try XCTUnwrap(coordinator.barLayout)
        XCTAssertFalse(reset.customized)
        XCTAssertEqual(reset.trailing, ["clock"])
    }

    func testEachProfileKeepsItsOwnLayout() async throws {
        let shell = try barFixture()
        try writeBarFile("leading = [\"clock\"]\ntrailing = []", to: "styled/shell.toml", in: shell)
        try writeBarFile("profile = \"styled\"", to: "shell.toml", in: shell)
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        XCTAssertEqual(coordinator.config.profile, "styled")
        try await coordinator.editBar { $0.add("weather", to: .center) }
        XCTAssertEqual(try parsedBarConfiguration(shell), [
            "profile": .string("styled"),
            "profiles": .table(["styled": .table([
                "leading": .array([.string("clock")]),
                "center": .array([.string("weather")]),
                "trailing": .array([])
            ])])
        ])
        let styled = try XCTUnwrap(coordinator.barLayout)
        XCTAssertEqual(styled.leading, ["clock"])
        XCTAssertEqual(styled.center, ["weather"])
        XCTAssertTrue(styled.customized)

        let selectedDefault = try await coordinator.selectProfile(ShellDefaults.profile)
        XCTAssertTrue(selectedDefault)
        let plain = try XCTUnwrap(coordinator.barLayout)
        XCTAssertEqual(plain.leading, ["workspaces"])
        XCTAssertEqual(plain.center, [])
        XCTAssertFalse(plain.customized)
        try await coordinator.resetBarLayout()
        let selectedStyled = try await coordinator.selectProfile("styled")
        XCTAssertTrue(selectedStyled)
        XCTAssertEqual(coordinator.barLayout?.center, ["weather"])
    }

    func testABrokenLayerBlocksEditingInsteadOfSavingFallbackLists() async throws {
        let shell = try barFixture()
        let original = "profiles.default.leading = [\"clock\"]\nprofiles.default.theme = \"dusk\"\n"
        try Data(original.utf8).write(to: shell.appendingPathComponent("shell.toml"))
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        try writeBarFile("leading = [", to: "default/shell.toml", in: shell)

        do {
            try await coordinator.refresh()
            XCTFail("A broken layer must not load")
        } catch let unreadable as ShellBarLayout.Unreadable {
            XCTAssertTrue(unreadable.problem.hasPrefix("default/shell.toml"), unreadable.problem)
        } catch {
            XCTFail("Expected unreadable layer, got \(error)")
        }
        do {
            try await coordinator.editBar { $0.remove("clock") }
            XCTFail("A broken layer must block editing")
        } catch let unreadable as ShellBarLayout.Unreadable {
            XCTAssertTrue(unreadable.problem.hasPrefix("default/shell.toml"), unreadable.problem)
        } catch {
            XCTFail("Expected unreadable layer, got \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: shell.appendingPathComponent("shell.toml")), Data(original.utf8))
    }

    func testBarEditsPreserveOutsideLayoutChanges() async throws {
        let shell = try barFixture()
        try writeBarFile("profiles.default.trailing = [\"clock\", \"weather\", \"mine\"]", to: "shell.toml", in: shell)
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        XCTAssertEqual(coordinator.barLayout?.trailing, ["clock", "weather", "mine"])

        let outside = "profiles.default.trailing = [\"mine\", \"clock\"]\nprofiles.default.center = [\"weather\"]\n"
        try Data(outside.utf8).write(to: shell.appendingPathComponent("shell.toml"))
        XCTAssertEqual(try Data(contentsOf: shell.appendingPathComponent("shell.toml")), Data(outside.utf8))
        try await coordinator.editBar { $0.remove("clock") }
        let saved = try XCTUnwrap(coordinator.barLayout)
        XCTAssertEqual(saved.center, ["weather"])
        XCTAssertEqual(saved.trailing, ["mine"])
        try await coordinator.editBar { $0.add("clock", to: .center) }
        XCTAssertEqual(coordinator.barLayout?.center, ["weather", "clock"])
    }

    func testResetBarLayoutRestoresSystemMenuPrefixAndRemovesLaneOverrides() async throws {
        let shell = try fixture()
        defer { try? FileManager.default.removeItem(at: shell) }
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        try await coordinator.refresh()
        let selected = try await coordinator.selectProfile("default")
        XCTAssertTrue(selected)
        let selectedTheme = try await coordinator.selectTheme("nocturne")
        XCTAssertTrue(selectedTheme)
        try await coordinator.editBar { $0.leading = ["workspaces"] }
        XCTAssertEqual(coordinator.config.leading, ["workspaces"])

        try await coordinator.resetBarLayout()

        XCTAssertEqual(Array(coordinator.config.leading.prefix(3)), ["apple-menu", "app-menu", "omniwm"])
        let document = try parsedBarConfiguration(shell)
        XCTAssertEqual(document["profile"], .string("default"))
        guard case let .table(profiles)? = document["profiles"],
              case let .table(profile)? = profiles["default"]
        else {
            return XCTFail("Expected retained default profile theme")
        }
        XCTAssertNil(profile["leading"])
        XCTAssertNil(profile["center"])
        XCTAssertNil(profile["trailing"])
        XCTAssertEqual(profile["theme"], .string("nocturne"))
    }

    private func barFixture() throws -> URL {
        let shell = try fixture()
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: shell.path) {
                try FileManager.default.removeItem(at: shell)
            }
        }
        try writeBarFile(
            "leading = [\"workspaces\"]\ntrailing = [\"clock\"]\nhiddenBarWidget = \"hidden-bar\"",
            to: "default/shell.toml",
            in: shell
        )
        try writeBarFile("function render(ctx) return ui.box{} end", to: "widgets/mine/init.luau", in: shell)
        return shell
    }

    private func writeBarFile(_ contents: String, to path: String, in shell: URL) throws {
        let url = shell.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((contents + "\n").utf8).write(to: url)
    }

    private func parsedBarConfiguration(_ shell: URL) throws -> [String: TOMLNode] {
        try TOMLDecoder().decode(
            [String: TOMLNode].self,
            from: Data(contentsOf: shell.appendingPathComponent("shell.toml"))
        )
    }

    private func expectObservedBarHeight(
        _ height: Double, from coordinator: ShellConfigurationCoordinator, edit: () throws -> Void
    ) async throws {
        let published = expectation(description: "Observed bar height \(height)")
        published.assertForOverFulfill = false
        coordinator.onSave = { config in
            if config.barOverride?.settings.height == height { published.fulfill() }
        }
        try edit()
        await fulfillment(of: [published], timeout: 3)
        await coordinator.flush()
        XCTAssertEqual(coordinator.config.barOverride?.settings.height, height)
        XCTAssertNil(coordinator.metadataError)
    }

    private func replaceDirectoryLink(_ link: URL, destination: String) throws {
        let replacement = link.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(atPath: replacement.path, withDestinationPath: destination)
        guard Darwin.rename(replacement.path, link.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func fixture() throws -> URL {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try ShellStyleFixture.prepare(into: shell)
        _ = try ShellProfiles.select("lake", in: shell)
        return shell
    }

    private func load(_ shell: URL) throws -> ShellConfig {
        var problems: [String] = []
        return try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems), "\(problems)")
    }
}
