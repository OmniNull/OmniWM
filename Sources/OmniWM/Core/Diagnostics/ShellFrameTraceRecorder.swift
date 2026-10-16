// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore
import Synchronization

struct ShellFrameTraceContext: Equatable, Sendable {
    let capture: UInt64
    let id: UInt64
    var parent: UInt64 = 0
    var widget = ""
    var generation = 0
    var display: CGDirectDisplayID = 0
    var placement = ""
    var slice = ""
    var view = ""
}

enum ShellFrameTrace {
    @TaskLocal static var context: ShellFrameTraceContext?
    static let shared = ShellFrameTraceRecorder()

    static var current: ShellFrameTraceContext? {
        shared.isActive ? context : nil
    }
}

final class ShellFrameTraceRecorder: RuntimeTraceRecording, Sendable {
    enum Event: String, Sendable {
        case input, enqueue, packageWake, handlerStart, handlerEnd, render, outboxDrain, coalesced
        case applyStart, applyEnd, engineSubmit, engineCommit, frameEstimate, counters
    }

    struct Record: Sendable {
        let event: Event
        let context: ShellFrameTraceContext
        var time = CACurrentMediaTime()
        var duration: Double = 0
        var cpuNs: UInt64 = 0
        var encodeCpuNs: UInt64 = 0
        var vmBytes = 0
        var count = 0
        var inputTimestamp: Double = 0
        var targetTimestamp: Double = 0
        var status = 0
        var detail = ""
    }

    private struct Pending {
        var commits: [Record] = []
        var dropped = 0
    }

    let sectionTitle = "Shell Frame Timing"
    private let recorder: SessionTraceRecorder<Record>
    private let activeCapture = Atomic<UInt64>(0)
    private let nextCapture = Atomic<UInt64>(0)
    private let nextID = Atomic<UInt64>(0)
    private let pending = Mutex(Pending())
    private let pendingLimit: Int

    init(capacity: Int = 8192, pendingLimit: Int = 1024) {
        self.pendingLimit = pendingLimit
        recorder = SessionTraceRecorder(sectionTitle: sectionTitle, capacity: capacity) { record in
            let context = record.context
            return "event=\(record.event.rawValue) capture=\(context.capture) id=\(context.id) parent=\(context.parent)"
                + " widget=\(context.widget) generation=\(context.generation) display=\(context.display) view=\(context.view)"
                + " placement=\(context.placement) slice=\(context.slice)"
                + String(
                    format: " t=%.9f duration_ms=%.6f input_t=%.9f estimated_target_t=%.9f",
                    record.time,
                    record.duration * 1000,
                    record.inputTimestamp,
                    record.targetTimestamp
                )
                + " cpu_ns=\(record.cpuNs) encode_cpu_ns=\(record.encodeCpuNs) vm_bytes=\(record.vmBytes)"
                + " count=\(record.count) status=\(record.status) \(record.detail)"
        }
    }

    var isActive: Bool {
        activeCapture.load(ordering: .acquiring) != 0
    }

    var isStoragePrepared: Bool {
        recorder.isStoragePrepared
    }

    var pendingCount: Int {
        pending.withLock { $0.commits.count }
    }

    func makeContext(parent: ShellFrameTraceContext? = nil) -> ShellFrameTraceContext? {
        let capture = activeCapture.load(ordering: .acquiring)
        guard capture != 0 else { return nil }
        return ShellFrameTraceContext(
            capture: capture,
            id: nextID.wrappingAdd(1, ordering: .relaxed).newValue,
            parent: parent?.capture == capture ? parent?.id ?? 0 : 0
        )
    }

    func record(_ event: Event, context: ShellFrameTraceContext? = ShellFrameTrace.current) {
        guard let context, context.capture == activeCapture.load(ordering: .acquiring) else { return }
        record(Record(event: event, context: context))
    }

    func record(_ record: Record) {
        guard record.context.capture == activeCapture.load(ordering: .acquiring) else { return }
        pending.withLock { _ in
            guard record.context.capture == activeCapture.load(ordering: .acquiring) else { return }
            recorder.record(record)
        }
    }

    func commit(_ context: ShellFrameTraceContext?, time: Double) {
        guard let context, context.capture == activeCapture.load(ordering: .acquiring) else { return }
        let record = Record(event: .engineCommit, context: context, time: time)
        self.record(record)
        guard context.display != 0 else { return }
        pending.withLock {
            guard context.capture == activeCapture.load(ordering: .acquiring) else { return }
            guard $0.commits.count < pendingLimit else {
                $0.dropped += 1
                return
            }
            $0.commits.append(record)
        }
    }

    func estimate(display: CGDirectDisplayID, targetTimestamp: Double) {
        guard isActive else { return }
        let ready = pending.withLock { pending in
            let ready = pending.commits.filter {
                $0.context.display == display && $0.time < targetTimestamp
            }
            pending.commits.removeAll {
                $0.context.display == display && $0.time < targetTimestamp
            }
            return ready
        }
        for commit in ready {
            record(Record(
                event: .frameEstimate,
                context: commit.context,
                duration: targetTimestamp - commit.time,
                targetTimestamp: targetTimestamp,
                detail: "estimate_only=true"
            ))
        }
    }

    func beginCapture() {
        activeCapture.store(0, ordering: .releasing)
        pending.withLock {
            $0 = Pending()
            recorder.beginCapture()
            activeCapture.store(nextCapture.wrappingAdd(1, ordering: .relaxed).newValue, ordering: .releasing)
        }
    }

    func endCapture() {
        activeCapture.store(0, ordering: .releasing)
        pending.withLock {
            $0.commits.removeAll()
            recorder.endCapture()
        }
    }

    func releaseStorage() {
        pending.withLock {
            recorder.releaseStorage()
            $0 = Pending()
        }
    }

    func dump() -> String {
        var lines: [String] = []
        forEachLine { lines.append($0)
            return true
        }
        return lines.joined(separator: "\n")
    }

    func forEachLine(_ body: (String) -> Bool) {
        let dropped = pending.withLock { $0.dropped }
        if dropped > 0, !body("incomplete_estimates=true dropped=\(dropped)") { return }
        recorder.forEachLine(body)
    }
}

@MainActor
final class ShellFrameTraceDisplayLink: NSObject {
    private static var active: [CGDirectDisplayID: ShellFrameTraceDisplayLink] = [:]
    private let display: CGDirectDisplayID
    private var link: CADisplayLink?

    private init(display: CGDirectDisplayID) {
        self.display = display
    }

    static var count: Int {
        active.count
    }

    static func prepare(screen: NSScreen?) {
        guard ShellFrameTrace.shared.isActive, let screen, let display = screen.displayId,
              active[display] == nil
        else { return }
        let driver = ShellFrameTraceDisplayLink(display: display)
        let link = screen.displayLink(target: driver, selector: #selector(tick(_:)))
        driver.link = link
        active[display] = driver
        link.add(to: .main, forMode: .common)
    }

    static func stop() {
        for driver in active.values {
            driver.link?.invalidate()
            driver.link = nil
        }
        active.removeAll()
    }

    @objc private func tick(_ link: CADisplayLink) {
        ShellFrameTrace.shared.estimate(display: display, targetTimestamp: link.targetTimestamp)
    }
}
