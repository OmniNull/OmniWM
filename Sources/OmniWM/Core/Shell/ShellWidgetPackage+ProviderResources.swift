// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellWidgetPackage {
    enum ProviderResourceWork: Sendable {
        case prepare(ShellResourceLeaseKey, String, Data, [ShellResourceID], ShellResourceOperation)
        case decode(ShellResourceLeaseKey, Data)
        case importOutputs(ShellResourceLeaseKey, [ShellResourceOutput], [ShellResourceID])
        case release([ShellResourceID], ShellServiceOwner)
        case finish(ShellResourceLeaseKey)
    }

    func enqueueProviderResource(_ work: ProviderResourceWork) {
        resourceWork.append(.provider(work))
        startResourceWorker()
    }

    func performProviderResource(_ work: ProviderResourceWork) async {
        switch work {
        case let .prepare(key, name, arguments, inputs, operation):
            await resourceStore.prepareProviderAction(
                key,
                action: ShellProviderActionRequest(name: name, arguments: arguments, inputs: inputs),
                operation: operation
            ) { [providerInbox] result in
                _ = providerInbox.actionPrepared(key, result: result)
            }
        case let .decode(key, data):
            let result = await resourceStore.decodeProviderOutputs(data)
            _ = providerInbox.prepareResultMetadata(key, result: result)
        case let .importOutputs(key, outputs, ids):
            var result: Result<[ShellResourceID], ShellResourceFailure>
            var failed = false
            do {
                try await resourceStore.importOutputs(outputs, ids: ids, action: key)
                result = .success(ids)
            } catch {
                failed = true
                result = .failure(ShellResourceFailure(String(describing: error)))
            }
            let accepted = providerInbox.finishResultImport(key, result: result)
            if !accepted || failed {
                retireResourceIDs(ids, owner: key.id.owner)
                resourceStore.catalog.remove(ids, owner: key.id.owner)
                await resourceStore.release(ids, owner: key.id.owner)
                if providerActions[key.id]?.identity.incarnation == key
                    .incarnation { providerActions[key.id]?.outputs = [] }
            }
        case let .release(ids, owner):
            await resourceStore.release(ids, owner: owner)
        case let .finish(key):
            if let route = providerActions[key.id], route.identity.incarnation == key.incarnation {
                retireResourceIDs(route.outputs, owner: key.id.owner)
                resourceStore.catalog.remove(route.outputs, owner: key.id.owner)
                await resourceStore.release(route.outputs, owner: key.id.owner)
            }
            await resourceStore.finishAction(key)
            providerInbox.finishActionCleanup(key)
            if providerActions[key.id]?.identity.incarnation == key
                .incarnation { providerActions.removeValue(forKey: key.id) }
        }
    }

    func consumeProviderWork(_ work: ShellProviderInbox.Work) {
        switch work {
        case let .decodeResult(key, data): enqueueProviderResource(.decode(key, data))
        case let .importResult(key, outputs):
            do {
                guard let route = providerActions[key.id], route.identity.incarnation == key.incarnation,
                      route.operation?.isActive == true, !closing else { throw ShellResourceFailure("cancelled") }
                if outputs.files.isEmpty {
                    _ = providerInbox.finishResultImport(key, result: .success([]))
                    return
                }
                let ids = try admitResources(outputs.descriptors, owner: key.id.owner, component: route.component)
                providerActions[key.id]?.outputs = ids
                enqueueProviderResource(.importOutputs(key, outputs.files, ids))
            } catch {
                _ = providerInbox.finishResultImport(
                    key,
                    result: .failure(ShellResourceFailure(String(describing: error)))
                )
            }
        case let .finishAction(key): enqueueProviderResource(.finish(key))
        }
    }

    func disposeProviderOutputs(_ ids: [ShellResourceID], owner: ShellServiceOwner) {
        guard !ids.isEmpty else { return }
        retireResourceIDs(ids, owner: owner)
        resourceStore.catalog.remove(ids, owner: owner)
        enqueueProviderResource(.release(ids, owner))
    }

    func finishProviderCleanup(owner: ShellServiceOwner? = nil) async {
        await resourceBarrier()
        while true {
            let batch = providerInbox.takeCleanup(owner: owner)
            guard !batch.isEmpty else { return }
            for delivery in batch {
                if let work = delivery.work { consumeProviderWork(work) }
            }
            await resourceBarrier()
        }
    }
}
