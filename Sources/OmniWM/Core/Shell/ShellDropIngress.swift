// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

struct ShellDropResourceBridge: Sendable {
    let admit: @Sendable (ShellDropReservation, [ShellPickedResource]) async throws -> [ShellResourceID]
    let deliver: @Sendable (ShellDropReservation, [ShellResourceID], CGPoint) async -> Bool
    let retire: @Sendable (ShellServiceOwner, [ShellResourceID]) async -> Void
    let finish: @Sendable (ShellDropReservation) async -> Void
}

@MainActor
final class ShellDropIngress {
    struct Promises {
        let count: Int
        let start: @MainActor (ShellFilePromiseBatch, OperationQueue) throws -> [ShellFilePromiseBatch.Item]

        @MainActor init(_ receivers: [NSFilePromiseReceiver]) {
            count = receivers.count
            var session: ShellFilePromiseSession?
            start = { batch, queue in
                let value = ShellFilePromiseSession(receivers: receivers, batch: batch, readerQueue: queue)
                session = value
                return try session!.start()
            }
        }

        init(
            count: Int,
            start: @escaping @MainActor (ShellFilePromiseBatch, OperationQueue) throws -> [ShellFilePromiseBatch.Item]
        ) {
            self.count = count
            self.start = start
        }
    }

    private final class Operation {
        let reservation: ShellDropReservation
        let bridge: ShellDropResourceBridge
        var task: Task<Void, Never>?
        var batch: ShellFilePromiseBatch?
        var promises: Promises?
        var items: [ShellDropItem] = []
        var resources: [ShellResourceID] = []
        var deliveryStarted = false
        var transferred = false

        init(_ reservation: ShellDropReservation, bridge: ShellDropResourceBridge) {
            self.reservation = reservation
            self.bridge = bridge
        }
    }

    static let capacity = 256
    static let ownerCapacity = 32
    private static var live: Set<ShellServiceID> = []
    private let resources: ShellResourceStore
    private let readerQueue: OperationQueue
    private let report: @MainActor (String) -> Void
    private var operations: [ShellServiceID: Operation] = [:]

    init(
        resources: ShellResourceStore,
        report: @escaping @MainActor (String) -> Void = { Log.shell.error("Drop: \($0)") }
    ) {
        self.resources = resources
        self.report = report
        readerQueue = OperationQueue()
        readerQueue.name = "com.barut.OmniWM.shell.promises"
        readerQueue.qualityOfService = .utility
        readerQueue.maxConcurrentOperationCount = 2
    }

    var activeCount: Int {
        operations.count
    }

    func prepare(
        _ reservation: ShellDropReservation,
        ledger: ShellServiceLedger,
        bridge: ShellDropResourceBridge
    ) -> Bool {
        let id = reservation.id
        guard reservation.operation.isActive, !Self.live.contains(id), Self.live.count < Self.capacity,
              Self.live.lazy.filter({ $0.owner == id.owner }).count < Self.ownerCapacity else { return false }
        let operation = Operation(reservation, bridge: bridge)
        guard ledger.adopt(id, cancel: { [weak self] in
            reservation.operation.cancel()
            Task { @MainActor in self?.cancel(reservation) }
        }) else { return false }
        Self.live.insert(id)
        operations[id] = operation
        return true
    }

    func accept(_ reservation: ShellDropReservation, snapshot: ShellDropSnapshot, point: CGPoint) {
        accept(
            reservation,
            items: snapshot.items,
            promises: snapshot.promises.isEmpty ? nil : Promises(snapshot.promises),
            point: point
        )
    }

    func accept(_ reservation: ShellDropReservation, items: [ShellDropItem], promises: Promises?, point: CGPoint) {
        guard let operation = operations[reservation.id], operation.reservation == reservation,
              operation.task == nil else { return }
        operation.items = items
        operation.promises = promises
        operation.task = Task { await run(operation, point: point) }
    }

    func cancel(_ reservation: ShellDropReservation) {
        reservation.operation.cancel()
        guard let operation = operations[reservation.id], operation.reservation == reservation else { return }
        operation.batch?.cancel()
        if operation.task == nil { operation.task = Task { await finish(operation) } }
    }

