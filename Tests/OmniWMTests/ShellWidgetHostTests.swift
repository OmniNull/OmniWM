// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellWidgetOutboxTests: XCTestCase {
    private final class Sink {
        var batches: [[String: ShellWidgetDelivery]] = []
    }

    private func wire(stringCount: UInt32, epoch: UInt32 = 0) -> [UInt8] {
        var header = omni_wire_header(
            magic: OMNI_WIRE_MAGIC,
            node_count: 0,
            string_count: stringCount,
            flags: 0,
            deps: 0,
            epoch: epoch
        )
        var bytes = withUnsafeBytes(of: &header) { Array($0) }
        var record = omni_wire_string(id: 1, length: 1)
        bytes += withUnsafeBytes(of: &record) { Array($0) }
        bytes += [UInt8(ascii: "a"), 0, 0, 0]
        return bytes
    }

    func testOlderGenerationCannotReplaceNewerDelivery() async {
        let key = ShellTreeKey(bar: ShellBarKey(monitor: .init(displayId: 1)), view: .bar)
        let delivered = expectation(description: "delivered")
        let sink = Sink()
        let outbox = ShellWidgetOutbox { batch in
            sink.batches.append(batch)
            delivered.fulfill()
        }
        wire(stringCount: 1).withUnsafeBytes {
            outbox.publish(name: "widget", generation: 2, key: key, sequence: 1, output: $0)
        }
        wire(stringCount: 1).withUnsafeBytes {
            outbox.publish(name: "widget", generation: 1, key: key, sequence: 1, output: $0)
        }
        outbox.fail(name: "widget", generation: 1, failure: ShellScriptFailure(kind: .runtime, message: "stale"))
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertEqual(sink.batches.count, 1)
        XCTAssertEqual(sink.batches.first?["widget"]?.generation, 2)
        XCTAssertEqual(sink.batches.first?["widget"]?.stringCount, 1)
        XCTAssertNil(sink.batches.first?["widget"]?.failure)
    }

    func testFirstFailureInABatchIsKept() async {
        let delivered = expectation(description: "delivered")
        let sink = Sink()
        let outbox = ShellWidgetOutbox { batch in
            sink.batches.append(batch)
            delivered.fulfill()
        }
        outbox.fail(name: "widget", generation: 1, failure: ShellScriptFailure(kind: .runtime, message: "handler"))
        outbox.fail(
            name: "widget",
            generation: 1,
            failure: ShellScriptFailure(kind: .runtime, message: "render"),
            deps: ShellDataKey.vars.bit
        )
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertEqual(sink.batches.first?["widget"]?.failure?.message, "handler")
        XCTAssertEqual(sink.batches.first?["widget"]?.failedDeps, ShellDataKey.vars.bit)
    }

    func testLaterDeliveryPreservesRetainedBatchContents() async throws {
        let key = ShellTreeKey(bar: ShellBarKey(monitor: .init(displayId: 1)), view: .bar)
        let first = expectation(description: "first delivery")
        let second = expectation(description: "second delivery")
        let sink = Sink()
        let outbox = ShellWidgetOutbox { batch in
            sink.batches.append(batch)
            (sink.batches.count == 1 ? first : second).fulfill()
        }
        let original = wire(stringCount: 1, epoch: 1)
        original.withUnsafeBytes {
            outbox.publish(name: "widget", generation: 1, key: key, sequence: 1, output: $0)
        }
        outbox.request(name: "widget", generation: 1, requests: [.init(bar: key.bar, text: "first")])
        await fulfillment(of: [first], timeout: 10)
        for sequence in 2 ... 4 {
            wire(stringCount: 1, epoch: 2).withUnsafeBytes {
                outbox.publish(name: "widget", generation: 1, key: key, sequence: sequence, output: $0)
            }
            outbox.request(name: "widget", generation: 1, requests: [.init(bar: key.bar, text: "later")])
        }
        await fulfillment(of: [second], timeout: 10)
        XCTAssertEqual(sink.batches.count, 2)
        let retained = try XCTUnwrap(sink.batches[0]["widget"])
        let current = try XCTUnwrap(sink.batches[1]["widget"])
        XCTAssertEqual(retained.trees[key]?.nodes, Array(original.prefix(MemoryLayout<omni_wire_header>.stride)))
        XCTAssertEqual(retained.strings, Array(original.dropFirst(MemoryLayout<omni_wire_header>.stride)))
        XCTAssertEqual(retained.requests.map(\.text), ["first"])
        XCTAssertEqual(retained.stringCount, 1)
        XCTAssertEqual(current.trees[key]?.sequence, 4)
        XCTAssertEqual(current.stringCount, 3)
        XCTAssertEqual(current.requests.map(\.text), ["later", "later", "later"])
    }

    func testEpochChangeReplacesTreesAndStringsWhilePreservingSideEffects() async throws {
        let bar = ShellBarKey(monitor: .init(displayId: 1))
        let firstKey = ShellTreeKey(bar: bar, view: .bar)
        let secondKey = ShellTreeKey(bar: bar, view: .popout)
        let delivered = expectation(description: "coalesced delivery")
        let sink = Sink()
        let outbox = ShellWidgetOutbox { batch in
            sink.batches.append(batch)
            delivered.fulfill()
        }
        for key in [firstKey, secondKey] {
            wire(stringCount: 1, epoch: 1).withUnsafeBytes {
                outbox.publish(name: "widget", generation: 1, key: key, sequence: 1, output: $0)
            }
        }
        outbox.request(name: "widget", generation: 1, requests: [.init(bar: bar, text: "pending")])
        outbox.demand(name: "widget", generation: 1, background: 3)
        outbox.reload(name: "widget", generation: 1)
        outbox.fail(name: "widget", generation: 1, failure: .init(kind: .runtime, message: "first"), deps: 4)
        wire(stringCount: 1, epoch: 2).withUnsafeBytes {
            outbox.publish(name: "widget", generation: 1, key: secondKey, sequence: 2, output: $0)
        }
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertEqual(sink.batches.count, 1)
        let delivery = try XCTUnwrap(sink.batches.first?["widget"])
        XCTAssertEqual(delivery.epoch, 2)
        XCTAssertEqual(delivery.trees.count, 1)
        XCTAssertEqual(delivery.trees[secondKey]?.sequence, 2)
        XCTAssertEqual(delivery.stringCount, 1)
        XCTAssertEqual(delivery.strings.count, MemoryLayout<omni_wire_string>.stride + 4)
        XCTAssertEqual(delivery.requests.map(\.text), ["pending"])
        XCTAssertEqual(delivery.backgroundDemand, 3)
        XCTAssertTrue(delivery.reload)
        XCTAssertEqual(delivery.failure?.message, "first")
        XCTAssertEqual(delivery.failedDeps, 4)
    }
}

@MainActor
final class ShellWidgetBarLifecycleTests: XCTestCase {
    private var controller: WMController!
    private var root: URL?
    private var managers: [WorkspaceBarManager] = []

    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.root = root
        let config = root.appendingPathComponent("config", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: config, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let widget = config.appendingPathComponent("shell/widgets/test", isDirectory: true)
        try FileManager.default.createDirectory(at: widget, withIntermediateDirectories: true)
        try Data("function render(ctx) return ui.text{ text = \"hello\" } end".utf8)
            .write(to: widget.appendingPathComponent("init.luau"))
        try Data("profiles.default.leading = []\nprofiles.default.trailing = [\"test\"]\n".utf8)
            .write(to: config.appendingPathComponent("shell/shell.toml"))
        controller = WMController(settings: settings)
    }

    override func tearDown() async throws {
        for manager in managers { manager.cleanup() }
        if let controller {
            controller.hasStartedServices = false
            controller.workspaceBarManager.cleanup()
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
        for manager in managers { await manager.flushShellForQuit() }
        if let controller { await controller.workspaceBarManager.flushShellForQuit() }
        managers.removeAll()
        controller = nil
        await ShellWidgetHost.flushRetiredWork()
        if let root, FileManager.default.fileExists(atPath: root.path) {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                XCTFail("Could not remove shell lifecycle fixture at \(root.path): \(error)")
            }
        }
        root = nil
        try await super.tearDown()
    }

    func testCleanupKeepsBarsRemovedAndNextApplyRestoresWidgets() async {
        executionTimeAllowance = 60
        let manager = makeManager()

        manager.apply([barSurface()])
        await waitForShellWidgets(manager)
        XCTAssertNotNil(manager.notificationBadges.onLabelsChange)

        manager.cleanup()
        XCTAssertTrue(manager.barsByMonitor.isEmpty)
        XCTAssertNil(manager.notificationBadges.onLabelsChange)

        manager.apply([barSurface()])
        await waitForShellWidgets(manager)
        XCTAssertEqual(manager.barsByMonitor[monitor.id]?.model.snapshot.shellWidgets.map(\.id), ["test"])
        manager.cleanup()
    }

