// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

extension ShellHTTPRequest {
    init(bytes: [UInt8]) throws {
        guard let fields = try ShellServiceValue.decode(bytes, byteLimit: (4 << 20) + (128 << 10)).fields,
              let url = fields["url"]?.string,
              fields.keys
                  .allSatisfy({
                      ["url", "method", "headers", "body", "bodyResource", "response", "maxBytes", "timeout"]
                          .contains($0)
                  })
        else { throw ShellHTTPFailure("invalid_request") }
        self.init(url: url)
        if let value = fields["method"] {
            guard let method = value.string else { throw ShellHTTPFailure("invalid_request") }
            self.method = method
        }
        try decodeHeaders(fields["headers"])
        try decodeBody(fields)
        try decodeResponseOptions(fields)
    }

    private mutating func decodeHeaders(_ value: ShellServiceValue?) throws {
        if let value {
            guard let fields = value.fields, fields.count <= 128 else { throw ShellHTTPFailure("invalid_request") }
            for (key, value) in fields {
                guard let value = value.string else { throw ShellHTTPFailure("invalid_request") }
                headers[key] = value
            }
        }
    }

    private mutating func decodeBody(_ fields: [String: ShellServiceValue]) throws {
        if let value = fields["body"] {
            guard case let .bytes(bytes) = value else { throw ShellHTTPFailure("invalid_request") }
            body = bytes
        }
        if let value = fields["bodyResource"] {
            guard body == nil, case let .bytes(bytes) = value,
                  bytes.count == 16 else { throw ShellHTTPFailure("invalid_request") }
            bodyResource = ShellResourceID(bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) })
        }
    }

    private mutating func decodeResponseOptions(_ fields: [String: ShellServiceValue]) throws {
        if let value = fields["response"] {
            guard let name = value.string,
                  let response = Response(rawValue: name) else { throw ShellHTTPFailure("invalid_request") }
            self.response = response
        }
        if let value = fields["maxBytes"] {
            guard let number = value.number, number >= 1, number <= Double(ShellHTTPService.byteLimit),
                  number.rounded(.towardZero) == number
            else { throw ShellHTTPFailure("invalid_request") }
            maxBytes = Int(number)
        }
        if let value = fields["timeout"] {
            guard let number = value.number, number > 0,
                  number <= ShellHTTPService.timeoutLimit else { throw ShellHTTPFailure("invalid_request") }
            timeout = number
        }
    }
}

extension ShellWidgetPackage {
    func dispatchHTTP(_ id: ShellServiceID, component: String?, value: [UInt8], in script: ShellScript) {
        do {
            guard id.owner.owner == 0 || componentConfigurationValid
            else { throw ShellHTTPFailure("configuration_failed") }
            let request = try ShellHTTPRequest(bytes: value)
            let policy: ShellHTTPPolicy
            if id.owner.owner == 0 { policy = .hosts(rootNetwork) }
            else if let component, !component.isEmpty {
                policy = .resolve(
                    component: component,
                    instances: configuredComponents.values,
                    descriptors: componentDescriptors
                )
            } else { policy = .hosts([]) }
            if request.bodyResource != nil {
                try dispatchHTTPBody(id, component: component, request: request, policy: policy, in: script)
                return
            }
            if http == nil { http = ShellHTTPService(ledger: services, captureID: utilityCaptureID) }
            guard http?.start(id, request: request, policy: policy) == true else {
                _ = omni_vm_cancel_service(script.vm, id.owner.wire, id.request)
                log(1) { _ in "HTTP request was rejected by its native owner" }
                return
            }
        } catch {
            guard services.register(id) else {
                _ = omni_vm_cancel_service(script.vm, id.owner.wire, id.request)
                log(1) { _ in "HTTP failure was rejected by its native owner" }
                return
            }
            services.complete(ShellServiceCompletion(
                id: id,
                payload: ShellHTTPResponse.failure((error as? ShellHTTPFailure)?.code ?? "invalid_request")
            ))
        }
    }

    private func dispatchHTTPBody(
        _ id: ShellServiceID,
        component: String?,
        request: ShellHTTPRequest,
        policy: ShellHTTPPolicy,
        in script: ShellScript
    ) throws {
        guard permitsFiles(id.owner, component: component) else { throw ShellHTTPFailure("files_denied") }
        guard let url = URL(string: request.url),
              policy.allows(url) else { throw ShellHTTPFailure("network_denied") }
        guard resourceWork.count + (resourceWorker == nil ? 0 : 1) < ShellServiceLedger.capacity else {
            throw ShellHTTPFailure("resource_work_overloaded")
        }
        let operation = ShellResourceOperation()
        guard services.register(id, cancel: { operation.cancel() }) else {
            _ = omni_vm_cancel_service(script.vm, id.owner.wire, id.request)
            log(1) { _ in "HTTP resource request was rejected by its native owner" }
            return
        }
        resourceWork.append(.httpBody(id, request, policy, operation))
        startResourceWorker()
    }

    func prepareHTTPBody(
        _ id: ShellServiceID,
        request: ShellHTTPRequest,
        policy: ShellHTTPPolicy,
        operation: ShellResourceOperation
    ) async {
        guard !closing, operation.isActive, let resource = request.bodyResource else { return }
        do {
            let bytes = try await resourceStore.httpBody(resource, owner: id.owner, operation: operation)
            guard !closing, operation.isActive else { return }
            var prepared = request
            prepared.bodyResource = nil
            prepared.body = bytes
            if http == nil { http = ShellHTTPService(ledger: services, captureID: utilityCaptureID) }
            _ = http?.start(id, request: prepared, policy: policy, registered: true)
        } catch {
            services.complete(ShellServiceCompletion(id: id, payload: ShellHTTPResponse.failure(
                (error as? ShellHTTPFailure)?.code ?? "resource_unavailable"
            )))
        }
    }
}
