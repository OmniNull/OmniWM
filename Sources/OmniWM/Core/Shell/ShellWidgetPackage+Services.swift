// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

extension ShellServiceOwner {
    init(_ token: omni_owner_token) {
        self.init(generation: token.generation, owner: token.owner, epoch: token.epoch)
    }

    var wire: omni_owner_token {
        omni_owner_token(generation: generation, owner: owner, epoch: epoch)
    }
}

extension ShellWidgetPackage {
    func namespace(_ component: String?) -> ShellStoreNamespace {
        ShellStoreNamespace(profile: storeProfile, package: name, instance: component)
    }

    func seedStore(_ component: String?, in script: ShellScript) async {
        let snapshot = await store.load(namespace(component))
        guard !closing, self.script === script else { return }
        let bytes = snapshot.bytes ?? []
        let problem = snapshot.error ?? ""
        let owner = component ?? ""
        let status = bytes.withUnsafeBufferPointer {
            omni_vm_seed_store(
                script.vm, owner, owner.utf8.count, $0.baseAddress, $0.count,
                problem, problem.utf8.count, &errorBuffer, errorBuffer.count
            )
        }
        if status != OMNI_OK {
            let message = lastError()
            _ = omni_vm_seed_store(
                script.vm, owner, owner.utf8.count, nil, 0,
                message, message.utf8.count, &errorBuffer, errorBuffer.count
            )
        }
    }

    func seedComponents(_ source: ShellWidgetSource, in script: ShellScript) async {
        for component in source.components
            where component.enabled && configuredComponents[component.id]?.widget != component.widget
        {
            await seedStore(component.id, in: script)
            guard !closing, self.script === script else { return }
            await seedResources(component.id, in: script)
            guard !closing, self.script === script else { return }
        }
    }

    func drainServices(in script: ShellScript) {
        var request = omni_service_request()
        while omni_vm_next_service(script.vm, &request) {
            let id = ShellServiceID(owner: ShellServiceOwner(request.owner), request: request.id)
            let component = request.owner_name.map {
                String(decoding: UnsafeRawBufferPointer(start: $0, count: request.owner_name_length), as: UTF8.self)
            }
            let value = request.value.map { Array(UnsafeBufferPointer(start: $0, count: request.value_length)) } ?? []
            if request.cancelled { services.cancel(id) }
            switch request.kind {
            case OMNI_SERVICE_TIMER:
                if !request.cancelled, !services.startTimer(id, seconds: request.seconds, queue: queue) {
                    _ = omni_vm_cancel_service(script.vm, request.owner, request.id)
                    log(1) { _ in "timer request was rejected by its native owner" }
                }
            case OMNI_SERVICE_DROP,
                 OMNI_SERVICE_DRAG:
                break
            case OMNI_SERVICE_HTTP:
                if !request.cancelled { dispatchHTTP(id, component: component, value: value, in: script) }
            case OMNI_SERVICE_PROVIDER:
                enqueueProvider(id, component: component, value: value, cancelled: request.cancelled, in: script)
            case OMNI_SERVICE_DESKTOP:
                if !request.cancelled {
                    enqueueDesktop(
                        id,
                        component: component,
                        origin: desktopOrigin(request, in: script),
                        value: value,
                        in: script
                    )
                }
            case OMNI_SERVICE_RESOURCE:
                enqueueResource(id, component: component, value: value, cancelled: request.cancelled, in: script)
            case OMNI_SERVICE_CONFIG:
                enqueueConfiguration(id, value: value, cancelled: request.cancelled, in: script)
            case OMNI_SERVICE_STORE:
                dispatchStore(id, component: component, request: request, value: value, in: script)
            default:
                log(1) { _ in "unknown native service request" }
            }
        }
        flushServiceMessages(in: script)
    }