    func cancel(sourceID: UInt64) {
        for operation in operations.values
            where operation.reservation.authority.sourceID == sourceID && !operation.deliveryStarted
        {
            cancel(operation.reservation)
        }
    }

    func waitUntilFinished(_ reservation: ShellDropReservation) async {
        if let task = operations[reservation.id]?.task { await task.value }
    }

    private func run(_ operation: Operation, point: CGPoint) async {
        let reservation = operation.reservation
        let fence = reservation.operation
        var reception = PromiseReception()
        do {
            guard fence.isActive else { throw ShellResourceFailure("cancelled") }
            var descriptors = operation.items.map { ShellPickedResource(name: $0.name, kind: $0.kind, uti: $0.uti) }
            if let promises = operation.promises {
                descriptors += try await preparePromises(promises, operation: operation, reception: &reception)
            }
            guard !descriptors.isEmpty, descriptors.count <= ShellResourceStore.attachmentLimit else {
                throw ShellResourceFailure("drop exceeds 32 resources")
            }
            guard fence.isActive else { throw ShellResourceFailure("cancelled") }
            operation.resources = try await operation.bridge.admit(reservation, descriptors)
            guard fence.isActive else { throw ShellResourceFailure("cancelled") }
            operation.deliveryStarted = true
            operation.transferred = await operation.bridge.deliver(reservation, operation.resources, point)
            guard operation.transferred,
                  fence.isActive else { throw ShellResourceFailure("drop target is unavailable") }
            if !operation.items.isEmpty {
                try await resources.materializeIngress(
                    operation.items.map(\.source),
                    ids: Array(operation.resources.prefix(operation.items.count)),
                    owner: reservation.id.owner,
                    operation: fence
                )
            }
        } catch {
            report(String(describing: error))
            operation.batch?.cancel(error: String(describing: error))
            if operation.transferred {
                await resources.fail(operation.resources, owner: reservation.id.owner, error: String(describing: error))
            }
        }
        await drainPromises(operation, reception: reception)
        await finish(operation)
    }

    private struct PromiseReception {
        var stream: AsyncStream<Void>?
        var continuation: AsyncStream<Void>.Continuation?
        var directory: URL?
        var started = false
    }

    private func preparePromises(
        _ promises: Promises,
        operation: Operation,
        reception: inout PromiseReception
    ) async throws -> [ShellPickedResource] {
        let fence = operation.reservation.operation
        let destination = try await resources.ingressDirectory()
        reception.directory = destination
        guard fence.isActive else { throw ShellResourceFailure("cancelled") }
        let batch = try ShellFilePromiseBatch(
            receiverCount: promises.count,
            directory: destination,
            temporaryRoot: resources.directory,
            operation: fence
        )
        operation.batch = batch
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        reception.stream = pair.stream
        reception.continuation = pair.continuation
        batch.attachWake { pair.continuation.yield(()) }
        let names: [ShellFilePromiseBatch.Item]
        do {
            names = try promises.start(batch, readerQueue)
            reception.started = true
        } catch {
            reception.started = batch.isConfigured
            throw error
        }
        return names.map { ShellPickedResource(name: $0.name, kind: "file", uti: $0.uti) }
    }

    private func drainPromises(_ operation: Operation, reception: PromiseReception) async {
        if reception.started, let batch = operation.batch, let stream = reception.stream {
            let transfer = ShellResourceIngressTransfer(
                ids: operation.resources,
                offset: operation.items.count,
                owner: operation.reservation.id.owner,
                operation: operation.reservation.operation,
                transferred: operation.transferred
            )
            batch.activate()
            for await _ in stream {
                let next = batch.takeBatch()
                await resources.consumeIngress(
                    next,
                    transfer: transfer
                )
                batch.finishBatch()
                if next.finished { break }
            }
        }
        reception.continuation?.finish()
        if let directory = reception.directory { await resources.finishIngress(directory) }
    }

    private func finish(_ operation: Operation) async {
        let reservation = operation.reservation
        if !operation.transferred, !operation.resources.isEmpty {
            await resources.release(operation.resources, owner: reservation.id.owner)
            await operation.bridge.retire(reservation.id.owner, operation.resources)
        }
        await operation.bridge.finish(reservation)
        guard operations[reservation.id] === operation else { return }
        operations.removeValue(forKey: reservation.id)
        Self.live.remove(reservation.id)
    }
}
