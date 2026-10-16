// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Synchronization

struct ShellEvent: Equatable, Sendable {
    enum Kind: Sendable {
        case click, scroll, slider, press, hover, gesture, key, outsidePress, textChange, textCommit, textCancel,
             textFocus, dropHover
    }

    enum Button: String, Sendable {
        case left, right, middle, none
    }

    enum Phase: String, Sendable {
        case began, changed, ended, cancelled, down, up, cancel, entered, exited
    }

    enum Momentum: String, Sendable {
        case none, began, changed, ended
    }

    var button = Button.left
    var shift = false
    var option = false
    var control = false
    var command = false
    var dx = 0.0
    var dy = 0.0
    var precise = false
    var value: Double?
    var phase: Phase?
    var trace = ShellFrameTrace.current
    var kind = Kind.click
    var x = 0.0
    var y = 0.0
    var clicks = 0
    var vx = 0.0
    var vy = 0.0
    var committed = false
    var momentum = Momentum.none
    var key: String?
    var characters: String?
    var isRepeat = false
    var sourceID: UInt64 = 0
    var invocationID: UInt64?
    var trackingToken: UInt64?
    var dropTypes: UInt8?
    var text: String?
    var focused: Bool?
    var coalescingTarget: UInt64 = 0

    var hasModifiers: Bool {
        shift || option || control || command
    }

    var isGesture: Bool {
        switch kind {
        case .scroll: (phase == nil || phase == .changed) && (momentum == .none || momentum == .changed)
        case .slider,
             .gesture,
             .textChange: phase == .changed
        default: false
        }
    }

    var bytes: [UInt8] {
        var writer = ShellValueWriter()
        writer.map(20 + (text == nil ? 0 : 1) + (focused == nil ? 0 : 1) + (dropTypes == nil ? 0 : 1))
        writer.key("button")
        writer.string(button.rawValue)
        writer.key("shift")
        writer.bool(shift)
        writer.key("option")
        writer.bool(option)
        writer.key("control")
        writer.bool(control)
        writer.key("command")
        writer.bool(command)
        writer.key("dx")
        writer.number(dx)
        writer.key("dy")
        writer.number(dy)
        writer.key("precise")
        writer.bool(precise)
        writer.key("value")
        if let value { writer.number(value) } else { writer.null() }
        writer.key("phase")
        if let phase { writer.string(phase.rawValue) } else { writer.null() }
        writer.key("x")
        writer.number(x)
        writer.key("y")
        writer.number(y)
        writer.key("clicks")
        writer.number(Double(clicks))
        writer.key("vx")
        writer.number(vx)
        writer.key("vy")
        writer.number(vy)
        writer.key("committed")
        writer.bool(committed)
        writer.key("momentum")
        writer.string(momentum.rawValue)
        writer.key("key")
        if let key { writer.string(key) } else { writer.null() }
        writer.key("characters")
        if let characters { writer.string(characters) } else { writer.null() }
        writer.key("repeat")
        writer.bool(isRepeat)
        if let text {
            writer.key("text")
            writer.string(text)
        }
        if let focused {
            writer.key("focused")
            writer.bool(focused)
        }
        if let dropTypes {
            let names = [(UInt8(1), "file"), (2, "url"), (4, "text"), (8, "image")].filter { dropTypes & $0.0 != 0 }
            writer.key("types")
            writer.array(names.count)
            for (_, name) in names { writer.string(name) }
        }
        return writer.bytes
    }
}

final class ShellGestureBox: Sendable {
    struct Gesture: Sendable {
        let bar: ShellBarKey
        let view: ShellWidgetView
        let action: UInt32
        var sequence: Int
        var event: ShellEvent
    }

    final class Pending: Sendable {
        private let value: Mutex<Gesture?>

        init(_ gesture: Gesture) {
            value = Mutex(gesture)
        }

        func merge(_ gesture: Gesture) -> Bool {
            value.withLock { queued in
                guard let previous = queued,
                      previous.bar == gesture.bar, previous.view == gesture.view,
                      previous.event.sourceID == gesture.event.sourceID,
                      previous.event.kind == .textChange || previous.action == gesture.action,
                      previous.event.kind == gesture.event.kind, previous.event.phase == gesture.event.phase,
                      previous.event.momentum == gesture.event.momentum,
                      previous.event.coalescingTarget == gesture.event.coalescingTarget else { return false }
                var next = gesture
                if gesture.event.kind == .scroll {
                    next.event.dx += previous.event.dx
                    next.event.dy += previous.event.dy
                }
                queued = next
                return true
            }
        }

        var isPending: Bool {
            value.withLock { $0 != nil }
        }

        func take() -> Gesture? {
            value.withLock { value in
                defer { value = nil }
                return value
            }
        }
    }

    private struct TextTarget: Hashable {
        let bar: ShellBarKey
        let view: Int
        let field: UInt64
    }

    private struct State {
        var gesture: Pending?
        var text: [TextTarget: Pending] = [:]
    }

    private let pending = Mutex(State())

    func post(_ gesture: Gesture) -> Pending? {
        pending.withLock { pending in
            if gesture.event.kind == .textChange {
                let key = TextTarget(
                    bar: gesture.bar,
                    view: gesture.view.rawValue,
                    field: gesture.event.coalescingTarget
                )
                if pending.text[key]?.merge(gesture) == true { return nil }
                if pending.text[key] == nil { pending.text = pending.text.filter { $0.value.isPending } }
                let next = Pending(gesture)
                pending.text[key] = next
                return next
            }
            if pending.gesture?.merge(gesture) == true { return nil }
            let next = Pending(gesture)
            pending.gesture = next
            return next
        }
    }

    func seal() {
        pending.withLock { $0.gesture = nil
            $0.text.removeAll(keepingCapacity: true)
        }
    }
}

@MainActor
enum ShellInvocation {
    private static var value: UInt64 = 0

    static func next() -> UInt64 {
        value += 1
        return value
    }
}
