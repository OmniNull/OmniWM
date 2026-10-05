// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@MainActor
final class ManualSleeper {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct PendingSleepsWait {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var requestedDurations: [Duration] = []
    private var nextId: UInt64 = 0
    private var permits = 0
    private var waiters: [Waiter] = []
    private var pendingSleepsWaits: [PendingSleepsWait] = []

    var pendingCount: Int {
        waiters.count
    }

    func sleep(for duration: Duration) async throws {
        requestedDurations.append(duration)
        try Task.checkCancellation()
        if permits > 0 {
            permits -= 1
            return
        }
        nextId &+= 1
        let id = nextId
        let elapsed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
                resumeSatisfiedPendingSleepsWaits()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id: id)
            }
        }
        guard elapsed else { throw CancellationError() }
    }

    func waitForPendingSleeps(_ count: Int) async {
        guard waiters.count < count else { return }
        await withCheckedContinuation { continuation in
            pendingSleepsWaits.append(PendingSleepsWait(count: count, continuation: continuation))
        }
    }

    func resumeNext() {
        guard !waiters.isEmpty else {
            permits += 1
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancel(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func resumeSatisfiedPendingSleepsWaits() {
        let satisfied = pendingSleepsWaits.filter { $0.count <= waiters.count }
        pendingSleepsWaits.removeAll { $0.count <= waiters.count }
        for wait in satisfied {
            wait.continuation.resume()
        }
    }
}