    func testBarsStartTheShellAndInstallTheDefaultProfile() async throws {
        executionTimeAllowance = 60
        let shell = ShellWidgetHost.shellDirectory(in: controller.settings.settingsFileURL.deletingLastPathComponent())
        try FileManager.default.removeItem(at: shell)
        let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = WindowToken(pid: NSRunningApplication.current.processIdentifier, windowId: 92_305)
        _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
        XCTAssertTrue(controller.workspaceManager.confirmManagedFocus(
            token, in: workspace, activateWorkspaceOnMonitor: false
        ))
        let manager = makeManager()
        defer { manager.cleanup() }

        manager.apply([barSurface()])
        XCTAssertNotNil(manager.shellHost)
        let clock = shell.appendingPathComponent("default/widgets/clock/init.luau")
        XCTAssertEqual(
            try Data(contentsOf: clock),
            try Data(contentsOf: XCTUnwrap(ShellConfig.bundledWidget("clock")))
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: shell.appendingPathComponent("widgets").path))
        let expected = ["apple-menu", "app-menu", "omniwm"]
        await until {
            let ids = manager.barsByMonitor[monitor.id]?.model.snapshot.shellWidgets.map(\.id) ?? []
            return Set(ids).isSuperset(of: expected)
        }
        XCTAssertEqual(
            manager.barsByMonitor[monitor.id].map { Array($0.model.snapshot.shellWidgets.prefix(3).map(\.id)) },
            expected
        )
    }

    func testWakeCleanupKeepsTheShellHostAndItsWidgets() async {
        executionTimeAllowance = 60
        let manager = makeManager()
        defer { manager.cleanup() }
        manager.apply([barSurface()])
        await waitForShellWidgets(manager)
        let host = manager.shellHost

        manager.cleanup(keepingShell: true)
        XCTAssertTrue(manager.barsByMonitor.isEmpty)
        XCTAssertTrue(manager.shellHost === host)

        manager.apply([barSurface()])
        XCTAssertEqual(manager.barsByMonitor[monitor.id]?.model.snapshot.shellWidgets.map(\.id), ["test"])
    }

    func testBarHiddenWhileEnabledKeepsItsWidgetInstance() async {
        executionTimeAllowance = 60
        controller.settings.workspaceBar.enabled = true
        let manager = makeManager()
        defer { manager.cleanup() }
        var bar = barSurface()
        manager.apply([bar])
        await waitForShellWidgets(manager)

        bar.visible = false
        manager.apply([bar])
        XCTAssertNil(manager.barsByMonitor[monitor.id])

        bar.visible = true
        manager.apply([bar])
        XCTAssertEqual(manager.barsByMonitor[monitor.id]?.model.snapshot.shellWidgets.map(\.id), ["test"])
    }

    func testWidgetsReadTheBarSettingsFromStyle() async throws {
        executionTimeAllowance = 60
        let shell = ShellWidgetHost.shellDirectory(in: controller.settings.settingsFileURL.deletingLastPathComponent())
        let widget = shell.appendingPathComponent("widgets/test/init.luau")
        try Data("""
        function render(ctx)
            local style = ctx.data.bar.style
            return ui.box{ h = 10, w = (style.position == "bottom" and 30 or 10)
                + (style.textColor == "#FF0000FF" and 100 or 0) + (style.vertical and 1000 or 0) }
        end
        """.utf8).write(to: widget)
        controller.settings.workspaceBar.position = .bottom
        XCTAssertTrue(try ShellProfiles.setValue(
            SettingsColor(red: 1, green: 0, blue: 0, alpha: 1),
            at: ShellProfiles.key("workspaceBar", of: "default") + ["textColor"],
            in: shell
        ))
        let manager = makeManager()
        defer { manager.cleanup() }
        manager.apply([barSurface()])
        await until {
            manager.barsByMonitor[monitor.id]?.model.snapshot.shellWidgets.first?.size.width == 130
        }
    }

    func testAutoHiddenBarStartsTheShellHost() {
        let manager = makeManager()
        defer { manager.cleanup() }
        var bar = barSurface()
        bar.visible = false
        bar.retainWhileHidden = true

        manager.apply([bar])

        XCTAssertNotNil(manager.shellHost)
    }

    func testAutoHiddenBarKeepsItsShellWidgetsWhileHiddenAndOnReveal() async {
        executionTimeAllowance = 60
        let manager = makeManager()
        defer { manager.cleanup() }
        var bar = barSurface()
        manager.apply([bar])
        await waitForShellWidgets(manager)

        bar.visible = false
        bar.retainWhileHidden = true
        manager.apply([bar])
        XCTAssertEqual(manager.barsByMonitor[monitor.id]?.model.snapshot.shellWidgets.map(\.id), ["test"])

        bar.visible = true
        manager.apply([bar])
        XCTAssertEqual(manager.barsByMonitor[monitor.id]?.model.snapshot.shellWidgets.map(\.id), ["test"])
    }

    func testShellPopoutKeepsAnAutoHideBarRevealed() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("popouts need the main display")
        }
        let display = Monitor(
            id: .init(displayId: CGMainDisplayID()),
            displayId: CGMainDisplayID(),
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            hasNotch: false,
            name: "Main"
        )
        let drawer = controller.settings.settingsFileURL.deletingLastPathComponent()
            .appendingPathComponent("shell/widgets/drawer", isDirectory: true)
        try FileManager.default.createDirectory(at: drawer, withIntermediateDirectories: true)
        try Data("""
        function render(ctx) return ui.text{ text = "d" } end
        function popout(ctx) return ui.box{ w = 50, h = 30 } end
        """.utf8).write(to: drawer.appendingPathComponent("init.luau"))
        try Data("profiles.default.trailing = [\"test\", \"drawer\"]\n".utf8)
            .write(to: drawer.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("shell.toml"))
        controller.settings.workspaceBar.autoHide = true
        var pointer = display.frame.center
        controller.currentMouseLocation = { pointer }
        let manager = makeManager()
        defer { manager.cleanup() }
        var bar = barSurface(on: display)
        bar.visible = false
        bar.retainWhileHidden = true
        manager.apply([bar])
        await waitForShellWidgets(manager, on: display, count: 2, loaded: "drawer")
        let panel = try XCTUnwrap(manager.barsByMonitor[display.id]?.primary.panel)
        panel.setFrame(
            CGRect(x: display.frame.minX + 100, y: display.frame.maxY - 24, width: 200, height: 24),
            display: false
        )
        panel.contentView?.layoutSubtreeIfNeeded()
        manager.rebuildAutoHideTargets()
        pointer = CGPoint(x: panel.frame.midX, y: display.frame.maxY - 0.5)
        manager.handleAutoHideMouseMoved(at: pointer)
        XCTAssertTrue(manager.isPointerRevealed(on: display.id))

        let host = try XCTUnwrap(manager.shellHost)
        XCTAssertTrue(host.togglePopout(of: "drawer", on: display.id))
        pointer = display.frame.center
        manager.handleAutoHideMouseMoved(at: pointer)
        XCTAssertTrue(manager.isPointerRevealed(on: display.id))

        XCTAssertTrue(host.togglePopout(of: "drawer", on: display.id))
        XCTAssertNil(host.popout)
        XCTAssertFalse(manager.isPointerRevealed(on: display.id))
    }

    func testTheShellHiddenBarDrawerJoinsAndFollowsTheBarPanel() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("drawers need the main display")
        }
        let display = Monitor(
            id: .init(displayId: CGMainDisplayID()),
            displayId: CGMainDisplayID(),
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            hasNotch: false,
            name: "Main"
        )
        let shell = controller.settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent("shell")
        let drawer = shell.appendingPathComponent("widgets/drawer", isDirectory: true)
        try FileManager.default.createDirectory(at: drawer, withIntermediateDirectories: true)
        try Data("""
        function render(ctx) return ui.box{ w = ctx.data.hiddenBar.cell, h = 10 } end
        function popout(ctx) return ui.box{ w = 260, h = 30 } end
        """.utf8).write(to: drawer.appendingPathComponent("init.luau"))
        try Data(
            "profiles.default.leading = []\nprofiles.default.trailing = [\"test\"]\nprofiles.default.hiddenBarWidget = \"drawer\"\n"
                .utf8
        )
        .write(to: shell.appendingPathComponent("shell.toml"))
        let manager = makeManager()
        defer { manager.cleanup() }
        let bar = barSurface(on: display)
        manager.apply([bar])
        await waitForShellWidgets(manager, on: display, count: 2)
        let instance = try XCTUnwrap(manager.barsByMonitor[display.id])
        let place = { (x: CGFloat) in
            instance.primary.panel.setFrame(
                CGRect(x: display.visibleFrame.minX + x, y: display.visibleFrame.maxY - 34, width: 200, height: 34),
                display: false
            )
        }
        place(100)
        let first = try XCTUnwrap(manager.hiddenBarPanelPlacement(on: display.id))
        XCTAssertEqual(first.cellHeight, 30)
        manager.makeShellHiddenBarDrawer().show([], display.id, first)
        let host = try XCTUnwrap(manager.shellHost)
        let popout = try XCTUnwrap(host.popout)
        XCTAssertEqual(popout.widget, "drawer")
        XCTAssertEqual(popout.drawerPlacement, first)
        let cellWidth = { instance.model.snapshot.shellWidgets.first { $0.id == "drawer" }?.size.width }
        await until { cellWidth() == 30 }
        await until { instance.model.hiddenBarJoinEdge != nil }
        XCTAssertEqual(instance.model.hiddenBarJoinEdge, first.attachment.edge)
        XCTAssertTrue(popout.panel.isVisible)

        place(400)
        manager.apply([bar])
        let second = try XCTUnwrap(manager.hiddenBarPanelPlacement(on: display.id))
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(host.popout === popout)
        XCTAssertEqual(popout.drawerPlacement, second)

        manager.makeShellHiddenBarDrawer().close(false)
        XCTAssertNil(host.popout)
        XCTAssertNil(instance.model.hiddenBarJoinEdge)

        let detached = HiddenBarPanelPlacement(
            attachment: PopupAttachment(anchor: CGPoint(x: display.frame.midX, y: display.visibleFrame.maxY)),
            visibleFrame: display.visibleFrame
        )
        manager.makeShellHiddenBarDrawer().show([], display.id, detached)
        place(250)
        manager.apply([bar])
        XCTAssertEqual(host.popout?.drawerPlacement, detached)

        manager.makeShellHiddenBarDrawer().close(false)
        manager.makeShellHiddenBarDrawer().show(
            [],
            display.id,
            try XCTUnwrap(manager.hiddenBarPanelPlacement(on: display.id))
        )
        XCTAssertNotNil(host.popout)
        var hidden = bar
        hidden.visible = false
        manager.apply([hidden])
        XCTAssertNil(host.popout)
    }

    func testMenuAcquisitionKeepsDrawerPlacementUntilCloseAndEndsWhenItsBarDisappears() async throws {
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("drawers need the main display")
        }
        let display = Monitor(
            id: .init(displayId: CGMainDisplayID()),
            displayId: CGMainDisplayID(),
            frame: screen.frame,
            visibleFrame: screen.frame,
            hasNotch: false,
            name: "Main"
        )
        let shell = controller.settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent("shell")
        let drawer = shell.appendingPathComponent("widgets/drawer", isDirectory: true)
        try FileManager.default.createDirectory(at: drawer, withIntermediateDirectories: true)
        try Data("""
        function render(ctx) return ui.box{ w = 30, h = 10 } end
        function popout(ctx) return ui.box{ w = 260, h = 30 } end
        """.utf8).write(to: drawer.appendingPathComponent("init.luau"))
        try Data("""
        profiles.default.leading = []
        profiles.default.trailing = ["test"]
        profiles.default.hiddenBarWidget = "drawer"
        """.utf8).write(to: shell.appendingPathComponent("shell.toml"))
        let manager = makeManager()
        defer { manager.cleanup() }
        manager.apply([barSurface(on: display)])
        await waitForShellWidgets(manager, on: display, count: 2)
        let instance = try XCTUnwrap(manager.barsByMonitor[display.id])
        instance.primary.panel.setFrame(
            CGRect(x: display.frame.minX + 100, y: display.frame.maxY - 34, width: 200, height: 34),
            display: false
        )
        let session = controller.hiddenBarController.menuSession
        let key = MenuBarItemKey(bundleID: "com.example.menu", ordinal: 0)
        let host = try XCTUnwrap(manager.shellHost)

        for removeBar in [false, true] {
            let placement = try XCTUnwrap(manager.hiddenBarPanelPlacement(on: display.id))
            manager.makeShellHiddenBarDrawer().show([], display.id, placement)
            let popout = try XCTUnwrap(host.popout)
            let anchor = ShellAnchor(frame: popout.panel.frame, level: popout.panel.level)
            manager.showHiddenBarMenu(key, origin: ShellCommandOrigin(monitor: display.id, anchor: anchor))
            let child = try XCTUnwrap(host.hiddenBarMenu)
            let started = expectation(description: "menu acquisition started")
            let returned = expectation(description: "menu acquisition returned")
            let ready = AsyncStream.makeStream(of: Void.self)
            var releases = 0
            session.acquire(
                target: .init(key: key, ownerPID: getpid(), cachedItems: nil),
                resolve: {
                    started.fulfill()
                    for await _ in ready.stream { break }
                    returned.fulfill()
                    return nil
                },
                release: { disposition in
                    XCTAssertEqual(disposition, .conceal)
                    releases += 1
                },
                onOpen: { _ in XCTFail("Closed acquisition must not publish") }
            )
            await fulfillment(of: [started], timeout: 5)
            let screenChangeHandled = expectation(description: "screen change handled")
            let ordinaryPanel = PanelDismissalMonitor()
            ordinaryPanel.start(
                panels: [instance.primary.panel], isExemptWindow: { _ in false },
                onDismiss: { screenChangeHandled.fulfill() }
            )
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            await fulfillment(of: [screenChangeHandled], timeout: 5)
            ordinaryPanel.stop()
            let changed = Monitor(
                id: display.id, displayId: display.displayId,
                frame: display.frame,
                visibleFrame: display.frame.insetBy(dx: 0, dy: removeBar ? 30 : 15),
                hasNotch: false, name: display.name
            )
            manager.apply([barSurface(on: changed)])
            let latest = try XCTUnwrap(manager.hiddenBarPanelPlacement(on: display.id))
            XCTAssertNotEqual(latest, placement)
            XCTAssertEqual(session.bundleID, key.bundleID)
            XCTAssertEqual(releases, 0)
            XCTAssertTrue(host.popout === popout)
            XCTAssertTrue(host.hiddenBarMenu === child)
            XCTAssertEqual(popout.drawerPlacement, placement)

            if removeBar {
                manager.apply([])
                XCTAssertNil(host.popout)
            } else {
                host.closeHiddenBarMenu()
                XCTAssertTrue(host.popout === popout)
                XCTAssertEqual(popout.drawerPlacement, latest)
                NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
                await until { host.popout == nil }
                XCTAssertNil(host.popout)
            }
            XCTAssertNil(host.hiddenBarMenu)
            XCTAssertNil(session.bundleID)
            XCTAssertEqual(releases, 1)
            ready.continuation.finish()
            await fulfillment(of: [returned], timeout: 5)
        }
    }

    func testTheHiddenBarDrawerOpensOnTheFirstPressWhenNoBarIsShown() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("drawers need the main display")
        }
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let shell = controller.settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent("shell")
        let drawer = shell.appendingPathComponent("widgets/drawer", isDirectory: true)
        try FileManager.default.createDirectory(at: drawer, withIntermediateDirectories: true)
        try Data("""
        function render(ctx) return ui.box{ w = 10, h = 10 } end
        function popout(ctx) return ui.box{ w = 260, h = 30 } end
        """.utf8).write(to: drawer.appendingPathComponent("init.luau"))
        try Data(
            "profiles.default.leading = []\nprofiles.default.trailing = [\"test\"]\nprofiles.default.hiddenBarWidget = \"drawer\"\n"
                .utf8
        )
        .write(to: shell.appendingPathComponent("shell.toml"))
        controller.settings.workspaceBar.enabled = false
        controller.settings.hiddenBar.enabled = true
        let manager = makeManager()
        defer { manager.cleanup() }
        manager.apply([])
        XCTAssertNil(manager.shellHost)

        controller.settings.workspaceBar.enabled = true
        manager.apply([])
        let host = try XCTUnwrap(manager.shellHost)
        let placement = HiddenBarPanelPlacement(
            attachment: PopupAttachment(anchor: CGPoint(x: screen.frame.midX, y: screen.visibleFrame.maxY)),
            visibleFrame: screen.visibleFrame
        )
        let toggle = manager.makeShellHiddenBarDrawer()
        XCTAssertTrue(toggle.isActive())
        await until { host.widgets["drawer"]?.package != nil }
        _ = try XCTUnwrap(host.widgets["drawer"]?.package)
        toggle.show([], main, placement)
        let popout = try XCTUnwrap(host.popout)
        XCTAssertEqual(popout.drawerPlacement, placement)
        await until { popout.surface.size.width > 0 }
        XCTAssertEqual(popout.surface.size, CGSize(width: 260, height: 30))
        XCTAssertTrue(host.slots(for: main).isEmpty)

        try Data("""
        function render(ctx) return ui.box{ w = 10, h = 10 } end
        function popout(ctx) return ui.box{ w = 200, h = 30 } end
        """.utf8).write(to: drawer.appendingPathComponent("init.luau"))
        host.rescan()
        await until { host.popout == nil }
        guard host.popout == nil else { return XCTFail("The old drawer did not close during reload") }
        toggle.show([], main, placement)
        let reloaded = try XCTUnwrap(host.popout)
        await until { reloaded.surface.size.width > 0 }
        XCTAssertEqual(reloaded.surface.size, CGSize(width: 200, height: 30))

        toggle.close(false)
        XCTAssertNil(host.popout)
    }

    func testHoverDrawersOpenWhenThePointerReachesTheirScreenEdge() async throws {
        executionTimeAllowance = 60
        let monitors = controller.workspaceManager.monitors
        guard let main = monitors.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("drawers need the main display")
        }
        let point = CGPoint(x: main.frame.maxX - 0.5, y: main.frame.midY)
        let edge = ShellDrawerConfig(id: "probe", edge: .right, widgets: [], hover: true)
        guard ShellEdgeHover.touches(point, edge, main.frame, monitors.map(\.frame)) else {
            throw XCTSkip("the main display's right edge adjoins another display")
        }
        let shell = controller.settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent("shell")
        let widget = shell.appendingPathComponent("widgets/test", isDirectory: true)
        try Data("""
        function render(ctx) return ui.box{ w = 10, h = 10 } end
        function popout(ctx) return ui.box{ w = 50, h = 30 } end
        """.utf8).write(to: widget.appendingPathComponent("init.luau"))
        try Data("""
        profiles.default.leading = []
        profiles.default.trailing = ["test"]
        [profiles.default.drawer.controls]
        widgets = ["test"]
        hover = true
        """.utf8).write(to: shell.appendingPathComponent("shell.toml"))
        let manager = makeManager()
        defer { manager.cleanup() }
        manager.apply([barSurface(on: main)])
        await waitForShellWidgets(manager, on: main, count: 1)
        XCTAssertTrue(manager.needsShellEdgeMouseMoves)

        manager.handleAutoHideMouseMoved(at: CGPoint(x: main.frame.midX, y: main.frame.midY))
        XCTAssertNil(manager.shellHost?.drawer)
        manager.handleAutoHideMouseMoved(at: point)
        XCTAssertEqual(manager.shellHost?.drawer?.id, "controls")
        XCTAssertEqual(manager.shellHost?.drawer?.monitor, main.id)
    }

    func testFlushDashboardDrawersStayOpenUntilThePointerLeavesThem() async throws {
        executionTimeAllowance = 60
        let monitors = controller.workspaceManager.monitors
        guard let main = monitors.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("drawers need the main display")
        }
        let shell = controller.settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent("shell")
        let widget = shell.appendingPathComponent("widgets/test", isDirectory: true)
        try Data("""
        function render(ctx) return ui.box{ w = 10, h = 10 } end
        function popout(ctx) return ui.box{ w = 300, h = 120, fill = "surface" } end
        """.utf8).write(to: widget.appendingPathComponent("init.luau"))
        try Data("""
        profiles.default.leading = []
        profiles.default.trailing = ["test"]
        [profiles.default.drawer.dashboard]
        edge = "top"
        widgets = ["test"]
        hover = true
        reach = 10
        width = 400
        close = "leave"
        chrome = false
        """.utf8).write(to: shell.appendingPathComponent("shell.toml"))
        let manager = makeManager()
        defer { manager.cleanup() }
        manager.apply([barSurface(on: main)])
        await waitForShellWidgets(manager, on: main, count: 1)
        let host = try XCTUnwrap(manager.shellHost)
        XCTAssertTrue(host.toggleDrawer("dashboard", on: main.id))
        let drawer = try XCTUnwrap(host.drawer)
        XCTAssertNil(drawer.holdRegion)
        await until { drawer.panel.isVisible }
        XCTAssertNotNil(drawer.holdRegion)
        XCTAssertFalse(drawer.chrome)
        XCTAssertEqual(drawer.sections.first?.surface.view.frame.origin, .zero)
        XCTAssertEqual(drawer.panel.frame.width, 300)

        manager.handleAutoHideMouseMoved(at: CGPoint(x: main.frame.minX + 5, y: main.frame.minY + 5))
        XCTAssertNotNil(host.drawer)
        manager.handleAutoHideMouseMoved(at: CGPoint(x: drawer.panel.frame.midX, y: drawer.panel.frame.midY))
        XCTAssertNotNil(host.drawer)
        manager.handleAutoHideMouseMoved(at: CGPoint(x: main.frame.minX + 5, y: main.frame.minY + 5))
        XCTAssertNil(host.drawer)
    }

    func testSystemStatsTogglesTheConfiguredWidgetWhereItIsShown() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("popouts need the main display")
        }
        let display = Monitor(
            id: .init(displayId: CGMainDisplayID()),
            displayId: CGMainDisplayID(),
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            hasNotch: false,
            name: "Main"
        )
        let other = Monitor(
            id: .init(displayId: 92_501),
            displayId: 92_501,
            frame: CGRect(x: -2000, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: -2000, y: 0, width: 800, height: 600),
            hasNotch: false,
            name: "Other"
        )
        let shell = controller.settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent("shell")
        let stats = shell.appendingPathComponent("widgets/stats", isDirectory: true)
        try FileManager.default.createDirectory(at: stats, withIntermediateDirectories: true)
        try Data("""
        function render(ctx) return ui.box{ w = 10, h = 10 } end
        function popout(ctx) return ui.box{ w = 50, h = 30 } end
        """.utf8).write(to: stats.appendingPathComponent("init.luau"))
        try Data(
            "profiles.default.leading = []\nprofiles.default.trailing = [\"test\", \"stats\"]\nprofiles.default.systemStatsWidget = \"stats\"\n"
                .utf8
        )
        .write(to: shell.appendingPathComponent("shell.toml"))
        let manager = makeManager()
        defer { manager.cleanup() }
        manager.apply([barSurface(on: display)])
        await waitForShellWidgets(manager, on: display, count: 2)
        let primary = try XCTUnwrap(manager.barsByMonitor[display.id]).primary
        primary.panel.setFrame(
            CGRect(x: display.visibleFrame.minX + 100, y: display.visibleFrame.maxY - 24, width: 200, height: 24),
            display: false
        )
        primary.hostingView.layoutSubtreeIfNeeded()
        let host = try XCTUnwrap(manager.shellHost)
        XCTAssertEqual(host.systemStatsWidget, "stats")
        XCTAssertTrue(host.shows("stats", on: display.id))
        XCTAssertFalse(host.shows("stats", on: other.id))
        let anchor = try XCTUnwrap(host.widgets["stats"]?.instances[ShellBarKey(monitor: display.id)]?.surface?
            .screenAnchor)
        XCTAssertTrue(screen.frame.contains(CGPoint(x: anchor.frame.midX, y: anchor.frame.midY)))

        XCTAssertFalse(manager.toggleShellSystemStats(preferring: [other]))
        XCTAssertNil(host.popout)
        XCTAssertTrue(manager.toggleShellSystemStats(preferring: [other, display]))
        XCTAssertEqual(host.popout?.widget, "stats")
        XCTAssertEqual(host.popout?.key.monitor, display.id)
        manager.closeShellSystemStats(on: other.id)
        XCTAssertNotNil(host.popout)
        manager.closeShellSystemStats(on: display.id)
        XCTAssertNil(host.popout)

        XCTAssertTrue(manager.toggleShellSystemStats(preferring: [display]))
        XCTAssertTrue(manager.toggleShellSystemStats(preferring: [display]))
        XCTAssertNil(host.popout)
    }

    private func makeManager() -> WorkspaceBarManager {
        let manager = WorkspaceBarManager(
            configDirectory: controller.settings.settingsFileURL.deletingLastPathComponent(),
            motionPolicy: MotionPolicy(animationsEnabled: false)
        )
        manager.setup(controller: controller, settings: controller.settings)
        manager.panelFactory = { WorkspaceBarPanel.defaultPanel() }
        manager.frameApplier = { _, _ in }
        managers.append(manager)
        return manager
    }

    func testTheShellProfileOverridesTheBarSettingsWhileTheHostRuns() async throws {
        executionTimeAllowance = 60
        let shell = ShellWidgetHost.shellDirectory(in: controller.settings.settingsFileURL.deletingLastPathComponent())
        try Data("""
        profiles.default.leading = []
        profiles.default.trailing = []
        [profiles.default.workspaceBar]
        height = 31
        [profiles.default.hiddenBar]
        enabled = false
        """.utf8).write(to: shell.appendingPathComponent("shell.toml"))
        controller.settings.hiddenBar.enabled = true
        let manager = makeManager()
        defer { manager.cleanup() }

        manager.apply([barSurface()])
        let override = try XCTUnwrap(controller.settings.workspaceBar.profileOverride)
        XCTAssertEqual(override.profile, "default")
        XCTAssertEqual(override.settings.height, 31)
        XCTAssertEqual(controller.settings.workspaceBar.resolved(for: monitor).height, 31)
        XCTAssertEqual(controller.settings.hiddenBar.profileOverride?.enabled, false)
        XCTAssertFalse(controller.settings.effectiveHiddenBarEnabled)

        manager.cleanup()
        XCTAssertNil(controller.settings.workspaceBar.profileOverride)
        XCTAssertNil(controller.settings.hiddenBar.profileOverride)
        XCTAssertTrue(controller.settings.effectiveHiddenBarEnabled)
    }

    func testHiddenBarGlyphsBecomeBitmapsThatOutliveOnePublish() throws {
        let manager = makeManager()
        defer { manager.cleanup() }
        manager.apply([barSurface()])
        let host = try XCTUnwrap(manager.shellHost)
        let image = {
            NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                return true
            }
        }
        let publish = { (image: NSImage?) in
            manager.publishShellHiddenBar([HiddenBarGlyph(
                key: MenuBarItemKey(bundleID: "com.example.app", ordinal: 1),
                name: "App",
                image: image,
                size: CGSize(width: 16, height: 16)
            )])
            return manager.shellHiddenBarBitmaps.first
        }
        let first = try XCTUnwrap(publish(image()))
        XCTAssertNotNil(host.resources.bitmap(first))
        let second = try XCTUnwrap(publish(image()))
        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(host.resources.bitmap(first))
        XCTAssertNil(publish(nil))
        XCTAssertNil(host.resources.bitmap(first))
        XCTAssertNotNil(host.resources.bitmap(second))
        _ = publish(nil)
        XCTAssertNil(host.resources.bitmap(second))
    }

    func testSplitBarsGiveEachIslandItsOwnShellWidgets() async {
        executionTimeAllowance = 60
        controller.settings.workspaceBar.notchMode = .splitActiveLeft
        let manager = makeManager()
        defer { manager.cleanup() }
        let focused = WorkspaceBarItem(
            id: WorkspaceDescriptor.ID(),
            name: "1",
            rawName: "1",
            isFocused: true,
            tiledWindows: [],
            floatingWindows: []
        )

        manager.apply([barSurface(items: [focused])])
        await waitForShellWidgets(manager)
        let instance = manager.barsByMonitor[monitor.id]
        XCTAssertEqual(instance?.model.snapshot.shellWidgets.map(\.island), [.secondary])
        XCTAssertEqual(instance?.secondary?.slice, .secondary)
        XCTAssertEqual(instance?.primary.slice, .active)
    }

    private func waitForShellWidgets(_ manager: WorkspaceBarManager) async {
        await waitForShellWidgets(manager, on: monitor, count: 1)
    }

    private func waitForShellWidgets(
        _ manager: WorkspaceBarManager,
        on monitor: Monitor,
        count: Int,
        loaded widget: String? = nil
    ) async {
        let widgets = { manager.barsByMonitor[monitor.id]?.model.snapshot.shellWidgets.count }
        await until("\(count) shell widgets on \(monitor.name), have \(String(describing: widgets()))") {
            if let widget, manager.shellHost?.widgets[widget]?.package == nil { return false }
            return (widgets() ?? 0) >= count
        }
    }

    private func barSurface(on monitor: Monitor? = nil, items: [WorkspaceBarItem] = []) -> DesiredBarSurface {
        DesiredBarSurface(
            monitor: monitor ?? self.monitor,
            visible: true,
            snapshot: WorkspaceBarSnapshot(
                projection: WorkspaceBarProjection(items: items, scratchpads: []),
                backgroundOpacity: 0.6,
                barHeight: 24
            )
        )
    }

    private var monitor: Monitor {
        Monitor(
            id: .init(displayId: 92_300),
            displayId: 92_300,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055),
            hasNotch: false,
            name: "Test"
        )
    }
}

@MainActor
final class ShellWidgetClickTests: XCTestCase {
    private final class Sink {
        var commands: [ShellRequest] = []
        var origins: [ShellCommandOrigin] = []
        var world = ShellWorldData()
        var vars: [String: String] = [:]
        var bars: [ShellBarKey: ShellBarData] = [:]
        var barRequests = 0
        var menus: [String] = []
        var previews: [String?] = []
        var drags: [ShellDragRequest] = []
        var titleDemands: [Bool] = []
        var popoutChanges = 0
        var iconOverride: NSImage?
    }

    @MainActor
    private struct Harness {
        let root: URL
        let host: ShellWidgetHost
        let resources: ShellResources
        let sink: Sink
        let layoutChanges: AsyncStream<Void>

