// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellProviderConfiguration: Equatable, Sendable {
    let widget: String
    let instance: String
    let folder: URL
    let command: [String]
    let options: Data
    let authorized: Bool
}

struct ShellProviderLifecycle {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case closingInput
        case stopping
        case draining
        case terminal
    }

    enum Effect: Equatable {
        case launch(ShellProviderIdentity, ShellProviderConfiguration)
        case running(ShellProviderIdentity)
        case closeInput(ShellProviderIdentity)
        case terminate(ShellProviderIdentity)
        case armKill(ShellProviderIdentity)
        case cancelKill(ShellProviderIdentity)
        case kill(ShellProviderIdentity)
        case ended(ShellProviderIdentity, ShellProviderInbox.Status)
    }

    let owner: ShellServiceOwner
    private(set) var identity: ShellProviderIdentity?
    private(set) var phase = Phase.idle
    private(set) var configuration: ShellProviderConfiguration?
    private var replacement: ShellProviderConfiguration?
    private var exitStatus: ShellProviderInbox.Status?
    private var nextIncarnation: UInt64 = 1
    private var closing = false

    var acceptsActions: Bool {
        !closing && (phase == .starting || phase == .running)
    }

    var isClosed: Bool {
        closing && (phase == .idle || phase == .terminal)
    }

    mutating func reconcile(_ next: ShellProviderConfiguration?) -> [Effect] {
        guard !closing else { return [] }
        switch phase {
        case .idle,
             .terminal:
            if next == nil { configuration = nil
                return []
            }
            guard let next, next != configuration else { return [] }
            return launch(next)
        case .starting,
             .running:
            guard next != configuration else { return [] }
            if next == nil { configuration = nil }
            replacement = next
            return stop()
        case .closingInput,
             .stopping,
             .draining:
            if next == nil { configuration = nil }
            replacement = next
            return []
        }
    }

    mutating func launched(_ expected: ShellProviderIdentity) -> [Effect] {
        guard identity == expected, phase == .starting else { return [] }
        phase = .running
        return [.running(expected)]
    }

    mutating func launchFailed(_ expected: ShellProviderIdentity, message: String) -> [Effect] {
        guard identity == expected, phase == .starting else { return [] }
        phase = .terminal
        exitStatus = .failed(String(message.prefix(1024)))
        return [.ended(expected, exitStatus!)]
    }

    mutating func failed(_ expected: ShellProviderIdentity, message: String) -> [Effect] {
        guard identity == expected, phase != .terminal, phase != .idle else { return [] }
        let status = ShellProviderInbox.Status.failed(String(message.prefix(1024)))
        exitStatus = status
        return [.ended(expected, status)] + stop()
    }

    mutating func outputClosed(_ expected: ShellProviderIdentity) -> [Effect] {
        guard identity == expected else { return [] }
        return stop()
    }

    mutating func inputClosed(_ expected: ShellProviderIdentity) -> [Effect] {
        guard identity == expected, phase == .closingInput else { return [] }
        phase = .stopping
        return [.terminate(expected), .armKill(expected)]
    }

    mutating func exited(_ expected: ShellProviderIdentity, code: Int32) -> [Effect] {
        guard identity == expected,
              phase == .running || phase == .closingInput || phase == .stopping || phase == .starting else { return [] }
        phase = .draining
        if exitStatus == nil { exitStatus = .exited(code) }
        return [.closeInput(expected), .cancelKill(expected)]
    }

    mutating func drained(_ expected: ShellProviderIdentity) -> [Effect] {
        guard identity == expected, phase == .draining else { return [] }
        phase = .terminal
        var effects: [Effect] = [.ended(expected, exitStatus ?? .exited(0))]
        if !closing, let next = replacement {
            replacement = nil
            effects += launch(next)
        }
        return effects
    }

    mutating func killDeadline(_ expected: ShellProviderIdentity) -> [Effect] {
        guard identity == expected, phase == .stopping else { return [] }
        return [.kill(expected)]
    }

    mutating func close() -> [Effect] {
        closing = true
        replacement = nil
        return stop()
    }

    private mutating func stop() -> [Effect] {
        guard let identity, phase == .running || phase == .starting else { return [] }
        phase = .closingInput
        return [.closeInput(identity)]
    }

    private mutating func launch(_ next: ShellProviderConfiguration) -> [Effect] {
        guard nextIncarnation != .max else { return [] }
        let nextIdentity = ShellProviderIdentity(owner: owner, incarnation: nextIncarnation)
        nextIncarnation += 1
        identity = nextIdentity
        configuration = next
        exitStatus = nil
        phase = .starting
        return [.launch(nextIdentity, next)]
    }
}
