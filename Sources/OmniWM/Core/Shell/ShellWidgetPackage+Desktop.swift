// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

struct ShellDesktopSubmission: Sendable {
    let request: ShellDesktopRequest
    let component: String?
    let origin: ShellDesktopOrigin?
}

extension ShellDesktopRequest {
    init(id: ShellServiceID, bytes: [UInt8]) throws {
        guard let fields = try ShellServiceValue.decode(bytes, byteLimit: (1 << 20) + 128, nodeLimit: 40).fields,
              let operation = fields["op"]?.string else { throw ShellResourceFailure("invalid_request") }
        guard bytes.count <= 8192 || (operation == "clipboardCopy" && fields["text"] != nil) else {
            throw ShellResourceFailure("invalid_request")
        }
        var anchor: ShellDesktopAnchorLocator?
        let action: Action
        if operation == "clipboardRead", fields.count == 1 {
            action = .clipboardRead
        } else if operation == "clipboardCopy", fields.count == 2 {
            if let text = fields["text"]?.string, text.utf8.count <= 1 << 20 { action = .clipboardText(text) }
            else { action = .clipboardCopy(try Self.resource(fields["resource"])) }
        } else if operation == "pick", fields.count == 2, let multiple = fields["multiple"]?.boolean {
            action = .pick(multiple: multiple)
        } else if operation == "open", fields.count == 2, let value = fields["url"]?.string,
                  let url = URL(string: value), !url.isFileURL, url.scheme != nil
        {
            action = .openURL(url)
        } else if operation == "open" || operation == "reveal", fields.count == 2 {
            let resource = try Self.resource(fields["resource"])
            action = operation == "open" ? .open(resource) : .reveal(resource)
        } else if operation == "quicklook" || operation == "share" {
            action = try Self.groupAction(operation, fields: fields, anchor: &anchor)
        } else { throw ShellResourceFailure("invalid_request") }
        self.init(id: id, action: action, anchor: anchor)
    }

    private static func groupAction(
        _ operation: String,
        fields: [String: ShellServiceValue],
        anchor: inout ShellDesktopAnchorLocator?
    ) throws -> Action {
        guard let values = fields["resources"]?.values, !values.isEmpty, values.count <= 32 else {
            throw ShellResourceFailure("invalid_resources")
        }
        let resources = try values.map { try Self.resource($0) }
        guard Set(resources).count == resources.count else { throw ShellResourceFailure("duplicate_resource") }
        if operation == "quicklook" {
            guard fields.count == 3, let value = fields["index"]?.number, value.isFinite,
                  value >= 1, value <= Double(resources.count), value.rounded(.towardZero) == value
            else {
                throw ShellResourceFailure("invalid_preview")
            }
            return .quicklook(resources, index: Int(value))
        } else {
            let service = fields["service"]?.string
            guard fields.count == (fields["service"] == nil ? 3 : 4),
                  fields["service"] == nil || service == "airdrop",
                  case let .bytes(value) = fields["anchor"] else { throw ShellResourceFailure("invalid_request") }
            anchor = try ShellDesktopAnchorLocator(bytes: value)
            return .share(resources, service: service)
        }
    }

    private static func resource(_ value: ShellServiceValue?) throws -> ShellResourceID {
        guard case let .bytes(bytes) = value, bytes.count == 16 else { throw ShellResourceFailure("invalid_resource") }
        return ShellResourceID(bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) })
    }
}

extension ShellWidgetPackage {
    func permitsFiles(_ owner: ShellServiceOwner, component: String?) -> Bool {
        permitsDesktopCapability(owner, component: component, capability: \.files)
    }

    func permitsClipboard(_ owner: ShellServiceOwner, component: String?) -> Bool {
        permitsDesktopCapability(owner, component: component, capability: \.clipboard)
    }

    private func permitsDesktopCapability(
        _ owner: ShellServiceOwner,
        component: String?,
        capability: KeyPath<ShellComponentCapabilities, Bool>
    ) -> Bool {
        guard owner.generation == services.generation else { return false }
        if owner.owner == 0 { return true }
        guard componentConfigurationValid, let component,
              let instance = configuredComponents[component], instance.enabled,
              let descriptor = componentDescriptors.first(where: { $0.widget == instance.widget }) else { return false }
        return descriptor.capabilities[keyPath: capability] || instance.capabilities?[keyPath: capability] == true
    }

    func enqueueDesktop(
        _ id: ShellServiceID,
        component: String?,
        origin: ShellDesktopOrigin?,
        value: [UInt8],
        in script: ShellScript
    ) {
        guard services.register(id, cancel: { [outbox, name, generation] in
            outbox.cancelDesktop(name: name, generation: generation, id: id)
        }) else {
            _ = omni_vm_cancel_service(script.vm, id.owner.wire, id.request)
            log(1) { _ in "desktop request was rejected by its native owner" }
            return
        }
        let component = component?.isEmpty == false ? component : nil
        do {
            let request = try ShellDesktopRequest(id: id, bytes: value)
            switch request.action {
            case .clipboardCopy:
                guard permitsFiles(id.owner, component: component) else { throw ShellResourceFailure("files_denied") }
                fallthrough
            case .clipboardText,
                 .clipboardRead:
                guard permitsClipboard(id.owner, component: component)
                else { throw ShellResourceFailure("clipboard_denied") }
            default:
                guard permitsFiles(id.owner, component: component) else { throw ShellResourceFailure("files_denied") }
            }
            try bindResources(id.owner, component: component)
            outbox.desktop(
                name: name,
                generation: generation,
                request: ShellDesktopSubmission(request: request, component: component, origin: origin)
            )
        } catch {
            services.complete(ShellServiceCompletion(
                id: id,
                payload: ShellDesktopResult(error: String(describing: error)).payload
            ))
        }
    }
}
