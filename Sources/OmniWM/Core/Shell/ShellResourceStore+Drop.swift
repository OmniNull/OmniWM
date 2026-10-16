// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellResourceIngressTransfer: Sendable {
    let ids: [ShellResourceID]
    let offset: Int
    let owner: ShellServiceOwner
    let operation: ShellResourceOperation
    let transferred: Bool
}

extension ShellResourceStore {
    func materializeIngress(
        _ sources: [Source],
        ids: [ShellResourceID],
        owner: ShellServiceOwner,
        operation: ShellResourceOperation
    ) throws {
        try requirePending(ids, owner: owner)
        guard sources.count == ids.count else { throw ShellResourceFailure("resource batch size mismatch") }
        var prepared: [Backing] = []
        do {
            for source in sources {
                guard operation.isActive else { throw ShellResourceFailure("cancelled") }
                prepared.append(try prepare(source))
            }
            try install(prepared, ids: ids, owner: owner, operation: operation)
            finishWaiting(ids)
        } catch {
            for value in prepared { clean(value.ownedDirectory) }
            fail(ids, owner: owner, error: String(describing: error))
            throw error
        }
    }

    func consumeIngress(
        _ batch: ShellFilePromiseBatch.Batch,
        transfer: ShellResourceIngressTransfer
    ) {
        for delivery in batch.deliveries {
            let index = delivery.index.map { $0 + transfer.offset }
            let id = index.flatMap { transfer.ids.indices.contains($0) ? transfer.ids[$0] : nil }
            guard transfer.transferred, transfer.operation.isActive, let id else {
                if case let .success(file) = delivery.result { discard([file]) }
                continue
            }
            switch delivery.result {
            case let .success(file):
                do { try receive(file, id: id, owner: transfer.owner, operation: transfer.operation) }
                catch { fail([id], owner: transfer.owner, error: String(describing: error)) }
            case let .failure(error):
                fail([id], owner: transfer.owner, error: error.description)
            }
        }
        if transfer.transferred, let error = batch.error { fail(transfer.ids, owner: transfer.owner, error: error) }
    }
}
