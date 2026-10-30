// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Darwin

struct ShellBrightness: Equatable, Sendable, ShellValueWritable {
    var value = 0.0
    var available = false

    func write(into writer: inout ShellValueWriter) {
        writer.map(2)
        writer.key("value")
        writer.number(value)
        writer.key("available")
        writer.bool(available)
    }
}

enum ShellBrightnessCommand: Equatable, Sendable {
    case set(percent: Double)
    case change(percent: Double)

    init?(words: [String]) {
        switch words {
        case ["up"]: self = .change(percent: 6.25)
        case ["down"]: self = .change(percent: -6.25)
        case let words where words.count == 2 && words[0] == "set":
            guard let percent = Double(words[1]), percent.isFinite, (0 ... 100).contains(percent) else { return nil }
            self = .set(percent: percent)
        default: return nil
        }
    }
}

@MainActor
struct ShellBrightnessAccess {
    var display: () -> CGDirectDisplayID
    var read: (CGDirectDisplayID) -> Double?
    var set: ((CGDirectDisplayID, Double) -> Bool)?

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
        }
    )

    func snapshot(for display: CGDirectDisplayID) -> ShellBrightness {
        guard set != nil, let value = read(display), value.isFinite, (0 ... 1).contains(value) else { return .init() }
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
    private var listening = false

    init(access: ShellBrightnessAccess = .live) {
        self.access = access
    }

    func setListening(_ listening: Bool) {
        guard self.listening != listening else { return }
        self.listening = listening
        if listening { publish(access.snapshot(for: access.display())) }
        else { value = nil }
    }

    @discardableResult
    func perform(_ command: ShellBrightnessCommand) -> Bool {
        let display = access.display()
        let current = access.snapshot(for: display)
        guard current.available, let set = access.set else { return false }
        let percent: Double
        switch command {
        case let .set(value):
            guard value.isFinite, (0 ... 100).contains(value) else { return false }
            percent = value
        case let .change(delta):
            guard delta.isFinite else { return false }
            percent = min(100, max(0, current.value + delta))
        }
        let succeeded = set(display, percent / 100)
        if listening { publish(access.snapshot(for: display)) }
        return succeeded
    }

    private func publish(_ value: ShellBrightness) {
        guard value != self.value else { return }
        self.value = value
        onChange?(value)
    }
}
