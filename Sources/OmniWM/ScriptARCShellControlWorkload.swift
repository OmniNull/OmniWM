// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMAutomation
import ScriptARCCounters

@MainActor
func measureShellControls(in directory: URL) async throws {
    for kind in ShellControlAudit.Kind.allCases {
        let audit = try ShellControlAudit(in: directory, kind: kind)
        defer { audit.close() }
        try await audit.measureScript()
        await audit.measureNative()
    }
}

@MainActor
private final class ShellControlAudit {
    enum Kind: String, CaseIterable {
        case absent
        case setChanged = "set-changed"
        case setEqual = "set-equal"
        case unsetMissing = "unset-missing"
        case togglePopup = "toggle-popup"
        case triggerAccepted = "trigger-accepted"
        case triggerRefused = "trigger-refused"
    }

    private final class Counts {
        var varReads = 0
        var publications = 0
        var popupChanges = 0

        func reset() {
            varReads = 0
            publications = 0
            popupChanges = 0
        }
    }

    private static let chord = "Control+Option+S"
    private static let varKey = "audit.mode"
    private static let value = "writing"
    private static let widget = "control-audit"
    private static let trigger = "refresh"
    private let fixture: ScriptARCFixture
    private let kind: Kind
    private let manager: WorkspaceBarManager
    private let host: ShellWidgetHost
    private let state: ShellWidgetHost.WidgetState
    private let barKey: ShellBarKey
    private let popupScreen: NSScreen?
    private let counts: Counts

    private var scriptRoute: String {
        "shell/" + kind.rawValue
    }

    private var nativeRoute: String {
        "native/shell-" + kind.rawValue
    }

    init(in directory: URL, kind: Kind) throws {
        self.kind = kind
        let root = directory.appendingPathComponent("shell-control-" + kind.rawValue)
        let fixture = try ScriptARCFixture(directory: root, snapshotRows: 1)
        self.fixture = fixture
        let controller = fixture.controller
        let manager = controller.workspaceBarManager
        self.manager = manager
        manager.controller = controller
        let monitor = controller.workspaceManager.interactionMonitorId ?? .fallback
        let barKey = ShellBarKey(monitor: monitor)
        self.barKey = barKey
        let popupScreen = kind == .togglePopup ? NSScreen.screens.first : nil
        if kind == .togglePopup, popupScreen == nil {
            throw ScriptARCError("Shell popup audit needs a WindowServer screen for its unpublished panel")
        }
        self.popupScreen = popupScreen
        let counts = Counts()
        self.counts = counts
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        let resourceStore = ShellResourceStore(directory: root.appendingPathComponent("resources"))
        let host = ShellWidgetHost(
            configDirectory: root, resources: resources, resourceStore: resourceStore,
            world: { ShellWorldData() },
            vars: { [weak manager] in
                counts.varReads += 1
                return manager?.shellVars ?? [:]
            },
            bars: { [:] }, onLayoutChange: {}, onCommand: { _, _ in },
            onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: { counts.popupChanges += 1 }, onTitleDemandChange: { _ in }
        )
        self.host = host
        host.feed = ShellDataFeed { [weak host] data in
            counts.publications += 1
            host?.broadcast(data)
        }
        state = Self.makeWidget(at: root, host: host, kind: kind, barKey: barKey)
        host.publishDemand()
        manager.shellHost = host
    }

    private static func makeWidget(
        at root: URL, host: ShellWidgetHost, kind: Kind, barKey: ShellBarKey
    ) -> ShellWidgetHost.WidgetState {
        let state = ShellWidgetHost.WidgetState(name: widget, sourceURL: root.appendingPathComponent("init.luau"))
        state.package = ShellWidgetPackage(
            name: widget, generation: state.generation, outbox: ShellWidgetOutbox { _ in },
            store: ShellStore(directoryURL: root.appendingPathComponent("store")),
            latestData: host.latestData, resourceStore: host.resourceStore
        )
        state.declaration.hasPopout = true
        state.declaration.hasTrigger = kind != .triggerRefused
        state.backgroundDemand = ShellDataKey.vars.bit
        state.instances[barKey] = ShellWidgetHost.InstanceState()
        host.bars[barKey] = ShellBarData()
        host.widgets[widget] = state
        return state
    }

    func close() {
        state.mailbox?.finish()
        state.mailbox = nil
        host.closePopout(animated: false)
        manager.shellHost = nil
        fixture.script.stop()
    }