        static let monitor = Monitor.ID(displayId: 92_301)
        static let secondMonitor = Monitor.ID(displayId: 92_302)
        static let bar = ShellBarKey(monitor: monitor)

        var slot: WorkspaceBarShellWidget? {
            host.slots(for: Self.monitor).first
        }

        func barSurface(on monitor: Monitor.ID = Self.monitor) throws -> ShellWidgetSurface {
            let key = ShellBarKey(monitor: monitor, island: .all)
            let view = try XCTUnwrap(host.surfaceView(widget: "test", key: key, scale: 2) as? ShellSurfaceView)
            return try XCTUnwrap(view.surface)
        }

        func close() {
            host.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func harness(
        _ source: String,
        world: ShellWorldData = ShellWorldData(),
        bars: [ShellBarKey: ShellBarData] = [Harness.bar: ShellBarData()],
        animations: Bool = false,
        files: [String: String] = [:]
    ) throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contents = ["shell.toml": "profiles.default.trailing = [\"test\"]\n"]
            .merging(files, uniquingKeysWith: { $1 })
            .merging(["widgets/test/init.luau": source], uniquingKeysWith: { $1 })
        for (path, contents) in contents {
            let url = root.appendingPathComponent("shell/" + path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        let sink = Sink()
        sink.world = world
        sink.bars = bars
        let (changes, changed) = AsyncStream.makeStream(of: Void.self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { changed.finish() }
        let resources = ShellResources(
            motion: MotionPolicy(animationsEnabled: animations),
            iconOverride: { _ in sink.iconOverride }
        )
        let host = ShellWidgetHost(
            configDirectory: root,
            resources: resources,
            world: { sink.world },
            vars: { sink.vars },
            bars: { sink.bars },
            onLayoutChange: { changed.yield() },
            onCommand: { request, origin in
                sink.commands.append(request)
                sink.origins.append(origin)
            },
            onMenu: { sink.menus.append($0.target) },
            onPreview: { sink.previews.append($0.target) },
            onDrag: { sink.drags.append($0) },
            onPopoutChange: { sink.popoutChanges += 1 },
            onTitleDemandChange: { sink.titleDemands.append($0) }
        )
        host.start()
        return Harness(root: root, host: host, resources: resources, sink: sink, layoutChanges: changes)
    }

    private func click(_ surface: ShellWidgetSurface, at point: CGPoint) {
        surface.press(at: point)
        surface.release(at: point)
    }

    func testHostAsksForWindowTitlesOnlyWhileAWidgetReadsThem() async throws {
        executionTimeAllowance = 60
        let harness = try harness("function render(ctx) return ui.text{ text = \"t\" .. ctx.data.title } end")
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertEqual(harness.sink.titleDemands, [true])

        harness.close()
        XCTAssertEqual(harness.sink.titleDemands, [true, false])
    }

    func testStoppingWithAPopoutOpenLeavesWindowTitlesOff() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx) return ui.text{ text = "t" .. ctx.data.title } end
        function popout(ctx) return ui.box{ w = 10, h = 10 } end
        """)
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertTrue(harness.host.togglePopout(
            of: "test",
            on: Harness.monitor,
            anchor: ShellAnchor(frame: CGRect(x: 100, y: 100, width: 10, height: 10), level: .statusBar)
        ))
        XCTAssertNotNil(harness.host.popout)

        harness.close()
        XCTAssertEqual(harness.sink.titleDemands.last, false)
    }

    func testTheShellPausesWhileLockedOrWhileTheDisplaysSleep() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = tonumber(ctx.data.vars.w) or 10, h = 10 }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot?.size.width != 10 {
            try await layoutChanges.change()
        }
        let center = NSWorkspace.shared.notificationCenter
        XCTAssertFalse(harness.host.isPaused)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertTrue(harness.host.isPaused)
        harness.sink.vars = ["w": "9"]
        harness.host.updateVars()
        harness.host.setLocked(true)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertTrue(harness.host.isPaused)
        harness.host.setLocked(false)
        XCTAssertFalse(harness.host.isPaused)
        while harness.slot?.size.width != 9 {
            try await layoutChanges.change()
        }

        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        harness.host.stop()
        XCTAssertFalse(harness.host.isPaused)
        harness.host.start()
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertTrue(harness.host.isPaused)
    }

    func testTheWidgetReportListsConfigProblemsAsTheConfigChanges() async throws {
        executionTimeAllowance = 60
        let harness = try harness("function render(ctx) return ui.box{ w = 10, h = 10 } end")
        defer { harness.close() }
        let (changes, changed) = AsyncStream.makeStream(of: Void.self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { changed.finish() }
        harness.host.onWidgetsChange = { changed.yield() }
        var reports = changes.makeAsyncIterator()
        XCTAssertEqual(harness.host.widgetReport.problems, [])
        let config = harness.root.appendingPathComponent("shell/shell.toml")

        try Data("trailling = []\n".utf8).write(to: config)
        while harness.host.widgetReport.problems.isEmpty {
            try await reports.change()
        }
        XCTAssertEqual(harness.host.widgetReport.problems, ["shell.toml has unknown key trailling"])

        try Data("trailing = [\n".utf8).write(to: config)
        while harness.host.widgetReport.problems == ["shell.toml has unknown key trailling"] {
            try await reports.change()
        }
        XCTAssertEqual(harness.host.widgetReport.problems.count, 1)
        XCTAssertTrue(harness.host.widgetReport.problems.first?.hasPrefix("shell/shell.toml: ") == true)
    }

    func testWidgetsThatIgnoreTitlesDoNotAskForThem() async throws {
        executionTimeAllowance = 60
        let harness = try harness("function render(ctx) return ui.text{ text = ctx.data.app .. \"!\" } end")
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertNotNil(harness.slot)
        XCTAssertEqual(harness.sink.titleDemands, [])
    }

    func testClicksRunCommandsAndHandlers() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 20, h = 10, onClick = "switch-workspace 2" },
                ui.box{ w = ctx.state.wide and 40 or 20, h = 10, onClick = function(ctx) ctx.state.wide = true end },
            }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertEqual(harness.slot?.size, CGSize(width: 40, height: 10))

        let surface = try harness.barSurface()
        XCTAssertFalse(surface.hasAction(at: CGPoint(x: 45, y: 5)))
        click(surface, at: CGPoint(x: 5, y: 5))
        XCTAssertEqual(harness.sink.commands, [.command(.workspace(.switchTo(workspaceNumber: 2)))])

        click(surface, at: CGPoint(x: 25, y: 5))
        try await layoutChanges.change()
        XCTAssertEqual(harness.slot?.size, CGSize(width: 60, height: 10))
    }

    func testRightAndMiddleClicksCarryTheirButtonAndModifiers() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 20, h = 10, onClick = "switch-workspace 2", onRightClick = "switch-workspace 3" },
                ui.box{ w = ctx.state.seen == "lefttrue" and 40 or 20, h = 10,
                    onClick = function(ctx, event) ctx.state.seen = event.button .. tostring(event.shift) end },
            }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let string = CGPoint(x: 5, y: 5)
        let handler = CGPoint(x: 25, y: 5)

        surface.press(at: string, button: .right)
        surface.release(at: string, event: ShellEvent(button: .right))
        XCTAssertEqual(harness.sink.commands, [.command(.workspace(.switchTo(workspaceNumber: 3)))])

        surface.press(at: string, button: .middle)
        surface.release(at: string, event: ShellEvent(button: .middle))
        surface.press(at: string)
        surface.release(at: string, event: ShellEvent(button: .middle))
        XCTAssertEqual(harness.sink.commands.count, 1)

        surface.press(at: handler)
        surface.release(at: handler, event: ShellEvent(button: .left, shift: true))
        try await layoutChanges.change()
        XCTAssertEqual(harness.slot?.size, CGSize(width: 60, height: 10))
    }

    func testLongTextTruncatesAtItsMaximumWidth() async throws {
        executionTimeAllowance = 60
        let harness = try harness(
            "function render(ctx) return ui.text{ text = string.rep(\"W\", 50), maxWidth = 40 } end"
        )
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertEqual(harness.slot?.size.width, 40)
        let surface = try harness.barSurface()
        ShellLayerScene.engineQueue.sync {}
        let label = surface.view.layer?.sublayers?.first?.sublayers?.first?.contents as AnyObject?
        let image = try XCTUnwrap(label.map { $0 as! CGImage })
        XCTAssertLessThanOrEqual(image.width, 80)
    }

    func testHoverAppliesEveryEffectOnThePathAndRestoresThem() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = 30, h = 20, hover = "#FF0000FF", onClick = "switch-workspace 2",
                ui.box{ w = 16, h = 16, fill = "#00FF00FF", hoverScale = 1.25 } }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        ShellLayerScene.engineQueue.sync {}
        let all = try XCTUnwrap(surface.view.layer).flattened
        let pill = try XCTUnwrap(all.first { $0.bounds.size == CGSize(width: 30, height: 20) })
        let inner = try XCTUnwrap(all.first { $0.bounds.size == CGSize(width: 16, height: 16) })

        surface.hover(at: CGPoint(x: 5, y: 5))
        ShellLayerScene.engineQueue.sync {}
        XCTAssertEqual(pill.backgroundColor?.components?.first, 1)
        XCTAssertEqual(inner.transform.m11, 1.25, accuracy: 0.001)

        surface.hover(at: nil)
        ShellLayerScene.engineQueue.sync {}
        XCTAssertNil(pill.backgroundColor)
        XCTAssertEqual(inner.transform.m11, 1, accuracy: 0.001)
    }

    func testHelpShowsATooltipAfterTheDelay() async throws {
        executionTimeAllowance = 60
        UserDefaults.standard.set(1, forKey: "NSInitialToolTipDelay")
        defer { UserDefaults.standard.removeObject(forKey: "NSInitialToolTipDelay") }
        let harness =
            try harness("function render(ctx) return ui.box{ w = 20, h = 10, help = \"Focus workspace\" } end")
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        surface.hover(at: CGPoint(x: 5, y: 5))
        await until { harness.host.tooltip.text != nil }
        XCTAssertEqual(harness.host.tooltip.text, "Focus workspace")
        surface.hover(at: nil)
        XCTAssertNil(harness.host.tooltip.text)
    }

    func testSlidersReportBeganChangedAndEndedValues() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            local phases = ctx.state.phases or ""
            local ordered = phases:sub(1, 1) == "b" and phases:sub(-1) == "e" and phases:find("c") ~= nil
            return ui.row{
                ui.slider{ w = 116, h = 16, value = ctx.state.value or 0,
                    onChange = function(ctx, event)
                        ctx.state.value = event.value
                        ctx.state.phases = (ctx.state.phases or "") .. event.phase:sub(1, 1)
                    end },
                ui.box{ w = 1 + math.floor((ctx.state.value or 0) * 100 + 0.5) + (ordered and 1000 or 0), h = 1 },
            }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        surface.press(at: CGPoint(x: 8, y: 8))
        surface.drag(to: CGPoint(x: 58, y: 8), screen: .zero)
        surface.drag(to: CGPoint(x: 68, y: 8), screen: .zero)
        surface.release(at: CGPoint(x: 108, y: 8), event: ShellEvent(button: .left))
        while harness.slot?.size.width != 1217 {
            try await layoutChanges.change()
        }
        XCTAssertTrue(harness.sink.commands.isEmpty)
    }

    func testScrollingAContainerMovesWhichItemIsClicked() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.column{ h = 30, scroll = true,
                ui.box{ w = 20, h = 30, onClick = "switch-workspace 1" },
                ui.box{ w = 20, h = 30, onClick = "switch-workspace 2" },
            }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertEqual(harness.slot?.size.height, 30)
        let surface = try harness.barSurface()
        XCTAssertTrue(surface.scroll(
            at: CGPoint(x: 5, y: 5),
            event: ShellEvent(button: .none),
            content: CGPoint(x: 0, y: 30)
        ))
        click(surface, at: CGPoint(x: 5, y: 5))
        XCTAssertEqual(harness.sink.commands, [.command(.workspace(.switchTo(workspaceNumber: 2)))])
    }

    func testMaterialsDrawABlurredBackdropUnderTheirTint() async throws {
        executionTimeAllowance = 60
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
            throw XCTSkip("Reduce Transparency replaces materials with solid fills")
        }
        let harness = try harness(
            "function render(ctx) return ui.box{ w = 20, h = 10, material = \"regular\", fill = \"#FF000080\" } end"
        )
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        ShellLayerScene.engineQueue.sync {}
        let pill = try XCTUnwrap(surface.view.layer?.sublayers?.first?.sublayers?.first)
        XCTAssertNil(pill.backgroundColor)
        let backdrop = try XCTUnwrap(pill.sublayers?.first { $0.zPosition == -2 })
        let tint = try XCTUnwrap(pill.sublayers?.first { $0.zPosition == -1 })
        XCTAssertTrue(NSStringFromClass(type(of: backdrop)).contains("Backdrop"))
        XCTAssertEqual(backdrop.filters?.count, 2)
        XCTAssertEqual(backdrop.bounds.size, CGSize(width: 20, height: 10))
        XCTAssertEqual(tint.backgroundColor?.components?.first, 1)
    }

    func testEditingAHelperModuleReloadsTheWidget() async throws {
        executionTimeAllowance = 60
        let harness = try harness("function render(ctx) return ui.box{ w = require(\"@self/size\"), h = 10 } end")
        defer { harness.close() }
        let helper = harness.root.appendingPathComponent("shell/widgets/test/size.luau")
        try Data("return 12".utf8).write(to: helper)
        harness.host.rescan()
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot?.size.width != 12 {
            try await layoutChanges.change()
        }
        try Data("return 345".utf8).write(to: helper)
        harness.host.rescan()
        while harness.slot?.size.width != 345 {
            try await layoutChanges.change()
        }
    }

    func testWidgetsShareModulesFromTheLibFolders() async throws {
        executionTimeAllowance = 60
        let harness = try harness(
            "function render(ctx) return ui.box{ w = require(\"../lib/size\"), h = 10 } end",
            files: [
                "shell.toml": "profile = \"look\"\nprofiles.look.trailing = [\"test\"]\n",
                "look/lib/size.luau": "return 12"
            ]
        )
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot?.size.width != 12 {
            try await layoutChanges.change()
        }
        let own = harness.root.appendingPathComponent("shell/lib/size.luau")
        try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("return 34".utf8).write(to: own)
        harness.host.rescan()
        while harness.slot?.size.width != 34 {
            try await layoutChanges.change()
        }
        XCTAssertFalse(ShellProfiles.names(in: harness.root.appendingPathComponent("shell")).contains("lib"))
    }

    func testScrollsReachHandlersWithoutLosingDeltas() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = 10 + (ctx.state.total or 0), h = 10,
                onScroll = function(ctx, event) ctx.state.total = (ctx.state.total or 0) + event.dy end }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        var event = ShellEvent(button: .none)
        event.dy = 1
        for batch in 1 ... 10 {
            for _ in 0 ..< 3 {
                XCTAssertTrue(surface.scroll(at: CGPoint(x: 5, y: 5), event: event))
            }
            while harness.slot?.size.width != CGFloat(10 + 3 * batch) {
                try await layoutChanges.change()
            }
        }
        XCTAssertEqual(harness.slot?.size.width, 40)
    }

    func testWidgetsStartWithTheCurrentWorldAndFollowUpdates() async throws {
        executionTimeAllowance = 60
        let workspace = ShellWorkspace(id: "1", name: "1", focused: true, visible: true, windows: 2)
        let harness = try harness(
            """
            function render(ctx)
                return ui.box{ w = 10 * #(ctx.data.workspaces or {}), h = 10 }
            end
            """,
            world: ShellWorldData(workspace: "1", workspaces: Array(repeating: workspace, count: 3))
        )
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertEqual(harness.slot?.size, CGSize(width: 30, height: 10))

        harness.sink.world.workspaces.append(workspace)
        harness.host.updateWorld()
        try await layoutChanges.change()
        XCTAssertEqual(harness.slot?.size, CGSize(width: 40, height: 10))
    }

    func testEachMonitorRunsItsOwnInstanceWithItsBarData() async throws {
        executionTimeAllowance = 60
        let window = ShellBarWindow(id: "ow_a", title: "Notes", focused: true, hidden: false)
        let item = ShellBarItem(
            id: "ow_a",
            bundle: "com.apple.finder",
            name: "Finder",
            focused: true,
            count: 2,
            hidden: 0,
            windows: [window, window]
        )
        let workspace = ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [item])
        let harness = try harness(
            """
            function render(ctx)
                local bar = ctx.data.bar
                local windows = #bar.workspaces > 0 and bar.workspaces[1].windows[1].count or 0
                return ui.box{ w = 10 + 10 * windows + (ctx.state.wide and 5 or 0), h = 10,
                    onClick = function(ctx) ctx.state.wide = true end }
            end
            """,
            bars: [
                Harness.bar: ShellBarData(monitor: "Main", workspaces: [workspace]),
                ShellBarKey(monitor: Harness.secondMonitor): ShellBarData(monitor: "Side")
            ]
        )
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.host.slots(for: Harness.secondMonitor).isEmpty || harness.slot == nil {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.slot?.size, CGSize(width: 30, height: 10))
        XCTAssertEqual(harness.host.slots(for: Harness.secondMonitor).first?.size, CGSize(width: 10, height: 10))

        click(try harness.barSurface(on: Harness.secondMonitor), at: CGPoint(x: 5, y: 5))
        while harness.host.slots(for: Harness.secondMonitor).first?.size.width == 10 {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.host.slots(for: Harness.secondMonitor).first?.size, CGSize(width: 15, height: 10))
        XCTAssertEqual(harness.slot?.size, CGSize(width: 30, height: 10))

        harness.sink.bars = [Harness.bar: ShellBarData(monitor: "Main", workspaces: [workspace])]
        harness.host.updateBars()
        XCTAssertTrue(harness.host.slots(for: Harness.secondMonitor).isEmpty)
    }

    func testPopoutFlagRunsTheHandlerBeforeOpening() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first else { throw XCTSkip("popouts need a screen") }
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 20, h = 10, popout = true, onClick = function(ctx) ctx.state.pick = 7 end },
                ui.box{ w = ctx.state.pick and 30 or 20, h = 10 },
            }
        end
        function popout(ctx)
            return ui.box{ w = 10 * (ctx.state.pick or 1), h = 5 }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let bar = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.maxY - 100, width: 40, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        bar.isReleasedWhenClosed = false
        bar.contentView = surface.view
        click(surface, at: CGPoint(x: 5, y: 5))
        let popout = try XCTUnwrap(harness.host.popout)
        try await layoutChanges.change()
        await until { popout.surface.size == CGSize(width: 70, height: 5) }
        XCTAssertEqual(popout.surface.size, CGSize(width: 70, height: 5))
    }

    func testPopoutHandlerRunsWhenBarDataChangesJustBeforeTheClick() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first else { throw XCTSkip("popouts need a screen") }
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = ctx.state.pick and 30 or 20, h = 10, popout = true,
                    onClick = function(ctx) ctx.state.pick = 7 end },
                ui.box{ w = 10 + #ctx.data.bar.workspaces, h = 10 },
            }
        end
        function popout(ctx)
            return ui.box{ w = 10 * (ctx.state.pick or 0), h = 5 }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let bar = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.maxY - 100, width: 40, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        bar.isReleasedWhenClosed = false
        bar.contentView = surface.view
        let workspace = ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [])

        harness.sink.bars = [Harness.bar: ShellBarData(monitor: "Main", workspaces: [workspace])]
        harness.host.updateBars()
        click(surface, at: CGPoint(x: 5, y: 5))
        harness.sink.bars = [Harness.bar: ShellBarData(monitor: "Main", workspaces: [workspace, workspace])]
        harness.host.updateBars()
        while let width = harness.slot?.size.width, width != 32, width != 42 {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.slot?.size.width, 42)
        XCTAssertEqual(harness.host.popout?.surface.size, CGSize(width: 70, height: 5))
    }

    func testBarDataIsBuiltOnlyWhileWidgetsExist() async throws {
        executionTimeAllowance = 60
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("shell", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("profiles.default.trailing = [\"test\"]\n".utf8)
            .write(to: root.appendingPathComponent("shell/shell.toml"))
        let workspace = ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [])
        let sink = Sink()
        sink.bars = [Harness.bar: ShellBarData(monitor: "Main", workspaces: [workspace, workspace])]
        let (changes, changed) = AsyncStream.makeStream(of: Void.self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { changed.finish() }
        let host = ShellWidgetHost(
            configDirectory: root,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            world: { sink.world },
            vars: { sink.vars },
            bars: {
                sink.barRequests += 1
                return sink.bars
            },
            onLayoutChange: { changed.yield() },
            onCommand: { request, _ in sink.commands.append(request) },
            onMenu: { sink.menus.append($0.target) },
            onPreview: { sink.previews.append($0.target) },
            onDrag: { sink.drags.append($0) },
            onPopoutChange: {},
            onTitleDemandChange: { sink.titleDemands.append($0) }
        )
        defer {
            host.stop()
            try? FileManager.default.removeItem(at: root)
        }
        host.start()
        host.updateBars()
        XCTAssertEqual(sink.barRequests, 0)

        let widget = host.widgetsDirectory.appendingPathComponent("test", isDirectory: true)
        try FileManager.default.createDirectory(at: widget, withIntermediateDirectories: true)
        try Data("function render(ctx) return ui.box{ w = 10 * #ctx.data.bar.workspaces, h = 10 } end".utf8)
            .write(to: widget.appendingPathComponent("init.luau"))
        host.rescan()
        XCTAssertEqual(sink.barRequests, 1)
        var layoutChanges = changes.makeAsyncIterator()
        while host.slots(for: Harness.monitor).first?.size.width != 20 {
            try await layoutChanges.change()
        }
    }

    func testCompileFailureShowsABadgeUntilTheWidgetLoads() async throws {
        executionTimeAllowance = 60
        let harness = try harness("function render(ctx) return ui.box{ w = 10, h = 10 }")
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot?.failure == nil {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.slot?.size, .zero)
        XCTAssertEqual(harness.slot?.failure?.source.lastPathComponent, "init.luau")

        try Data("function render(ctx) return ui.box{ w = 10, h = 10 } end".utf8)
            .write(to: harness.root.appendingPathComponent("shell/widgets/test/init.luau"))
        harness.host.rescan()
        while harness.slot?.failure != nil || harness.slot?.size != CGSize(width: 10, height: 10) {
            try await layoutChanges.change()
        }
    }

    func testAReloadWithoutARenderFunctionKeepsTheRunningWidget() async throws {
        executionTimeAllowance = 60
        let harness =
            try harness("function render(ctx) return ui.box{ w = tonumber(ctx.data.vars.w) or 10, h = 10 } end")
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot?.size.width != 10 {
            try await layoutChanges.change()
        }
        try Data("function popout(ctx) return ui.box{ w = 5, h = 5 } end".utf8)
            .write(to: harness.root.appendingPathComponent("shell/widgets/test/init.luau"))
        harness.host.rescan()
        while harness.slot?.failure == nil {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.slot?.failure?.message, "the widget does not define a render function")

        harness.sink.vars = ["w": "12"]
        harness.host.updateVars()
        while harness.slot?.size.width != 12 {
            try await layoutChanges.change()
        }
    }

    func testRepeatedRenderFailuresStopTheWidget() async throws {
        executionTimeAllowance = 60
        let harness = try harness("function render(ctx) error(\"tick \" .. ctx.data.seconds) end")
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot?.failure?.message.hasPrefix("Stopped after repeated errors") != true {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.host.dataDemand, 0)
    }

    func testSampledNetworkWidgetRendersWithoutUnrelatedDataDemand() async throws {
        executionTimeAllowance = 60
        let harness =
            try harness("function render(ctx) return ui.box{ w = 10 + ctx.data.network.down * 0, h = 10 } end")
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot?.size.width != 10 {
            try await layoutChanges.change()
        }
        XCTAssertNil(harness.slot?.failure)
        XCTAssertNotEqual(harness.host.dataDemand & ShellDataKey.network.bit, 0)
        XCTAssertEqual(harness.host.dataDemand & ShellDataKey.gpu.bit, 0)
    }

    func testAFailingWidgetDemandsOnlyTheDataItRead() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = tonumber(ctx.data.vars.w) or error("no width"), h = 10 }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot?.failure == nil {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.host.dataDemand, ShellDataKey.vars.bit)
        XCTAssertEqual(harness.sink.titleDemands, [])

        harness.sink.vars = ["w": "10"]
        harness.host.updateVars()
        while harness.slot?.failure != nil || harness.slot?.size.width != 10 {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.host.dataDemand, ShellDataKey.vars.bit)
    }

    func testRecoveringFromARenderFailurePublishesTheWidgetReport() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = tonumber(ctx.data.vars.w) or error("no width"), h = 10 }
        end
        """)
        defer { harness.close() }
        var published: [String?] = []
        harness.host.onWidgetsChange = { [host = harness.host] in
            published.append(host.widgetReport.widgets.first { $0.name == "test" }?.state)
        }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot?.failure == nil {
            try await layoutChanges.change()
        }
        XCTAssertEqual(published.last, "failed")

        harness.sink.vars = ["w": "10"]
        harness.host.updateVars()
        while harness.slot?.failure != nil || harness.slot?.size.width != 10 {
            try await layoutChanges.change()
        }
        XCTAssertEqual(published.last, "loaded")
    }

    func testBrokenOverrideOfABundledWidgetFallsBackUntilItIsFixed() async throws {
        executionTimeAllowance = 60
        let harness = try harness(
            "function render(ctx) return ui.box{ w = 10, h = 10 } end",
            files: ["shell.toml": "profiles.default.trailing = [\"test\", \"clock\"]\n"]
        )
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let clock = { harness.host.slots(for: Harness.monitor).first { $0.id == "clock" } }
        let source = harness.root.appendingPathComponent("shell/widgets/clock/init.luau")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("function render(ctx) return ui.box{ w = 33, h = 10 }".utf8).write(to: source)
        harness.host.rescan()
        while clock()?.failure == nil || clock()?.size.width ?? 0 == 0 {
            try await layoutChanges.change()
        }
        XCTAssertNotEqual(clock()?.size.width, 33)
        XCTAssertTrue(clock()?.failure?.source.path.hasSuffix("widgets/clock/init.luau") == true)

        try Data("function render(ctx) return ui.box{ w = 33, h = 10 } end".utf8).write(to: source)
        harness.host.rescan()
        while clock()?.size.width != 33 || clock()?.failure != nil {
            try await layoutChanges.change()
        }
    }

    func testRemovingAnIslandDropsOnlyItsSurfaces() async throws {
        executionTimeAllowance = 60
        let harness = try harness(
            "spanIslands = true\nfunction render(ctx) return ui.box{ w = 10, h = 10 } end",
            bars: Self.splitBars(ShellBarData())
        )
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let view = { (island: WorkspaceBarIslandSlice) in
            harness.host.surfaceView(
                widget: "test",
                key: ShellBarKey(monitor: Harness.monitor, island: island),
                scale: 2
            )
        }
        let active = try XCTUnwrap(view(.active))
        let secondary = try XCTUnwrap(view(.secondary))

        harness.host.removeSurfaces(for: Harness.monitor, island: .active)
        XCTAssertFalse(view(.active) === active)
        XCTAssertTrue(view(.secondary) === secondary)
    }

    func testHandlerFailureKeepsContentNextToTheBadge() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = 10, h = 10, onClick = function(ctx) error("boom") end }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        click(try harness.barSurface(), at: CGPoint(x: 5, y: 5))
        while harness.slot?.failure == nil {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.slot?.size, CGSize(width: 10, height: 10))
        XCTAssertTrue(harness.slot?.failure?.message.contains("boom") == true)
        XCTAssertEqual(harness.host.dataDemand, 0)
        XCTAssertEqual(harness.sink.titleDemands, [])
    }

