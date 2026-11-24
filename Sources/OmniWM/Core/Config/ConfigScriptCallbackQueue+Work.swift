// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension ConfigScriptCallbackQueue {
    static func combined(
        _ current: ConfigScriptListenerMask?,
        _ additional: ConfigScriptListenerMask
    ) -> ConfigScriptListenerMask {
        guard var current else { return additional }
        current.formUnion(additional)
        return current
    }

    static func windowKey(
        _ kind: ConfigScriptEventKind, _ argument: borrowing ConfigScriptNativeEvent
    ) -> WindowStateKey? {
        guard case let .window(token, _, epoch) = argument.id else { return nil }
        return .window(kind, token, epoch)
    }

    enum WindowStateKey: Hashable {
        case window(ConfigScriptEventKind, WindowToken, UInt64)
    }

    struct Listener {
        let function: Int
        let index: Int
    }

    struct Declaration {
        let fullQueueDiagnostic: String
        let reads: ConfigScriptReads
    }

    struct EventReads {
        var all: ConfigScriptReads = []
        var readers: [(function: Int, reads: ConfigScriptReads)] = []

        func demand(excluding functions: ConfigScriptListenerMask) -> ConfigScriptReads {
            if functions.isEmpty { return all }
            var demand: ConfigScriptReads = []
            for reader in readers where !functions.contains(reader.function) { demand.formUnion(reader.reads) }
            return demand
        }
    }

    enum Trigger {
        case function(Int, ConfigScriptCapture)
        case title(ConfigScriptWindowTitle)
        case causedTitle(ConfigScriptWindowTitle, excluding: ConfigScriptListenerMask)
        case event(
            ConfigScriptEventKind,
            ConfigScriptNativeEvent,
            excluding: ConfigScriptListenerMask?,
            capture: ConfigScriptCapture?
        )
    }

    struct Work {
        var trigger: Trigger
        var missed: UInt64 = 0
    }

    struct InFlight {
        var capture: ConfigScriptCapture?
        var event: ConfigScriptQueuedEvent?
        var missed: UInt64 = 0
        var excluded: ConfigScriptListenerMask?
        var listenerIndex = 0
        var listeners: ArraySlice<Listener>?

        mutating func nextEventArgument() -> ConfigScriptQueuedEvent? {
            if listeners?.isEmpty == false { return event }
            return event.take()
        }
    }
}
