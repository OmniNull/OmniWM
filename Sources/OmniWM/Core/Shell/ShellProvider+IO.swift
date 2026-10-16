// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

extension ShellProvider {
    func readSource(fd: Int32, identity: ShellProviderIdentity, signal: Signal) -> any DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let signals = signals
        source.setEventHandler { signals.post(signal, identity: identity) }
        source.setCancelHandler { _ = Darwin.close(fd) }
        source.resume()
        return source
    }

    func flushInput(_ identity: ShellProviderIdentity) {
        guard lifecycle.identity == identity, let fd = inputFD, lifecycle.acceptsActions else { return }
        let discarded = writer.discardUnsent(where: { !inbox.isPending($0, identity: identity) }, onDiscard: {
            inbox.actionUnsent(ShellResourceLeaseKey(id: $0, incarnation: identity.incarnation))
        })
        actions.consumed(discarded, identity: identity)
        for action in actions.takeBatch() {
            guard inbox.isPending(action.id, identity: identity) else {
                actions.consumed(action.frame.count, identity: identity)
                inbox.actionUnsent(ShellResourceLeaseKey(id: action.id, incarnation: identity.incarnation))
                continue
            }
            do { try writer.append(action.frame, id: action.id) }
            catch {
                actions.consumed(action.frame.count, identity: identity)
                inbox.actionUnsent(ShellResourceLeaseKey(id: action.id, incarnation: identity.incarnation))
                inbox.failAction(action.id, identity: identity, error: error.localizedDescription)
            }
        }
        let before = writer.pendingBytes
        let progress = writer.drain { bytes in
            let count = Darwin.write(fd, bytes.baseAddress, bytes.count)
            if count > 0 { return .written(count) }
            if count < 0, errno == EINTR { return .interrupted }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
            return .failed("Provider stdin write failed: \(errno)")
        }
        actions.consumed(before - writer.pendingBytes, identity: identity)
        switch progress {
        case .empty:
            suspendInput()
            if actions.hasPending { signals.post(.writable, identity: identity) }
        case .blocked:
            if !inputResumed { inputSource?.resume()
                inputResumed = inputSource != nil
            }
        case .yielded:
            signals.post(.writable, identity: identity)
        case let .failed(error):
            fail(identity, message: error)
        }
    }

    func suspendInput() {
        if inputResumed { inputSource?.suspend()
            inputResumed = false
        }
    }

    func closeInput(_ identity: ShellProviderIdentity) {
        inbox.stopAccepting(identity)
        for id in actions.stop(identity) { inbox.actionUnsent(ShellResourceLeaseKey(
            id: id,
            incarnation: identity.incarnation
        )) }
        _ = writer.discardUnsent(where: { _ in true }, onDiscard: {
            inbox.actionUnsent(ShellResourceLeaseKey(id: $0, incarnation: identity.incarnation))
        })
        inputFD = nil
        if let inputSource {
            inputSource.cancel()
            if !inputResumed { inputSource.resume() }
        } else {
            signals.post(.inputClosed, identity: identity)
        }
        inputSource = nil
        inputResumed = false
        writer.removeAll()
    }

    func readOutput(_ identity: ShellProviderIdentity) {
        guard lifecycle.identity == identity, let fd = outputFD, !outputFinished else { return }
        let outcome = read(fd: fd) { [inbox] bytes in
            guard !discardOutput else { return }
            do {
                try framer.consume(bytes) { message in
                    if case let .failed(message) = inbox.post(message, from: identity) { throw failure(message) }
                }
            } catch { fail(identity, message: error.localizedDescription) }
        }
        switch outcome {
        case .more:
            signals.post(.output, identity: identity)
        case .blocked:
            if lifecycle.phase == .draining { finishOutput(identity) }
        case .end:
            finishOutput(identity)
            perform(lifecycle.outputClosed(identity))
        case let .failed(message):
            fail(identity, message: message)
            finishOutput(identity)
        }
    }

    func finishOutput(_ identity: ShellProviderIdentity) {
        guard !outputFinished else { return }
        outputFinished = true
        if !discardOutput {
            do { try framer.finish() }
            catch { fail(identity, message: error.localizedDescription) }
        }
        outputFD = nil
        outputSource?.cancel()
        outputSource = nil
    }

    func readDiagnostics(_ identity: ShellProviderIdentity) {
        guard lifecycle.identity == identity, let fd = diagnosticFD, !diagnosticFinished else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let report = diagnostics
        let outcome = read(fd: fd) { bytes in
            diagnosticFramer.consume(bytes, now: now) { report(identity, $0) }
        }
        switch outcome {
        case .more:
            signals.post(.diagnostic, identity: identity)
        case .blocked where lifecycle.phase != .draining:
            break
        case let .failed(message):
            fail(identity, message: message)
            finishDiagnostics(identity, now: now)
        case .blocked,
             .end:
            finishDiagnostics(identity, now: now)
        }
    }

    func finishDiagnostics(_ identity: ShellProviderIdentity, now: UInt64) {
        guard !diagnosticFinished else { return }
        let report = diagnostics
        diagnosticFinished = true
        diagnosticFramer.finish(now: now) { report(identity, $0) }
        diagnosticFD = nil
        diagnosticSource?.cancel()
        diagnosticSource = nil
    }

    enum ReadProgress {
        case more
        case blocked
        case end
        case failed(String)
    }

    func read(fd: Int32, receive: (UnsafeRawBufferPointer) -> Void) -> ReadProgress {
        var remaining = 65_536
        var attempts = 32
        while remaining > 0, attempts > 0 {
            attempts -= 1
            let count = readBuffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min(remaining, $0.count)) }
            if count > 0 {
                readBuffer.withUnsafeBytes { receive(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                remaining -= count
            } else if count == 0 { return .end }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return .blocked }
            else { return .failed("Provider pipe read failed: \(errno)") }
        }
        return .more
    }
}