    func testStartInstallsTypeDefinitionsAndKeepsAnExistingLuaurc() throws {
        let harness = try harness("function render(ctx) return ui.box{ w = 10, h = 10 } end")
        defer { harness.close() }
        let shell = harness.root.appendingPathComponent("shell", isDirectory: true)
        let definitions = try String(contentsOf: shell.appendingPathComponent("omniwm.d.luau"), encoding: .utf8)
        XCTAssertTrue(definitions.contains("declare ui:"))
        XCTAssertTrue(definitions.contains("export type Context"))
        let luaurc = shell.appendingPathComponent(".luaurc")
        XCTAssertEqual(try String(contentsOf: luaurc, encoding: .utf8), #"{"lint": {"FunctionUnused": false}}"# + "\n")

        harness.host.stop()
        try Data("{}".utf8).write(to: luaurc)
        try Data("stale".utf8).write(to: shell.appendingPathComponent("omniwm.d.luau"))
        harness.host.start()
        XCTAssertEqual(try String(contentsOf: luaurc, encoding: .utf8), "{}")
        XCTAssertEqual(
            try String(contentsOf: shell.appendingPathComponent("omniwm.d.luau"), encoding: .utf8),
            definitions
        )
    }

    func testShaderCompileFailureShowsABadgeUntilTheShaderFileIsSaved() async throws {
        executionTimeAllowance = 60
        guard ShellShaderGPU.device != nil else { throw XCTSkip("Metal is not available") }
        let harness = try harness("""
        function render(ctx)
            return ui.shader{ source = "glow.metal", w = 10, h = 10 }
        end
        """)
        defer { harness.close() }
        let shader = harness.root.appendingPathComponent("shell/widgets/test/glow.metal")
        try Data("float4 shade(float2 uv, constant OmniShader& shader) { return nope; }".utf8).write(to: shader)
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        _ = try harness.barSurface()
        while harness.slot?.failure == nil {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.slot?.failure?.source.lastPathComponent, "glow.metal")
        XCTAssertTrue(harness.slot?.failure?.message.contains("glow.metal:1") == true)

        try Data("float4 shade(float2 uv, constant OmniShader& shader) { return float4(1); }".utf8).write(to: shader)
        while harness.slot?.failure != nil {
            try await layoutChanges.change()
        }
    }

    func testWidgetsSeeScratchpadsAndBadges() async throws {
        executionTimeAllowance = 60
        let item = ShellBarItem(
            id: "ow_a",
            bundle: "com.apple.finder",
            name: "Finder",
            focused: false,
            count: 1,
            hidden: 0,
            badge: "12",
            windows: []
        )
        let scratchpad = ShellBarScratchpad(
            id: 1,
            name: "1",
            focused: false,
            revealed: false,
            visible: true,
            windows: [item]
        )
        let harness = try harness(
            """
            function render(ctx)
                local bar = ctx.data.bar
                local badge = #bar.workspaces[1].windows[1].badge
                return ui.box{ w = 10 * #bar.scratchpads + badge + (bar.badges == "dot" and 100 or 0), h = 10 }
            end
            """,
            bars: [Harness.bar: ShellBarData(
                monitor: "Main",
                badges: "dot",
                workspaces: [ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [item])],
                scratchpads: [scratchpad, scratchpad]
            )]
        )
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot == nil {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.slot?.size.width, 122)
    }

    func testProfileColorsReachNativeAndNamedPalettesAndReset() throws {
        for theme in ["native", "look"] {
            let harness = try harness("function render(ctx) return ui.box{ w = 10, h = 10 } end", files: [
                "shell.toml": "profiles.default.trailing = [\"test\"]\nprofiles.default.theme = \"\(theme)\"\n",
                "themes/look.toml": "[light]\naccent = \"#0000FF\"\n[dark]\naccent = \"#0000FF\"\n"
            ])
            defer { harness.close() }
            let directory = harness.root.appendingPathComponent("shell", isDirectory: true)
            let accent = ShellRole.accent.rawValue
            let original = harness.resources.palette.shaderColors[accent]
            XCTAssertTrue(try ShellProfiles.setValue(
                SettingsColor(red: 0, green: 1, blue: 0, alpha: 1),
                at: ["profiles", "default", "workspaceBar", "accentColor"], in: directory
            ))
            harness.host.reloadConfig()
            XCTAssertGreaterThan(harness.resources.palette.shaderColors[accent].y, 0.9)
            XCTAssertLessThan(harness.resources.palette.shaderColors[accent].x, 0.2)
            XCTAssertTrue(try ShellProfiles.reset(
                ["profiles", "default", "workspaceBar", "accentColor"],
                in: directory
            ))
            harness.host.reloadConfig()
            XCTAssertEqual(harness.resources.palette.shaderColors[accent], original)
        }
    }

