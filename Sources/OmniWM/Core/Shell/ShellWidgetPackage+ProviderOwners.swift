// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

extension ShellWidgetPackage {
    struct ProviderSlot {
        let owner: ShellServiceOwner
        let supervisor: ShellProvider
        var configuration: ShellProviderConfiguration?
        var captureStart: Task<Void, Never>?
    }

    struct PendingProviderRequest {
        let id: ShellServiceID
        let instance: String
        let configuration: ShellProviderConfiguration
        let payload: ProviderRequestPayload
    }

    enum ProviderRequestPayload {
        case data(Data)
        case files(name: String, arguments: Data, ids: [ShellResourceID])
    }

    struct ProviderActionRoute {
        let supervisor: ShellProvider
        let identity: ShellProviderIdentity
        let component: String
        let operation: ShellResourceOperation?
        var outputs: [ShellResourceID] = []

        func key(_ id: ShellServiceID) -> ShellResourceLeaseKey {
            ShellResourceLeaseKey(id: id, incarnation: identity.incarnation)
        }
    }

    func prepareProviderConfigurations(_ source: ShellWidgetSource) throws -> [String: ShellProviderConfiguration] {
        var result: [String: ShellProviderConfiguration] = [:]
        for instance in source.components {
            guard let descriptor = source.componentDescriptors.first(where: { $0.widget == instance.widget }),
                  descriptor.authorizesProvider(instance)
            else { continue }
            result[instance.id] = try ShellProviderConfiguration(instance: instance, descriptor: descriptor)
        }
        return result
    }

    func providerOwner(_ name: String) -> ShellServiceOwner? {
        guard let script else { return nil }
        var token = omni_owner_token()
        guard omni_vm_component_owner(script.vm, name, name.utf8.count, &token) else { return nil }
        return ShellServiceOwner(token)
    }

    func updateProviderConfigurations(_ configurations: [String: ShellProviderConfiguration]) {
        providerConfigurations = componentConfigurationValid && !closing ? configurations : [:]
        pendingProviderRequests.removeAll { request in
            guard providerConfigurations[request.instance] != request.configuration else { return false }
            failPendingProvider(request, error: "configuration_changed")
            return true
        }
        scheduleProviderReconciliation()
        dispatchPendingProviderRequests()
    }

    func scheduleProviderReconciliation() {
        guard providerReconciliation == nil, !providerSlots.isEmpty || !providerConfigurations.isEmpty else { return }
        providerReconciliation = Task { await reconcileProviderOwners() }
    }

    private func reconcileProviderOwners() async {
        while true {
            if let entry = providerSlots.first(where: { closing || providerOwner($0.key) != $0.value.owner }) {
                await retireProviderCapture(entry.value, name: entry.key)
                await entry.value.supervisor.close()
                if providerSlots[entry.key]?.owner == entry.value.owner {
                    providerSlots.removeValue(forKey: entry.key)
                    providerInbox.remove(owner: entry.value.owner)
                    await finishProviderCleanup(owner: entry.value.owner)
                }
                continue
            }
            var changed = false
            for name in Set(providerConfigurations.keys).union(providerSlots.keys) {
                guard !closing, let owner = providerOwner(name) else { continue }
                let next = providerConfigurations[name]
                if providerSlots[name] == nil, next != nil {
                    let package = self.name
                    let supervisor = ShellProvider(owner: owner, inbox: providerInbox) { _, line in
                        Log.shell
                            .error(
                                "\(package)/\(name): \(line.text) (truncated=\(line.truncated), suppressed=\(line.suppressed))"
                            )
                    }
                    let captureID = utilityCaptureID
                    let captureStart: Task<Void, Never>? = captureID == 0 ? nil : Task {
                        await supervisor.captureBegin(captureID)
                    }
                    providerSlots[name] = ProviderSlot(owner: owner, supervisor: supervisor, captureStart: captureStart)
                    await captureStart?.value
                }
                guard var slot = providerSlots[name], slot.owner == owner, slot.configuration != next else { continue }
                slot.configuration = next
                providerSlots[name] = slot
                await slot.supervisor.reconcile(next)
                changed = true
                break
            }
            if !changed { break }
        }
        providerReconciliation = nil
        dispatchPendingProviderRequests()
    }

    func retireProviders() async {
        scheduleProviderReconciliation()
        if let task = providerReconciliation { await task.value }
    }

    func closeProviders() async {
        providerConfigurations = [:]
        pendingProviderRequests.removeAll()
        providerDeadline?.cancel()
        providerDeadline = nil
        providerInbox.close()
        await retireProviders()
        await finishProviderCleanup()
        providerActions.removeAll()
    }

    func enqueueProvider(
        _ id: ShellServiceID,
        component: String?,
        value: [UInt8],
        cancelled: Bool,
        in script: ShellScript
    ) {
        if cancelled {
            pendingProviderRequests.removeAll { $0.id == id }
            if let route = providerActions[id] {
                route.supervisor.cancel(id, identity: route.identity)
                if route.operation == nil { providerActions.removeValue(forKey: id) }
            }
            providerInbox.cancel(id)
            return
        }
        guard services.register(id, cancel: { [providerInbox] in providerInbox.cancel(id) }) else {
            _ = omni_vm_cancel_service(script.vm, id.owner.wire, id.request)
            log(1) { _ in "provider request was rejected by its native owner" }
            return
        }
        do {
            guard componentConfigurationValid, id.owner.owner != 0, let component,
                  let configuration = providerConfigurations[component], providerOwner(component) == id.owner
            else { throw ShellProviderProtocol.Failure(message: "provider_denied") }
            let payload = try providerPayload(id, component: component, value: value)
            pendingProviderRequests.append(PendingProviderRequest(
                id: id,
                instance: component,
                configuration: configuration,
                payload: payload
            ))
            dispatchPendingProviderRequests()
        } catch {
            providerInbox.failUndispatched(
                id,
                error: (error as? ShellResourceFailure)?.description ?? error.localizedDescription
            )
        }
    }

