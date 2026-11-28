// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMAutomation
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptLayoutChangedTests: XCTestCase {
    private static let noReads = "omniwm.on('layout.changed', function(event) assert(next(event) == nil) end)"

    func testRenumberingPublishesWithoutAReadAndKeepsTheCLIClassification() async throws {
        let fixture = try Fixture(test: self)
        let script = try await fixture.load(Self.noReads)
        try await fixture.applySilently(script)
        let previous = fixture.scene
        let before = try fixture.summary()
        #if DEBUG || OMNIWM_CONFIG_CALLBACK_TRACE
            let captures = ConfigScriptSnapshot.captures
        #endif

        try fixture.reverseFirstTwoColumns()
        try await fixture.publish(expecting: 1)

        let after = try fixture.summary()
        let first = fixture.tokens[0]
        let second = fixture.tokens[1]
        XCTAssertNotEqual(before.columnIndexByToken[first], before.columnIndexByToken[second])
        XCTAssertEqual(after.columnIndexByToken[first], before.columnIndexByToken[second])
        XCTAssertEqual(after.columnIndexByToken[second], before.columnIndexByToken[first])
        XCTAssertEqual(after.viewport, before.viewport)
        XCTAssertEqual(after.displayModes, before.displayModes)
        XCTAssertTrue(previous.niriColumnsAreFlexOnly)
        XCTAssertTrue(fixture.scene.niriColumnsAreFlexOnly)
        XCTAssertEqual(WMController.workspaceDataChannels(from: previous, to: fixture.scene), [])
        var beforeIPC = previous
        var afterIPC = fixture.scene
        beforeIPC.niriColumnsAreFlexOnly = false
        afterIPC.niriColumnsAreFlexOnly = false
        XCTAssertEqual(WMController.workspaceDataChannels(from: beforeIPC, to: afterIPC), [.windowsChanged])
        XCTAssertTrue(fixture.scene.bars.isEmpty)
        #if DEBUG || OMNIWM_CONFIG_CALLBACK_TRACE
            XCTAssertEqual(ConfigScriptSnapshot.captures, captures)
        #endif
        try await fixture.publish(expecting: 0)
    }

    func testPixelOnlyMovementAndBarChangesDoNotPublish() async throws {
        let fixture = try Fixture(test: self)
        let gap = fixture.controller.innerGap(for: fixture.monitor)
        XCTAssertGreaterThan(gap, 0)
        fixture.moveViewport(to: fixture.tokens.startIndex, offset: -gap / 2)
        try await fixture.applySilently(fixture.load(Self.noReads))
        let previous = fixture.scene
        let initialOffset = fixture.manager.niriViewportState(for: fixture.workspace).viewOffset

        fixture.moveViewport(to: fixture.tokens.startIndex, offset: -gap / 3)
        XCTAssertNotEqual(fixture.manager.niriViewportState(for: fixture.workspace).viewOffset, initialOffset)
        try await fixture.publish(expecting: 0)
        XCTAssertEqual(fixture.scene.niriColumns, previous.niriColumns)

        fixture.controller.settings.workspaceBar.enabled = true
        fixture.reconciler.noteBordersAndBarsChanged()
        try await fixture.publish(expecting: 0, schedule: false)
        XCTAssertNotEqual(fixture.scene.bars, previous.bars)
        XCTAssertEqual(fixture.scene.niriColumns, previous.niriColumns)
        XCTAssertEqual(WMController.workspaceDataChannels(from: previous, to: fixture.scene), [
            .workspaceBar, .windowsChanged, .layoutChanged
        ])
    }

    func testLayoutEdgeViewportAndTabModePublishCurrentDeclaredDetails() async throws {
        let fixture = try Fixture(test: self)
        let body = """
        local calls = 0
        omniwm.on('layout.changed', function(event)
            calls += 1
            local columns
            for _, row in assert(event.workspaces) do
                if row.id == '\(fixture.workspace.uuidString)' then columns = assert(row.columns) end
            end
            assert(columns and #columns == \(fixture.tokens.count))
            if calls == 1 then
                assert(columns[#columns].viewport == 'intersecting')
            else
                assert(calls == 2 and columns[1].mode == 'tabbed')
            end
        end, { reads = { 'workspaces', 'details' } })
        """
        try await fixture.applySilently(fixture.load(body))
        let before = try fixture.summary()
        XCTAssertEqual(before.viewport?.last, .after)
        let last = try XCTUnwrap(fixture.tokens.indices.last)
        fixture.moveViewport(to: last)
        fixture.reconciler.noteInvalidation(.layoutEdge)
        XCTAssertEqual(fixture.reconciler.pendingReconcileScope, .fullScene)
        try await fixture.publish(expecting: 1, schedule: false)
        let scrolled = try fixture.summary()
        XCTAssertEqual(scrolled.viewport?.last, .intersecting)
        XCTAssertEqual(scrolled.columnIndexByToken, before.columnIndexByToken)

        try fixture.setMode(.tabbed, at: fixture.tokens.startIndex)
        try await fixture.publish(expecting: 1)
        XCTAssertEqual(try fixture.summary().displayModes?.first, .tabbed)
        XCTAssertTrue(fixture.scene.bars.isEmpty)
    }

    func testAReplacementSeedsFromTheCurrentSceneSilentlyAndRetirementDropsDemand() async throws {
        let fixture = try Fixture(test: self)
        let original = try await fixture.load(Self.noReads)
        try await fixture.applySilently(original)
        let replacement = try await fixture.load(Self.noReads)
        try fixture.reverseFirstTwoColumns()
        try await fixture.applySilently(replacement)
        try fixture.reverseFirstTwoColumns()
        try await fixture.publish(expecting: 1)

        let withoutListener = try await fixture.load("omniwm.command('No listener', function() end)")
        try await fixture.applySilently(withoutListener)
        XCTAssertNil(fixture.controller.scriptLayoutObserver)
        XCTAssertTrue(fixture.scene.niriColumns.isEmpty)

        fixture.reconciler.noteInvalidation(.layoutEdge)
        XCTAssertEqual(fixture.reconciler.pendingReconcileScope, .borderOnly)
    }

    func testAListenerInstalledBeforeServicesStartsWithTheFirstPublishedScene() async throws {
        let fixture = try Fixture(test: self)
        fixture.controller.hasStartedServices = false
        try await fixture.applySilently(fixture.load(Self.noReads))
        XCTAssertTrue(fixture.scene.niriColumns.isEmpty)

        try fixture.reverseFirstTwoColumns()
        fixture.controller.hasStartedServices = true
        try await fixture.publish(expecting: 0)
        XCTAssertEqual(try fixture.summary().columnIndexByToken.count, fixture.tokens.count)

        try fixture.reverseFirstTwoColumns()
        try await fixture.publish(expecting: 1)
    }

    func testQueuedChangesCoalesceDuringDeliveryAndCaptureTheNewestDetails() async throws {
        let fixture = try Fixture(test: self)
        let delivery = "First layout delivery"
        let body = """
        local calls = 0
        omniwm.on('layout.changed', function(event)
            calls += 1
            if calls == 1 then error('\(delivery)') end
            assert(calls == 2)
            for _, row in assert(event.workspaces) do
                if row.id == '\(fixture.workspace.uuidString)' then
                    local columns = assert(row.columns)
                    assert(columns[1].mode == 'normal' and columns[#columns].mode == 'tabbed')
                    return
                end
            end
            error('Workspace missing from layout event')
        end, { reads = { 'workspaces', 'details' } })
        """
        try await fixture.applySilently(fixture.load(body))
        let first = fixture.tokens.startIndex
        let last = try XCTUnwrap(fixture.tokens.indices.last)
        var diagnostics: [String] = []
        fixture.script.onDiagnosticChanged = { diagnostic in
            guard let diagnostic else { return }
            diagnostics.append(diagnostic)
            if diagnostics.count == 1, diagnostic.contains(delivery) {
                do {
                    try fixture.setMode(.normal, at: first)
                    fixture.reconcile()
                    try fixture.setMode(.tabbed, at: last)
                    fixture.reconcile()
                } catch {
                    XCTFail("Cannot mutate fixture columns: \(error)")
                }
            }
        }
        defer { fixture.script.onDiagnosticChanged = nil }
        #if DEBUG || OMNIWM_CONFIG_CALLBACK_TRACE
            let captures = ConfigScriptSnapshot.captures
        #endif
        try fixture.setMode(.tabbed, at: first)
        try await fixture.publish(expecting: 2, diagnostic: delivery)
        XCTAssertEqual(diagnostics.count, 1)
        #if DEBUG || OMNIWM_CONFIG_CALLBACK_TRACE
            XCTAssertEqual(ConfigScriptSnapshot.captures - captures, 2)
        #endif
    }

    func testEmptyWorkspaceLayoutChangesReachTheSceneFromTheCommandAndSettingsReload() async throws {
        let fixture = try Fixture(test: self, windowCount: 0)
        let body = """
        local seen = {}
        omniwm.on('layout.changed', function(event)
            for _, row in assert(event.workspaces) do
                if row.id == '\(fixture.workspace.uuidString)' then
                    table.insert(seen, assert(row.layout))
                    return
                end
            end
            error('Workspace missing from the layout change')
        end, { reads = { 'workspaces', 'details' } })
        omniwm.command('Check changes', function()
            assert(table.concat(seen, ',') == 'dwindle,niri')
        end)
        """
        try await fixture.applySilently(fixture.load(body))
        XCTAssertTrue(try fixture.summary().columnIndexByToken.isEmpty)

        let beforeCommand = omni_config_vm_entry_count()
        XCTAssertEqual(fixture.controller.commandHandler.setWorkspaceLayout(.dwindle), .executed)
        try await fixture.finishScheduledLayout()
        XCTAssertNil(fixture.scene.niriColumns[fixture.workspace])
        assertConfigVMEntries(1, since: beforeCommand)

        let beforeReload = omni_config_vm_entry_count()
        try fixture.reloadLayout(.niri)
        try await fixture.finishScheduledLayout()
        XCTAssertTrue(try fixture.summary().columnIndexByToken.isEmpty)
        assertConfigVMEntries(1, since: beforeReload)

        let beforeEquivalentReload = omni_config_vm_entry_count()
        try fixture.reloadLayout(.defaultLayout)
        try await fixture.finishScheduledLayout()
        assertConfigVMEntries(0, since: beforeEquivalentReload)

        let check = try XCTUnwrap(fixture.script.acceptedCommands.first { $0.name == "Check changes" })
        XCTAssertEqual(fixture.controller.enqueueConfigFunction(check.function), .executed)
        await fixture.script.callbackQueue?.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testDwindleRatioChangesDoNotPublish() async throws {
        let fixture = try Fixture(test: self, layout: .dwindle)
        try await fixture.applySilently(fixture.load(Self.noReads))
        let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
        let token = try XCTUnwrap(fixture.tokens.first)
        let split = try XCTUnwrap(engine.existingState(for: fixture.workspace)?.leafByToken[token]?.parent)
        guard case let .split(orientation, ratio) = split.kind else {
            return XCTFail("The fixture window must be in a split")
        }
        fixture.manager.withEngineMutationScope(in: fixture.workspace) {
            split.kind = .split(orientation: orientation, ratio: ratio / 2)
        }
        try await fixture.publish(expecting: 0)
        XCTAssertNil(fixture.scene.niriColumns[fixture.workspace])
    }
}

extension ConfigScriptLayoutChangedTests {
    @MainActor
    private struct Fixture {
        let controller: WMController
        let script: ConfigScriptController
        let persistence: SettingsFilePersistence
        let monitor: Monitor
        let workspace: WorkspaceDescriptor.ID
        let tokens: [WindowToken]

        var manager: WorkspaceManager {
            controller.workspaceManager
        }

        var reconciler: SurfaceReconciler {
            controller.surfaceReconciler
        }

        var scene: DesiredSurfaceScene {
            reconciler.appliedScene
        }

        init(test: XCTestCase, layout: LayoutType = .niri, windowCount: Int = 3) throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("LayoutChanged-\(UUID().uuidString)")
            let persistence = SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            )
            let monitor = NiriGatherFixture.monitor(displayId: UInt32.max - 1)
            let (controller, workspace) = try Self.makeController(
                persistence: persistence, directory: directory, monitor: monitor, layout: layout
            )
            let settings = controller.settings
            let pid: pid_t = 73_000
            let tokens = (0 ..< windowCount).map { WindowToken(pid: pid, windowId: Int(pid) + $0) }
            Self.track(tokens, in: workspace, on: monitor, controller: controller)
            controller.layoutRefreshController.resetState()
            controller.layoutRefreshController.layoutState
                .backingScaleByDisplay = [monitor.displayId: monitor.backingScale]
            let script = ConfigScriptController(
                fileURL: settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent("init.luau"),
                settings: settings, wmController: controller, didChangeBindings: { _ in }
            )
            controller.configScript = script
            controller.hasStartedServices = true
            settings.onExternalSettingsReloaded = { [weak controller] in
                controller?.updateWorkspaceConfig()
            }
            test.addTeardownBlock { @MainActor in
                controller.stopConfigScript()
                controller.hasStartedServices = false
                controller.layoutRefreshController.resetState()
                controller.surfaceReconciler.cleanup()
                try? FileManager.default.removeItem(at: directory)
            }
            self.controller = controller
            self.script = script
            self.persistence = persistence
            self.monitor = monitor
            self.workspace = workspace
            self.tokens = tokens
        }

        private static func makeController(
            persistence: SettingsFilePersistence, directory: URL, monitor: Monitor, layout: LayoutType
        ) throws -> (WMController, WorkspaceDescriptor.ID) {
            let settings = SettingsStore(
                persistence: persistence, runtimeState: RuntimeStateStore(directory: directory),
                autosaveEnabled: false
            )
            settings.hotkeyBindings = []
            settings.animationsEnabled = false
            settings.borders.enabled = false
            settings.workspaceBar.enabled = false
            settings.island.enabled = false
            settings.workspaces.defaultLayoutType = .niri
            let name = WorkspaceIDPolicy.lowestUnusedRawID(in: settings.workspaces.configuredNames())
            settings.workspaces.configurations = [
                WorkspaceConfiguration(
                    name: name, monitorAssignment: .specificDisplay(OutputId(from: monitor)), layoutType: layout
                )
            ]
            let controller = WMController(
                settings: settings, windowFocusOperations: NiriGatherFocusOperationRecorder().windowFocusOperations
            )
            let manager = controller.workspaceManager
            manager.applyMonitorConfigurationChange([monitor])
            manager.applySettings()
            let workspace = try XCTUnwrap(manager.workspaceId(for: name, createIfMissing: true))
            XCTAssertTrue(manager.setActiveWorkspace(workspace, on: monitor.id))
            _ = manager.setInteractionMonitor(monitor.id)
            let space = UInt64(monitor.displayId)
            manager.commitSpaceTopology(SpaceTopology(
                displays: [.init(
                    displayIdentifier: monitor.displayUUID ?? String(monitor.displayId),
                    spaceIds: [space], currentSpaceId: space
                )],
                activeSpaceId: space, fullscreenSpaceIds: [space]
            ))
            controller.enableNiriLayout()
            controller.enableDwindleLayout()
            return (controller, workspace)
        }

        private static func track(
            _ tokens: [WindowToken], in workspace: WorkspaceDescriptor.ID, on monitor: Monitor, controller: WMController
        ) {
            let manager = controller.workspaceManager
            for token in tokens {
                _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
            }
            manager.withEngineMutationScope(in: workspace) {
                for token in tokens {
                    switch manager.activeLayoutKind(for: workspace) {
                    case .dwindle:
                        _ = controller.dwindleEngine?.addWindow(token: token, to: workspace, activeWindowFrame: nil)
                    case .niri:
                        _ = controller.niriEngine?.addWindow(token: token, to: workspace, afterSelection: nil)
                    }
                }
                let span = monitor.visibleFrame.width / 2
                for column in controller.niriEngine?.columns(in: workspace) ?? [] {
                    column.width = .fixed(span)
                    column.cachedWidth = span
                }
            }
        }

        func load(_ source: String) async throws -> ConfigScriptLoad {
            let mask = controller.settings.hyperKeyModifiers.carbonMask
            let evaluation = try await script.loader.evaluate(Data(source.utf8), hyperMask: mask)
            return ConfigScriptLoad(versions: [:], result: .success(evaluation))
        }

        func applySilently(
            _ load: ConfigScriptLoad, file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            let entries = omni_config_vm_entry_count()
            XCTAssertTrue(
                script.apply(load, hyperMask: controller.settings.hyperKeyModifiers.carbonMask), file: file, line: line
            )
            reconcile()
            XCTAssertTrue(scene.parkingEdgeMasks.isEmpty, file: file, line: line)
            let queue = try XCTUnwrap(script.callbackQueue, file: file, line: line)
            XCTAssertFalse(queue.hasPendingWork, file: file, line: line)
            await queue.waitUntilParked()
            assertConfigVMEntries(0, since: entries, file: file, line: line)
            XCTAssertNil(script.diagnostic, file: file, line: line)
        }

        func moveViewport(to index: Int, offset: CGFloat = 0) {
            manager.withNiriViewportState(for: workspace) { state in
                state.activeColumnIndex = index
                state.jumpOffset(to: offset)
            }
        }

        func reverseFirstTwoColumns() throws {
            let engine = try XCTUnwrap(controller.niriEngine)
            let columns = engine.columns(in: workspace)
            let first = try XCTUnwrap(columns.first)
            let second = try XCTUnwrap(columns.dropFirst().first)
            manager.withEngineMutationScope(in: workspace) {
                first.swapWith(second)
            }
        }

        func setMode(_ mode: ColumnDisplay, at index: Int) throws {
            let engine = try XCTUnwrap(controller.niriEngine)
            let column = try XCTUnwrap(engine.columns(in: workspace).dropFirst(index).first)
            manager.withEngineMutationScope(in: workspace) {
                XCTAssertTrue(engine.setColumnDisplay(
                    mode, for: column, in: workspace, motion: .disabled, orientation: .horizontal
                ))
            }
        }

        func summary(file: StaticString = #filePath, line: UInt = #line) throws -> NiriColumnSummary {
            try XCTUnwrap(scene.niriColumns[workspace], file: file, line: line)
        }

        func reconcile(schedule: Bool = true) {
            if schedule { reconciler.noteWorldChanged() }
            reconciler.reconcileNow()
        }

        func publish(
            expecting count: UInt64, schedule: Bool = true, diagnostic: String? = nil,
            file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            let before = omni_config_vm_entry_count()
            let queue = try XCTUnwrap(script.callbackQueue, file: file, line: line)
            reconcile(schedule: schedule)
            XCTAssertEqual(queue.hasPendingWork, count > 0, file: file, line: line)
            await queue.waitUntilParked()
            assertConfigVMEntries(count, since: before, file: file, line: line)
            if let diagnostic {
                XCTAssertTrue(script.diagnostic?.contains(diagnostic) == true, file: file, line: line)
            } else {
                XCTAssertNil(script.diagnostic, file: file, line: line)
            }
        }

        func finishScheduledLayout() async throws {
            await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
            if reconciler.reconcileScheduled { reconciler.reconcileNow() }
            let queue = try XCTUnwrap(script.callbackQueue)
            await queue.waitUntilParked()
            XCTAssertNil(script.diagnostic)
        }

        func reloadLayout(_ layout: LayoutType) throws {
            var export = controller.settings.toExport()
            export.workspaceConfigurations = export.workspaceConfigurations.map { $0.with(layoutType: layout) }
            try SettingsLuauDocument.initialSource(export).write(
                to: controller.settings.settingsFileURL,
                options: .atomic
            )
            persistence.handlePossibleSettingsFileChange()
        }
    }
}
