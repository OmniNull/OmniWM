// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Dispatch
import Foundation
import OmniWMScriptHost

struct ConfigScriptBinding: Equatable, Sendable {
    let rawChord: String
    var chord: KeyBinding
    let command: HotkeyCommand
    let commandText: String
    let line: Int
    var source = "init.luau"
    var modeKey: KeyBinding?
    var mode: Int?
    var modeName: String?
    var reads: ConfigScriptReads = []
}

struct ConfigScriptNamedMode: Equatable, Sendable {
    let id: Int
    let name: String
    let source: String
    let line: Int
}

struct ConfigScriptRule: Equatable, Sendable {
    let rule: AppRule
    let source: String
    let line: Int
}

struct ConfigScriptNamedCommand: Equatable, Sendable {
    let name: String
    let function: Int
    let source: String
    let line: Int
    var reads: ConfigScriptReads = []
}

enum ConfigScriptEventKind: String, CaseIterable, Sendable {
    case workspaceActive = "workspace.active"
    case windowActive = "window.active"
    case monitorFocused = "monitor.focused"
    case keybindsSubmap = "keybinds.submap"
    case configReloaded = "config.reloaded"
    case windowOpen = "window.open"
    case windowClose = "window.close"
    case windowMoveToWorkspace = "window.move_to_workspace"
    case workspaceCreated = "workspace.created"
    case workspaceRemoved = "workspace.removed"
    case workspaceMoveToMonitor = "workspace.move_to_monitor"
    case monitorAdded = "monitor.added"
    case monitorRemoved = "monitor.removed"
    case monitorLayoutChanged = "monitor.layout_changed"
    case windowTitle = "window.title"
    case windowMinimize = "window.minimize"
    case windowFullscreen = "window.fullscreen"
    case windowUpdateState = "window.update_state"

    enum Delivery {
        case latest, edge, latestPerWindow
    }

    var delivery: Delivery {
        switch self {
        case .workspaceActive,
             .windowActive,
             .monitorFocused,
             .keybindsSubmap,
             .configReloaded: .latest
        case .windowTitle,
             .windowMinimize,
             .windowFullscreen,
             .windowUpdateState: .latestPerWindow
        default: .edge
        }
    }
}

struct ConfigScriptEventListener: Equatable, Sendable {
    let kind: ConfigScriptEventKind
    let function: Int
    let source: String
    let line: Int
    var reads: ConfigScriptReads = []
}

struct ConfigScriptEventPayload: Equatable, Sendable {
    enum Edge: Equatable, Sendable {
        case title(String)
        case minimized(Bool)
        case fullscreen(Bool)
        case floating(Bool)
        case workspace(id: String?, name: String?, previousId: String? = nil, previousName: String? = nil)
        case monitor(id: String?, name: String?, previousId: String? = nil, previousName: String? = nil)
        case geometry(
            frame: CGRect?,
            previousFrame: CGRect? = nil,
            visibleFrame: CGRect? = nil,
            previousVisibleFrame: CGRect? = nil
        )
    }

    let id: String?
    let name: String?
    let bundleId: String?
    let edge: Edge?

    init(id: String? = nil, name: String? = nil, bundleId: String? = nil, edge: Edge? = nil) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
        self.edge = edge
    }
}

struct ConfigScriptEvaluation: Sendable {
    let bindings: [ConfigScriptBinding]
    let peakBytes: Int
    let rules: [ConfigScriptRule]
    let namedCommands: [ConfigScriptNamedCommand]
    var namedModes: [ConfigScriptNamedMode] = []
    var events: [ConfigScriptEventListener] = []
    var timers: [ConfigScriptTimer] = []
    let moduleReads: Int
    let moduleExecutions: Int
    let generation: ConfigScriptGeneration?
}

struct ConfigScriptError: LocalizedError, Equatable {
    let line: Int?
    let message: String
    var source = "init.luau"

    var errorDescription: String? {
        message
    }
}

actor ConfigScriptLoader {
    static let sourceLimit = Int(OMNI_CONFIG_BYTE_LIMIT)
    static let heapLimit = 32 << 20
    static let cpuBudget: UInt64 = 100_000_000

    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.config.luau", qos: .userInitiated)
    nonisolated let store: ConfigScriptStore

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(store: ConfigScriptStore = ConfigScriptStore()) {
        self.store = store
    }

    nonisolated func makeGeneration() -> ConfigScriptGeneration {
        ConfigScriptGeneration(queue: queue, store: store)
    }

    nonisolated func evaluate(_ source: Data, hyperMask: UInt32) async throws -> ConfigScriptEvaluation {
        try await makeGeneration().evaluate(source, hyperMask: hyperMask)
    }

    nonisolated func load(fileURL: URL, hyperMask: UInt32) async -> ConfigScriptLoad {
        await makeGeneration().load(fileURL: fileURL, hyperMask: hyperMask)
    }
}
