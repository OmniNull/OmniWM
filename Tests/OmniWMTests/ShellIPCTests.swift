// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
@testable import OmniWMCtl
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellIPCTests: XCTestCase {
    func testCLIParsesShellSetAndUnset() throws {
        let set = try CLIParser.parse(arguments: ["omniwmctl", "shell", "set", "weather", "12°", "sunny"])
        XCTAssertEqual(set.request.payload, .shell(.set(key: "weather", value: "12° sunny")))
        let unset = try CLIParser.parse(arguments: ["omniwmctl", "shell", "unset", "weather"])
        XCTAssertEqual(unset.request.payload, .shell(.unset(key: "weather")))
        let toggle = try CLIParser.parse(arguments: ["omniwmctl", "shell", "toggle", "control"])
        XCTAssertEqual(toggle.request.payload, .shell(.toggle(widget: "control")))
        let profile = try CLIParser.parse(arguments: ["omniwmctl", "shell", "profile", "noctalia"])
        XCTAssertEqual(profile.request.payload, .shell(.profile(name: "noctalia")))
        let theme = try CLIParser.parse(arguments: ["omniwmctl", "shell", "theme", "nord"])
        XCTAssertEqual(theme.request.payload, .shell(.theme(name: "nord", scheme: nil)))
        let wallpaper = try CLIParser.parse(arguments: ["omniwmctl", "shell", "theme", "wallpaper", "vibrant"])
        XCTAssertEqual(wallpaper.request.payload, .shell(.theme(name: "wallpaper", scheme: "vibrant")))
        let eject = try CLIParser.parse(arguments: ["omniwmctl", "shell", "eject", "clock"])
        XCTAssertEqual(eject.request.payload, .shell(.eject(widget: "clock")))
        let library = try CLIParser.parse(arguments: ["omniwmctl", "shell", "eject", "lib/lake/policy.luau"])
        XCTAssertEqual(library.request.payload, .shell(.eject(widget: "lib/lake/policy.luau")))
        let create = try CLIParser.parse(arguments: ["omniwmctl", "shell", "init", "quota"])
        XCTAssertEqual(create.request.payload, .shell(.initialize(widget: "quota")))
        let bare = try CLIParser.parse(arguments: ["omniwmctl", "shell", "trigger", "quota", "refresh"])
        XCTAssertEqual(bare.request.payload, .shell(.trigger(widget: "quota", name: "refresh", value: nil)))
        let valued = try CLIParser.parse(arguments: ["omniwmctl", "shell", "trigger", "quota", "set", "80", "%"])
        XCTAssertEqual(valued.request.payload, .shell(.trigger(widget: "quota", name: "set", value: "80 %")))
        for arguments in [
            ["shell"], ["shell", "set", "weather"], ["shell", "unset", "a", "b"], ["shell", "get", "a"],
            ["shell", "toggle"], ["shell", "toggle", "a", "b"], ["shell", "profile"], ["shell", "eject", "a", "b"],
            ["shell", "theme"], ["shell", "theme", "a", "b", "c"],
            ["shell", "init", "a", "b"], ["shell", "trigger", "a"]
        ] {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl"] + arguments))
        }
    }

    func testShellRequestsRoundTripOnTheWire() throws {
        for shell in [
            IPCShellRequest.set(key: "weather", value: ""),
            .unset(key: "weather"),
            .toggle(widget: "my widget"),
            .profile(name: "noctalia"),
            .theme(name: "nord", scheme: nil),
            .theme(name: "wallpaper", scheme: "content"),
            .eject(widget: "clock"),
            .eject(widget: "lib/lake/policy.luau"),
            .initialize(widget: "quota"),
            .trigger(widget: "quota", name: "refresh", value: nil),
            .trigger(widget: "quota", name: "set", value: "80 %")
        ] {
            let line = try IPCWire.encodeRequestLine(IPCRequest(id: "1", shell: shell))
            XCTAssertEqual(try IPCWire.decodeRequest(from: line).payload, .shell(shell))
        }
        let unsetWithValue = Data("""
        {"version":20,"id":"1","kind":"shell","payload":{"name":"unset","key":"a","value":"b"}}
        """.utf8)
        XCTAssertThrowsError(try IPCWire.decodeRequest(from: unsetWithValue))
    }

    func testBarManagerValidatesAndStoresShellVars() {
        let manager = WorkspaceBarManager(
            configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            motionPolicy: MotionPolicy(animationsEnabled: false)
        )
        XCTAssertEqual(manager.applyShellRequest(.set(key: "weather.now", value: "12°")), .executed)
        XCTAssertEqual(manager.shellVars, ["weather.now": "12°"])
        XCTAssertEqual(manager.applyShellRequest(.unset(key: "weather.now")), .executed)
        XCTAssertEqual(manager.applyShellRequest(.unset(key: "weather.now")), .noChange)
        XCTAssertEqual(manager.applyShellRequest(.toggle(widget: "control")), .notFound)
        XCTAssertEqual(manager.applyShellRequest(.toggle(widget: "")), .invalidArguments)
        for invalid in [
            IPCShellRequest.profile(name: ".."),
            .profile(name: "a/b"),
            .theme(name: "../x", scheme: nil),
            .theme(name: "", scheme: nil),
            .theme(name: "wallpaper", scheme: ""),
            .theme(name: "nord", scheme: "vibrant"),
            .theme(name: "wallpaper", scheme: "sepia"),
            .eject(widget: ""),
            .eject(widget: ".x"),
            .eject(widget: "lib/../escape"),
            .eject(widget: "lib//policy.luau"),
            .eject(widget: "lib/"),
            .initialize(widget: "two words"),
            .initialize(widget: "quote\""),
            .trigger(widget: "", name: "refresh", value: nil),
            .trigger(widget: "quota", name: "has space", value: nil)
        ] {
            XCTAssertEqual(manager.applyShellRequest(invalid), .invalidArguments)
        }
        let tooLong = String(repeating: "x", count: IPCShellRequest.valueLimit + 1)
        for invalid in [
            IPCShellRequest.set(key: "", value: "a"),
            .set(key: "has space", value: "a"),
            .set(key: "wetter°", value: "a"),
            .set(key: "long", value: tooLong)
        ] {
            XCTAssertEqual(manager.applyShellRequest(invalid), .invalidArguments)
        }
        for index in 0 ..< IPCShellRequest.countLimit {
            XCTAssertEqual(manager.applyShellRequest(.set(key: "k\(index)", value: "v")), .executed)
        }
        XCTAssertEqual(manager.applyShellRequest(.set(key: "overflow", value: "v")), .invalidArguments)
        XCTAssertEqual(manager.applyShellRequest(.set(key: "k0", value: "updated")), .executed)
        XCTAssertEqual(manager.shellVars["k0"], "updated")
        XCTAssertEqual(manager.applyShellRequest(.trigger(widget: "quota", name: "refresh", value: nil)), .notFound)
    }

    func testShellToggleAndTriggerFollowTheCommandGates() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMShellIPCTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let bridge = IPCApplicationBridge(
            controller: controller,
            appVersion: "0.0.0-test",
            sessionToken: "session",
            authorizationToken: "token"
        )
        let send = { (request: IPCShellRequest) async in
            await bridge.response(for: IPCRequest(id: "shell", shell: request, authorizationToken: "token"))
        }
        let toggle = IPCShellRequest.toggle(widget: "control")
        let trigger = IPCShellRequest.trigger(widget: "quota", name: "refresh", value: nil)

        controller.isEnabled = false
        for request in [toggle, trigger] {
            let response = await send(request)
            XCTAssertEqual(response.status, .ignored)
            XCTAssertEqual(response.code, .disabled)
        }
        let set = await send(.set(key: "a", value: "b"))
        XCTAssertEqual(set.status, .executed)

        controller.isEnabled = true
        let allowed = await send(toggle)
        XCTAssertEqual(allowed.code, .notFound)

        controller.settings.animationsEnabled = false
        controller.toggleOverview()
        defer {
            if controller.isOverviewOpen() {
                controller.toggleOverview()
            }
        }
        XCTAssertTrue(controller.isOverviewOpen())
        for request in [toggle, trigger] {
            let response = await send(request)
            XCTAssertEqual(response.code, .overviewOpen)
        }
    }

    func testInitWritesAStarterWidgetOnceThatLoadsAndRenders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(try ShellProfiles.create("quota", in: root))
        XCTAssertFalse(try ShellProfiles.create("quota", in: root))
        let source = try String(
            contentsOf: root.appendingPathComponent("default/widgets/quota/init.luau"),
            encoding: .utf8
        )
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 8 << 20))
        defer { _ = omni_vm_destroy(vm) }
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(omni_vm_load(vm, "=quota", source, source.utf8.count, 100_000_000, &error, error.count), OMNI_OK)
        let declaration = ShellWidgetDeclaration(vm: vm)
        XCTAssertTrue(declaration.hasPopout)
        XCTAssertTrue(declaration.hasTrigger)
        let instance = try XCTUnwrap(omni_instance_create(vm))
        defer { omni_instance_destroy(instance) }
        for (key, value) in [("clock", "9:41"), ("date", "Thu 8 Oct")] {
            XCTAssertEqual(omni_instance_set_string(instance, key, value, value.utf8.count), OMNI_OK)
        }
        var stats = omni_render_stats()
        for view in [OMNI_VIEW_BAR, OMNI_VIEW_POPOUT] {
            XCTAssertEqual(omni_instance_render(instance, view, 8_000_000, &stats, &error, error.count), OMNI_OK)
        }
    }
}
