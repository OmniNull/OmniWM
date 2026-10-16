// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMShellCore

struct ShellDropAuthority: Equatable, Sendable {
    let handle: ElementHandle
    let sequence: Int
    let action: UInt32
    let accepts: UInt8
    let sourceID: UInt64

    init(handle: ElementHandle, sequence: Int, action: UInt32, accepts: UInt8, sourceID: UInt64 = 0) {
        self.handle = handle
        self.sequence = sequence
        self.action = action
        self.accepts = accepts
        self.sourceID = sourceID
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.handle == rhs.handle && lhs.action == rhs.action && lhs.accepts == rhs.accepts && lhs.sourceID == rhs
            .sourceID
    }
}

struct ShellDropReservation: Equatable, Sendable {
    let id: ShellServiceID
    let authority: ShellDropAuthority
    let component: String?
    let operation: ShellResourceOperation

    init(
        id: ShellServiceID,
        authority: ShellDropAuthority,
        component: String? = nil,
        operation: ShellResourceOperation = ShellResourceOperation()
    ) {
        self.id = id
        self.authority = authority
        self.component = component
        self.operation = operation
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.authority == rhs.authority && lhs.component == rhs.component && lhs.operation === rhs
            .operation
    }
}

struct ShellDropBridge: Sendable {
    let reserve: @Sendable (ShellDropAuthority) async -> Result<ShellDropReservation, ShellResourceFailure>
    let finish: @Sendable (ShellDropReservation) -> Void
}

@MainActor
final class ShellDropPreflight {
    private let bridge: ShellDropBridge
    private let declined: @MainActor (String) -> Void
    private var request = UUID()
    private(set) var authority: ShellDropAuthority?
    private(set) var reservation: ShellDropReservation?
    private(set) var preparation: Task<Void, Never>?

    init(bridge: ShellDropBridge, declined: @escaping @MainActor (String) -> Void = { _ in }) {
        self.bridge = bridge
        self.declined = declined
    }

    isolated deinit {
        if let reservation { bridge.finish(reservation) }
    }

    func update(_ authority: ShellDropAuthority?) {
        guard self.authority != authority else { return }
        clear()
        guard let authority else { return }
        self.authority = authority
        let request = request
        let bridge = bridge
        preparation = Task { [weak self] in
            let result = await bridge.reserve(authority)
            guard let self, self.request == request, self.authority == authority else {
                if case let .success(reservation) = result { bridge.finish(reservation) }
                return
            }
            switch result {
            case let .success(reservation):
                guard reservation.authority == authority else {
                    bridge.finish(reservation)
                    declined("drop reservation authority changed")
                    return
                }
                self.reservation = reservation
            case let .failure(error): declined(String(error.description.prefix(1024)))
            }
        }
    }

    func take(_ authority: ShellDropAuthority) -> ShellDropReservation? {
        guard self.authority == authority, let reservation else { return nil }
        self.reservation = nil
        self.authority = nil
        request = UUID()
        return reservation
    }

    func clear() {
        preparation = nil
        request = UUID()
        authority = nil
        if let reservation { bridge.finish(reservation) }
        reservation = nil
    }
}
