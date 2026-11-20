// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import ObjectiveC

struct ShellNightShift: Equatable, Sendable, ShellValueWritable {
    var available = false
    var enabled = false

    func write(into writer: inout ShellValueWriter) {
        writer.map(2)
        writer.key("available")
        writer.bool(available)
        writer.key("enabled")
        writer.bool(enabled)
    }
}

enum ShellNightShiftCommand: String, Sendable {
    case on
    case off

    init?(words: [String]) {
        guard words.count == 1 else { return nil }
        self.init(rawValue: words[0])
    }
}

@MainActor
struct ShellNightShiftAccess {
    var read: () -> Bool?
    var setEnabled: (Bool) -> Bool

    static let live = ShellNightShiftAccess(
        read: { CoreBrightnessNightShift.shared?.enabled() },
        setEnabled: { CoreBrightnessNightShift.shared?.setEnabled($0) ?? false }
    )

    func snapshot() -> ShellNightShift {
        guard let enabled = read() else { return .init() }
        return ShellNightShift(available: true, enabled: enabled)
    }
}

@MainActor
final class ShellNightShiftMonitor: ShellDeviceSource {
    private(set) var value: ShellNightShift?
    var onChange: ((ShellNightShift?) -> Void)?
    private let access: ShellNightShiftAccess
    private var listening = false

    init(access: ShellNightShiftAccess = .live) {
        self.access = access
    }

    func setListening(_ listening: Bool) {
        guard self.listening != listening else { return }
        self.listening = listening
        if listening { publish(access.snapshot()) }
        else { value = nil }
    }

    @discardableResult
    func perform(_ command: ShellNightShiftCommand) -> Bool {
        let current = access.snapshot()
        let enabled = command == .on
        guard current.available, current.enabled != enabled else {
            if listening { publish(current) }
            return current.available
        }
        let succeeded = access.setEnabled(enabled)
        if listening { publish(access.snapshot()) }
        return succeeded
    }

    private func publish(_ value: ShellNightShift) {
        guard value != self.value else { return }
        self.value = value
        onChange?(value)
    }
}

@MainActor
private struct CoreBrightnessNightShift {
    private typealias New = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    private typealias Supports = @convention(c) (AnyClass, Selector) -> Bool
    private typealias Read = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Bool

    private static let library = dlopen(
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
        RTLD_LAZY | RTLD_LOCAL
    )
    private static let supportsSelector = NSSelectorFromString("supportsBlueLightReduction")
    private static let readSelector = NSSelectorFromString("getBlueLightStatus:")
    private static let setSelector = NSSelectorFromString("setEnabled:")
    private static let statusEncoding = "^{?=BBBi{?={?=ii}{?=ii}}QB}"
    private static let statusWordCount = 5
    private static let enabledOffset = 1
    private static let availableOffset = 32

    static let shared: Self? = {
        let newSelector = NSSelectorFromString("new")
        guard library != nil, let clientClass = NSClassFromString("CBBlueLightClient"),
              let allocate = implementation(class_getClassMethod(clientClass, newSelector), returning: "@"),
              let supports = implementation(class_getClassMethod(clientClass, supportsSelector), returning: "B"),
              let read = implementation(
                  class_getInstanceMethod(clientClass, readSelector), returning: "B", argument: statusEncoding
              ),
              let set = implementation(
                  class_getInstanceMethod(clientClass, setSelector), returning: "B", argument: "B"
              ),
              let client = unsafeBitCast(allocate, to: New.self)(clientClass, newSelector)?.takeRetainedValue()
        else { return nil }
        return Self(
            clientClass: clientClass, client: client, supports: unsafeBitCast(supports, to: Supports.self),
            read: unsafeBitCast(read, to: Read.self), set: unsafeBitCast(set, to: Set.self)
        )
    }()

    private let clientClass: AnyClass
    private let client: AnyObject
    private let supports: Supports
    private let read: Read
    private let set: Set

    func enabled() -> Bool? {
        guard supports(clientClass, Self.supportsSelector) else { return nil }
        return withUnsafeTemporaryAllocation(of: UInt64.self, capacity: Self.statusWordCount) { words in
            words.initialize(repeating: 0)
            let bytes = UnsafeMutableRawBufferPointer(words)
            guard let address = bytes.baseAddress, read(client, Self.readSelector, address),
                  bytes[Self.availableOffset] == 1, bytes[Self.enabledOffset] <= 1
            else { return nil }
            return bytes[Self.enabledOffset] == 1
        }
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        set(client, Self.setSelector, enabled)
    }

    private static func implementation(_ method: Method?, returning result: String, argument: String? = nil) -> IMP? {
        guard let method, method_getNumberOfArguments(method) == (argument == nil ? 2 : 3) else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == result else { return nil }
        if let argument {
            guard let argumentType = method_copyArgumentType(method, 2) else { return nil }
            defer { free(argumentType) }
            guard String(cString: argumentType) == argument else { return nil }
        }
        return method_getImplementation(method)
    }
}