    private func dispatchStore(
        _ id: ShellServiceID,
        component: String?,
        request: omni_service_request,
        value: [UInt8],
        in script: ShellScript
    ) {
        let namespace = namespace(component?.isEmpty == false ? component : nil)
        storeOwners[namespace] = id.owner
        let write = ShellStore.Write(namespace: namespace, id: id, revision: request.revision, bytes: value)
        if request.cancelled {
            if resourceOwners.contains(id.owner) { finalResourceStores[namespace] = write }
            else { store.submit(write, final: true) { _ in } }
        } else if services.register(id) {
            store.submit(write) { [services] commit in
                var writer = ShellValueWriter()
                writer.map(commit.error == nil ? 1 : 2)
                writer.key("ok")
                writer.bool(commit.error == nil)
                if let error = commit.error {
                    writer.key("error")
                    writer.string(error)
                }
                services.complete(ShellServiceCompletion(
                    id: commit.id,
                    revision: commit.revision,
                    payload: writer.bytes
                ))
            }
        } else {
            _ = omni_vm_cancel_service(script.vm, request.owner, request.id)
            log(1) { _ in "store request was rejected by its native owner" }
        }
    }

    func deliverServices(in script: ShellScript) async {
        var changed = false
        for (key, instance) in script.instances { hydrate(key, instance) }
        let completions = services.takeBatch()
        for (index, completion) in completions.enumerated() {
            guard !closing, self.script === script else {
                for pending in completions[index...] { pending.discardUndelivered() }
                break
            }
            if completion.resource != nil { resourceRestores.removeValue(forKey: completion.id) }
            var handled = false
            var resourcesTransferred = false
            let status = completeService(
                completion, in: script, handled: &handled, resourcesTransferred: &resourcesTransferred
            )
            if completion.desktopResources != nil ? !resourcesTransferred : !handled { completion.discardUndelivered() }
            if status == OMNI_ERR_COMPONENT {
                log(1) { _ in lastError() }
            } else if status != OMNI_OK {
                fail(status)
            }
            changed = changed || handled
            drainServices(in: script)
            await Task.yield()
        }
        if changed, !closing, self.script === script {
            for (key, instance) in script.instances { await renderVisible(key, instance) }
        }
        _ = services.finishBatch()
    }

    private func completeService(
        _ completion: ShellServiceCompletion,
        in script: ShellScript,
        handled: inout Bool,
        resourcesTransferred: inout Bool
    ) -> omni_status {
        return completion.payload.withUnsafeBufferPointer { payload in
            if let resource = completion.resource {
                let problem = resource.error ?? ""
                return omni_vm_complete_resource(
                    script.vm, completion.id.owner.wire, completion.id.request, resource.error == nil,
                    resource.revision, resource.size ?? 0, resource.size != nil, problem, problem.utf8.count,
                    Self.handlerBudget, &handled, &errorBuffer, errorBuffer.count
                )
            }
            if let resources = completion.desktopResources {
                let ids = resources.map { omni_resource_id(bytes: $0.value.uuid) }
                return ids.withUnsafeBufferPointer {
                    omni_vm_complete_desktop(
                        script.vm, completion.id.owner.wire, completion.id.request,
                        payload.baseAddress, payload.count, $0.baseAddress, $0.count,
                        Self.handlerBudget, &handled, &resourcesTransferred, &errorBuffer, errorBuffer.count
                    )
                }
            }
            return omni_vm_complete_service(
                script.vm, completion.id.owner.wire, completion.id.request, completion.revision,
                payload.baseAddress, payload.count, Self.handlerBudget, &handled, &errorBuffer, errorBuffer.count
            )
        }
    }

    private func flushServiceMessages(in script: ShellScript) {
        let message = { (kind: omni_message_kind, index: Int) -> String in
            var count = 0
            guard let text = omni_vm_message(script.vm, kind, index, &count) else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: text, count: count), as: UTF8.self)
        }
        let logs = omni_vm_message_count(script.vm, OMNI_MESSAGE_LOG)
        if logs > 0 { log(logs) { message(OMNI_MESSAGE_LOG, $0) } }
        var requests: [ShellWidgetScriptRequest] = []
        for index in 0 ..< omni_vm_message_count(script.vm, OMNI_MESSAGE_REQUEST) {
            var owner = omni_owner_token()
            var display: UInt32 = .max
            guard omni_vm_message_origin(script.vm, OMNI_MESSAGE_REQUEST, index, &owner, &display) else { continue }
            let bar = script.instances.first { omni_instance_display_id($0.value) == display }?.key
            requests.append(ShellWidgetScriptRequest(
                bar: bar, text: message(OMNI_MESSAGE_REQUEST, index), owner: ShellServiceOwner(owner)
            ))
        }
        omni_vm_clear_messages(script.vm)
        if !requests.isEmpty { outbox.request(name: name, generation: generation, requests: requests) }
    }
}
