// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import IOKit.pwr_mgt

enum ShellSessionCommand: String, CaseIterable, Sendable {
    case lock
    case sleep
    case logout
    case restart
    case shutdown

    init?(words: [String]) {
        guard words.count == 1, let command = Self(rawValue: words[0]) else { return nil }
        self = command
    }

    var loginWindowEvent: AEEventID? {
        switch self {
        case .lock,
             .sleep: nil
        case .logout: AEEventID(kAELogOut)
        case .restart: AEEventID(kAEShowRestartDialog)
        case .shutdown: AEEventID(kAEShowShutdownDialog)
        }
    }
}

enum ShellSession {
    private typealias LockScreen = @convention(c) () -> Int32

    private static let lockScreen: LockScreen? = dlopen(
        "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
        RTLD_LAZY
    )
    .flatMap { dlsym($0, "SACLockScreenImmediate") }
    .map { unsafeBitCast($0, to: LockScreen.self) }

    static func perform(_ command: ShellSessionCommand) {
        switch command {
        case .lock:
            guard let lockScreen else {
                return Log.shell.error("Locking the screen is unavailable: SACLockScreenImmediate was not found")
            }
            let status = lockScreen()
            if status != 0 {
                Log.shell.error("Locking the screen failed: \(status)")
            }
        case .sleep:
            let power = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
            defer { IOServiceClose(power) }
            let status = IOPMSleepSystem(power)
            if status != kIOReturnSuccess {
                Log.shell.error("Sleeping failed: \(status)")
            }
        case .logout,
             .restart,
             .shutdown:
            guard let event = command.loginWindowEvent else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                ask(event, for: command)
            }
        }
    }

    private static func ask(_ eventID: AEEventID, for command: ShellSessionCommand) {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow"),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        do {
            try event.sendEvent(options: [.noReply], timeout: TimeInterval(kAEDefaultTimeout))
        } catch {
            Log.shell.error("macOS did not show the \(command.rawValue) confirmation: \(error.localizedDescription)")
        }
    }
}
