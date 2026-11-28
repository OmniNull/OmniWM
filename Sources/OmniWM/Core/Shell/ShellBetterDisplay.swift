// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

struct ShellBetterDisplay: Equatable, Sendable, ShellValueWritable {
    var running = false
    var displays: [ShellBrightness.Display] = []
    var nightShift = ShellNightShift()

    var available: Bool {
        nightShift.available || displays.contains(where: \.available)
    }

    func write(into writer: inout ShellValueWriter) {
        writer.map(4)
        writer.key("running")
        writer.bool(running)
        writer.key("available")
        writer.bool(available)
        writer.key("displays")
        ShellBrightness.write(displays, into: &writer)
        writer.key("nightShift")
        nightShift.write(into: &writer)
    }
}

enum ShellBetterDisplayCommand: Equatable, Sendable {
    case brightness(id: UUID, percent: Double)
    case nightShift(ShellNightShiftCommand)
    case menu

    init?(words: [String]) {
        if words == ["menu"] {
            self = .menu
        } else if words.first == "night-shift", let command = ShellNightShiftCommand(words: Array(words.dropFirst())) {
            self = .nightShift(command)
        } else {
            guard words.count == 4, words[0] == "brightness", words[2] == "set",
                  let id = UUID(uuidString: words[1]), let percent = Double(words[3]),
                  percent.isFinite, (0 ... 100).contains(percent) else { return nil }
            self = .brightness(id: id, percent: percent)
        }
    }
}

@MainActor
final class ShellBetterDisplayMonitor: ShellDeviceSource {
    typealias ObserveApplications = (@escaping @MainActor @Sendable () -> Void) -> () -> Void

    private(set) var value: ShellBetterDisplay?
    var onChange: ((ShellBetterDisplay?) -> Void)?
    var onBrightnessSupportLoss: (() -> Void)?
    var onNightShiftSupportLoss: (() -> Void)?
    private let client: ShellBetterDisplayClient
    private let monitors: () -> [Monitor]
    private let center: NotificationCenter
    private let observeApplications: ObserveApplications
    private var stopObserving: (() -> Void)?
    private var screenObserver: NSObjectProtocol?
    private var pid: pid_t?
    // Retain previous ownership across subscriptions so the first fallback reads current native values.
    private var managedBrightnessIDs: Set<String> = []
    private var managedNightShift = false
    private(set) var sample: Task<Void, Never>?
    private var commands: Task<Void, Never>?
    private var pending: [(pid: pid_t, command: ShellBetterDisplayCommand)] = []

    init(
        client: ShellBetterDisplayClient = .live,
        monitors: @escaping () -> [Monitor] = Monitor.current,
        center: NotificationCenter = .default,
        observeApplications: @escaping ObserveApplications = { changed in
            let observation = NSWorkspace.shared.observe(\.runningApplications) { _, _ in
                Task { @MainActor in changed() }
            }
            return { observation.invalidate() }
        }
    ) {
        self.client = client
        self.monitors = monitors
        self.center = center
        self.observeApplications = observeApplications
    }

    isolated deinit {
        stopObserving?()
        if let screenObserver { center.removeObserver(screenObserver) }
        sample?.cancel()
        commands?.cancel()
    }

    func setListening(_ listening: Bool) {
        guard listening != (stopObserving != nil) else { return }
        if listening {
            stopObserving = observeApplications { [weak self] in self?.updatePresence() }
            screenObserver = center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            updatePresence()
        } else {
            stopObserving?()
            stopObserving = nil
            if let screenObserver { center.removeObserver(screenObserver) }
            screenObserver = nil
            sample?.cancel()
            sample = nil
            pid = nil
            value = nil
        }
    }

    private func updatePresence() {
        guard stopObserving != nil else { return }
        let current = client.runningPID()
        guard value == nil || current != pid else { return }
        pid = current
        publish(ShellBetterDisplay(running: current != nil))
        refresh()
    }

