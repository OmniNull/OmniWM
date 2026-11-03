// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

struct ShellWindowRequest: Sendable {
    enum Operation: String, Sendable {
        case open
        case close
    }

    let id: ShellServiceID
    let rootID: UUID
    let sourceID: UInt64
    let operation: Operation
    let childID: String

    init(id: ShellServiceID, origin: ShellDesktopOrigin?, bytes: [UInt8]) throws {
        guard let origin, case let .window(rootID) = origin.key.instance,
              origin.key.view == .window, origin.sourceID != 0,
              let fields = try ShellServiceValue.decode(bytes).fields,
              let value = fields["op"]?.string, let operation = Operation(rawValue: value),
              let childID = fields["id"]?.string, !childID.isEmpty
        else {
            throw ShellServiceValue.Failure()
        }
        self.id = id
        self.rootID = rootID
        sourceID = origin.sourceID
        self.operation = operation
        self.childID = childID
    }

    static func completion(id: ShellServiceID, error: String? = nil) -> ShellServiceCompletion {
        var writer = ShellValueWriter()
        writer.map(error == nil ? 1 : 2)
        writer.key("ok")
        writer.bool(error == nil)
        if let error {
            writer.key("error")
            writer.string(error)
        }
        return ShellServiceCompletion(id: id, payload: writer.bytes)
    }
}

extension ShellWidgetPackage {
    func enqueueWindow(
        _ id: ShellServiceID,
        origin: ShellDesktopOrigin?,
        value: [UInt8],
        in script: ShellScript
    ) {
        guard services.register(id, cancel: { [outbox, name, generation] in
            outbox.cancelWindow(name: name, generation: generation, id: id)
        }) else {
            _ = omni_vm_cancel_service(script.vm, id.owner.wire, id.request)
            return
        }
        do {
            outbox.window(
                name: name,
                generation: generation,
                request: try ShellWindowRequest(id: id, origin: origin, bytes: value)
            )
        } catch {
            services.complete(ShellWindowRequest.completion(id: id, error: "invalid_window_request"))
        }
    }
}
