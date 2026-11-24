// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

enum ConfigScriptInvocationInput {
    case timer
    case context(ConfigScriptContext)
    case event(ConfigScriptEventPayload, missed: UInt64)

    func withTrigger<R>(snapshot: ConfigScriptSnapshot? = nil, _ body: (omni_config_trigger) -> R) -> R {
        guard let snapshot else { return withTrigger(bytes: omni_config_span(), body) }
        return snapshot.withUnsafeBytes { bytes in
            withTrigger(
                bytes: omni_config_span(data: bytes.bindMemory(to: CChar.self).baseAddress, length: bytes.count),
                body
            )
        }
    }

    private func withTrigger<R>(bytes: omni_config_span, _ body: (omni_config_trigger) -> R) -> R {
        switch self {
        case .timer:
            var trigger = omni_config_trigger()
            trigger.snapshot = bytes
            return body(trigger)
        case let .context(context):
            return withSpans(context.windowId, context.bundleId, context.workspace, context.layout) {
                body(omni_config_trigger(id: $0, bundle_id: $1, name: $2, layout: $3, edge: nil, snapshot: bytes))
            }
        case let .event(payload, missed):
            return withSpans(payload.id, payload.bundleId, payload.name, nil) { id, bundle, name, layout in
                guard let edge = payload.edge else {
                    return body(omni_config_trigger(
                        id: id,
                        bundle_id: bundle,
                        name: name,
                        layout: layout,
                        edge: nil,
                        snapshot: bytes
                    ))
                }
                return edge.withFields(missed: missed) { fields in
                    withUnsafePointer(to: fields) { pointer in
                        body(omni_config_trigger(
                            id: id,
                            bundle_id: bundle,
                            name: name,
                            layout: layout,
                            edge: pointer,
                            snapshot: bytes
                        ))
                    }
                }
            }
        }
    }
}

private func withSpans<R>(
    _ first: String?, _ second: String?, _ third: String?, _ fourth: String?,
    _ body: (omni_config_span, omni_config_span, omni_config_span, omni_config_span) -> R
) -> R {
    withSpan(first) { first in
        withSpan(second) { second in
            withSpan(third) { third in
                withSpan(fourth) { fourth in body(first, second, third, fourth) }
            }
        }
    }
}

private func withSpan<R>(_ string: String?, _ body: (omni_config_span) -> R) -> R {
    guard let string else { return body(omni_config_span()) }
    let count = string.utf8.count
    return string.withCString { body(omni_config_span(data: $0, length: count)) }
}

extension ConfigScriptEventPayload.Edge {
    fileprivate func withFields<R>(missed: UInt64, _ body: (omni_config_edge) -> R) -> R {
        var value = omni_config_edge()
        value.missed = missed
        switch self {
        case let .title(title):
            value.kind = OMNI_WINDOW_TITLE
            return withSpan(title) {
                value.name = $0
                return body(value)
            }
        case let .minimized(flag):
            value.kind = OMNI_WINDOW_MINIMIZED
            value.flag = flag
            return body(value)
        case let .fullscreen(flag):
            value.kind = OMNI_WINDOW_FULLSCREEN
            value.flag = flag
            return body(value)
        case let .floating(flag):
            value.kind = OMNI_WINDOW_FLOATING
            value.flag = flag
            return body(value)
        case let .geometry(frame, previousFrame, visibleFrame, previousVisibleFrame):
            value.kind = OMNI_EDGE_GEOMETRY
            value.frame = Self.rect(frame)
            value.previous_frame = Self.rect(previousFrame)
            value.visible_frame = Self.rect(visibleFrame)
            value.previous_visible_frame = Self.rect(previousVisibleFrame)
            return body(value)
        case let .workspace(id, name, previousId, previousName),
             let .monitor(id, name, previousId, previousName):
            if case .workspace = self { value.kind = OMNI_EDGE_WORKSPACE } else { value.kind = OMNI_EDGE_MONITOR }
            return withSpans(id, name, previousId, previousName) {
                value.id = $0
                value.name = $1
                value.previous_id = $2
                value.previous_name = $3
                return body(value)
            }
        }
    }

    private static func rect(_ rect: CGRect?) -> omni_config_rect {
        guard let rect else { return omni_config_rect() }
        return omni_config_rect(
            x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height, present: true
        )
    }
}
