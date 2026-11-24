// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ConfigScriptNativeEvent: Sendable {
    enum ID: Sendable {
        case none
        case window(WindowToken, ConfigScriptSession, UInt64)
        case capturedWindow(WindowToken, UInt64)
        case workspace(UUID)
        case monitor(Monitor.ID)
    }

    enum Edge: Sendable {
        case minimized(Bool)
        case fullscreen(Bool)
        case floating(Bool)
        case workspace(id: UUID?, name: String?, previousId: UUID? = nil, previousName: String? = nil)
        case monitor(id: Monitor.ID?, name: String?, previousId: Monitor.ID? = nil, previousName: String? = nil)
        case geometry(
            frame: CGRect?,
            previousFrame: CGRect? = nil,
            visibleFrame: CGRect?,
            previousVisibleFrame: CGRect? = nil
        )

        var encoded: ConfigScriptEventPayload.Edge {
            switch self {
            case let .minimized(value): .minimized(value)
            case let .fullscreen(value): .fullscreen(value)
            case let .floating(value): .floating(value)
            case let .workspace(id, name, previous, previousName):
                .workspace(id: id?.uuidString, name: name, previousId: previous?.uuidString, previousName: previousName)
            case let .monitor(id, name, previous, previousName):
                .monitor(
                    id: id?.scriptIdentifier,
                    name: name,
                    previousId: previous?.scriptIdentifier,
                    previousName: previousName
                )
            case let .geometry(frame, previous, visible, previousVisible):
                .geometry(
                    frame: frame,
                    previousFrame: previous,
                    visibleFrame: visible,
                    previousVisibleFrame: previousVisible
                )
            }
        }
    }

    var id: ID = .none
    var name: String?
    var bundleId: String?
    var edge: Edge?

    var windowToken: WindowToken? {
        switch id {
        case let .window(token, _, _),
             let .capturedWindow(token, _): token
        default: nil
        }
    }

    mutating func attachCapturedSession(_ session: @autoclosure () -> ConfigScriptSession) {
        if case let .capturedWindow(token, epoch) = id {
            id = .window(token, session(), epoch)
        }
    }

    func payload(windowID: String? = nil) -> ConfigScriptEventPayload {
        let text: String? = switch id {
        case .capturedWindow: preconditionFailure("Window edge needs its trigger capture")
        case .none: nil
        case let .workspace(id): id.uuidString
        case let .monitor(id): id.scriptIdentifier
        case let .window(token, session, _): windowID ?? ConfigScriptWindowID.string(token, session: session)
        }
        return .init(id: text, name: name, bundleId: bundleId, edge: edge?.encoded)
    }
}
