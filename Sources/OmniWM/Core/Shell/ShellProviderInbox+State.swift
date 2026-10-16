// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellProviderInbox {
    struct Slot {
        var value: Data
        var changed: Bool
    }

    struct Entry {
        let identity: ShellProviderIdentity
        let configuration: ShellProviderConfiguration?
        var accepting = true
        var topics: [String: Slot] = [:]
        var deliveredTopics: Set<String> = []
        var byteCount = 0
        var lastConsumption: UInt64?
        var status: Status = .starting
        var statusPending = true
        var terminal = false

        var hasChanges: Bool {
            topics.values.contains { $0.changed } || deliveredTopics.contains { topics[$0] == nil }
        }

        var deadline: UInt64 {
            guard let lastConsumption else { return 0 }
            let result = lastConsumption.addingReportingOverflow(ShellProviderInbox.stateInterval)
            return result.overflow ? .max : result.partialValue
        }
    }

    struct ResourceAction {
        let operation: ShellResourceOperation
        var input: ResourceInput = .preparing
        var delivery: ResourceDelivery = .active
        var utility: ResourceUtility = .none
        var cleanupStarted = false

        var canClean: Bool {
            delivery == .done && input != .submitted && utility == .none && !cleanupStarted
        }
    }

    struct Registered {
        let identity: ShellProviderIdentity
        var queued = false
        var resource: ResourceAction?
    }

    struct Queued {
        let identity: ShellProviderIdentity
        var control: Control
        var preparation: Preparation?

        var runnable: Bool {
            switch preparation {
            case .decoding?,
                 .importing?: false
            default: true
            }
        }
    }

    struct State {
        var entries: [ShellServiceOwner: Entry] = [:]
        var registered: [ShellServiceID: Registered] = [:]
        var controls: [Queued] = []
        var eventCount = 0
        var counters = Counters()
        var wake: (@Sendable () -> Void)?
        var waking = false
        var deadline: UInt64?
        var closed = false
        var capture = Capture()
    }

    enum ResourceInput: Equatable { case preparing, ready(Data), submitted, finished }
    enum ResourceDelivery { case active, consuming, done }
    enum ResourceUtility { case none, decoding, importing }
    enum Preparation { case raw(Data), decoding, decoded(ShellPreparedProviderOutputs), importing }
}