    private func prepare() -> AsyncStream<ShellWidgetMessage> {
        state.mailbox?.finish()
        state.mailbox = nil
        host.closePopout(animated: false)
        manager.shellVars = kind == .setEqual ? [Self.varKey: Self.value] : [:]
        host.feed?.setVars(manager.shellVars)
        if let screen = popupScreen {
            let popup = ShellPopout(
                widget: Self.widget, key: barKey,
                anchor: ShellAnchor(frame: screen.visibleFrame, level: .statusBar), screen: screen,
                resources: host.resources, directories: [], tracksDismissal: false, onDismiss: {}
            )
            precondition(!popup.panel.isVisible && !popup.panel.isKeyWindow)
            host.popout = popup
        }
        counts.reset()
        let (messages, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
        state.mailbox = mailbox
        return messages
    }

    private func checkWork(
        _ messages: AsyncStream<ShellWidgetMessage>, route: String, report: Bool
    ) async {
        let set = kind == .setChanged || kind == .setEqual
        let expectedVars = set ? [Self.varKey: Self.value] : [:]
        precondition(manager.shellVars == expectedVars && host.feed?.current.vars == expectedVars)
        let expectedPublications = kind == .setChanged ? 1 : 0
        precondition(
            counts.varReads == expectedPublications && counts.publications == expectedPublications,
            "\(route): reads \(counts.varReads), publications \(counts.publications)"
        )
        precondition(counts.popupChanges == (kind == .togglePopup ? 1 : 0))
        precondition(host.popout == nil)
        let handoffs = await countHandoffs(messages)
        if report {
            print(
                "shell-control-work \(route) var-reads=\(counts.varReads) publications=\(counts.publications) "
                    + "popup-changes=\(counts.popupChanges) handoffs=\(handoffs)"
            )
        }
    }

    private func countHandoffs(_ messages: AsyncStream<ShellWidgetMessage>) async -> Int {
        state.mailbox?.finish()
        state.mailbox = nil
        var count = 0
        for await message in messages {
            switch (kind, message) {
            case (.setChanged, .dataChanged): break
            case let (.togglePopup, .popout(key, false, _)): precondition(key == barKey)
            case let (.triggerAccepted, .trigger(name, value)): precondition(name == Self.trigger && value == nil)
            default: preconditionFailure("Unexpected Shell work for \(kind.rawValue)")
            }
            count += 1
        }
        let expectsHandoff = kind == .setChanged || kind == .togglePopup || kind == .triggerAccepted
        precondition(count == (expectsHandoff ? 1 : 0))
        return count
    }

    private var request: ShellRuntimeRequest? {
        switch kind {
        case .absent: nil
        case .setChanged,
             .setEqual: .set(key: Self.varKey, value: Self.value)
        case .unsetMissing: .unset(key: Self.varKey)
        case .togglePopup: .toggle(widget: Self.widget)
        case .triggerAccepted,
             .triggerRefused: .trigger(widget: Self.widget, name: Self.trigger, value: nil)
        }
    }

    private var statement: String {
        guard let request else { return "" }
        let args = switch request {
        case let .set(key, value): "\"set\", \"\(key)\", \"\(value)\""
        case let .unset(key): "\"unset\", \"\(key)\""
        case let .toggle(widget): "\"toggle\", \"\(widget)\""
        case let .trigger(widget, name, _): "\"trigger\", \"\(widget)\", \"\(name)\""
        }
        return "omniwm.dispatch(\"shell\", \(args))"
    }

    func measureScript() async throws {
        let queue = try await fixture.acceptTitleScript("""
        omniwm.keymap.set("\(Self.chord)", function()
            \(statement)
        end)
        """)
        await queue.waitForAuditPark()
        let command = try fixture.binding(Self.chord)
        for report in kind == .triggerRefused ? [true] : [false, true] {
            let messages = prepare()
            precondition(fixture.key(command, measured: true) == .executed)
            try await fixture.measureWorker(seed: false)
            if kind == .triggerRefused {
                precondition(fixture.script.diagnostic?
                    .contains("shell trigger: the widget has no available trigger.") == true)
            } else if let diagnostic = fixture.script.diagnostic {
                throw ScriptARCError(diagnostic)
            }
            if report { script_arc_report(scriptRoute, kind == .absent ? "settings/key" : nativeRoute, 1) }
            await checkWork(messages, route: scriptRoute, report: report)
        }
    }

    func measureNative() async {
        guard let request else { return }
        let controller = fixture.controller
        for report in [false, true] {
            let messages = prepare()
            script_arc_begin()
            let result: ExternalCommandResult = if case let .toggle(widget) = request {
                controller.commandHandler.performCommand(.shellToggle(widget))
            } else {
                manager.applyShellRuntimeRequest(request)
            }
            script_arc_end()
            switch kind {
            case .triggerRefused: precondition(result == .notFound)
            case .unsetMissing: precondition(result == .noChange)
            default: precondition(result == .executed)
            }
            if report { script_arc_report(nativeRoute, "native", 0) }
            await checkWork(messages, route: nativeRoute, report: report)
        }
    }
}
