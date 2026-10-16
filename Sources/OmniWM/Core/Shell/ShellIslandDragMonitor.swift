// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellIslandDragMonitor {
    @MainActor
    struct Environment {
        let changeCount: () -> Int
        let types: () -> ShellDropTypes
        let install: (@escaping @Sendable (ShellIslandDragInbox.Event) -> Void) -> [Any]
        let remove: ([Any]) -> Void

        static func system() -> Self {
            let pasteboard = NSPasteboard(name: .drag)
            return Self(
                changeCount: { pasteboard.changeCount },
                types: { ShellDropSnapshot.types(pasteboard) },
                install: { receive in
                    let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseDown, .leftMouseUp, .keyDown]
                    let local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
                        if let input = ShellIslandDragMonitor.input(event) { receive(input) }
                        return event
                    }
                    let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
                        if let input = ShellIslandDragMonitor.input(event) { receive(input) }
                    }
                    return [local, global].compactMap { $0 }
                },
                remove: { monitors in for monitor in monitors { NSEvent.removeMonitor(monitor) } }
            )
        }
    }

    private let environment: Environment
    private let onChange: (ShellIslandDragState) -> Void
    private var reducer = ShellIslandDragReducer(changeCount: 0)
    private var monitors: [Any] = []
    private(set) var inbox: ShellIslandDragInbox?

    var state: ShellIslandDragState {
        reducer.state
    }

    var monitoring: Bool {
        inbox != nil
    }

    init(environment: Environment? = nil, onChange: @escaping (ShellIslandDragState) -> Void) {
        self.environment = environment ?? .system()
        self.onChange = onChange
    }

    func setDemand(_ demanded: Bool) {
        guard demanded != monitoring else { return }
        if !demanded {
            inbox?.close()
            inbox = nil
            environment.remove(monitors)
            monitors.removeAll()
            end()
            return
        }
        reducer.reset(changeCount: environment.changeCount())
        let inbox = ShellIslandDragInbox { [weak self] inbox in
            DispatchQueue.main.async { [weak self] in self?.drain(inbox) }
        }
        self.inbox = inbox
        monitors = environment.install { [inbox] in inbox.post($0) }
        if monitors.count != 2 {
            Log.shell.error("Unable to install both island drag event monitors")
            setDemand(false)
        }
    }

    func end() {
        let old = reducer.state
        reducer.reset(changeCount: environment.changeCount())
        if reducer.state != old { onChange(reducer.state) }
    }

    func drain(_ inbox: ShellIslandDragInbox) {
        guard self.inbox === inbox else { return }
        defer { inbox.finish() }
        guard let batch = inbox.take() else { return }
        let old = reducer.state
        let changeCount = environment.changeCount()
        if batch.ended { reducer.reset(changeCount: changeCount) }
        else if batch.began { reducer.reset(changeCount: batch.dragged ? reducer.changeCount : changeCount) }
        if batch.dragged { reducer.drag(changeCount: changeCount, types: environment.types) }
        if reducer.state != old { onChange(reducer.state) }
    }

    private nonisolated static func input(_ event: NSEvent) -> ShellIslandDragInbox.Event? {
        switch event.type {
        case .leftMouseDragged: .dragged
        case .leftMouseDown: .began
        case .leftMouseUp: .ended
        case .keyDown: event.keyCode == 53 ? .ended : nil
        default: nil
        }
    }
}