    func testMenuTargetsOpenFromRightAndControlClicks() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 10, h = 10, target = "workspace 1", menu = true },
                ui.box{ w = 10, h = 10, onClick = "switch-workspace 2" },
            }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 20, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = surface.view

        XCTAssertTrue(surface.hasAction(at: CGPoint(x: 5, y: 5)))
        XCTAssertTrue(surface.openMenu(at: CGPoint(x: 5, y: 5)))
        XCTAssertFalse(surface.openMenu(at: CGPoint(x: 15, y: 5)))
        let controlClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 5, y: 5),
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        surface.view.mouseDown(with: controlClick)
        XCTAssertEqual(harness.sink.menus, ["workspace 1", "workspace 1"])
        XCTAssertTrue(harness.sink.commands.isEmpty)
    }

    func testPreviewTargetsReportHoverStartAndEnd() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 10, h = 10, target = "window ow_a", preview = true },
                ui.box{ w = 10, h = 10 },
            }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        surface.hover(at: CGPoint(x: 5, y: 5))
        surface.hover(at: CGPoint(x: 6, y: 5))
        surface.hover(at: CGPoint(x: 15, y: 5))
        surface.hover(at: nil)
        XCTAssertEqual(harness.sink.previews, ["window ow_a", nil])
    }

    func testPreviewFollowsRelayoutUnderAStillPointer() throws {
        let widget = try ShellRenderedWidget(name: "preview", source: """
        function render(ctx)
            local s = ctx.data.seconds
            local a = ui.box{ key = "a", w = 10, h = 10, target = "window ow_a", preview = true }
            local b = ui.box{ key = "b", w = 10, h = 10, target = "window ow_b", preview = true }
            if s == 9 then
                return ui.row{ b, a, ui.box{ key = "tail", w = 4, h = 10 } }
            end
            return ui.row{ ui.box{ key = "pad", w = s, h = 10 }, a, b, ui.box{ key = "tail", w = 4 - s, h = 10 } }
        end
        """)
        var events: [(target: String, anchor: CGRect?)] = []
        widget.surface.onPreview = { event in
            events.append((widget.text.string(event.target), event.anchor?.frame))
        }
        widget.set("seconds") { $0.number(0) }
        widget.render(ShellBarData())
        widget.surface.hover(at: CGPoint(x: 5, y: 5))
        widget.set("seconds") { $0.number(2) }
        widget.render(ShellBarData())
        widget.set("seconds") { $0.number(9) }
        widget.render(ShellBarData())

        XCTAssertEqual(events.map(\.target), ["window ow_a", "window ow_a", "window ow_b"])
        if events.count >= 2, let first = events[0].anchor, let moved = events[1].anchor {
            XCTAssertEqual(moved.minX, first.minX + 2)
        }
    }

    func testDragsStartPastTheThresholdAndSuppressTheClick() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 30, h = 10, target = "window ow_a", drag = true, onClick = "switch-workspace 2" },
                ui.box{ w = 10, h = 10, target = "workspace 1", drop = true },
            }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()

        surface.press(at: CGPoint(x: 2, y: 5))
        surface.drag(to: CGPoint(x: 5, y: 5), screen: .zero)
        XCTAssertTrue(harness.sink.drags.isEmpty)
        surface.drag(to: CGPoint(x: 12, y: 5), screen: CGPoint(x: 100, y: 0))
        surface.drag(to: CGPoint(x: 20, y: 5), screen: CGPoint(x: 108, y: 0))
        XCTAssertTrue(surface.endDrag(at: CGPoint(x: 110, y: 0)))
        XCTAssertEqual(harness.sink.drags.count, 3)
        guard case let .began(_, target, point) = harness.sink.drags.first else {
            return XCTFail("the drag did not begin")
        }
        XCTAssertEqual(target, "window ow_a")
        XCTAssertEqual(point, CGPoint(x: 100, y: 0))
        XCTAssertTrue(harness.sink.commands.isEmpty)

        surface.press(at: CGPoint(x: 2, y: 5))
        XCTAssertFalse(surface.endDrag(at: .zero))
        surface.release(at: CGPoint(x: 2, y: 5))
        XCTAssertEqual(harness.sink.commands, [.command(.workspace(.switchTo(workspaceNumber: 2)))])

        let targets = harness.host.dropTargets(on: Harness.monitor)
        XCTAssertEqual(Set(targets.map(\.target)), ["window ow_a", "workspace 1"])
        XCTAssertEqual(targets.first { $0.target == "workspace 1" }?.drop, true)
        XCTAssertEqual(targets.first { $0.target == "window ow_a" }?.drop, false)
    }

    func testLuauWorkspacesModeRunsTheBundledWorkspacesWidget() async throws {
        executionTimeAllowance = 60
        let window = ShellBarWindow(id: "ow_b", title: "Inbox", focused: false, hidden: false)
        let item = { (id: String, count: Int, hidden: Int, badge: String, floating: Bool) in
            ShellBarItem(
                id: id,
                bundle: "com.apple.finder",
                name: "Finder",
                focused: id == "ow_a",
                count: count,
                hidden: hidden,
                badge: badge,
                floating: floating,
                windows: Array(repeating: window, count: count)
            )
        }
        let bar = ShellBarData(
            monitor: "Main",
            badges: "text",
            style: ShellBarStyle(height: 28, inactive: 0.45),
            workspaces: [
                ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [
                    item("ow_a", 1, 0, "", false),
                    item("ow_c", 3, 1, "4", false),
                    item("ow_d", 1, 1, "", true)
                ]),
                ShellBarWorkspace(id: "2", name: "2", focused: false, windows: [])
            ],
            scratchpads: [ShellBarScratchpad(
                id: 1,
                name: "1",
                focused: false,
                revealed: true,
                visible: true,
                windows: [item("ow_e", 1, 0, "", false)]
            )]
        )
        let harness = try harness(
            "function render(ctx) return ui.box{ w = 1, h = 1 } end",
            bars: [Harness.bar: bar]
        )
        defer { harness.close() }
        try Data("profiles.default.leading = [\"workspaces\", \"test\"]\n".utf8)
            .write(to: harness.root.appendingPathComponent("shell/shell.toml"))
        harness.host.rescan()
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.host.slots(for: Harness.monitor).first(where: { $0.id == "workspaces" })?.size.width ?? 0 == 0 {
            try await layoutChanges.change()
        }
        let slots = harness.host.slots(for: Harness.monitor)
        XCTAssertEqual(slots.map(\.id), ["workspaces", "test"])
        XCTAssertNil(slots.first?.failure)
        XCTAssertEqual(slots.first?.size.height, 24)

        _ = harness.host.surfaceView(
            widget: "workspaces",
            key: ShellBarKey(monitor: Harness.monitor, island: .all),
            scale: 2
        )
        XCTAssertEqual(
            Set(harness.host.dropTargets(on: Harness.monitor).map(\.target)),
            ["workspace 1", "workspace 2", "window ow_a", "window ow_c", "window ow_d"]
        )
    }

    func testSplitIslandsPlaceWidgetsByLaneOrDeclaration() async throws {
        executionTimeAllowance = 60
        let window = ShellBarWindow(id: "ow_a", title: "A", focused: true, hidden: false)
        let item = { (id: String) in
            ShellBarItem(id: id, bundle: "", name: "A", focused: false, count: 1, hidden: 0, windows: [window])
        }
        let bar = ShellBarData(
            monitor: "Main",
            workspaces: [
                ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [item("ow_a")]),
                ShellBarWorkspace(id: "2", name: "2", focused: false, windows: [item("ow_b")])
            ]
        )
        let harness = try harness(
            "function render(ctx) return ui.box{ w = ctx.data.bar.island == \"active\" and 12 or 7, h = 10 } end",
            bars: Self.splitBars(bar)
        )
        defer { harness.close() }
        let side = harness.root.appendingPathComponent("shell/widgets/side", isDirectory: true)
        try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
        try Data("""
        spanIslands = true
        function render(ctx) return ui.box{ w = ctx.data.bar.island == "active" and 5 or 9, h = 10 } end
        """.utf8).write(to: side.appendingPathComponent("init.luau"))
        try Data("profiles.default.leading = [\"workspaces\", \"test\"]\nprofiles.default.trailing = [\"side\"]\n".utf8)
            .write(to: harness.root.appendingPathComponent("shell/shell.toml"))
        harness.host.rescan()
        let placed = { (island: WorkspaceBarIslandSlice) in
            harness.host.slots(for: Harness.monitor).filter { $0.island == island }
                .map { "\($0.id) \(Int($0.size.width))" }
        }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while placed(.active).count < 3 || placed(.secondary).count < 2 {
            try await layoutChanges.change()
        }
        XCTAssertEqual(placed(.active).dropFirst(), ["test 12", "side 5"])
        XCTAssertEqual(placed(.secondary).last, "side 9")
        XCTAssertEqual(placed(.active).first?.hasPrefix("workspaces "), true)
        XCTAssertEqual(placed(.secondary).first?.hasPrefix("workspaces "), true)
        XCTAssertTrue(harness.host.slots(for: Harness.monitor).allSatisfy { $0.island != .all })

        let targets = { (island: WorkspaceBarIslandSlice) in
            harness.host.removeSurfaces(for: Harness.monitor)
            _ = harness.host.surfaceView(
                widget: "workspaces",
                key: ShellBarKey(monitor: Harness.monitor, island: island),
                scale: 2
            )
            return Set(harness.host.dropTargets(on: Harness.monitor).map(\.target))
        }
        XCTAssertEqual(targets(.active), ["workspace 1", "window ow_a"])
        XCTAssertEqual(targets(.secondary), ["workspace 2", "window ow_b"])

        try Data("profiles.default.leading = [\"workspaces\"]\nprofiles.default.trailing = [\"side\", \"test\"]\n".utf8)
            .write(to: harness.root.appendingPathComponent("shell/shell.toml"))
        harness.host.rescan()
        while !placed(.secondary).contains("test 7") {
            try await layoutChanges.change()
        }
        XCTAssertFalse(placed(.active).contains { $0.hasPrefix("test ") })

        harness.sink.bars = [Harness.bar: bar]
        harness.host.updateBars()
        XCTAssertEqual(harness.host.slots(for: Harness.monitor).map(\.island), [])
        while harness.host.slots(for: Harness.monitor).count < 3 {
            try await layoutChanges.change()
        }
        XCTAssertEqual(placed(.all).dropFirst(), ["side 9", "test 7"])
    }

    private static func splitBars(_ bar: ShellBarData) -> [ShellBarKey: ShellBarData] {
        var result: [ShellBarKey: ShellBarData] = [:]
        for island in [WorkspaceBarIslandSlice.active, .secondary] {
            var data = bar
            data.island = island
            result[ShellBarKey(monitor: Harness.monitor, island: island)] = data
        }
        return result
    }

    func testProfilesChooseWhichListedWidgetsLoad() async throws {
        executionTimeAllowance = 60
        let harness = try harness("function render(ctx) return ui.box{ w = 10, h = 10 } end")
        defer { harness.close() }
        let shell = harness.root.appendingPathComponent("shell", isDirectory: true)
        let write = { (contents: String, path: String) in
            let url = shell.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        for (path, width) in [("look/widgets/clock", 13), ("default/widgets/clock", 17), (
            "default/widgets/extra",
            19
        )] {
            try write("function render(ctx) return ui.box{ w = \(width), h = 10 } end", "\(path)/init.luau")
        }
        try write("trailing = [\"clock\", \"test\"]\n", "look/shell.toml")
        try write("profile = \"look\"\n", "shell.toml")
        harness.host.rescan()
        let widths = {
            Dictionary(uniqueKeysWithValues: harness.host.slots(for: Harness.monitor).map {
                ($0.id, Int($0.size.width))
            })
        }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while widths() != ["test": 10, "clock": 13] {
            try await layoutChanges.change()
        }

        try write("profile = \"default\"\nprofiles.default.trailing = [\"clock\", \"test\"]\n", "shell.toml")
        harness.host.rescan()
        while widths() != ["test": 10, "clock": 17] {
            try await layoutChanges.change()
        }
    }

    func testApplicationMenuCommandsKeepTheirOwnWidgetAnchors() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{w=10,h=10,onClick="menu apple"},
                ui.box{w=20,h=10,onClick="menu app"},
            }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()

        surface.press(at: CGPoint(x: 5, y: 5))
        surface.release(at: CGPoint(x: 5, y: 5))
        surface.press(at: CGPoint(x: 20, y: 5))
        surface.release(at: CGPoint(x: 20, y: 5))

        XCTAssertEqual(harness.sink.commands, [.menu(.apple), .menu(.application)])
        XCTAssertEqual(harness.sink.origins.map(\.monitor), [Harness.monitor, Harness.monitor])
        XCTAssertEqual(harness.sink.origins.map(\.command), ["menu apple", "menu app"])
        XCTAssertEqual(harness.sink.origins.map { $0.anchor?.frame.size }, [
            CGSize(width: 10, height: 10), CGSize(width: 20, height: 10)
        ])
        XCTAssertNotEqual(harness.sink.origins[0].anchor?.frame, harness.sink.origins[1].anchor?.frame)
        XCTAssertEqual(ShellAction("menu apple"), .wm(.menu(.apple)))
        XCTAssertEqual(ShellAction("menu app"), .wm(.menu(.application)))
        XCTAssertNil(ShellAction("menu all"))
        XCTAssertNil(ShellAction("menu app extra"))
    }

    func testTheMenuCommandCarriesTheClickAndMarksItsElementAsTheMenuButton() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 10, h = 10, onClick = "shell menu", onRightClick = "shell menu" },
                ui.box{ w = 10, h = 10, onClick = "toggle-system-stats" },
            }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        XCTAssertEqual(ShellAction("shell menu"), .wm(.statusMenu))

        surface.press(at: CGPoint(x: 5, y: 5), button: .right)
        surface.release(at: CGPoint(x: 5, y: 5), event: ShellEvent(button: .right, modifiers: .option))
        XCTAssertEqual(harness.sink.commands, [.statusMenu])
        let origin = try XCTUnwrap(harness.sink.origins.first)
        XCTAssertEqual(origin.monitor, Harness.monitor)
        XCTAssertEqual(origin.event.button, .right)
        XCTAssertTrue(origin.event.option)
        XCTAssertEqual(origin.anchor?.frame.size, CGSize(width: 10, height: 10))
        XCTAssertEqual(origin.widget, "test")
        XCTAssertEqual(origin.command, "shell menu")

        XCTAssertEqual(surface.command(at: CGPoint(x: 5, y: 5)), ShellRequest.statusMenuCommand)
        XCTAssertEqual(surface.command(at: CGPoint(x: 15, y: 5)), "toggle-system-stats")

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 20, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = surface.view
        surface.view.frame = CGRect(x: 0, y: 0, width: 20, height: 10)
        let event = { (x: CGFloat) in
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: CGPoint(x: x, y: 5),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }
        XCTAssertTrue(WorkspaceBarMenuButton.contains(event(5), in: window))
        XCTAssertFalse(WorkspaceBarMenuButton.contains(event(15), in: window))
    }

    func testBarsCarryTheDragPresentation() async throws {
        executionTimeAllowance = 60
        let workspaceId = WorkspaceDescriptor.ID()
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(
                items: [WorkspaceBarItem(
                    id: workspaceId,
                    name: "One",
                    rawName: "1",
                    isFocused: true,
                    tiledWindows: [],
                    floatingWindows: []
                )],
                scratchpads: []
            ),
            backgroundOpacity: 1,
            barHeight: 24
        )
        let source = WindowToken(pid: 41, windowId: 7)
        let target = WindowToken(pid: 42, windowId: 8)
        let id = { (token: WindowToken) in
            IPCWindowOpaqueID.encode(pid: token.pid, windowId: token.windowId, sessionToken: "s")
        }
        XCTAssertNil(ShellBarDrag(ShellDragState(), snapshot: snapshot, sessionToken: "s"))
        let drag = try XCTUnwrap(ShellBarDrag(
            ShellDragState(
                sources: [source],
                highlights: [.workspace(workspaceId), .gap(workspaceId, beforeIcon: 0), .icon(workspaceId, target)]
            ),
            snapshot: snapshot,
            sessionToken: "s"
        ))
        XCTAssertEqual(drag, ShellBarDrag(
            sources: [id(source)],
            workspaces: ["1"],
            icons: [id(target)],
            gaps: [ShellBarDrag.Gap(workspace: "1", before: 1)]
        ))

        let harness = try harness(
            """
            function render(ctx)
                local drag = ctx.data.bar.drag
                if not drag then
                    return ui.box{ w = 5, h = 10 }
                end
                return ui.box{ w = 10 * #drag.sources + #drag.workspaces + drag.gaps[1].before * 100, h = 10 }
            end
            """,
            bars: [Harness.bar: ShellBarData(drag: drag)]
        )
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot?.size.width != 111 {
            try await layoutChanges.change()
        }
        harness.sink.bars = [Harness.bar: ShellBarData()]
        harness.host.updateBars()
        while harness.slot?.size.width != 5 {
            try await layoutChanges.change()
        }
    }

    func testTheBrandMarkSymbolsRenderTinted() {
        let mark = OmniWMBrandMark.tintedStatusImage(pointSize: 14, tint: .systemRed)
        XCTAssertFalse(mark.isTemplate)
        XCTAssertEqual(mark.size, CGSize(width: 14, height: 14))
    }

    func testShiftClicksMoveTheFocusedWindowAndModifiedClicksSkipThePopout() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first else { throw XCTSkip("popouts need a screen") }
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 10, h = 10, onClick = "switch-workspace 2", target = "workspace 2" },
                ui.box{ w = 10, h = 10, popout = true, onClick = function(ctx) ctx.state.clicks = (ctx.state.clicks or 0) + 1 end },
            }
        end
        function popout(ctx) return ui.box{ w = 20, h = 20 } end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let bar = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.maxY - 100, width: 20, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        bar.isReleasedWhenClosed = false
        bar.contentView = surface.view
        let click = { (x: CGFloat, modifiers: NSEvent.ModifierFlags) in
            surface.press(at: CGPoint(x: x, y: 5))
            surface.release(at: CGPoint(x: x, y: 5), event: ShellEvent(button: .left, modifiers: modifiers))
        }

        click(5, .shift)
        XCTAssertEqual(harness.sink.commands, [.moveFocusedWindow(target: "workspace 2")])
        click(5, [])
        XCTAssertEqual(harness.sink.commands.last, .command(.workspace(.switchTo(workspaceNumber: 2))))

        click(15, .option)
        XCTAssertNil(harness.host.popout)
        click(15, [])
        XCTAssertNotNil(harness.host.popout)
    }

    func testScratchpadsCompactOnlyWhenTheirIslandRunsOutOfRoom() {
        let window = WorkspaceBarWindowItem(
            id: WindowToken(pid: 41, windowId: 7),
            handle: WindowHandle(id: WindowToken(pid: 41, windowId: 7)),
            windowId: 7,
            appName: "Mail",
            bundleId: nil,
            icon: nil,
            isFocused: false,
            windowCount: 1,
            hiddenWindowCount: 0,
            allWindows: []
        )
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: [
                WorkspaceBarScratchpadItem(index: 1, label: "Notes", windows: [window], isVisible: false),
                WorkspaceBarScratchpadItem(index: 2, label: "Shown", windows: [window], isVisible: true)
            ]),
            backgroundOpacity: 1,
            barHeight: 24
        )
        let slot = { (id: String, width: CGFloat) in
            WorkspaceBarShellWidget(id: id, size: CGSize(width: width, height: 24), lane: .leading)
        }
        let compact = { (slots: [WorkspaceBarShellWidget], width: CGFloat) in
            WorkspaceBarManager.compactScratchpads(snapshot, beside: slots, availableWidth: width)
        }
        XCTAssertEqual(compact([slot("workspaces", 100), slot("scratchpads", 900)], 400), [])
        XCTAssertEqual(compact([slot("workspaces", 230)], 400), [1])
        XCTAssertEqual(compact([slot("workspaces", 390)], 400), [1, 2])
    }

    func testHiddenBarItemsReachWidgetsAndActivationPreservesTheIconAnchor() async throws {
        executionTimeAllowance = 60
        guard NSScreen.screens.contains(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("edge popouts need the main display")
        }
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = 10 + #ctx.data.hiddenBar.items + (tonumber(ctx.data.vars.n) or 0), h = 10 }
        end
        function popout(ctx)
            return ui.box{ w = 20, h = 20, onClick = "hidden-bar activate " .. ctx.data.hiddenBar.items[1].id }
        end
        """, bars: [ShellBarKey(monitor: main): ShellBarData()])
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        harness.host.updateHiddenBar(ShellHiddenBarData(enabled: true, available: true, items: [
            ShellHiddenBarItem(id: "com.example.app#1", name: "App", image: nil, width: 16, height: 16),
            ShellHiddenBarItem(id: "com.example.app#2", name: "App", image: "hidden-bar/1", width: 22, height: 16)
        ]))
        let slot = { harness.host.slots(for: main).first?.size.width }
        while slot() != 12 {
            try await layoutChanges.change()
        }

        XCTAssertTrue(harness.host.togglePopout(of: "test", on: main))
        let popout = try XCTUnwrap(harness.host.popout)
        harness.sink.vars = ["n": "1"]
        harness.host.updateVars()
        while slot() != 13 {
            try await layoutChanges.change()
        }
        XCTAssertEqual(popout.surface.size, CGSize(width: 20, height: 20))
        popout.surface.press(at: CGPoint(x: 5, y: 5))
        popout.surface.release(at: CGPoint(x: 5, y: 5))
        XCTAssertEqual(harness.sink.commands, [.hiddenBarActivate(item: "com.example.app#1")])
        XCTAssertTrue(harness.host.popout === popout)
        let origin = try XCTUnwrap(harness.sink.origins.last)
        XCTAssertEqual(origin.monitor, main)
        XCTAssertEqual(origin.anchor?.frame, popout.panel.convertToScreen(
            popout.surface.view.convert(CGRect(x: 0, y: 0, width: 20, height: 20), to: nil)
        ))

        XCTAssertEqual(ShellRequest("hidden-bar activate a.b#c#3"), .hiddenBarActivate(item: "a.b#c#3"))
        XCTAssertEqual(MenuBarItemKey(shellID: "a.b#c#3"), MenuBarItemKey(bundleID: "a.b#c", ordinal: 3))
        XCTAssertEqual(MenuBarItemKey(bundleID: "a.b", ordinal: 0).shellID, "a.b#0")
        XCTAssertNil(MenuBarItemKey(shellID: "a.b"))
        XCTAssertNil(MenuBarItemKey(shellID: "a.b#x"))
    }

    func testClosingHiddenBarClosesItsMenuAndInvalidatesActions() async throws {
        executionTimeAllowance = 60
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let harness = try harness("""
        function render(ctx) return ui.box{ w = 10, h = 10 } end
        function popout(ctx) return ui.box{ w = 20, h = 20 } end
        """, bars: [ShellBarKey(monitor: main): ShellBarData()])
        defer { harness.close() }
        var changes = harness.layoutChanges.makeAsyncIterator()
        try await changes.change()
        XCTAssertTrue(harness.host.togglePopout(of: "test", on: main))
        let parent = try XCTUnwrap(harness.host.popout)
        let page = HiddenBarMenuPage(title: "App", rows: [
            HiddenBarMenuRow(
                id: "command", title: "Command", enabled: true,
                mark: nil, shortcut: nil, submenu: false, separator: false
            )
        ], backID: nil)
        var closed = 0
        XCTAssertTrue(harness.host.showHiddenBarMenu(
            page,
            anchor: ShellAnchor(frame: CGRect(x: 200, y: 500, width: 20, height: 20), level: .popUpMenu),
            onSelect: { _ in XCTFail("closed menu must not dispatch") },
            onClose: { closed += 1 }
        ))
        let menu = try XCTUnwrap(harness.host.hiddenBarMenu)
        XCTAssertTrue(harness.host.popout === parent)
        harness.host.closePopout(animated: false)
        XCTAssertNil(harness.host.hiddenBarMenu)
        XCTAssertNil(harness.host.popout)
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(menu.popout.panel.isVisible)
        harness.host.closePopout(animated: false)
        XCTAssertEqual(closed, 1)
    }

    func testProfileChangeClosesHiddenBarMenuWhenParentSourceAndThemeAreUnchanged() async throws {
        executionTimeAllowance = 60
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let harness = try harness("""
        function render(ctx) return ui.box{ w = 10, h = 10 } end
        function popout(ctx) return ui.box{ w = 20, h = 20 } end
        """, bars: [ShellBarKey(monitor: main): ShellBarData()], files: [
            "look/shell.toml": "trailing = [\"test\"]\n"
        ])
        defer { harness.close() }
        var changes = harness.layoutChanges.makeAsyncIterator()
        try await changes.change()
        XCTAssertTrue(harness.host.togglePopout(of: "test", on: main))
        let parent = try XCTUnwrap(harness.host.popout)
        let theme = harness.host.config.theme
        var closed = 0
        XCTAssertTrue(harness.host.showHiddenBarMenu(
            HiddenBarMenuPage(title: nil, rows: [], backID: nil),
            anchor: ShellAnchor(frame: CGRect(x: 200, y: 500, width: 20, height: 20), level: .popUpMenu),
            onSelect: { _ in XCTFail("closed menu must not dispatch") },
            onClose: { closed += 1 }
        ))
        let menu = try XCTUnwrap(harness.host.hiddenBarMenu)
        let shell = harness.root.appendingPathComponent("shell")
        XCTAssertTrue(try ShellProfiles.select("look", in: shell))
        harness.host.reloadConfig()
        XCTAssertEqual(harness.host.config.profile, "look")
        XCTAssertEqual(harness.host.config.theme, theme)
        XCTAssertTrue(harness.host.popout === parent)
        XCTAssertNil(harness.host.hiddenBarMenu)
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(menu.popout.panel.isVisible)
    }

    func testHandlersRunCommandsAndReportInvalidOnes() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            print("rendering", 1)
            omniwm.log("still rendering")
            return ui.box{ w = 10, h = 10, onClick = function(ctx)
                omniwm.run("switch-workspace 3")
                omniwm.run("not a command")
            end }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        click(try harness.barSurface(), at: CGPoint(x: 5, y: 5))
        while harness.slot?.failure == nil {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.sink.commands, [.command(.workspace(.switchTo(workspaceNumber: 3)))])
        XCTAssertEqual(harness.sink.origins.first?.widget, "test")
        XCTAssertEqual(harness.sink.origins.first?.command, "switch-workspace 3")
        XCTAssertEqual(
            harness.slot?.failure?.message,
            "omniwm.run command is not an omniwmctl, shell or volume command"
        )
    }

    func testInvalidCommandsReportNoCommandContents() async throws {
        executionTimeAllowance = 60
        let hex = "Private reply draft".utf8.map { String(format: "%02x", $0) }.joined()
        let command = "notifications reply com.example.fixture 01234567-89ab-cdef-0123-456789abcdef \(hex)0"
        let harness = try harness("""
        function render(ctx)
            return ui.row{ gap = 0,
                ui.box{ w = 10, h = 10, onClick = function() omniwm.run("\(command)") end },
                ui.box{ w = 10, h = 10, onClick = "\(command)" },
            }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        for (point, source) in [(CGPoint(x: 5, y: 5), "omniwm.run"), (CGPoint(x: 15, y: 5), "onClick")] {
            let message = "\(source) command is not an omniwmctl, shell or volume command"
            click(try harness.barSurface(), at: point)
            while harness.slot?.failure?.message != message {
                try await layoutChanges.change()
            }
            XCTAssertEqual(harness.host.widgetReport.widgets.first { $0.name == "test" }?.error, message)
            let errors = LogErrorTap.shared.dump()
            XCTAssertTrue(errors.contains(message))
            XCTAssertFalse(errors.contains(hex))
            XCTAssertFalse(errors.contains("Private reply draft"))
        }
        XCTAssertTrue(harness.sink.commands.isEmpty)
    }

    func testRenderCannotRunCommands() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            omniwm.run("switch-workspace 2")
            return ui.box{ w = 10, h = 10 }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot?.failure == nil {
            try await layoutChanges.change()
        }
        XCTAssertTrue(harness.slot?.failure?.message.contains("requires a handler or service callback") == true)
        XCTAssertTrue(harness.sink.commands.isEmpty)
    }

    func testHostDemandsOnlyTheDataWidgetsRead() async throws {
        executionTimeAllowance = 60
        let harness = try harness("function render(ctx) return ui.box{ w = 10 + (ctx.data.gpu or 0) * 0, h = 10 } end")
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertNotEqual(harness.host.dataDemand & ShellDataKey.gpu.bit, 0)
        XCTAssertEqual(harness.host.dataDemand & ShellDataKey.network.bit, 0)
    }

    func testIconOverrideChangesRedrawWidgetIcons() async throws {
        executionTimeAllowance = 60
        let harness = try harness("function render(ctx) return ui.icon{ app = \"com.apple.finder\" } end")
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let icon = { () -> AnyObject? in
            ShellLayerScene.engineQueue.sync {}
            return surface.view.layer?.sublayers?.first?.sublayers?.first?.contents as AnyObject?
        }
        let original = try XCTUnwrap(icon())

        let override = NSImage(size: NSSize(width: 8, height: 8))
        override.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        override.unlockFocus()
        harness.sink.iconOverride = override
        harness.host.iconsDidChange()
        XCTAssertFalse(try XCTUnwrap(icon()) === original)
    }

    func testWidgetsReadingTheTimeThroughOsDemandSeconds() async throws {
        executionTimeAllowance = 60
        let harness = try harness("function render(ctx) return ui.text{ text = os.date(\"%S\") } end")
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertNotEqual(harness.host.dataDemand & ShellDataKey.seconds.bit, 0)
    }

    func testWidgetsReadValuesPushedThroughShellVars() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = tonumber(ctx.data.vars.size) or 10, h = 10 }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot?.size.width != 10 {
            try await layoutChanges.change()
        }
        for (vars, width) in [(["size": "30"], CGFloat(30)), ([:], 10)] {
            harness.sink.vars = vars
            harness.host.updateVars()
            while harness.slot?.size.width != width {
                try await layoutChanges.change()
            }
        }
    }

    func testLanesLoadBundledWidgetsUnlessAUserWidgetSharesTheName() async throws {
        executionTimeAllowance = 60
        let harness = try harness("function render(ctx) return ui.box{ w = 10, h = 10 } end")
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let clockWidth = { harness.host.slots(for: Harness.monitor).first { $0.id == "clock" }?.size.width ?? 0 }
        try Data("profiles.default.trailing = [\"test\", \"clock\"]\n".utf8)
            .write(to: harness.root.appendingPathComponent("shell/shell.toml"))
        harness.host.rescan()
        while clockWidth() == 0 {
            try await layoutChanges.change()
        }
        XCTAssertNotEqual(clockWidth(), 33)

        let user = harness.root.appendingPathComponent("shell/widgets/clock", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data("function render(ctx) return ui.box{ w = 33, h = 10 } end".utf8)
            .write(to: user.appendingPathComponent("init.luau"))
        harness.host.rescan()
        while clockWidth() != 33 {
            try await layoutChanges.change()
        }
    }

    func testPopoutsWithAnimateMorphToTheirNewSize() async throws {
        executionTimeAllowance = 60
        guard NSScreen.screens.contains(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("edge popouts need the main display")
        }
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let harness = try harness("""
        function render(ctx) return ui.box{ w = 5, h = 10 } end
        function popout(ctx)
            local w = tonumber(ctx.data.vars.w) or 100
            return ui.box{ w = w, h = 40, fill = "surface", animate = { duration = 0.05, curve = "spatial" } }
        end
        """, bars: [ShellBarKey(monitor: main): ShellBarData()], animations: true)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertTrue(harness.host.togglePopout(of: "test", on: main))
        let popout = try XCTUnwrap(harness.host.popout)
        await until { popout.panel.isVisible && popout.surface.size.width == 100 }
        let before = popout.panel.frame

        harness.sink.vars = ["w": "180"]
        harness.host.updateVars()
        await until { popout.surface.size.width == 180 }
        let after = popout.panel.frame
        XCTAssertEqual(after.width, max(before.maxX, after.maxX) - min(before.minX, after.minX))
        XCTAssertNotNil(popout.panel.contentView?.subviews.last?.layer?.animation(forKey: ShellPopoutPanel.morphBounds))
        await until { popout.panel.frame.width == 180 }
    }

    func testPopoutsDemandTheDataTheyRead() async throws {
        executionTimeAllowance = 60
        guard NSScreen.screens.contains(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("edge popouts need the main display")
        }
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = tonumber(ctx.data.vars.w) or 5, h = 10 }
        end
        function popout(ctx)
            return ui.box{ w = 20 + (ctx.data.gpu or 0) * 0, h = 20 }
        end
        """, bars: [ShellBarKey(monitor: main): ShellBarData()])
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let gpu = ShellDataKey.gpu.bit
        XCTAssertEqual(harness.host.dataDemand & gpu, 0)

        XCTAssertTrue(harness.host.togglePopout(of: "test", on: main))
        harness.sink.vars = ["w": "9"]
        harness.host.updateVars()
        try await layoutChanges.change()
        XCTAssertNotEqual(harness.host.dataDemand & gpu, 0)

        XCTAssertTrue(harness.host.togglePopout(of: "test", on: main))
        XCTAssertEqual(harness.host.dataDemand & gpu, 0)
    }

    func testWidgetsReadTheirSettingsFromShellToml() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            local settings = ctx.data.settings
            return ui.box{ w = settings and settings.size or 10, h = 10 }
        end
        """)
        defer { harness.close() }
        let config = harness.root.appendingPathComponent("shell/shell.toml")
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.slot?.size.width != 10 {
            try await layoutChanges.change()
        }
        let steps: [(String, CGFloat)] = [
            ("profiles.default.trailing = [\"test\"]\n[profiles.default.widgets.test]\nsize = 30\n", 30),
            ("profiles.default.trailing = [\"test\"]\n[profiles.default.widgets.test]\nsize = 40\n", 40),
            ("profiles.default.trailing = [\"test\"]\n", 10)
        ]
        for (contents, width) in steps {
            try Data(contents.utf8).write(to: config)
            harness.host.rescan()
            while harness.slot?.size.width != width {
                try await layoutChanges.change()
            }
        }
    }

    func testRequestsParseCommandsAndWindowActions() {
        XCTAssertEqual(ShellRequest("switch-workspace 2"), .command(.workspace(.switchTo(workspaceNumber: 2))))
        XCTAssertEqual(ShellRequest("window focus ow_abc"), .window(IPCWindowRequest(name: .focus, windowId: "ow_abc")))
        XCTAssertNil(ShellRequest("window focus"))
        XCTAssertNil(ShellRequest("window explode ow_abc"))
    }

    func testActionsParseVolumeCommandsBesideWindowManagerCommands() {
        XCTAssertEqual(ShellAction("volume up"), .volume(.change(percent: 6.25)))
        XCTAssertEqual(ShellAction("volume down"), .volume(.change(percent: -6.25)))
        XCTAssertEqual(ShellAction("volume mute"), .volume(.toggleMute))
        XCTAssertEqual(ShellAction("volume set 40"), .volume(.set(percent: 40)))
        XCTAssertEqual(ShellAction("switch-workspace 2"), .wm(.command(.workspace(.switchTo(workspaceNumber: 2)))))
        XCTAssertNil(ShellAction("volume"))
        XCTAssertNil(ShellAction("volume set loud"))
        XCTAssertNil(ShellAction("volume set nan"))
        XCTAssertEqual(ShellAction("volume up 3"), .volume(.change(percent: 3)))
        XCTAssertNil(ShellAction("volume up loud"))
        XCTAssertEqual(ShellAction("shell toggle control"), .toggle(widget: "control"))
        XCTAssertNil(ShellAction("shell toggle"))
    }

    func testToggleOpensAWidgetPopoutAtTheScreenEdgeWithoutABarSlot() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("edge popouts need the main display")
        }
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = tonumber(ctx.data.vars.w) or 5, h = 10 }
        end
        function popout(ctx)
            return ui.box{ w = 50, h = 30 }
        end
        """, bars: [ShellBarKey(monitor: main): ShellBarData()])
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertFalse(harness.host.togglePopout(of: "missing", on: main))

        XCTAssertTrue(harness.host.togglePopout(of: "test", on: main))
        let popout = try XCTUnwrap(harness.host.popout)
        harness.sink.vars = ["w": "9"]
        harness.host.updateVars()
        try await layoutChanges.change()
        await until { popout.surface.size == CGSize(width: 50, height: 30) }
        XCTAssertEqual(popout.surface.size, CGSize(width: 50, height: 30))
        XCTAssertEqual(popout.panel.frame.maxX, screen.visibleFrame.maxX - 8, accuracy: 0.5)
        XCTAssertEqual(popout.panel.frame.maxY, screen.visibleFrame.maxY - 5, accuracy: 0.5)
        XCTAssertEqual(popout.panel.level, .popUpMenu)

        XCTAssertTrue(harness.host.togglePopout(of: "test", on: main))
        XCTAssertNil(harness.host.popout)
    }

    func testDrawersStackTheirWidgetsPopoutsAtTheScreenEdgeAsTheOnlyOpenSurface() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("drawers need the main display")
        }
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let harness = try harness("""
        function render(ctx) return ui.box{ w = 10, h = 10 } end
        function popout(ctx) return ui.box{ w = 60, h = 20 } end
        """, bars: [ShellBarKey(monitor: main): ShellBarData()])
        defer { harness.close() }
        let shell = harness.root.appendingPathComponent("shell")
        let second = shell.appendingPathComponent("widgets/second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("""
        function render(ctx) return ui.box{ w = 12, h = 10 } end
        function popout(ctx) return ui.box{ w = 80, h = 30 } end
        """.utf8).write(to: second.appendingPathComponent("init.luau"))
        try Data("""
        profiles.default.leading = []
        profiles.default.trailing = ["test", "second"]
        [profiles.default.drawer.controls]
        edge = "right"
        widgets = ["test", "second"]
        """.utf8).write(to: shell.appendingPathComponent("shell.toml"))
        harness.host.rescan()
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.host.slots(for: main).count < 2 {
            try await layoutChanges.change()
        }
        XCTAssertFalse(harness.host.toggleDrawer("missing", on: main))

        XCTAssertTrue(harness.host.toggle("controls", on: main))
        let drawer = try XCTUnwrap(harness.host.drawer)
        XCTAssertEqual(drawer.sections.map(\.widget), ["test", "second"])
        await until {
            drawer.panel.isVisible && drawer.sections.allSatisfy { $0.surface.size.height > 0 }
        }
        XCTAssertEqual(drawer.panel.frame.size, CGSize(width: 80 + 24, height: 12 + 20 + 12 + 30 + 12))
        XCTAssertEqual(drawer.panel.frame.maxX, screen.visibleFrame.maxX - 8, accuracy: 1)
        XCTAssertEqual(drawer.panel.frame.midY, screen.visibleFrame.midY, accuracy: 1)
        XCTAssertEqual(drawer.sections.map(\.surface.view.frame.minY), [12, 44])
        XCTAssertEqual(drawer.sections.map(\.surface.view.frame.minX), [22, 12])

        XCTAssertTrue(harness.host.toggle("test", on: main))
        XCTAssertNil(harness.host.drawer)
        XCTAssertEqual(harness.host.popout?.widget, "test")
        XCTAssertTrue(harness.host.toggle("controls", on: main))
        XCTAssertNil(harness.host.popout)
        XCTAssertNotNil(harness.host.drawer)
        XCTAssertTrue(harness.host.toggle("controls", on: main))
        XCTAssertNil(harness.host.drawer)
    }

    func testPopoutsFollowTheElementThatOpenedThem() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("popouts need the main display")
        }
        let harness = try harness("""
        function render(ctx)
            return ui.row{ ui.box{ key = "pad", w = tonumber(ctx.data.vars.w) or 0, h = 10 },
                ui.box{ key = "button", w = 10, h = 10, onClick = ui.popout } }
        end
        function popout(ctx) return ui.box{ w = 50, h = 30 } end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let bar = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.maxY - 100, width: 200, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        bar.isReleasedWhenClosed = false
        bar.contentView = surface.view
        bar.orderFrontRegardless()
        defer { bar.close() }
        click(surface, at: CGPoint(x: 5, y: 5))
        let popout = try XCTUnwrap(harness.host.popout)
        await until { popout.panel.isVisible }
        let opened = popout.panel.frame

        harness.sink.vars = ["w": "40"]
        harness.host.updateVars()
        try await layoutChanges.change()
        XCTAssertEqual(popout.panel.frame.midX, opened.midX + 40, accuracy: 0.5)

        bar.setFrameOrigin(CGPoint(x: bar.frame.minX + 30, y: bar.frame.minY))
        XCTAssertEqual(popout.panel.frame.midX, opened.midX + 70, accuracy: 0.5)
        XCTAssertTrue(harness.host.popout === popout)
    }

    func testATallPopoutLaysItsContentOutAtThePanelSize() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("popouts need the main display")
        }
        let harness = try harness("""
        function render(ctx) return ui.box{ w = 10, h = 10, onClick = ui.popout } end
        function popout(ctx) return ui.column{ scroll = true, ui.box{ w = 50, h = 5000 } } end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let bar = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.maxY - 100, width: 40, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        bar.isReleasedWhenClosed = false
        bar.contentView = surface.view
        bar.orderFrontRegardless()
        defer { bar.close() }
        click(surface, at: CGPoint(x: 5, y: 5))
        let popout = try XCTUnwrap(harness.host.popout)
        await until { popout.panel.isVisible }
        XCTAssertLessThan(popout.panel.frame.height, 5000)
        XCTAssertEqual(popout.surface.naturalSize.height, 5000)
        XCTAssertEqual(popout.surface.size, popout.panel.frame.size)
    }

    func testAPopoutThatRendersNothingCloses() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("popouts need the main display")
        }
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = ctx.data.vars.gone and 12 or 10, h = 10, onClick = ui.popout }
        end
        function popout(ctx)
            if ctx.data.vars.gone then return ui.column{} end
            return ui.box{ w = 20, h = 20 }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let bar = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.maxY - 100, width: 40, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        bar.isReleasedWhenClosed = false
        bar.contentView = surface.view
        bar.orderFrontRegardless()
        defer { bar.close() }
        click(surface, at: CGPoint(x: 5, y: 5))
        let popout = try XCTUnwrap(harness.host.popout)
        await until { popout.panel.isVisible }
        let opened = harness.sink.popoutChanges

        harness.sink.vars = ["gone": "1"]
        harness.host.updateVars()
        try await layoutChanges.change()
        XCTAssertNil(harness.host.popout)
        XCTAssertEqual(harness.sink.popoutChanges, opened + 1)
    }

    func testClicksOnTheOldTreeWhileAReloadedWidgetIsUnrenderedRunNothing() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = 10, h = 10, onClick = function() omniwm.run("switch-workspace 1") end }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        var clicked = false
        harness.host.onToggleNamesChange = { [unowned self] in
            guard !clicked else { return }
            clicked = true
            click(surface, at: CGPoint(x: 5, y: 5))
        }
        try Data("""
        function render(ctx)
            local w = 12 + (tonumber(ctx.data.vars.n) or 0)
            return ui.box{ w = w, h = 10, onClick = function() omniwm.run("switch-workspace 2") end }
        end
        function popout(ctx) return ui.box{ w = 10, h = 10 } end
        """.utf8).write(to: harness.root.appendingPathComponent("shell/widgets/test/init.luau"))
        harness.host.rescan()
        while harness.slot?.size.width != 12 {
            try await layoutChanges.change()
        }
        XCTAssertTrue(clicked)
        harness.sink.vars = ["n": "3"]
        harness.host.updateVars()
        while harness.slot?.size.width != 15 {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.sink.commands, [])
    }

    func testDrawerOnlyProfileWidgetsStayOffTheBars() throws {
        let harness = try harness("function render(ctx) return ui.box{ w = 10, h = 10 } end")
        defer { harness.close() }
        let shell = harness.root.appendingPathComponent("shell")
        let drawn = shell.appendingPathComponent("default/widgets/drawn", isDirectory: true)
        try FileManager.default.createDirectory(at: drawn, withIntermediateDirectories: true)
        try Data("""
        function render(ctx) return ui.box{ w = 7, h = 10 } end
        function popout(ctx) return ui.box{ w = 10, h = 10 } end
        """.utf8).write(to: drawn.appendingPathComponent("init.luau"))
        try Data("""
        profiles.default.trailing = ["test"]
        [profiles.default.drawer.side]
        edge = "right"
        widgets = ["drawn"]
        """.utf8).write(to: shell.appendingPathComponent("shell.toml"))
        harness.host.rescan()

        XCTAssertNotNil(harness.host.surfaceView(widget: "test", key: Harness.bar, scale: 2))
        XCTAssertNil(harness.host.surfaceView(widget: "drawn", key: Harness.bar, scale: 2))
        let report = harness.host.widgetReport.widgets
        XCTAssertEqual(report.first { $0.name == "drawn" }?.placements, ["drawer side"])
        XCTAssertEqual(report.first { $0.name == "test" }?.placements, ["trailing"])
    }

    func testSymlinkedWidgetFoldersLoadLikeTheSettingsListShowsThem() throws {
        let harness = try harness("function render(ctx) return ui.box{ w = 10, h = 10 } end")
        defer { harness.close() }
        let shell = harness.root.appendingPathComponent("shell")
        let target = harness.root.appendingPathComponent("elsewhere/linked", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("function render(ctx) return ui.box{ w = 5, h = 10 } end".utf8)
            .write(to: target.appendingPathComponent("init.luau"))
        try FileManager.default.createSymbolicLink(
            at: shell.appendingPathComponent("widgets/linked"),
            withDestinationURL: target
        )
        XCTAssertEqual(try ShellBarLayout.load(shellDirectory: shell).get().addable.map(\.name), ["linked"])
        try Data("profiles.default.trailing = [\"linked\", \"test\"]\n".utf8)
            .write(to: shell.appendingPathComponent("shell.toml"))
        harness.host.rescan()

        XCTAssertNotNil(harness.host.surfaceView(widget: "linked", key: Harness.bar, scale: 2))
        XCTAssertEqual(harness.host.widgetReport.widgets.first { $0.name == "linked" }?.placements, ["trailing"])
        XCTAssertEqual(try ShellBarLayout.load(shellDirectory: shell).get().trailing, ["linked", "test"])
    }

    func testToggleNamesListDrawersAndWidgetsWithPopouts() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx) return ui.box{ w = 10, h = 10 } end
        function popout(ctx) return ui.box{ w = 10, h = 10 } end
        """)
        defer { harness.close() }
        var changes = 0
        harness.host.onToggleNamesChange = { changes += 1 }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertEqual(harness.host.toggleNames, ["test"])

        let shell = harness.root.appendingPathComponent("shell")
        try Data("""
        profiles.default.trailing = ["test", "plain"]
        [profiles.default.drawer.controls]
        widgets = ["test"]
        """.utf8).write(to: shell.appendingPathComponent("shell.toml"))
        let before = changes
        harness.host.rescan()
        XCTAssertEqual(harness.host.toggleNames, ["controls", "test"])
        XCTAssertEqual(changes, before + 1)

        let plain = shell.appendingPathComponent("widgets/plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data("function render(ctx) return ui.box{ w = 12, h = 10 } end".utf8)
            .write(to: plain.appendingPathComponent("init.luau"))
        harness.host.rescan()
        while harness.host.slots(for: Harness.monitor).count < 2 {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.host.toggleNames, ["controls", "test"])
        XCTAssertEqual(changes, before + 1)
    }

    func testTriggersCallTheWidgetsTriggerFunctionAndRerender() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx) return ui.box{ w = ctx.state.width or 5, h = 10 } end
        function trigger(ctx, event)
            if event.name == "width" then
                ctx.state.width = tonumber(event.value)
            end
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertEqual(harness.slot?.size.width, 5)
        XCTAssertFalse(harness.host.trigger("missing", name: "width", value: "9"))

        XCTAssertTrue(harness.host.trigger("test", name: "width", value: "17"))
        try await layoutChanges.change()
        XCTAssertEqual(harness.slot?.size.width, 17)
        XCTAssertNil(harness.slot?.failure)
    }

    func testWidgetsWithoutATriggerFunctionCannotBeTriggered() async throws {
        executionTimeAllowance = 60
        let harness = try harness("function render(ctx) return ui.box{ w = 5, h = 10 } end")
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertFalse(harness.host.trigger("test", name: "width", value: "17"))
    }

    func testTheWidgetReportFollowsLoadsAndFailures() async throws {
        executionTimeAllowance = 60
        let harness = try harness("function render(ctx) return ui.box{ w = 5, h = 10 } end")
        defer { harness.close() }
        var changes = 0
        harness.host.onWidgetsChange = { changes += 1 }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let loaded = try XCTUnwrap(harness.host.widgetReport.widgets.first { $0.name == "test" })
        XCTAssertEqual(loaded.state, "loaded")
        XCTAssertEqual(loaded.placements, ["trailing"])
        XCTAssertNil(loaded.error)
        XCTAssertTrue(loaded.source.hasSuffix("shell/widgets/test/init.luau"))
        XCTAssertEqual(harness.host.widgetReport.profile, "default")
        let before = changes

        try Data("function render(ctx) return ui.box{ w = = 5 } end".utf8)
            .write(to: harness.root.appendingPathComponent("shell/widgets/test/init.luau"))
        harness.host.rescan()
        while harness.host.widgetReport.widgets.first(where: { $0.name == "test" })?.state != "failed" {
            try await layoutChanges.change()
        }
        XCTAssertNotNil(harness.host.widgetReport.widgets.first { $0.name == "test" }?.error)
        XCTAssertGreaterThan(changes, before)
    }

    func testToggleOpensAHeadlessPopoutOnAMonitorWithoutABar() async throws {
        executionTimeAllowance = 60
        guard NSScreen.screens.contains(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("edge popouts need the main display")
        }
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = tonumber(ctx.data.vars.w) or 5, h = 10 }
        end
        function popout(ctx)
            return ui.box{ w = 50, h = 30 }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let headlessView = { harness.host.surfaceView(widget: "test", key: ShellBarKey(monitor: main), scale: 2) }
        XCTAssertNil(headlessView())

        XCTAssertTrue(harness.host.togglePopout(of: "test", on: main))
        let popout = try XCTUnwrap(harness.host.popout)
        XCTAssertEqual(popout.key, ShellBarKey(monitor: main))
        harness.sink.vars = ["w": "9"]
        harness.host.updateVars()
        try await layoutChanges.change()
        await until { popout.surface.size == CGSize(width: 50, height: 30) }
        XCTAssertEqual(popout.surface.size, CGSize(width: 50, height: 30))
        XCTAssertTrue(harness.host.slots(for: main).isEmpty)
        XCTAssertEqual(harness.slot?.size.width, 9)

        harness.sink.vars = ["w": "11"]
        harness.host.updateBars()
        harness.host.updateVars()
        try await layoutChanges.change()
        XCTAssertTrue(harness.host.popout === popout)
        XCTAssertNotNil(headlessView())

        XCTAssertTrue(harness.host.togglePopout(of: "test", on: main))
        XCTAssertNil(harness.host.popout)
        XCTAssertNil(headlessView())
    }

    @MainActor
    private final class JoinLog {
        var joins: [HiddenBarPanelPlacement.Join?] = []
    }

    private func assertFrame(_ frame: CGRect, _ expected: CGRect, line: UInt = #line) {
        XCTAssertEqual(frame.minX, expected.minX, accuracy: 1, line: line)
        XCTAssertEqual(frame.minY, expected.minY, accuracy: 1, line: line)
        XCTAssertEqual(frame.maxX, expected.maxX, accuracy: 1, line: line)
        XCTAssertEqual(frame.maxY, expected.maxY, accuracy: 1, line: line)
    }

    func testTextWrapsUpToItsLineLimit() async throws {
        executionTimeAllowance = 60
        let sample = "Version 27.2 (Build 26C5) 5120×2880 @ 120 Hz 1920×1080 @ 60 Hz"
        let harness = try harness("""
        function render(ctx)
            local text = "\(sample)"
            return ui.column{
                ui.text{ text = text, maxWidth = 120, lines = 2, style = "small" },
                ui.text{ text = text, maxWidth = 120, style = "small" },
            }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let font = ShellTextStyle.font(for: 3)
        let text = NSAttributedString(
            string: sample,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        XCTAssertGreaterThan(ShellTextStyle.wrappedLines(text, width: 120, limit: 10).count, 2)
        let wrapped = ShellTextStyle.wrappedSize(
            of: ShellTextStyle.wrappedLines(text, width: 120, limit: 2),
            font: font
        )
        let single = (CTFontGetAscent(font) + CTFontGetDescent(font)).rounded(.up)
        XCTAssertLessThanOrEqual(wrapped.width, 120)
        XCTAssertGreaterThan(wrapped.height, single * 2 - 1)
        XCTAssertEqual(harness.slot?.size, CGSize(width: 120, height: wrapped.height + single))

        let surface = try harness.barSurface()
        ShellLayerScene.engineQueue.sync {}
        let labels = try XCTUnwrap(surface.view.layer).flattened
            .filter { $0.contents != nil }
            .sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(labels.first?.bounds.height, wrapped.height)
        let image = (labels.first?.contents as AnyObject?).map { $0 as! CGImage }
        XCTAssertEqual(image?.height, Int(wrapped.height * 2))
    }

    func testBundledHiddenBarWrapsItemsLikeTheNativeDrawer() async throws {
        executionTimeAllowance = 60
        guard NSScreen.screens.contains(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("popouts need the main display")
        }
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let source = try String(
            contentsOf: XCTUnwrap(ShellConfig.bundledWidget("hidden-bar")),
            encoding: .utf8
        )
        let harness = try harness(source, bars: [ShellBarKey(monitor: main): ShellBarData()])
        defer { harness.close() }
        let items = (0 ..< 6).map {
            ShellHiddenBarItem(id: "com.example.\($0)#0", name: "\($0)", image: nil, width: 30, height: 16)
        }
        await until { harness.host.widgets["test"]?.package != nil }
        _ = try XCTUnwrap(harness.host.widgets["test"]?.package)
        var previous = 0
        let size = { (data: ShellHiddenBarData) async throws -> CGSize in
            harness.host.updateHiddenBar(data)
            XCTAssertTrue(harness.host.togglePopout(of: "test", on: main))
            let popout = try XCTUnwrap(harness.host.popout)
            defer { harness.host.closePopout(animated: false) }
            await until { popout.surface.sequence > previous }
            XCTAssertGreaterThan(popout.surface.sequence, previous)
            previous = popout.surface.sequence
            return popout.surface.size
        }
        let rows = try await size(ShellHiddenBarData(
            enabled: true,
            available: true,
            items: items,
            maxWidth: 70,
            cell: 20
        ))
        XCTAssertEqual(rows, CGSize(width: 2 + 2 + 60 + 2 + 2, height: 2 + 3 * 20 + 2 * 2 + 2))
        let columns = try await size(ShellHiddenBarData(
            enabled: true,
            available: true,
            items: items,
            maxHeight: 50,
            cell: 20,
            vertical: true
        ))
        XCTAssertEqual(columns, CGSize(width: 2 + 3 * 30 + 2 * 2 + 2, height: 2 + 2 + 2 * 20 + 2 + 2))
        let single = try await size(ShellHiddenBarData(enabled: true, available: true, items: items, cell: 20))
        XCTAssertEqual(single, CGSize(width: 2 + 2 + 6 * 30 + 2 + 2, height: 2 + 20 + 2))
    }

    func testWidgetsReadSystemDetails() async throws {
        executionTimeAllowance = 60
        let harness = try harness("""
        function render(ctx)
            local system = ctx.data.system
            if not system then
                return ui.box{ w = 1, h = 10 }
            end
            local ready = system.memory.total > system.memory.used and system.disk.total > 0
                and system.uptime > 0 and #system.host.chip > 0 and #system.host.os > 0
                and system.displays[1].w > 0 and system.displays[1].hz > 0
            return ui.box{ w = 10 * #system.displays + (ready and 1 or 0), h = 10 }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        let expected = CGFloat(10 * NSScreen.screens.count + 1)
        while harness.slot?.size.width != expected, harness.slot?.failure == nil {
            try await layoutChanges.change()
        }
        XCTAssertNil(harness.slot?.failure)
        XCTAssertEqual(harness.slot?.size.width, expected)
    }

    func testPopoutRootsChooseThePanelChrome() async throws {
        executionTimeAllowance = 60
        guard NSScreen.screens.contains(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("popouts need the main display")
        }
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = tonumber(ctx.data.vars.w) or 5, h = 10 }
        end
        function popout(ctx)
            local mode = ctx.data.vars.glass
            local material = if mode == "1" then "glass" elseif mode == "2" then "clear" else nil
            return ui.box{ w = 50, h = 30, material = material, radius = if mode == "1" then 14 else nil,
                ui.box{ w = 10, h = 10, material = if mode == "2" then "clear" else nil } }
        end
        """, bars: [ShellBarKey(monitor: main): ShellBarData()])
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertTrue(harness.host.togglePopout(of: "test", on: main))
        let popout = try XCTUnwrap(harness.host.popout)
        let panel = try XCTUnwrap(popout.panel as? ShellPopoutPanel)
        harness.sink.vars = ["w": "9"]
        harness.host.updateVars()
        try await layoutChanges.change()
        await until { popout.surface.size.width > 0 }
        XCTAssertEqual(popout.surface.chrome, ShellPopoutChrome())
        XCTAssertFalse(panel.showsGlass)

        harness.sink.vars = ["w": "11", "glass": "1"]
        harness.host.updateVars()
        try await layoutChanges.change()
        await until { popout.surface.chrome.glass }
        XCTAssertEqual(popout.surface.chrome, ShellPopoutChrome(glass: true, radius: 14))
        XCTAssertTrue(panel.showsGlass)
        ShellLayerScene.engineQueue.sync {}
        let backdrops = try XCTUnwrap(popout.surface.view.layer).flattened.filter { $0.zPosition == -2 }
        XCTAssertEqual(backdrops, [])
        XCTAssertTrue(panel.hasShadow)

        harness.sink.vars = ["w": "13", "glass": "2"]
        harness.host.updateVars()
        try await layoutChanges.change()
        await until { popout.surface.chrome.clear }
        XCTAssertEqual(popout.surface.chrome, ShellPopoutChrome(clear: true))
        XCTAssertFalse(panel.showsGlass)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.contentView?.subviews.filter { !$0.isHidden }, [popout.surface.view])
        ShellLayerScene.engineQueue.sync {}
        XCTAssertEqual(try XCTUnwrap(popout.surface.view.layer).flattened.filter { $0.zPosition == -2 }, [])
    }

    func testPopoutsHangOffTheBarEdgeCenteredOnTheirElement() async throws {
        executionTimeAllowance = 60
        let element = CGRect(x: 4, y: 500, width: 22, height: 22)
        let bar = CGRect(x: 2, y: 100, width: 26, height: 800)
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(
            ShellPopout.attachment(
                anchor: ShellAnchor(frame: element, level: .statusBar, container: bar),
                edge: .right,
                screen: screen
            ),
            PopupAttachment(anchor: CGPoint(x: 28, y: 511), edge: .right)
        )
        XCTAssertEqual(
            ShellPopout.attachment(
                anchor: ShellAnchor(frame: element, level: .statusBar),
                edge: .right,
                screen: screen
            ),
            PopupAttachment(sourceFrame: element, edge: .below)
        )
        XCTAssertEqual(
            ShellPopout.attachment(
                anchor: ShellAnchor(frame: element, level: .statusBar, container: bar),
                edge: nil,
                screen: screen
            ),
            PopupAttachment(sourceFrame: element, edge: .below)
        )

        guard let main = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("popouts need the main display")
        }
        let monitor = Monitor.ID(displayId: CGMainDisplayID())
        let visible = main.visibleFrame
        var data = ShellBarData()
        data.style.position = WorkspaceBarPosition.left.rawValue
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = tonumber(ctx.data.vars.w) or 5, h = 10 }
        end
        function popout(ctx)
            return ui.box{ w = 50, h = 30 }
        end
        """, bars: [ShellBarKey(monitor: monitor): data])
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let side = CGRect(x: visible.minX, y: visible.minY + 100, width: 30, height: 600)
        let button = CGRect(x: side.minX + 4, y: side.minY + 300, width: 22, height: 22)
        XCTAssertTrue(harness.host.togglePopout(
            of: "test",
            on: monitor,
            anchor: ShellAnchor(frame: button, level: .statusBar, container: side)
        ))
        let popout = try XCTUnwrap(harness.host.popout)
        harness.sink.vars = ["w": "9"]
        harness.host.updateVars()
        try await layoutChanges.change()
        await until { popout.panel.isVisible }
        XCTAssertEqual(popout.panel.frame.minX, side.maxX + 4, accuracy: 0.5)
        XCTAssertEqual(popout.panel.frame.midY, button.midY, accuracy: 0.5)
    }

    func testDrawerPopoutsJoinTheBarFollowItAndUnjoinOnClose() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("drawers need the main display")
        }
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = tonumber(ctx.data.vars.w) or 5, h = 10 }
        end
        function popout(ctx)
            return ui.box{ w = 50, h = 30 }
        end
        """, bars: [ShellBarKey(monitor: main): ShellBarData()])
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let visible = screen.visibleFrame
        let placement = { (x: CGFloat) in
            let bar = CGRect(x: visible.minX + x, y: visible.maxY - 30, width: 40, height: 30)
            return HiddenBarPanelPlacement(
                attachment: PopupAttachment(sourceFrame: bar, edge: .below),
                visibleFrame: visible,
                workspaceBar: HiddenBarPanelPlacement.WorkspaceBar(
                    monitorId: main,
                    frame: bar,
                    backgroundStyle: .material,
                    backgroundOpacity: 0
                )
            )
        }
        let log = JoinLog()
        let first = placement(200)
        XCTAssertTrue(harness.host.togglePopout(
            of: "test",
            on: main,
            anchor: ShellAnchor(frame: first.workspaceBar!.frame, level: .statusBar),
            drawer: ShellPopoutDrawer(
                placement: first,
                isExemptWindow: { _ in false },
                onJoin: { log.joins.append($0) }
            )
        ))
        let popout = try XCTUnwrap(harness.host.popout)
        XCTAssertEqual(popout.drawerPlacement, first)
        harness.sink.vars = ["w": "9"]
        harness.host.updateVars()
        try await layoutChanges.change()
        let size = CGSize(width: 50, height: 30)
        XCTAssertEqual(popout.surface.size, size)
        let layout = first.layout(size: size)
        XCTAssertTrue(layout.squaresBar)
        XCTAssertTrue(popout.panel.isVisible)
        assertFrame(popout.panel.frame, layout.frame)
        XCTAssertEqual(popout.panel.level, .popUpMenu)
        XCTAssertGreaterThan(layout.body.width, size.width)
        XCTAssertEqual(popout.surface.view.frame.size, size)
        XCTAssertEqual(popout.surface.view.frame.midX, layout.body.midX, accuracy: 0.5)
        XCTAssertEqual(popout.surface.view.frame.midY, layout.frame.height - layout.body.midY, accuracy: 0.5)
        XCTAssertEqual(log.joins, [first.join])

        let second = placement(300)
        popout.move(to: second)
        popout.move(to: second)
        assertFrame(popout.panel.frame, second.layout(size: size).frame)
        XCTAssertEqual(log.joins, [first.join, second.join])

        harness.host.closePopout(animated: false)
        XCTAssertNil(harness.host.popout)
        XCTAssertFalse(popout.panel.isVisible)
        XCTAssertEqual(log.joins, [first.join, second.join, nil])
    }

    func testDrawerKeysMoveTheFocusRingAndActivateTheFocusedItem() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("drawers need the main display")
        }
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let harness = try harness("""
        function render(ctx)
            return ui.box{ w = tonumber(ctx.data.vars.w) or 5, h = 10 }
        end
        function popout(ctx)
            local items = { gap = 0 }
            for i = 1, 3 do
                items[i] = ui.stack{ key = "item" .. i, w = 20, h = 20, onClick = "switch-workspace " .. i,
                    ui.box{ w = 16, h = 16, radius = 6, hover = "#FF0000FF" } }
            end
            return ui.row(items)
        end
        """, bars: [ShellBarKey(monitor: main): ShellBarData()])
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        XCTAssertTrue(harness.host.togglePopout(
            of: "test",
            on: main,
            drawer: ShellPopoutDrawer(
                placement: HiddenBarPanelPlacement(
                    attachment: PopupAttachment(
                        anchor: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY)
                    ),
                    visibleFrame: screen.visibleFrame
                ),
                isExemptWindow: { _ in false },
                onJoin: { _ in }
            )
        ))
        let popout = try XCTUnwrap(harness.host.popout)
        harness.sink.vars = ["w": "9"]
        harness.host.updateVars()
        try await layoutChanges.change()
        await until { popout.surface.size == CGSize(width: 60, height: 20) }
        XCTAssertEqual(popout.surface.size, CGSize(width: 60, height: 20))
        XCTAssertTrue(popout.panel.firstResponder === popout.surface.view)
        let rings = try XCTUnwrap(popout.surface.view.layer).flattened
            .filter { $0.bounds.size == CGSize(width: 16, height: 16) }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        XCTAssertEqual(rings.count, 3)
        func ringed() -> [Bool] {
            ShellLayerScene.engineQueue.sync {}
            return rings.map { $0.borderWidth == 2 && $0.backgroundColor != nil }
        }
        let press = { (code: Int, shift: Bool) in
            XCTAssertTrue(popout.surface.handleKey(UInt16(code), shift: shift))
        }
        XCTAssertEqual(ringed(), [true, false, false])
        press(kVK_RightArrow, false)
        XCTAssertEqual(ringed(), [false, true, false])
        press(kVK_LeftArrow, false)
        press(kVK_LeftArrow, false)
        XCTAssertEqual(ringed(), [false, false, true])
        press(kVK_Tab, false)
        XCTAssertEqual(ringed(), [true, false, false])
        press(kVK_Tab, true)
        press(kVK_DownArrow, false)
        XCTAssertEqual(ringed(), [false, false, true])
        XCTAssertFalse(popout.surface.handleKey(UInt16(kVK_ANSI_A), shift: false))
        XCTAssertEqual(harness.sink.commands, [])

        let enter = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: popout.panel.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: UInt16(kVK_Return)
        ))
        popout.surface.view.keyDown(with: enter)
        XCTAssertEqual(harness.sink.commands, [.command(.workspace(.switchTo(workspaceNumber: 3)))])
        XCTAssertNil(harness.host.popout)
    }

    func testADrawerReopenedWhileTheLastOneClosesStaysRegistered() async throws {
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("drawers need the main display")
        }
        let placement = HiddenBarPanelPlacement(
            attachment: PopupAttachment(anchor: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY)),
            visibleFrame: screen.visibleFrame
        )
        let motion = MotionPolicy(animationsEnabled: true)
        let closing = ShellDrawerChrome(content: NSView(), placement: placement, motion: motion) { _ in }
        closing.show(size: CGSize(width: 40, height: 20), level: .popUpMenu)
        closing.close(animated: true)
        let reopened = ShellDrawerChrome(content: NSView(), placement: placement, motion: motion) { _ in }
        reopened.show(size: CGSize(width: 40, height: 20), level: .popUpMenu)
        defer { reopened.close(animated: false) }
        XCTAssertTrue(closing.panel.isVisible)

        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !closing.panel.isVisible },
            object: nil
        )
        await fulfillment(of: [hidden], timeout: 10)
        XCTAssertTrue(reopened.panel.isVisible)
        XCTAssertTrue(OwnedWindowRegistry.shared.contains(window: reopened.panel))
        XCTAssertFalse(OwnedWindowRegistry.shared.contains(window: closing.panel))
    }

    func testAnAnimatedPopoutStaysAliveUntilItsCloseFinishes() async throws {
        executionTimeAllowance = 60
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("popouts need a screen") }
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 20, h = 10, onClick = ui.popout },
                ui.box{ w = ctx.state.wide and 40 or 20, h = 10, onClick = function(ctx) ctx.state.wide = not ctx.state.wide end },
            }
        end
        function popout(ctx)
            return ui.box{ w = 50, h = 30 }
        end
        """, animations: true)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let bar = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.maxY - 100, width: 40, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        bar.isReleasedWhenClosed = false
        bar.contentView = surface.view
        click(surface, at: CGPoint(x: 5, y: 5))
        let popout = try XCTUnwrap(harness.host.popout)
        click(surface, at: CGPoint(x: 25, y: 5))
        try await layoutChanges.change()
        await until { popout.panel.isVisible }
        XCTAssertTrue(popout.panel.isVisible)
        XCTAssertEqual(popout.surface.transition.from, 0)
        XCTAssertEqual(popout.surface.transition.to, 1)
        XCTAssertGreaterThan(popout.surface.transition.duration, 0)

        click(surface, at: CGPoint(x: 5, y: 5))
        XCTAssertNil(harness.host.popout)
        XCTAssertTrue(harness.host.closingPopout === popout)
        XCTAssertTrue(popout.panel.isVisible)
        XCTAssertEqual(popout.surface.transition.to, 0)
        XCTAssertFalse(OwnedWindowRegistry.shared.contains(window: popout.panel))

        popout.finishClose()
        XCTAssertNil(harness.host.closingPopout)
        XCTAssertFalse(popout.panel.isVisible)

        click(surface, at: CGPoint(x: 5, y: 5))
        let reopened = try XCTUnwrap(harness.host.popout)
        click(surface, at: CGPoint(x: 25, y: 5))
        try await layoutChanges.change()
        await until { reopened.panel.isVisible }
        XCTAssertTrue(reopened.panel.isVisible)
        harness.host.closePopout()
        XCTAssertTrue(harness.host.closingPopout === reopened)
        harness.host.stop()
        XCTAssertNil(harness.host.closingPopout)
        XCTAssertFalse(reopened.panel.isVisible)
    }

    func testABridgedPopoutCoversItsBarItemButLetsItsClicksThrough() async throws {
        executionTimeAllowance = 60
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("popouts need a screen") }
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 20, h = 10, onClick = ui.popout },
                ui.box{ w = ctx.state.wide and 40 or 20, h = 10, onClick = function(ctx) ctx.state.wide = true end },
            }
        end
        function popout(ctx)
            return ui.stack{ material = "clear", bridge = true,
                ui.column{ ui.box{ w = 50, h = 10, fill = "accent" }, ui.box{ w = 50, h = 20 } },
            }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let bar = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.maxY - 100, width: 40, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        bar.isReleasedWhenClosed = false
        bar.contentView = surface.view
        click(surface, at: CGPoint(x: 5, y: 5))
        let popout = try XCTUnwrap(harness.host.popout)
        click(surface, at: CGPoint(x: 25, y: 5))
        try await layoutChanges.change()
        await until { popout.panel.isVisible }
        XCTAssertTrue(popout.panel.isVisible)
        XCTAssertTrue(popout.isShaped)
        XCTAssertFalse(popout.panel.hasShadow)

        let item = CGPoint(x: bar.frame.minX + 10, y: bar.frame.midY)
        XCTAssertTrue(popout.panel.frame.contains(item))
        XCTAssertFalse(popout.contains(screenPoint: item))
        let top = bar.frame.minY - 4
        XCTAssertTrue(popout.contains(screenPoint: CGPoint(x: popout.panel.frame.minX + 5, y: top - 5)))
        XCTAssertFalse(popout.contains(screenPoint: CGPoint(x: popout.panel.frame.minX + 5, y: top - 20)))
    }

    func testAnAttachedPopoutMeetsTheBarEdge() async throws {
        executionTimeAllowance = 60
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("popouts need a screen") }
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 20, h = 10, onClick = ui.popout },
                ui.box{ w = 20, h = 10, onClick = function(ctx) ctx.state.attach = not ctx.state.attach end },
            }
        end
        function popout(ctx)
            return ui.column{ attach = ctx.state.attach, ui.box{ w = 50, h = 30 } }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let bar = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.maxY - 100, width: 40, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        bar.isReleasedWhenClosed = false
        bar.contentView = surface.view
        click(surface, at: CGPoint(x: 5, y: 5))
        let popout = try XCTUnwrap(harness.host.popout)
        await until { popout.panel.isVisible }
        XCTAssertEqual(popout.panel.frame.maxY, bar.frame.minY - PopupAttachment.gap, accuracy: 0.5)

        click(surface, at: CGPoint(x: 25, y: 5))
        await until { abs(popout.panel.frame.maxY - bar.frame.minY) < 0.5 }
        XCTAssertEqual(popout.panel.frame.maxY, bar.frame.minY, accuracy: 0.5)
        XCTAssertEqual(popout.panel.frame.midX, bar.frame.minX + 10, accuracy: 0.5)
    }

    func testPopoutOpensFromBarAndClosesAfterCommand() async throws {
        executionTimeAllowance = 60
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("popouts need a screen") }
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 20, h = 10, onClick = ui.popout },
                ui.box{ w = ctx.state.wide and 40 or 20, h = 10, onClick = function(ctx) ctx.state.wide = true end },
            }
        end
        function popout(ctx)
            return ui.column{ ui.box{ w = 50, h = 30, onClick = "switch-workspace 3" } }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let bar = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.maxY - 100, width: 40, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        bar.isReleasedWhenClosed = false
        bar.contentView = surface.view
        click(surface, at: CGPoint(x: 5, y: 5))
        let popout = try XCTUnwrap(harness.host.popout)

        click(surface, at: CGPoint(x: 25, y: 5))
        try await layoutChanges.change()
        await until { popout.surface.size == CGSize(width: 50, height: 30) }
        XCTAssertEqual(popout.surface.size, CGSize(width: 50, height: 30))
        XCTAssertTrue(popout.panel.isVisible)

        click(popout.surface, at: CGPoint(x: 25, y: 15))
        XCTAssertEqual(harness.sink.commands, [.command(.workspace(.switchTo(workspaceNumber: 3)))])
        XCTAssertNil(harness.host.popout)
        XCTAssertFalse(popout.panel.isVisible)

        click(surface, at: CGPoint(x: 5, y: 5))
        XCTAssertNotNil(harness.host.popout)
        click(surface, at: CGPoint(x: 5, y: 5))
        XCTAssertNil(harness.host.popout)

        click(surface, at: CGPoint(x: 5, y: 5))
        XCTAssertNotNil(harness.host.popout)
        harness.host.appearanceDidChange()
        XCTAssertNil(harness.host.popout)
    }
}

