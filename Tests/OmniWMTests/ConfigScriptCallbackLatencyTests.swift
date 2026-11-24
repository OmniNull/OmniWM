// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#if OMNIWM_LIVE_CHECKS && OMNIWM_CONFIG_CALLBACK_TRACE
    import AppKit
    import Carbon
    @testable import OmniWM
    import XCTest

    extension ConfigScriptLoader {
        fileprivate func crossExecutorForNativeControl() {
            ConfigScriptLatencyTrace.mark(.callback)
        }
    }

    @MainActor
    final class ConfigScriptCallbackLatencyTests: XCTestCase {
        private enum Route: CaseIterable {
            case plain
            case queuedNative
            case function
        }

        private static let warmupRounds = 5
        private static let measuredRounds = 36
        private var visibility: XCTestExpectation?
        private var dismissal: XCTestExpectation?

        @objc private func panelVisibilityChanged(_ note: Notification) {
            guard let panel = note.object as? NSPanel else { return }
            if panel.occlusionState.contains(.visible), let visibility {
                ConfigScriptLatencyTrace.mark(.visible)
                self.visibility = nil
                visibility.fulfill()
            } else if !panel.occlusionState.contains(.visible), let dismissal {
                self.dismissal = nil
                dismissal.fulfill()
            }
        }

        func testMatchedChordToVisiblePalette() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let controller = makeController(in: directory)
            defer {
                controller.hotkeys.stop()
                controller.mouseEventHandler.cleanup()
                controller.layoutRefreshController.resetState()
                try? FileManager.default.removeItem(at: directory)
            }
            let palette = controller.commandPaletteController
            palette.presentation.create(controller: palette)
            let panel = try XCTUnwrap(palette.presentation.panel)
            NotificationCenter.default.addObserver(
                self, selector: #selector(panelVisibilityChanged(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: panel
            )
            defer {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didChangeOcclusionStateNotification,
                    object: panel
                )
                palette.dismiss(reason: .superseded)
                controller.stopConfigScript()
            }
            let loader = ConfigScriptLoader()
            let config = try await loadBindings(for: controller, loader: loader)
            let entries = HotkeyCenter.registrationPlan(for: config.effectiveBindings).sideSpecificRegistrations
            let function = try XCTUnwrap(entries.first { if case .configFunction = $0.command { true } else { false } })
            let native = try XCTUnwrap(entries.first { $0.command == .openCommandPaletteMode(.commands) })
            let center = controller.hotkeys
            let ordinaryRoute = try XCTUnwrap(center.onCommand)
            let queuedRoute: (HotkeyInvocation) -> Void = { invocation in
                ConfigScriptLatencyTrace.mark(.enqueued)
                Task { @MainActor in
                    await loader.crossExecutorForNativeControl()
                    ordinaryRoute(invocation)
                }
            }
            let routes = Route.allCases
            for round in 0 ..< Self.warmupRounds + Self.measuredRounds {
                for index in routes.indices {
                    let route = routes[(index + round) % routes.count]
                    let entry = route == .function ? function : native
                    center.sideSpecificDispatch = [.init(binding: entry.binding, command: entry.command)]
                    center.onCommand = route == .queuedNative ? queuedRoute : ordinaryRoute
                    try await sample(route, round: round, key: entry.binding, controller: controller, panel: panel)
                }
            }
        }

        private func makeController(in directory: URL) -> WMController {
            _ = NSApplication.shared
            let settings = SettingsStore(
                persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
                runtimeState: RuntimeStateStore(
                    directory: directory.appendingPathComponent("state"),
                    deferSaves: false
                ),
                autosaveEnabled: false
            )
            settings.animationsEnabled = false
            settings.hotkeyBindings = []
            return WMController(settings: settings)
        }

        private func loadBindings(
            for controller: WMController,
            loader: ConfigScriptLoader
        ) async throws -> ConfigScriptController {
            let source = """
            local open = omniwm.cmd("open-command-palette", "commands")
            omniwm.keymap.set("Left Option+I", open)
            omniwm.keymap.set("Left Option+O", function() omniwm.dispatch(open) end)
            """
            let directory = controller.settings.settingsFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let config = ConfigScriptController(
                fileURL: directory.appendingPathComponent("init.luau"),
                settings: controller.settings
            ) { _ in }
            controller.configScript = config
            let mask = controller.settings.hyperKeyModifiers.carbonMask
            let evaluation = try await loader.evaluate(Data(source.utf8), hyperMask: mask)
            XCTAssertTrue(config.apply(ConfigScriptLoad(versions: [:], result: .success(evaluation)), hyperMask: mask))
            XCTAssertNil(config.diagnostic)
            return config
        }

        private func sample(
            _ route: Route, round: Int, key: KeyBinding, controller: WMController, panel: NSPanel
        ) async throws {
            guard !panel.isVisible, !panel.occlusionState.contains(.visible) else {
                return XCTFail("The previous palette presentation is still visible.")
            }
            let center = controller.hotkeys
            center.suppressedHotkeyKeyCodes.remove(key.keyCode)
            let shown = expectation(description: "WindowServer reports the palette panel visible")
            visibility = shown
            let flags = CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK)
            ConfigScriptLatencyTrace.reset()
            ConfigScriptLatencyTrace.mark(.chord)
            let matched = center.dispatchCommandKeyDown(keyCode: key.keyCode, rawFlags: flags)
            XCTAssertTrue(matched)
            if round == 0, route == .plain {
                let online = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
                let listed = online?.contains { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }
                print(
                    "Warmup panel ordered=\(panel.isVisible) palette=\(controller.commandPaletteController.isVisible) " +
                        "occlusion=\(panel.occlusionState.rawValue) WindowServerOnScreen=\(String(describing: listed)) " +
                        "alpha=\(panel.alphaValue) screen=\(String(describing: panel.screen?.frame))"
                )
            }
            await fulfillment(of: [shown], timeout: failureBound)
            let stamps = ConfigScriptLatencyTrace.read()
            let stages = route == .plain
                ? [ConfigScriptLatencyTrace.Stage.chord, .nativeCommand, .visible]
                : [.chord, .enqueued, .callback, .nativeCommand, .visible]
            let start = try XCTUnwrap(stamps[.chord])
            let elapsed = try stages.map { stage in
                let instant = try XCTUnwrap(stamps[stage], stage.rawValue)
                return "\(stage.rawValue)=\(instant - start)"
            }
            let retained = round >= Self.warmupRounds
            print(
                "Config latency route=\(route) round=\(round) retained=\(retained) ns \(elapsed.joined(separator: " "))"
            )
            let hidden = expectation(description: "WindowServer reports the dismissed palette hidden")
            dismissal = hidden
            controller.commandPaletteController.dismiss(reason: .superseded)
            if !panel.occlusionState.contains(.visible), dismissal != nil {
                dismissal = nil
                hidden.fulfill()
            }
            await fulfillment(of: [hidden], timeout: failureBound)
            XCTAssertFalse(panel.isVisible)
            await controller.configScript?.callbackQueue?.waitUntilParked()
        }
    }
#endif
