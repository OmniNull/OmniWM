// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

extension ShellProvider {
    func consumeSignals() {
        defer { signals.finish() }
        guard let (identity, pending) = signals.take(), lifecycle.identity == identity else { return }
        if pending.contains(.exited), let process, !process.isRunning {
            perform(lifecycle.exited(identity, code: process.terminationStatus))
        }
        if pending.contains(.inputClosed) { perform(lifecycle.inputClosed(identity)) }
        if pending.contains(.kill) { perform(lifecycle.killDeadline(identity)) }
        if pending.contains(.writable) { flushInput(identity) }
        if pending.contains(.output) || lifecycle.phase == .draining { readOutput(identity) }
        if pending.contains(.diagnostic) || lifecycle.phase == .draining { readDiagnostics(identity) }
        finishDrain(identity)
    }

    func perform(_ effects: [ShellProviderLifecycle.Effect]) {
        for effect in effects {
            switch effect {
            case let .launch(identity, configuration):
                launch(identity, configuration: configuration)
            case let .running(identity):
                inbox.running(identity)
            case let .closeInput(identity):
                guard lifecycle.identity == identity else { continue }
                closeInput(identity)
            case let .terminate(identity):
                if lifecycle.identity == identity, let process, process.isRunning { process.terminate() }
            case let .armKill(identity):
                guard lifecycle.identity == identity else { continue }
                killSource?.cancel()
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now() + 2)
                let signals = signals
                source.setEventHandler { signals.post(.kill, identity: identity) }
                killSource = source
                source.resume()
            case let .cancelKill(identity):
                guard lifecycle.identity == identity else { continue }
                killSource?.cancel()
                killSource = nil
            case let .kill(identity):
                guard lifecycle.identity == identity, let process, process.isRunning else { continue }
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                killSource?.cancel()
                killSource = nil
            case let .ended(identity, status):
                inbox.end(identity, status: status)
            }
        }
        if lifecycle.isClosed {
            let waiters = closeWaiters
            closeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func launch(_ identity: ShellProviderIdentity, configuration: ShellProviderConfiguration) {
        signals.arm(identity)
        actions.activate(identity)
        guard inbox.activate(identity, configuration: configuration) else {
            actions.stop(identity)
            perform(lifecycle.launchFailed(identity, message: "Provider owner is no longer available"))
            inbox.incarnationDrained(identity)
            return
        }
        writer.removeAll()
        framer.reset()
        diagnosticFramer = ShellProviderDiagnostics()
        outputFinished = false
        diagnosticFinished = false
        discardOutput = false
        do {
            let spawned = try spawn(identity, configuration: configuration)
            process = spawned.process
            inputFD = spawned.input
            outputFD = spawned.output
            diagnosticFD = spawned.diagnostic
            let signals = signals
            let inputDescriptor = spawned.input
            let input = DispatchSource.makeWriteSource(fileDescriptor: spawned.input, queue: queue)
            input.setEventHandler { signals.post(.writable, identity: identity) }
            input.setCancelHandler {
                _ = Darwin.close(inputDescriptor)
                signals.post(.inputClosed, identity: identity)
            }
            inputSource = input
            inputResumed = false
            outputSource = readSource(fd: spawned.output, identity: identity, signal: .output)
            diagnosticSource = readSource(fd: spawned.diagnostic, identity: identity, signal: .diagnostic)
            if let cleanupError = spawned.cleanupError {
                fail(identity, message: cleanupError)
            } else {
                perform(lifecycle.launched(identity))
            }
        } catch {
            actions.stop(identity)
            perform(lifecycle.launchFailed(identity, message: error.localizedDescription))
            inbox.incarnationDrained(identity)
        }
    }

    func fail(_ identity: ShellProviderIdentity, message: String) {
        discardOutput = true
        perform(lifecycle.failed(identity, message: message))
    }

    func finishDrain(_ identity: ShellProviderIdentity) {
        guard lifecycle.identity == identity, lifecycle.phase == .draining, outputFinished,
              diagnosticFinished else { return }
        outputSource?.cancel()
        diagnosticSource?.cancel()
        outputSource = nil
        diagnosticSource = nil
        process = nil
        signals.arm(nil)
        inbox.incarnationDrained(identity)
        perform(lifecycle.drained(identity))
    }
}