extension ShellWidgetClickTests {
    func testAPopoutsOwnOpenAndCloseSecondsRunExactlyEvenWithAnimationsOff() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first else { throw XCTSkip("popouts need a screen") }
        let harness = try harness("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 20, h = 10, onClick = ui.popout },
                ui.box{ w = ctx.state.wide and 40 or 20, h = 10, onClick = function(ctx) ctx.state.wide = not ctx.state.wide end },
            }
        end
        function popout(ctx)
            return ui.column{ w = 50, h = 30, open = 0.8, close = 0.6,
                ui.box{ w = 20, h = 10, fill = "accent", enter = { opacity = 0, from = 0.5 } },
                ui.path{ d = "M0 0 L20 0 L20 10 Z", w = 20, h = 10, fill = "accent",
                    enter = { d = "M10 5 L10 5 L10 5 Z" } },
                ui.stack{ w = 20, h = 10, fill = "accent",
                    ui.path{ d = "M0 0 L20 0 L20 10 Z", mask = true, enter = { d = "M10 5 L10 5 L10 5 Z" } } } }
        end
        """)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let surface = try harness.barSurface()
        let bar = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.maxY - 100, width: 40, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        bar.isReleasedWhenClosed = false
        bar.contentView = surface.view
        click(surface, at: CGPoint(x: 5, y: 5))
        let popout = try XCTUnwrap(harness.host.popout)
        click(surface, at: CGPoint(x: 25, y: 5))
        try await layoutChanges.change()
        await until { popout.panel.isVisible }
        XCTAssertEqual(popout.surface.timing, ShellTiming(open: 0.8, close: 0.6))
        XCTAssertEqual(popout.surface.transition.from, 0)
        XCTAssertEqual(popout.surface.transition.to, 1)
        XCTAssertEqual(popout.surface.transition.duration, 0.8, accuracy: 1e-6)
        XCTAssertTrue(popout.surface.transition.forced)
        ShellLayerScene.engineQueue.sync {}
        let all = try XCTUnwrap(popout.surface.view.layer).flattened
        XCTAssertTrue(all.contains { $0.animation(forKey: ShellLayerScene.enterOpacityKey) != nil })
        XCTAssertTrue(all.contains { $0.animation(forKey: ShellLayerScene.enterPathKey) != nil })
        XCTAssertTrue(all.contains { $0.mask?.animation(forKey: ShellLayerScene.enterPathKey) != nil })

        XCTAssertNotNil(popout.surface.onShapeChange)
        harness.host.closePopout()
        XCTAssertNil(popout.surface.onShapeChange)
        XCTAssertTrue(harness.host.closingPopout === popout)
        XCTAssertTrue(popout.panel.isVisible)
        XCTAssertEqual(popout.surface.transition.to, 0)
        XCTAssertTrue(popout.surface.transition.forced)
        XCTAssertGreaterThan(popout.surface.transition.duration, 0)
        XCTAssertLessThanOrEqual(popout.surface.transition.duration, 0.6)

        popout.finishClose()
        XCTAssertNil(harness.host.closingPopout)
        XCTAssertFalse(popout.panel.isVisible)
    }

    func testEdgeDrawerSectionsOpenAndCloseOnTheirWidgetsSeconds() async throws {
        executionTimeAllowance = 60
        guard NSScreen.screens.contains(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("drawers need the main display")
        }
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let harness = try harness("""
        function render(ctx) return ui.box{ w = 10, h = 10 } end
        function popout(ctx) return ui.box{ w = 60, h = 20, open = 0.6, close = 0.4 } end
        """, bars: [ShellBarKey(monitor: main): ShellBarData()])
        defer { harness.close() }
        let shell = harness.root.appendingPathComponent("shell")
        try Data("""
        profiles.default.leading = []
        profiles.default.trailing = ["test"]
        [profiles.default.drawer.controls]
        widgets = ["test"]
        """.utf8).write(to: shell.appendingPathComponent("shell.toml"))
        harness.host.rescan()
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.host.slots(for: main).isEmpty {
            try await layoutChanges.change()
        }

        XCTAssertTrue(harness.host.toggle("controls", on: main))
        let drawer = try XCTUnwrap(harness.host.drawer)
        let section = try XCTUnwrap(drawer.sections.first)
        await until { drawer.panel.isVisible && section.surface.size.height > 0 }
        XCTAssertEqual(section.surface.transition.duration, 0.6, accuracy: 1e-6)
        XCTAssertTrue(section.surface.transition.forced)

        harness.host.closeDrawer()
        XCTAssertNil(harness.host.drawer)
        XCTAssertTrue(harness.host.closingDrawer === drawer)
        XCTAssertTrue(drawer.panel.isVisible)
        XCTAssertEqual(section.surface.transition.to, 0)
        XCTAssertTrue(section.surface.transition.forced)
        XCTAssertLessThanOrEqual(section.surface.transition.duration, 0.4)

        harness.host.stop()
        XCTAssertNil(harness.host.closingDrawer)
        XCTAssertFalse(drawer.panel.isVisible)
    }

    func testHiddenBarStyleDrawerPopoutsKeepTheirSurfaceUntilTheirOwnCloseEnds() async throws {
        executionTimeAllowance = 60
        guard let screen = NSScreen.screens.first(where: { $0.displayId == CGMainDisplayID() }) else {
            throw XCTSkip("drawers need the main display")
        }
        let main = Monitor.ID(displayId: CGMainDisplayID())
        let harness = try harness("""
        function render(ctx) return ui.box{ w = tonumber(ctx.data.vars.w) or 5, h = 10 } end
        function popout(ctx) return ui.box{ w = 50, h = 30, open = 0.5, close = 0.4 } end
        """, bars: [ShellBarKey(monitor: main): ShellBarData()], animations: true)
        defer { harness.close() }
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        try await layoutChanges.change()
        let visible = screen.visibleFrame
        let placement = HiddenBarPanelPlacement(
            attachment: PopupAttachment(anchor: CGPoint(x: visible.midX, y: visible.maxY)),
            visibleFrame: visible
        )
        let log = JoinLog()
        XCTAssertTrue(harness.host.togglePopout(
            of: "test",
            on: main,
            anchor: ShellAnchor(
                frame: CGRect(x: visible.midX, y: visible.maxY - 10, width: 10, height: 10),
                level: .statusBar
            ),
            drawer: ShellPopoutDrawer(
                placement: placement,
                isExemptWindow: { _ in false },
                onJoin: { log.joins.append($0) }
            )
        ))
        let early = try XCTUnwrap(harness.host.popout)
        harness.host.closePopout()
        XCTAssertNil(harness.host.closingPopout)
        XCTAssertFalse(early.panel.isVisible)
        XCTAssertTrue(harness.host.togglePopout(
            of: "test",
            on: main,
            anchor: ShellAnchor(
                frame: CGRect(x: visible.midX, y: visible.maxY - 10, width: 10, height: 10),
                level: .statusBar
            ),
            drawer: ShellPopoutDrawer(
                placement: placement,
                isExemptWindow: { _ in false },
                onJoin: { log.joins.append($0) }
            )
        ))
        let popout = try XCTUnwrap(harness.host.popout)
        harness.sink.vars = ["w": "9"]
        harness.host.updateVars()
        try await layoutChanges.change()
        await until { popout.panel.isVisible }
        XCTAssertEqual(popout.surface.transition.duration, 0.5, accuracy: 1e-6)
        XCTAssertTrue(popout.surface.transition.forced)

        harness.host.closePopout()
        XCTAssertTrue(harness.host.closingPopout === popout)
        XCTAssertTrue(popout.panel.isVisible)
        XCTAssertEqual(popout.surface.transition.to, 0)
        XCTAssertTrue(popout.surface.transition.forced)

        harness.host.stop()
        XCTAssertNil(harness.host.closingPopout)
        XCTAssertFalse(popout.panel.isVisible)
        XCTAssertEqual(log.joins.last, .some(nil))
    }

    func testUnlistedWidgetsLeaveTheBarAndComeBackWhenListed() async throws {
        let harness = try harness("function render(ctx) return ui.box{ w = 10, h = 10 } end")
        defer { harness.close() }
        let monitor = Harness.bar.monitor
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.host.slots(for: monitor).isEmpty {
            try await layoutChanges.change()
        }
        let toml = harness.root.appendingPathComponent("shell/shell.toml")
        try Data("profiles.default.trailing = []\n".utf8).write(to: toml)
        harness.host.rescan()
        XCTAssertTrue(harness.host.slots(for: monitor).isEmpty)
        XCTAssertEqual(harness.host.widgetReport.widgets.first?.placements, [])

        try Data("profiles.default.trailing = [\"test\"]\n".utf8).write(to: toml)
        harness.host.rescan()
        while harness.host.slots(for: monitor).isEmpty {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.host.slots(for: monitor).map(\.id), ["test"])
    }

    func testCenterWidgetsSitBetweenTheLeadingAndTrailingOnes() async throws {
        let harness = try harness("function render(ctx) return ui.box{ w = 10, h = 10 } end")
        defer { harness.close() }
        let shell = harness.root.appendingPathComponent("shell")
        for name in ["one", "two"] {
            let folder = shell.appendingPathComponent("widgets/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("function render(ctx) return ui.box{ w = 10, h = 10 } end".utf8)
                .write(to: folder.appendingPathComponent("init.luau"))
        }
        try Data(
            "profiles.default.leading = [\"one\"]\nprofiles.default.center = [\"test\"]\nprofiles.default.trailing = [\"two\"]\n"
                .utf8
        )
        .write(to: shell.appendingPathComponent("shell.toml"))
        harness.host.rescan()
        let monitor = Harness.bar.monitor
        var layoutChanges = harness.layoutChanges.makeAsyncIterator()
        while harness.host.slots(for: monitor).count < 3 {
            try await layoutChanges.change()
        }
        XCTAssertEqual(harness.host.slots(for: monitor).map(\.id), ["one", "test", "two"])
        XCTAssertEqual(harness.host.slots(for: monitor).map(\.lane), [.leading, .center, .trailing])
    }
}
