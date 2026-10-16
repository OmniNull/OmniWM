// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class TraceMetricsCaptureTests: XCTestCase {
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    func testProblemStartAcknowledgementWaitsForMetricsWithRecordersActive() async throws {
        let directory = makeDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Trace Metrics", capacity: 8) { $0 }
        let coordinator = makeCoordinator(directory: directory, recorder: recorder)
        let gate = Gate()
        defer { gate.release() }
        let began = expectation(description: "metrics begin entered")
        var acknowledged = false
        var ended = 0
        let start = Task { @MainActor in
            let result = await coordinator.toggle(
                desiredState: .active,
                reportProvider: { "report" },
                traceMetricsBegin: {
                    XCTAssertTrue(recorder.isActive)
                    XCTAssertEqual(coordinator.status.phase, .starting)
                    recorder.record("metrics-begin")
                    began.fulfill()
                    await gate.wait()
                    recorder.record("metrics-ready")
                },
                traceMetricsEnd: {
                    XCTAssertTrue(recorder.isActive)
                    ended += 1
                    recorder.record("metrics-end")
                }
            )
            acknowledged = true
            return result
        }
        await fulfillment(of: [began], timeout: 2)
        XCTAssertFalse(acknowledged)
        XCTAssertTrue(recorder.isActive)
        XCTAssertEqual(coordinator.status.phase, .starting)
        guard case .noChange = await coordinator.toggle(desiredState: .inactive, reportProvider: { "unused" }) else {
            return XCTFail("Starting retains exclusive ownership until its actual completion")
        }
        gate.release()
        guard case .started = await start.value else { return XCTFail("Expected completed metrics start") }
        XCTAssertTrue(acknowledged)
        guard case let .stopped(artifact) = await coordinator.toggle(
            desiredState: .inactive,
            reportProvider: { "unused" }
        ) else {
            return XCTFail("Expected normal stop")
        }
        XCTAssertEqual(ended, 1)
        let report = try String(contentsOf: artifact.url, encoding: .utf8)
        for sentinel in ["metrics-begin", "metrics-ready", "metrics-end"] {
            XCTAssertTrue(report.contains(sentinel), sentinel)
        }
    }

    func testFinalizationAwaitsMetricsExactlyOnceAndRetainsRecordsAfterCallerCancellation() async throws {
        let directory = makeDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Trace Metrics", capacity: 8) { $0 }
        let coordinator = makeCoordinator(directory: directory, recorder: recorder)
        let gate = Gate()
        defer { gate.release() }
        let ending = expectation(description: "metrics end entered")
        var ended = 0
        guard case .started = await coordinator.toggle(
            desiredState: .active,
            reportProvider: { "report" },
            traceMetricsEnd: {
                ended += 1
                XCTAssertTrue(recorder.isActive)
                XCTAssertEqual(coordinator.status.phase, .finalizing)
                recorder.record("metrics-before-drain")
                ending.fulfill()
                await gate.wait()
                recorder.record("metrics-after-drain")
            }
        ) else { return XCTFail("Expected start") }
        var returned = false
        let stop = Task { @MainActor in
            let result = await coordinator.toggle(desiredState: .inactive, reportProvider: { "unused" })
            returned = true
            return result
        }
        await fulfillment(of: [ending], timeout: 2)
        XCTAssertFalse(returned)
        XCTAssertTrue(recorder.isActive)
        XCTAssertTrue(recorder.isStoragePrepared)
        guard case .noChange = await coordinator.toggle(desiredState: .inactive, reportProvider: { "unused" }) else {
            return XCTFail("A competing stop cannot repeat metrics cleanup")
        }
        guard case .noChange = await coordinator.toggle(desiredState: .active, reportProvider: { "unused" }) else {
            return XCTFail("A new capture must wait for finalization")
        }
        stop.cancel()
        gate.release()
        guard case let .stopped(artifact) = await stop.value
        else { return XCTFail("Accepted finalization must complete") }
        XCTAssertEqual(ended, 1)
        XCTAssertTrue(returned)
        XCTAssertFalse(recorder.isActive)
        XCTAssertFalse(recorder.isStoragePrepared)
        let report = try String(contentsOf: artifact.url, encoding: .utf8)
        XCTAssertTrue(report.contains("metrics-before-drain"))
        XCTAssertTrue(report.contains("metrics-after-drain"))
    }

    func testFailedStartAwaitsMetricsCleanupExactlyOnceBeforeReturningIdle() async throws {
        let directory = makeDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocked)
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Trace Metrics", capacity: 8) { $0 }
        let coordinator = makeCoordinator(directory: blocked, recorder: recorder)
        let gate = Gate()
        defer { gate.release() }
        let ending = expectation(description: "failed start metrics end entered")
        var began = 0
        var ended = 0
        let start = Task { @MainActor in
            await coordinator.toggle(
                desiredState: .active,
                reportProvider: { "report" },
                traceMetricsBegin: {
                    began += 1
                    XCTAssertTrue(recorder.isActive)
                },
                traceMetricsEnd: {
                    ended += 1
                    XCTAssertTrue(recorder.isActive)
                    ending.fulfill()
                    await gate.wait()
                }
            )
        }
        await fulfillment(of: [ending], timeout: 2)
        XCTAssertEqual(coordinator.status.phase, .finalizing)
        XCTAssertTrue(recorder.isActive)
        guard case .noChange = await coordinator.toggle(desiredState: .inactive, reportProvider: { "unused" }) else {
            return XCTFail("Failed-start cleanup must own finalization")
        }
        gate.release()
        guard case .writeFailed = await start.value else { return XCTFail("Expected the original write failure") }
        XCTAssertEqual(began, 1)
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(coordinator.status.phase, .idle)
        XCTAssertFalse(recorder.isActive)
        XCTAssertFalse(recorder.isStoragePrepared)
        XCTAssertNil(coordinator.lastArtifact)
    }

    func testAutomaticFinalizationUsesTheSameAwaitedMetricsBoundary() async throws {
        let directory = makeDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Trace Metrics", capacity: 8) { $0 }
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [recorder],
            diagnosticsEventRecorder: DiagnosticsEventRecorder(),
            captureSleeper: { _ in }
        )
        let gate = Gate()
        defer { gate.release() }
        let ending = expectation(description: "automatic metrics end entered")
        let finalized = expectation(description: "automatic final artifact published")
        var ended = 0
        coordinator.onStateChange = { [weak coordinator] in
            if coordinator?.status.phase == .idle, coordinator?.lastArtifact != nil { finalized.fulfill() }
        }
        defer { coordinator.onStateChange = nil }
        guard case .started = await coordinator.toggle(
            desiredState: .active,
            reportProvider: { "report" },
            traceMetricsEnd: {
                ended += 1
                XCTAssertTrue(recorder.isActive)
                ending.fulfill()
                await gate.wait()
                recorder.record("automatic-metrics-end")
            }
        ) else { return XCTFail("Expected start") }
        await fulfillment(of: [ending], timeout: 5)
        XCTAssertEqual(coordinator.status.phase, .finalizing)
        XCTAssertNil(coordinator.lastArtifact)
        guard case .noChange = await coordinator.toggle(desiredState: .inactive, reportProvider: { "unused" }) else {
            return XCTFail("Automatic finalization must retain the stop transition")
        }
        gate.release()
        await fulfillment(of: [finalized], timeout: 2)
        XCTAssertEqual(ended, 1)
        let artifact = try XCTUnwrap(coordinator.lastArtifact)
        XCTAssertTrue(try String(contentsOf: artifact.url, encoding: .utf8).contains("automatic-metrics-end"))
        XCTAssertFalse(recorder.isStoragePrepared)
    }

    func testPerformanceCaptureDoesNotInvokeDetailedTraceMetrics() async throws {
        let directory = makeDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Trace Metrics", capacity: 8) { $0 }
        let coordinator = makeCoordinator(directory: directory, recorder: recorder)
        var began = 0
        var ended = 0
        guard case .started = await coordinator.toggle(
            desiredState: .active,
            profile: .performance,
            reportProvider: { "report" },
            performanceMetricsBegin: { began += 1 },
            performanceMetricsEnd: { ended += 1 },
            traceMetricsBegin: { XCTFail("Performance capture must not arm detailed metrics") },
            traceMetricsEnd: { XCTFail("Performance capture must not finish detailed metrics") }
        ) else { return XCTFail("Expected performance start") }
        XCTAssertFalse(recorder.isActive)
        guard case .stopped = await coordinator.toggle(desiredState: .inactive, reportProvider: { "unused" }) else {
            return XCTFail("Expected performance stop")
        }
        XCTAssertEqual(began, 1)
        XCTAssertEqual(ended, 1)
    }

    private func makeDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TraceMetrics-\(UUID().uuidString)")
    }

    private func makeCoordinator(
        directory: URL,
        recorder: SessionTraceRecorder<String>
    ) -> RuntimeTraceCaptureCoordinator {
        RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [recorder],
            diagnosticsEventRecorder: DiagnosticsEventRecorder()
        )
    }
}
