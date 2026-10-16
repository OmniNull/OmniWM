// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

struct ShellResourceCompletion: Sendable {
    let revision: UInt64
    let size: UInt64?
    let error: String?

    init(revision: UInt64 = 0, size: UInt64? = nil, error: String? = nil) {
        self.revision = revision
        self.size = size
        self.error = error.map { RuntimeTraceLimits.boundedString(
            $0.replacingOccurrences(of: "\0", with: " "),
            maxBytes: 1024
        ) }
    }
}

extension ShellWidgetPackage {
    enum ResourceWork: Sendable {
        case httpBody(ShellServiceID, ShellHTTPRequest, ShellHTTPPolicy, ShellResourceOperation)
        case provider(ProviderResourceWork)
        case persist(ShellResourceToken)
        case restore(ShellServiceID, ShellResourceID, ShellResourceToken)
        case barrier(CheckedContinuation<Void, Never>)
    }

    func seedResources(_ component: String?, in script: ShellScript, validateOnly: Bool = false) async {
        let namespace = namespace(component)
        let snapshot: ShellResourceStore.PreparedTokens
        if let active = resourceStore.catalog.preparedTokens(namespace) {
            snapshot = active
        } else {
            snapshot = await resourceStore.prepare(namespace)
        }
        guard !closing, self.script === script else { return }
        if !validateOnly { preparedResources[namespace] = snapshot }
        let status = seedResourceTokens(snapshot, component: component, in: script)
        if status != OMNI_OK {
            let owner = component ?? ""
            let problem = Self.resourceError(lastError())
            if !validateOnly { preparedResources[namespace] = ShellResourceStore.PreparedTokens(
                namespace: namespace,
                tokens: [:],
                error: problem
            ) }
            _ = omni_vm_seed_resource_tokens(
                script.vm,
                owner,
                owner.utf8.count,
                nil,
                0,
                problem,
                problem.utf8.count,
                &errorBuffer,
                errorBuffer.count
            )
        }
    }