    private func providerPayload(
        _ id: ShellServiceID,
        component: String,
        value: [UInt8]
    ) throws -> ProviderRequestPayload {
        guard let fields = try ShellServiceValue.decode(value, byteLimit: 66_560).fields,
              let name = fields["name"]?.string, case let .bytes(argumentBytes)? = fields["argsJSON"],
              fields.count == (fields["files"] == nil ? 2 : 3)
        else { throw ShellResourceFailure("invalid_provider_request") }
        var files: [ShellResourceID]?
        if let declared = fields["files"] {
            guard permitsFiles(id.owner, component: component) else { throw ShellResourceFailure("files_denied") }
            guard let values = declared.values, values.count <= ShellResourceStore.attachmentLimit else {
                throw ShellResourceFailure("invalid_provider_files")
            }
            let resources = try values.map { value in
                guard let uuid = Self.resourceUUID(value)
                else { throw ShellResourceFailure("invalid_provider_files") }
                return ShellResourceID(uuid)
            }
            guard Set(resources).count == resources.count
            else { throw ShellResourceFailure("invalid_provider_files") }
            try bindResources(id.owner, component: component)
            guard resources.allSatisfy({ resourceStore.catalog.metadata($0, owner: id.owner) != nil }) else {
                throw ShellResourceFailure("invalid_provider_files")
            }
            files = resources
        }
        let arguments = Data(argumentBytes)
        let payload: ProviderRequestPayload
        if let files { payload = .files(name: name, arguments: arguments, ids: files) }
        else { payload = .data(try ShellProviderProtocol.action(id: id.request, name: name, arguments: arguments)) }
        return payload
    }

    func failPendingProvider(_ request: PendingProviderRequest, error: String) {
        guard let route = providerActions[request.id] else {
            providerInbox.failUndispatched(request.id, error: error)
            return
        }
        route.operation?.cancel()
        providerInbox.actionUnsent(route.key(request.id))
        providerInbox.failAction(request.id, identity: route.identity, error: error)
    }

    func dispatchPendingProviderRequests() {
        var kept: [PendingProviderRequest] = []
        var waiting: Set<ShellServiceOwner> = []
        for request in pendingProviderRequests {
            guard !closing, providerOwner(request.instance) == request.id.owner,
                  providerConfigurations[request.instance] == request.configuration
            else { failPendingProvider(request, error: "configuration_changed")
                continue
            }
            if waiting.contains(request.id.owner) { kept.append(request)
                continue
            }
            guard let slot = providerSlots[request.instance], slot.owner == request.id.owner,
                  let binding = providerInbox.binding(for: request.id.owner),
                  binding.configuration == request.configuration
            else { waiting.insert(request.id.owner)
                kept.append(request)
                continue
            }
            guard !binding.terminal else { failPendingProvider(request, error: "provider_unavailable")
                continue
            }
            guard binding.accepting else { waiting.insert(request.id.owner)
                kept.append(request)
                continue
            }
            dispatchProviderRequest(request, binding: binding, slot: slot, waiting: &waiting, kept: &kept)
        }
        pendingProviderRequests = kept
    }

    private func dispatchProviderRequest(
        _ request: PendingProviderRequest,
        binding: ShellProviderInbox.Binding,
        slot: ProviderSlot,
        waiting: inout Set<ShellServiceOwner>,
        kept: inout [PendingProviderRequest]
    ) {
        if let route = providerActions[request.id] {
            guard route.identity == binding.identity else { failPendingProvider(
                request,
                error: "configuration_changed"
            )
            return
            }
            let key = route.key(request.id)
            if let frame = providerInbox.preparedFrame(key), providerInbox.markSubmitted(key) {
                route.supervisor.send(request.id, identity: route.identity, frame: frame)
            } else if providerInbox.preparingAction(key) {
                waiting.insert(request.id.owner)
                kept.append(request)
            }
            return
        }
        let operation: ShellResourceOperation?
        if case .files = request.payload { operation = ShellResourceOperation() }
        else { operation = nil }
        guard providerInbox.register(request.id, identity: binding.identity, operation: operation) else {
            waiting.insert(request.id.owner)
            kept.append(request)
            return
        }
        let route = ProviderActionRoute(
            supervisor: slot.supervisor,
            identity: binding.identity,
            component: request.instance,
            operation: operation
        )
        providerActions[request.id] = route
        if case let .files(name, arguments, files) = request.payload, let operation {
            guard resourceWork.count + (resourceWorker == nil ? 0 : 1) < ShellServiceLedger.capacity else {
                _ = providerInbox.actionPrepared(
                    route.key(request.id),
                    result: .failure(ShellResourceFailure("resource_work_overloaded"))
                )
                return
            }
            enqueueProviderResource(.prepare(route.key(request.id), name, arguments, files, operation))
            waiting.insert(request.id.owner)
            kept.append(request)
        } else if case let .data(frame) = request.payload {
            slot.supervisor.send(request.id, identity: binding.identity, frame: frame)
        }
    }
}
