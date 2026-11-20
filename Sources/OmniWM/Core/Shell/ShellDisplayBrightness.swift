// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
import Darwin

struct ShellBrightness: Equatable, Sendable, ShellValueWritable {
    struct Display: Equatable, Sendable {
        let id: String
        let name: String
        let value: Double
        let available: Bool
    }

    var value = 0.0
    var available = false
    var mainDisplayId: String?
    var displays: [Display] = []

    func write(into writer: inout ShellValueWriter) {
        writer.map(4)
        writer.key("value")
        writer.number(value)
        writer.key("available")
        writer.bool(available)
        writer.key("mainDisplayId")
        if let mainDisplayId { writer.string(mainDisplayId) }
        else { writer.null() }
        writer.key("displays")
        writer.array(displays.count)
        for display in displays {
            writer.map(4)
            writer.key("id")
            writer.string(display.id)
            writer.key("name")
            writer.string(display.name)
            writer.key("value")
            writer.number(display.value)
            writer.key("available")
            writer.bool(display.available)
        }
    }
}

enum ShellBrightnessCommand: Equatable, Sendable {
    case set(percent: Double)
    case change(percent: Double)
    case setDisplay(id: UUID, percent: Double)

    init?(words: [String]) {
        switch words {
        case ["up"]: self = .change(percent: 6.25)
        case ["down"]: self = .change(percent: -6.25)
        case let words where words.count == 2 && words[0] == "set":
            guard let percent = Self.parsePercent(words[1]) else { return nil }
            self = .set(percent: percent)
        case let words where words.count == 4 && words[0] == "display" && words[2] == "set":
            guard let id = UUID(uuidString: words[1]), let percent = Self.parsePercent(words[3]) else { return nil }
            self = .setDisplay(id: id, percent: percent)
        default: return nil
        }
    }

    private static func parsePercent(_ text: String) -> Double? {
        guard let percent = Double(text), percent.isFinite, (0 ... 100).contains(percent) else { return nil }
        return percent
    }
}

@MainActor
struct ShellBrightnessAccess {
    var display: () -> CGDirectDisplayID
    var read: (CGDirectDisplayID) -> Double?
    var set: ((CGDirectDisplayID, Double) -> Bool)?
    var monitors: () -> [Monitor] = { [] }

    static let live = ShellBrightnessAccess(
        display: CGMainDisplayID,
        read: { display in
            guard let read = DisplayServicesBrightness.read, DisplayServicesBrightness.set != nil else { return nil }
            var value = Float.nan
            guard read(display, &value) == 0 else { return nil }
            return Double(value)
        },
        set: { display, value in
            guard let set = DisplayServicesBrightness.set else { return false }
            let status = set(display, Float(value))
            if status != 0 { Log.shell.error("Setting display brightness failed with status \(status)") }
            return status == 0
        },
        monitors: Monitor.current
    )

    func connectedDisplays() -> [Monitor] {
        Monitor.discardingAmbiguousDisplayUUIDs(in: monitors()).filter { $0.displayId != 0 }
    }

    func snapshot(for display: CGDirectDisplayID) -> ShellBrightness {
        guard display != 0, set != nil, let value = read(display), value.isFinite, (0 ... 1).contains(value) else {
            return .init()
        }
        return ShellBrightness(value: value * 100, available: true)
    }
}

@MainActor
private enum DisplayServicesBrightness {
    typealias Read = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    static let read: Read? = symbol("DisplayServicesGetBrightness", as: Read.self)
    static let set: Set? = symbol("DisplayServicesSetBrightness", as: Set.self)
    private static let library = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL
    )

    private static func symbol<Function>(_ name: String, as: Function.Type) -> Function? {
        guard let library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: Function.self)
    }
}

@MainActor
final class ShellDisplayBrightness: ShellDeviceSource {
    private(set) var value: ShellBrightness?
    var onChange: ((ShellBrightness?) -> Void)?
    private let access: ShellBrightnessAccess
    private let notificationCenter: NotificationCenter
    private var displayObserver: NSObjectProtocol?
    private var listening = false

    init(access: ShellBrightnessAccess = .live, notificationCenter: NotificationCenter = .default) {
        self.access = access
        self.notificationCenter = notificationCenter
    }

    isolated deinit {
        removeDisplayObserver()
    }

    func setListening(_ listening: Bool) {
        guard self.listening != listening else { return }
        self.listening = listening
        if listening {
            displayObserver = notificationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            refresh()
        } else {
            removeDisplayObserver()
            value = nil
        }
    }

    @discardableResult
    func perform(_ command: ShellBrightnessCommand) -> Bool {
        let display: CGDirectDisplayID
        switch command {
        case let .setDisplay(id, _):
            guard let monitor = access.connectedDisplays().first(where: { $0.displayUUID == id.uuidString }) else {
                return false
            }
            display = monitor.displayId
        case .set,
             .change:
            display = access.display()
        }
        let current = access.snapshot(for: display)
        guard current.available, let set = access.set else { return false }
        let percent: Double
        switch command {
        case let .set(value),
             let .setDisplay(_, value):
            guard value.isFinite, (0 ... 100).contains(value) else { return false }
            percent = value
        case let .change(delta):
            guard delta.isFinite else { return false }
            percent = min(100, max(0, current.value + delta))
        }
        let succeeded = set(display, percent / 100)
        refresh()
        return succeeded
    }

    private func refresh() {
        guard listening else { return }
        let mainId = access.display()
        let main = access.snapshot(for: mainId)
        let displays = access.connectedDisplays()
        var value = main
        value.mainDisplayId = displays.first(where: { $0.displayId == mainId })?.displayUUID
        value.displays = displays.compactMap { monitor in
            guard let id = monitor.displayUUID else { return nil }
            let brightness = monitor.displayId == mainId ? main : access.snapshot(for: monitor.displayId)
            return ShellBrightness.Display(
                id: id,
                name: monitor.name,
                value: brightness.value,
                available: brightness.available
            )
        }
        guard value != self.value else { return }
        self.value = value
        onChange?(value)
    }

    private func removeDisplayObserver() {
        guard let displayObserver else { return }
        notificationCenter.removeObserver(displayObserver)
        self.displayObserver = nil
    }
}