    private func seedResourceTokens(
        _ snapshot: ShellResourceStore.PreparedTokens,
        component: String?,
        in script: ShellScript
    ) -> omni_status {
        let entries = Array(snapshot.tokens)
        let descriptors = entries
            .map { ShellPickedResource(name: $0.value.name, kind: $0.value.kind, uti: $0.value.uti) }
        let owner = component ?? ""
        let problem = Self.resourceError(snapshot.error)
        return Self.withResourceDescriptors(descriptors) { descriptors in
            let tokens = entries.enumerated().map { index, entry in
                omni_resource_token_descriptor(
                    token: omni_resource_id(bytes: entry.key.value.uuid),
                    descriptor: descriptors[index]
                )
            }
            return tokens.withUnsafeBufferPointer {
                omni_vm_seed_resource_tokens(
                    script.vm,
                    owner,
                    owner.utf8.count,
                    $0.baseAddress,
                    $0.count,
                    problem,
                    problem.utf8.count,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
        }
    }

    func bindResources(_ owner: ShellServiceOwner, component: String?) throws {
        let namespace = namespace(component?.isEmpty == false ? component : nil)
        guard owner.generation == services.generation else { throw ShellResourceFailure("resource owner is stale") }
        if resourceOwners.contains(owner) {
            guard resourceStore.catalog.isActive(owner), resourceStore.catalog.namespace(owner) == namespace else {
                throw ShellResourceFailure("resource owner is inactive")
            }
            return
        }
        guard let prepared = preparedResources[namespace]
        else { throw ShellResourceFailure("resource namespace is not prepared") }
        try resourceStore.bind(owner, prepared: prepared)
        preparedResources.removeValue(forKey: namespace)
        resourceOwners.insert(owner)
        resourceInbox.attach(owner)
        resourceStore.catalog.attach(owner, changed: { [resourceInbox] owner in
            resourceInbox.changed(owner)
        }, persistence: { [services] result in
            services.complete(ShellServiceCompletion(
                id: result.id,
                payload: [],
                resource: ShellResourceCompletion(error: result.error)
            ))
        })
    }

    func enqueueResource(
        _ id: ShellServiceID,
        component: String?,
        value: [UInt8],
        cancelled: Bool,
        in script: ShellScript
    ) {
        if cancelled, value.isEmpty {
            if let resource = resourceRestores.removeValue(forKey: id) { resourceStore.catalog.remove(
                [resource],
                owner: id.owner
            ) }
            return
        }
        if !cancelled, !services.register(id) {
            _ = omni_vm_cancel_service(script.vm, id.owner.wire, id.request)
            log(1) { _ in "resource request was rejected by its native owner" }
            return
        }
        do {
            guard let fields = try ShellServiceValue.decode(value, byteLimit: 256, nodeLimit: 8).fields,
                  fields.count == 3, let operation = fields["op"]?.string,
                  let resourceUUID = Self.resourceUUID(fields["resource"]),
                  let tokenUUID = Self.resourceUUID(fields["token"]),
                  operation == "persist" || operation == "restore", !cancelled || operation == "persist"
            else { throw ShellResourceFailure("invalid_resource_request") }
            guard resourceWork.count + (resourceWorker == nil ? 0 : 1) < ShellServiceLedger.capacity else {
                throw ShellResourceFailure("resource_work_overloaded")
            }
            try bindResources(id.owner, component: component)
            let resource = ShellResourceID(resourceUUID)
            let token = ShellResourceToken(tokenUUID)
            if operation == "persist" {
                try resourceStore.catalog.admitPersistence(resource, id: id, token: token)
                resourceWork.append(.persist(token))
            } else {
                guard let descriptor = resourceStore.catalog.restoringDescriptor(token, id: resource, owner: id.owner)
                else {
                    throw ShellResourceFailure("unknown_resource_token")
                }
                try resourceStore.catalog.admit([descriptor], owner: id.owner)
                resourceRestores[id] = resource
                resourceWork.append(.restore(id, resource, token))
            }
            startResourceWorker()
        } catch {
            if cancelled { log(1) { _ in "resources: \(error)" } }
            else { services.complete(ShellServiceCompletion(
                id: id,
                payload: [],
                resource: ShellResourceCompletion(error: String(describing: error))
            )) }
        }
    }

    func startResourceWorker() {
        guard resourceWorker == nil else { return }
        resourceWorker = Task {
            while !resourceWork.isEmpty {
                switch resourceWork.removeFirst() {
                case let .httpBody(id, request, policy, operation):
                    await prepareHTTPBody(id, request: request, policy: policy, operation: operation)
                case let .provider(work): await performProviderResource(work)
                case let .persist(token):
                    _ = await resourceStore.persist(token)
                case let .restore(id, resource, token):
                    var failure: String?
                    do { try await resourceStore.restore(token, id: resource, owner: id.owner) }
                    catch { failure = String(describing: error) }
                    let metadata = resourceStore.catalog.metadata(resource, owner: id.owner)
                    let result = ShellResourceCompletion(
                        revision: metadata?.revision ?? 0,
                        size: metadata?.size,
                        error: failure ?? metadata?.error
                    )
                    if !services.complete(ShellServiceCompletion(id: id, payload: [], resource: result)) {
                        await resourceStore.release([resource], owner: id.owner)
                        resourceRestores.removeValue(forKey: id)
                    }
                case let .barrier(completion): completion.resume()
                }
            }
            resourceWorker = nil
        }
    }

    func resourceBarrier() async {
        guard resourceWorker != nil || !resourceWork.isEmpty else { return }
        await withCheckedContinuation { completion in
            resourceWork.append(.barrier(completion))
            startResourceWorker()
        }
    }

    func retireResources(components: Set<String>? = nil) async {
        let owners = resourceOwners.filter { owner in
            guard let components else { return true }
            return resourceStore.catalog.namespace(owner, includingInactive: true)?.instance
                .map(components.contains) == true
        }
        preparedResources = preparedResources.filter { namespace, _ in
            guard let components else { return false }
            return namespace.instance.map { !components.contains($0) } ?? true
        }
        for owner in owners {
            resourceStore.catalog.deactivate(owner)
            resourceStore.catalog.detach(owner)
            resourceInbox.detach(owner)
        }
        for owner in owners { await retireResourceImages(owner) }
        await resourceBarrier()
        for owner in owners {
            for failure in await resourceStore.retire(owner) {
                if let error = failure.error { log(1) { _ in "resources: \(error)" } }
            }
            resourceOwners.remove(owner)
            resourceRestores = resourceRestores.filter { $0.key.owner != owner }
        }
        let writes = finalResourceStores.filter { namespace, _ in
            components.map { names in namespace.instance.map(names.contains) == true } ?? true
        }
        for (namespace, write) in writes {
            finalResourceStores.removeValue(forKey: namespace)
            store.submit(write, final: true) { _ in }
        }
    }

    func deliverResources(in script: ShellScript) async {
        var changed = false
        for owner in resourceInbox.take() {
            guard !closing, self.script === script else { return }
            let metadata = resourceStore.catalog.metadata(owner: owner).filter { $0.revision != 0 }
            changed = applyResourceMetadata(metadata, owner: owner, in: script) || changed
        }
        if changed {
            for (key, instance) in script.instances {
                guard !closing, self.script === script else { return }
                await renderVisible(key, instance)
            }
        }
    }

    func applyResourceMetadata(
        _ metadata: [ShellResourceMetadata],
        owner: ShellServiceOwner,
        in script: ShellScript
    ) -> Bool {
        var changed = false
        for offset in stride(from: 0, to: metadata.count, by: ShellResourceStore.attachmentLimit) {
            let batch = Array(metadata[offset ..< min(offset + ShellResourceStore.attachmentLimit, metadata.count)])
            var errors: [CChar] = []
            let spans = batch.map { value -> (Int, Int) in
                let start = errors.count
                errors.append(contentsOf: Self.resourceError(value.error).utf8.map { CChar(bitPattern: $0) })
                return (start, errors.count - start)
            }
            var applied = false
            let status = errors.withUnsafeBufferPointer { errors in
                let updates = batch.enumerated().map { index, value in
                    let state: omni_resource_state = switch value.state {
                    case .pending: OMNI_RESOURCE_PENDING
                    case .ready: OMNI_RESOURCE_READY
                    case .failed: OMNI_RESOURCE_FAILED
                    }
                    return omni_resource_update(
                        id: omni_resource_id(bytes: value.descriptor.id.value.uuid),
                        revision: value.revision,
                        state: state,
                        size: value.size ?? 0,
                        has_size: value.size != nil,
                        error: errors.baseAddress?.advanced(by: spans[index].0),
                        error_length: spans[index].1
                    )
                }
                return updates.withUnsafeBufferPointer {
                    omni_vm_update_resources(
                        script.vm,
                        owner.wire,
                        $0.baseAddress,
                        $0.count,
                        &applied,
                        &errorBuffer,
                        errorBuffer.count
                    )
                }
            }
            if status != OMNI_OK { log(1) { _ in "resources: \(lastError())" } }
            changed = changed || applied
        }
        return changed
    }

    func admitResources(
        _ values: [ShellPickedResource],
        owner: ShellServiceOwner,
        component: String?
    ) throws -> [ShellResourceID] {
        guard !closing, let script, !values.isEmpty, values.count <= ShellResourceStore.attachmentLimit else {
            throw ShellResourceFailure("resource owner is unavailable")
        }
        if owner.owner == 0 {
            guard component == nil else { throw ShellResourceFailure("resource owner namespace mismatch") }
        } else {
            guard let component else { throw ShellResourceFailure("resource owner namespace mismatch") }
            var current = omni_owner_token()
            guard omni_vm_component_owner(script.vm, component, component.utf8.count, &current),
                  ShellServiceOwner(current) == owner
            else {
                throw ShellResourceFailure("resource owner is stale")
            }
        }
        var issued = [omni_resource_id](repeating: omni_resource_id(), count: values.count)
        let status = Self.withResourceDescriptors(values) { descriptors in
            issued.withUnsafeMutableBufferPointer {
                omni_vm_admit_resources(
                    script.vm,
                    owner.wire,
                    descriptors.baseAddress,
                    descriptors.count,
                    $0.baseAddress,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
        }
        guard status == OMNI_OK else { throw ShellResourceFailure(lastError()) }
        let ids = issued.map { ShellResourceID(UUID(uuid: $0.bytes)) }
        let admitted = values.enumerated().map { index, value in
            ShellResourceDescriptor(id: ids[index], name: value.name, kind: value.kind, uti: value.uti)
        }
        do {
            try bindResources(owner, component: component)
            try resourceStore.catalog.admit(admitted, owner: owner)
        } catch {
            _ = issued.withUnsafeBufferPointer { omni_vm_release_resources(
                script.vm,
                owner.wire,
                $0.baseAddress,
                $0.count
            ) }
            throw error
        }
        return ids
    }

    func retireResourceIDs(_ ids: [ShellResourceID], owner: ShellServiceOwner) {
        guard let script else { return }
        for offset in stride(from: 0, to: ids.count, by: ShellResourceStore.attachmentLimit) {
            let values = ids[offset ..< min(offset + ShellResourceStore.attachmentLimit, ids.count)]
                .map { omni_resource_id(bytes: $0.value.uuid) }
            _ = values.withUnsafeBufferPointer { omni_vm_release_resources(
                script.vm,
                owner.wire,
                $0.baseAddress,
                $0.count
            ) }
        }
    }

    static func resourceUUID(_ value: ShellServiceValue?) -> UUID? {
        guard case let .bytes(bytes) = value, bytes.count == 16 else { return nil }
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    private static func resourceError(_ value: String?) -> String {
        RuntimeTraceLimits.boundedString((value ?? "").replacingOccurrences(of: "\0", with: " "), maxBytes: 1024)
    }

    private static func withResourceDescriptors<T>(
        _ descriptors: [ShellPickedResource],
        _ body: (UnsafeBufferPointer<omni_resource_descriptor>) -> T
    ) -> T {
        var bytes: [CChar] = []
        let spans = descriptors.map { descriptor in
            [descriptor.name, descriptor.kind, descriptor.uti].map { value -> (Int, Int) in
                let offset = bytes.count
                bytes.append(contentsOf: value.utf8.map { CChar(bitPattern: $0) })
                return (offset, bytes.count - offset)
            }
        }
        return bytes.withUnsafeBufferPointer { bytes in
            let values = spans.map { span in
                omni_resource_descriptor(
                    name: bytes.baseAddress?.advanced(by: span[0].0),
                    name_length: span[0].1,
                    kind: bytes.baseAddress?.advanced(by: span[1].0),
                    kind_length: span[1].1,
                    uti: bytes.baseAddress?.advanced(by: span[2].0),
                    uti_length: span[2].1
                )
            }
            return values.withUnsafeBufferPointer(body)
        }
    }
}
