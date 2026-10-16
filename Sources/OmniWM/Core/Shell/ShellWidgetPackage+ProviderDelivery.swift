// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

extension ShellWidgetPackage {
    func applyProviderSnapshot(
        _ snapshot: ShellProviderInbox.Snapshot,
        identity: ShellProviderIdentity,
        in script: ShellScript
    ) -> Bool {
        guard providerInbox.binding(for: identity.owner)?.identity == identity else { return false }
        let status: omni_provider_status
        var exitCode: Int32 = 0
        var failure = ""
        switch snapshot.status {
        case .starting: status = OMNI_PROVIDER_STARTING
        case .running: status = OMNI_PROVIDER_RUNNING
        case let .exited(code): status = OMNI_PROVIDER_EXITED
            exitCode = code
        case let .failed(error): status = OMNI_PROVIDER_FAILED
            failure = ShellHTTPResponse.boundedError(error)
        case nil: status = OMNI_PROVIDER_UNCHANGED
        }
        var applied = false
        let outcome = Self.withProviderTopics(snapshot.topics) { topics in
            failure.withCString { error in
                var snapshot = omni_provider_snapshot(
                    incarnation: identity.incarnation,
                    status: status,
                    error: error,
                    error_length: failure.utf8.count,
                    exit_code: exitCode,
                    topics: topics.baseAddress,
                    topic_count: topics.count
                )
                return omni_vm_provider_update(
                    script.vm,
                    identity.owner.wire,
                    &snapshot,
                    Self.handlerBudget,
                    &applied,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
        }
        reportProviderStatus(outcome)
        drainServices(in: script)
        return applied
    }

    private static func withProviderTopics(
        _ topics: [ShellProviderInbox.Topic],
        _ body: (UnsafeBufferPointer<omni_provider_topic>) -> omni_status
    ) -> omni_status {
        struct Span {
            let name: Int
            let nameLength: Int
            let json: Int
            let jsonLength: Int
            let removed: Bool
        }
        var storage: [UInt8] = []
        let spans = topics.map { topic in
            let name = storage.count
            storage.append(contentsOf: topic.name.utf8)
            let json = storage.count
            if let value = topic.value { storage.append(contentsOf: value) }
            return Span(
                name: name,
                nameLength: json - name,
                json: json,
                jsonLength: storage.count - json,
                removed: topic.value == nil
            )
        }
        return storage.withUnsafeBytes { bytes in
            let base = bytes.bindMemory(to: CChar.self).baseAddress
            let topics = spans.map {
                omni_provider_topic(
                    name: base?.advanced(by: $0.name),
                    name_length: $0.nameLength,
                    json: $0.removed ? nil : base?.advanced(by: $0.json),
                    json_length: $0.jsonLength,
                    removed: $0.removed
                )
            }
            return topics.withUnsafeBufferPointer(body)
        }
    }

    func installProviderStateBeforeAction(
        _ action: UInt32,
        view: ShellWidgetView,
        instance: OpaquePointer,
        script: ShellScript
    ) {
        var owner = omni_owner_token()
        guard omni_instance_action_owner(instance, view.wire, action, &owner), owner.owner != 0,
              let identity = providerInbox.binding(for: ShellServiceOwner(owner))?.identity,
              let snapshot = providerInbox.takeState(identity, now: DispatchTime.now().uptimeNanoseconds)
        else { return }
        _ = applyProviderSnapshot(snapshot, identity: identity, in: script)
    }

    func deliverProvider(_ delivery: ShellProviderInbox.Delivery, in script: ShellScript) -> Bool {
        var changed = false
        if let snapshot = delivery.snapshot {
            changed = applyProviderSnapshot(snapshot, identity: delivery.identity, in: script) || changed
        }
        var handled = false
        if let control = delivery.control {
            let status: omni_status
            switch control {
            case let .event(name, value):
                guard providerInbox.binding(for: delivery.identity.owner)?.identity == delivery.identity else {
                    return changed
                }
                status = value.withUnsafeBytes { bytes in
                    omni_vm_provider_receive(
                        script.vm,
                        delivery.identity.owner.wire,
                        delivery.identity.incarnation,
                        name,
                        name.utf8.count,
                        bytes.bindMemory(to: CChar.self).baseAddress,
                        bytes.count,
                        Self.handlerBudget,
                        &handled,
                        &errorBuffer,
                        errorBuffer.count
                    )
                }
            case let .result(id, outcome):
                guard let result = deliverProviderResult(
                    id,
                    outcome: outcome,
                    in: script,
                    changed: &changed,
                    handled: &handled
                ) else { return changed }
                status = result
            }
            reportProviderStatus(status)
            changed = changed || handled
            drainServices(in: script)
        }
        return changed
    }

    private func deliverProviderResult(
        _ id: ShellServiceID,
        outcome: consuming ShellProviderInbox.Outcome,
        in script: ShellScript,
        changed: inout Bool,
        handled: inout Bool
    ) -> omni_status? {
        let route = providerActions[id]
        let key = route?.operation == nil ? nil : route?.key(id)
        if let key, !providerInbox.beginResultDelivery(key) { return nil }
        defer {
            if let key { providerInbox.finishResultDelivery(key) }
            else { providerActions.removeValue(forKey: id) }
        }
        guard services.takeRegistered(id) else {
            if case let .resources(_, ids) = outcome {
                disposeProviderOutputs(ids, owner: id.owner)
                providerActions[id]?.outputs = []
            }
            return nil
        }
        switch outcome {
        case .provider:
            return completeProvider(id, outcome: outcome, in: script, handled: &handled)
        case let .resources(_, ids):
            let metadata = ids.compactMap { resourceStore.catalog.metadata($0, owner: id.owner) }
            changed = applyResourceMetadata(metadata, owner: id.owner, in: script) || changed
            return completeProvider(id, outcome: outcome, in: script, handled: &handled)
        case let .failure(error):
            return completeProviderFailure(id, error: error, in: script, handled: &handled)
        }
    }

    func deliverProviders(in script: ShellScript) async {
        guard !closing, self.script === script else { return }
        providerDeadline?.cancel()
        providerDeadline = nil
        var changed = false
        for (key, instance) in script.instances { hydrate(key, instance) }
        let batch = providerInbox.takeBatch(now: DispatchTime.now().uptimeNanoseconds)
        for delivery in batch {
            if let work = delivery.work { consumeProviderWork(work) }
            else { changed = deliverProvider(delivery, in: script) || changed }
        }
        dispatchPendingProviderRequests()
        if !batch.isEmpty { await Task.yield() }
        if changed, !closing, self.script === script {
            for (key, instance) in script.instances { await renderVisible(key, instance) }
        }
        if case let .deadline(expected) = providerInbox.finishBatch(now: DispatchTime.now().uptimeNanoseconds) {
            let source = DispatchSource.makeTimerSource(queue: queue)
            let inbox = providerInbox
            source.schedule(deadline: DispatchTime(uptimeNanoseconds: expected))
            source.setEventHandler { inbox.deadlineFired(expected, now: DispatchTime.now().uptimeNanoseconds) }
            providerDeadline = source
            source.resume()
        }
    }

    private func completeProvider(
        _ id: ShellServiceID,
        outcome: borrowing ShellProviderInbox.Outcome,
        in script: ShellScript,
        handled: inout Bool
    ) -> omni_status {
        let ok: Bool
        let value: Data
        let ids: [ShellResourceID]
        switch outcome {
        case let .provider(success, payload, _):
            ok = success
            value = payload
            ids = []
        case let .resources(payload, resources):
            ok = true
            value = payload
            ids = resources
        case let .failure(error):
            return completeProviderFailure(id, error: error, in: script, handled: &handled)
        }
        var transferred = false
        let resources = ids.map { omni_resource_id(bytes: $0.value.uuid) }
        let status = resources.withUnsafeBufferPointer { resources in
            value.withUnsafeBytes { bytes in
                omni_vm_complete_provider(
                    script.vm,
                    id.owner.wire,
                    id.request,
                    ok,
                    bytes.bindMemory(to: CChar.self).baseAddress,
                    bytes.count,
                    resources.baseAddress,
                    resources.count,
                    Self.handlerBudget,
                    &handled,
                    &transferred,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
        }
        if !transferred { disposeProviderOutputs(ids, owner: id.owner) }
        if !ids.isEmpty { providerActions[id]?.outputs = [] }
        return status
    }

    private func completeProviderFailure(
        _ id: ShellServiceID,
        error: String,
        in script: ShellScript,
        handled: inout Bool
    ) -> omni_status {
        let bytes: Data
        do { bytes = try JSONEncoder().encode(ShellHTTPResponse.boundedError(error)) }
        catch { bytes = Data("\"provider_error\"".utf8) }
        return bytes.withUnsafeBytes {
            omni_vm_complete_provider(
                script.vm,
                id.owner.wire,
                id.request,
                false,
                $0.bindMemory(to: CChar.self).baseAddress,
                $0.count,
                nil, 0,
                Self.handlerBudget,
                &handled, nil,
                &errorBuffer,
                errorBuffer.count
            )
        }
    }

    private func reportProviderStatus(_ status: omni_status) {
        if status == OMNI_ERR_COMPONENT { log(1) { _ in lastError() } }
        else if status != OMNI_OK { fail(status) }
    }
}
