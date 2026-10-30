// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import Synchronization
import TOML
import XCTest

@MainActor
extension ShellDesktopEditorTests {
    struct Fixture {
        let shell: URL
        let configuration: ShellConfigurationCoordinator
        let editor: ShellDesktopEditor
        let saves: Events
    }

    func fixture(style: String = "lake") async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellDesktopEditorTests-\(UUID().uuidString)")
        let shell = directory.appendingPathComponent("shell")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        try ShellStyleFixture.installAll(into: shell)
        let configuration = ShellConfigurationCoordinator(shellDirectory: shell)
        try await configuration.ensureLoaded()
        try Data("""
        profile = "default"
        [weather]
        city = "Toronto"
        [profiles.default.workspaceBar]
        height = 34
        [profiles.lake.workspaceBar]
        height = 40
        [profiles.lake.weather]
        city = "Paris"
        [profiles.nocturne.workspaceBar]
        height = 46
        """.utf8).write(to: shell.appendingPathComponent("shell.toml"))
        try await configuration.refresh()
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        let controller = WMController(settings: settings)
        let editor = ShellDesktopEditor(configuration: configuration, settings: settings, controller: controller)
        let selected = await editor.selectStyle(style)
        XCTAssertTrue(selected)
        await editor.reload()
        XCTAssertEqual(editor.snapshot?.config.profile, style)
        let saves = Events()
        configuration.onSave = { _ in saves.record() }
        return Fixture(shell: shell, configuration: configuration, editor: editor, saves: saves)
    }

    func document(_ fixture: Fixture) throws -> [String: TOMLNode] {
        try TOMLDecoder().decode(
            [String: TOMLNode].self,
            from: Data(contentsOf: fixture.shell.appendingPathComponent("shell.toml"))
        )
    }

    func outsideLake(_ document: [String: TOMLNode]) -> [String: TOMLNode] {
        var document = document
        if case var .table(profiles)? = document["profiles"] {
            profiles["lake"] = nil
            document["profiles"] = .table(profiles)
        }
        return document
    }

    func display() -> Monitor {
        Monitor(
            id: .init(displayId: 94_611), displayId: 94_611,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876), hasNotch: false, name: "Editor display"
        )
    }

    func dirtyText(_ editor: ShellDesktopEditor, value: String = "#123456FF") async -> ShellEditorDraft.Key {
        _ = await editor.selectWidget("omniwm")
        editor.beginTextDraft(widget: "omniwm", key: "iconColor")
        let key = ShellEditorDraft.Key(widget: "omniwm", option: "iconColor")
        editor.updateDraft(key, .text(value))
        return key
    }

    func waitForSaving(_ configuration: ShellConfigurationCoordinator) async {
        guard !configuration.isSaving else { return }
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = configuration.isSaving } onChange: { continuation.resume() }
        }
    }

    func observeRoute(_ navigation: SettingsNavigationModel, changed: Events) {
        withObservationTracking { _ = navigation.route } onChange: {
            Task { @MainActor in changed.record() }
        }
    }

    func observeProblem(_ editor: ShellDesktopEditor, changed: Events) {
        withObservationTracking { _ = editor.problem } onChange: {
            Task { @MainActor in changed.record() }
        }
    }

    @MainActor
    final class Events {
        private(set) var count = 0
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func record() {
            count += 1
            let ready = waiters.filter { count >= $0.0 }
            waiters.removeAll { count >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }

        func wait(_ count: Int) async {
            guard self.count < count else { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
    }

    struct GateState {
        var entered = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    final class Gate: Sendable {
        private let state = Mutex(GateState())
        private let release = DispatchSemaphore(value: 0)

        func block() {
            let waiters = state.withLock {
                $0.entered = true
                let waiters = $0.waiters
                $0.waiters.removeAll()
                return waiters
            }
            for waiter in waiters { waiter.resume() }
            release.wait()
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let entered = state.withLock {
                    if $0.entered { return true }
                    $0.waiters.append(continuation)
                    return false
                }
                if entered { continuation.resume() }
            }
        }

        func finish() {
            release.signal()
        }
    }

    @MainActor
    final class HeldWrite {
        private var continuation: CheckedContinuation<Void, any Error>?
        let entered = Events()

        func write(_ value: Int) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                entered.record()
            }
        }

        func finish(failing: Bool = false) {
            let current = continuation
            continuation = nil
            if failing { current?.resume(throwing: CocoaError(.fileWriteNoPermission)) }
            else { current?.resume() }
        }
    }
}