    private func connectedDisplays() -> [(id: UUID, name: String)] {
        Monitor.discardingAmbiguousDisplayUUIDs(in: monitors()).compactMap { monitor in
            guard monitor.displayId != 0,
                  let id = monitor.displayUUID.flatMap(UUID.init(uuidString:)) else { return nil }
            return (id, monitor.name)
        }
    }

    private func refresh() {
        sample?.cancel()
        guard stopObserving != nil, let pid, commands == nil else { return }
        sample = Task { [weak self, client] in
            while !Task.isCancelled {
                guard let displays = self?.connectedDisplays() else { return }
                async let levels = client.brightness(displays.map(\.id))
                async let nightShift = client.nightShift()
                let snapshot = await Self.snapshot(displays, levels: levels, nightShift: nightShift)
                guard !Task.isCancelled else { return }
                guard client.runningPID() == pid else {
                    self?.updatePresence()
                    return
                }
                self?.publish(snapshot)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private static func snapshot(
        _ displays: [(id: UUID, name: String)], levels: [UUID: ShellBetterDisplayClient.Level], nightShift: Bool?
    ) -> ShellBetterDisplay {
        ShellBetterDisplay(
            running: true,
            displays: displays.compactMap { id, name in
                guard let connected = levels[id] else { return nil }
                let level = connected.value.flatMap { (0 ... 1).contains($0) ? $0 : nil }
                return ShellBrightness.Display(
                    id: id.uuidString,
                    name: name,
                    value: (level ?? 0) * 100,
                    available: level != nil
                )
            },
            nightShift: ShellNightShift(available: nightShift != nil, enabled: nightShift ?? false)
        )
    }

    private func publish(_ next: ShellBetterDisplay) {
        guard value != next else { return }
        let available = Set(next.displays.filter(\.available).map(\.id))
        let lostBrightnessSupport = !managedBrightnessIDs.isSubset(of: available)
        let lostNightShiftSupport = managedNightShift && !next.nightShift.available
        managedBrightnessIDs = available
        managedNightShift = next.nightShift.available
        value = next
        if lostBrightnessSupport { onBrightnessSupportLoss?() }
        if lostNightShiftSupport { onNightShiftSupportLoss?() }
        onChange?(next)
    }

    @discardableResult
    func perform(_ command: ShellBetterDisplayCommand) -> Task<Void, Never>? {
        guard let current = client.runningPID(), stopObserving == nil || current == pid else {
            updatePresence()
            return nil
        }
        guard supports(command) else { return nil }
        pending.append((current, command))
        if let commands { return commands }
        sample?.cancel()
        commands = Task { [weak self] in
            guard let self else { return }
            while !pending.isEmpty {
                let (target, command) = pending.removeFirst()
                guard client.runningPID() == target else { continue }
                let succeeded = await execute(command, pid: target)
                if !succeeded { Log.shell.debug("BetterDisplay command was unavailable") }
            }
            commands = nil
            if pid == client.runningPID() { refresh() }
            else { updatePresence() }
        }
        return commands
    }

    private func supports(_ command: ShellBetterDisplayCommand) -> Bool {
        switch command {
        case let .brightness(id, percent):
            return percent.isFinite && (0 ... 100).contains(percent) && connectedDisplays().contains { $0.id == id }
                && (value?.displays.contains { $0.id == id.uuidString && $0.available } ?? true)
        case .nightShift: return value?.nightShift.available ?? true
        case .menu: return true
        }
    }

    private func execute(_ command: ShellBetterDisplayCommand, pid: pid_t) async -> Bool {
        switch command {
        case let .brightness(id, percent):
            guard connectedDisplays().contains(where: { $0.id == id }) else { return false }
            return await client.setBrightness(pid, id, percent / 100)
        case let .nightShift(command): return await client.setNightShift(pid, command == .on)
        case .menu: return await client.openMenu(pid)
        }
    }
}
