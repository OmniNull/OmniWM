// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class DiagnosticsTraceCaptureTests: XCTestCase {
    @MainActor
    func testTraceCaptureToggleLifecycle() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        XCTAssertFalse(controller.isTraceCaptureActive)

        guard case .started = await controller.toggleTraceCapture(desiredState: .active) else {
            return XCTFail("expected capture to start")
        }
        XCTAssertTrue(controller.isTraceCaptureActive)
        XCTAssertNotNil(controller.traceCaptureStatus.startedAt)
        ShellNotificationTrace.record("test.capture.notification")

        guard case .noChange = await controller.toggleTraceCapture(desiredState: .active) else {
            return XCTFail("expected no change when already active")
        }

        guard case let .stopped(artifact) = await controller.toggleTraceCapture(desiredState: .inactive) else {
            return XCTFail("expected capture to stop and produce an artifact")
        }
        XCTAssertFalse(controller.isTraceCaptureActive)
        XCTAssertNil(controller.traceCaptureStatus.startedAt)
        let contents = try String(contentsOf: artifact.url, encoding: .utf8)
        XCTAssertTrue(contents.contains("== Shell Notification Trace =="))
        XCTAssertTrue(contents.contains("ev=test.capture.notification"))
    }

    @MainActor
    func testRuntimeDiagnosticsReportBuildsAllSections() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        let report = RuntimeDiagnosticsReport.build(controller, traceLimit: 50)

        for header in [
            "== OmniWM Diagnostics ==",
            "== Active Issues ==",
            "== Space Topology ==",
            "== Native Fullscreen Placeholders ==",
            "== Shell Notifications ==",
            "== Multitouch Source ==",
            "== AX Frame State ==",
            "== Settings (TOML) =="
        ] {
            XCTAssertTrue(report.contains(header), "missing report section \(header)")
        }
    }

    @MainActor
    func testStartRecordingWipesStaleTracesButPreservesCrashLogsAndUnrelatedFiles() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let staleTrace = directory.appendingPathComponent("omniwm-trace-1-2.log", isDirectory: false)
        let unrelated = directory.appendingPathComponent("unrelated.dat", isDirectory: false)
        let crashLog = directory.appendingPathComponent("omniwm-crash-1.log", isDirectory: false)
        try Data("stale".utf8).write(to: staleTrace)
        try Data("stale".utf8).write(to: unrelated)
        try Data("boom".utf8).write(to: crashLog)

        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        _ = await controller.toggleTraceCapture(desiredState: .active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTrace.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: crashLog.path))

        guard case let .stopped(artifact) = await controller.toggleTraceCapture(desiredState: .inactive) else {
            return XCTFail("expected capture to stop")
        }

        let traces = traceLogs(in: directory)
        XCTAssertEqual(traces, [artifact.url.lastPathComponent])
        XCTAssertFalse(traces.contains { $0.hasSuffix(".partial.log") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: crashLog.path))
    }

    @MainActor
    func testStartRecordingFailsCleanlyWhenDirectoryUnusable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDiagBlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocker", isDirectory: false)
        try Data("x".utf8).write(to: blocker)
        let unusable = blocker.appendingPathComponent("diagnostics", isDirectory: true)

        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: unusable)

        guard case .writeFailed = await controller.toggleTraceCapture(desiredState: .active) else {
            return XCTFail("expected .writeFailed when the diagnostics directory cannot be created")
        }
        XCTAssertFalse(controller.isTraceCaptureActive)
    }

    @MainActor
    func testOversizedPartialIsBoundedAndPreservedUntilSuccessfulFinalization() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TraceFinalizationGate()
        defer { gate.release() }
        let evidenceStarted = expectation(description: "automatic evidence started")
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [OversizedRuntimeTraceRecorder()]
        )

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            reportProvider: { String(repeating: "🪟", count: 400_000) },
            automaticEvidenceProvider: {
                evidenceStarted.fulfill()
                await gate.wait()
                return String(repeating: "é", count: 400_000)
            }
        ) else {
            return XCTFail("expected capture to start")
        }
        let partial = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
                .first { $0.lastPathComponent.hasSuffix(".partial.log") }
        )
        let partialData = try Data(contentsOf: partial)
        XCTAssertLessThanOrEqual(partialData.count, RuntimeTraceLimits.captureBytes)
        XCTAssertNotNil(String(data: partialData, encoding: .utf8))
        XCTAssertEqual(
            String(decoding: partialData, as: UTF8.self)
                .components(separatedBy: "== Trace Data Truncated ==").count - 1,
            1
        )

        let finalization = Task { @MainActor in
            await coordinator.toggle(desiredState: .inactive, reportProvider: { "unused" })
        }
        await fulfillment(of: [evidenceStarted], timeout: failureBound)

        XCTAssertEqual(try Data(contentsOf: partial), partialData)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix(".omniwm-trace-") && $0.hasSuffix(".tmp") }
        )

        gate.release()
        guard case let .stopped(artifact) = await finalization.value else {
            return XCTFail("expected capture to finalize")
        }
        let finalData = try Data(contentsOf: artifact.url)
        XCTAssertLessThanOrEqual(finalData.count, RuntimeTraceLimits.captureBytes)
        XCTAssertNotNil(String(data: finalData, encoding: .utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix(".omniwm-trace-") && $0.hasSuffix(".tmp") }
        )
    }

    @MainActor
    func testCallerCancellationDoesNotAbortAcceptedFinalization() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TraceFinalizationGate()
        defer { gate.release() }
        let evidenceStarted = expectation(description: "automatic evidence started")
        let coordinator = RuntimeTraceCaptureCoordinator(diagnosticsDirectory: directory, recorders: [])

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            reportProvider: { "report" },
            automaticEvidenceProvider: {
                evidenceStarted.fulfill()
                await gate.wait()
                return "evidence"
            }
        ) else {
            return XCTFail("expected capture to start")
        }

        let finalization = Task { @MainActor in
            await coordinator.toggle(desiredState: .inactive, reportProvider: { "unused" })
        }
        await fulfillment(of: [evidenceStarted], timeout: failureBound)
        XCTAssertEqual(coordinator.status.phase, .finalizing)

        finalization.cancel()
        XCTAssertTrue(finalization.isCancelled)
        gate.release()

        guard case let .stopped(artifact) = await finalization.value else {
            return XCTFail("expected canceled caller to receive completed finalization")
        }
        XCTAssertEqual(coordinator.status.phase, .idle)
        XCTAssertEqual(coordinator.status.lastArtifact, artifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
    }

    @MainActor
    func testStopLosingToAutomaticFinalizationCanDiscoverArtifactAfterIdle() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TraceFinalizationGate()
        defer { gate.release() }
        let evidenceStarted = expectation(description: "automatic evidence started")
        let finalized = expectation(description: "automatic finalization completed")
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [],
            captureSleeper: { _ in }
        )

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            reportProvider: { "report" },
            automaticEvidenceProvider: {
                evidenceStarted.fulfill()
                await gate.wait()
                return "evidence"
            }
        ) else {
            return XCTFail("expected capture to start")
        }
        await fulfillment(of: [evidenceStarted], timeout: failureBound)
        XCTAssertEqual(coordinator.status.phase, .finalizing)

        guard case .noChange = await coordinator.toggle(
            desiredState: .inactive,
            reportProvider: { "unused" }
        ) else {
            return XCTFail("expected automatic finalization to own the stop transition")
        }

        coordinator.onStateChange = {
            if coordinator.status.phase == .idle {
                finalized.fulfill()
            }
        }
        gate.release()
        await fulfillment(of: [finalized], timeout: failureBound)

        XCTAssertEqual(coordinator.status.phase, .idle)
        let artifact = try XCTUnwrap(coordinator.status.lastArtifact)
        XCTAssertEqual(artifact.profile, .problem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
    }

    @MainActor
    func testGlobalTraceBudgetPreservesLaterSectionHeadersAndIncompleteEvidence() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [
                OversizedRuntimeTraceRecorder(),
                SentinelRuntimeTraceRecorder()
            ]
        )

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            reportProvider: { "report" }
        ) else {
            return XCTFail("expected capture to start")
        }
        guard case let .stopped(artifact) = await coordinator.toggle(
            desiredState: .inactive,
            reportProvider: { "unused" }
        ) else {
            return XCTFail("expected capture to stop")
        }

        let data = try Data(contentsOf: artifact.url)
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        let laterHeader = try XCTUnwrap(body.range(of: "== Later Records =="))
        let laterBody = body[laterHeader.lowerBound...]

        XCTAssertLessThanOrEqual(data.count, RuntimeTraceLimits.captureBytes)
        XCTAssertTrue(body.contains("== Oversized Records =="))
        XCTAssertTrue(laterBody.contains("incomplete=true reason=file_byte_budget"))
        XCTAssertEqual(body.components(separatedBy: "== Trace Data Truncated ==").count - 1, 1)
    }

    @MainActor
    func testReplacementRecordingClearsLastArtifactAfterInitialPartialSucceeds() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = RuntimeTraceCaptureCoordinator(diagnosticsDirectory: directory, recorders: [])

        _ = await coordinator.toggle(desiredState: .active, reportProvider: { "report" })
        guard case let .stopped(first) = await coordinator.toggle(
            desiredState: .inactive,
            reportProvider: { "report" }
        ) else {
            return XCTFail("expected first capture artifact")
        }
        XCTAssertEqual(coordinator.status.lastArtifact, first)

        guard case .started = await coordinator.toggle(desiredState: .active, reportProvider: { "report" }) else {
            return XCTFail("expected replacement capture to start")
        }
        XCTAssertNil(coordinator.status.lastArtifact)

        _ = await coordinator.toggle(desiredState: .inactive, reportProvider: { "report" })
    }

    @MainActor
    func testFailedReplacementRecordingPreservesLastArtifact() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = RuntimeTraceCaptureCoordinator(diagnosticsDirectory: directory, recorders: [])

        _ = await coordinator.toggle(desiredState: .active, reportProvider: { "report" })
        guard case let .stopped(first) = await coordinator.toggle(
            desiredState: .inactive,
            reportProvider: { "report" }
        ) else {
            return XCTFail("expected first capture artifact")
        }
        try FileManager.default.removeItem(at: directory)
        try Data("blocker".utf8).write(to: directory)

        guard case .writeFailed = await coordinator.toggle(desiredState: .active, reportProvider: { "report" }) else {
            return XCTFail("expected replacement capture to fail")
        }
        XCTAssertEqual(coordinator.status.lastArtifact, first)
    }

    @MainActor
    func testSnapshotReportReplacesPriorReportWithoutCreatingZipOrSidecar() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = WMController(settings: makeSettingsStore(), diagnosticsDirectory: directory)

        let staleReport = directory.appendingPathComponent("omniwm-diagnostics-stale.log", isDirectory: false)
        let partial = directory.appendingPathComponent("omniwm-trace-1.partial.log", isDirectory: false)
        let trace = directory.appendingPathComponent("omniwm-trace-1-2.log", isDirectory: false)
        try Data("stale-report".utf8).write(to: staleReport)
        try Data("partial".utf8).write(to: partial)
        try Data("trace".utf8).write(to: trace)

        let report = try controller.writeDiagnosticsReport()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleReport.path), "prior report should be replaced")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trace.path), "completed trace should be preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "partial log should be preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))
        XCTAssertEqual(report.pathExtension, "log")
        XCTAssertFalse(
            (try FileManager.default.contentsOfDirectory(atPath: directory.path)).contains { $0.hasSuffix(".zip") }
        )
    }

    @MainActor
    func testSnapshotReportIncludesEffectiveSettingsWithoutRedaction() throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettingsStore()
        settings.focus.followsMouse = true

        let controller = WMController(settings: settings, diagnosticsDirectory: directory)
        let report = try controller.writeDiagnosticsReport()
        let content = try String(contentsOf: report, encoding: .utf8)

        XCTAssertTrue(content.contains("== Settings (TOML) =="))
        XCTAssertTrue(content.contains("followsMouse = true"))
        XCTAssertFalse(content.contains("<redacted>"), "redaction must not sneak back in")
    }

    @MainActor
    func testProblemCaptureReleasesRecorderStorageOnlyAfterTheFinalWrite() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Release Probe", capacity: 8) { $0 }
        let diagnosticsEventRecorder = DiagnosticsEventRecorder()
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [recorder],
            diagnosticsEventRecorder: diagnosticsEventRecorder
        )

        XCTAssertFalse(recorder.isStoragePrepared, "idle process must not hold trace ring storage")
        XCTAssertFalse(recorder.isSpareStoragePrepared, "idle process must not hold spare ring storage")

        _ = await coordinator.toggle(desiredState: .active, reportProvider: { "report" })
        XCTAssertTrue(recorder.isStoragePrepared)
        XCTAssertTrue(recorder.isSpareStoragePrepared)
        XCTAssertTrue(diagnosticsEventRecorder.isVerboseStoragePrepared)
        XCTAssertFalse(diagnosticsEventRecorder.isVerboseSpareStoragePrepared)
        recorder.record("release-probe-sentinel")
        diagnosticsEventRecorder.recordVerbose(name: "release-probe-verbose")

        guard case let .stopped(artifact) = await coordinator.toggle(
            desiredState: .inactive,
            reportProvider: { "report" }
        ) else {
            return XCTFail("expected capture to stop with an artifact")
        }

        let contents = try String(contentsOf: artifact.url, encoding: .utf8)
        XCTAssertTrue(
            contents.contains("release-probe-sentinel"),
            "records must survive into the artifact, so cleanup cannot run before the final write"
        )
        XCTAssertTrue(contents.contains("release-probe-verbose"))
        XCTAssertFalse(recorder.isStoragePrepared)
        XCTAssertFalse(recorder.isSpareStoragePrepared)
        XCTAssertFalse(diagnosticsEventRecorder.isVerboseStoragePrepared)
    }

    @MainActor
    func testFailedFinalWriteReleasesRecorderStorageAndStillReportsTheFailure() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Release Probe", capacity: 8) { $0 }
        let diagnosticsEventRecorder = DiagnosticsEventRecorder()
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [recorder],
            diagnosticsEventRecorder: diagnosticsEventRecorder
        )

        guard case .started = await coordinator.toggle(desiredState: .active, reportProvider: { "report" }) else {
            return XCTFail("expected capture to start")
        }
        let partial = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasSuffix(".partial.log") }
        )
        recorder.record("release-probe-sentinel")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        guard case .writeFailed = await coordinator.toggle(desiredState: .inactive, reportProvider: { "report" }) else {
            return XCTFail("expected the final write to fail")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix(".omniwm-trace-") && $0.hasSuffix(".tmp") }
        )
        XCTAssertFalse(recorder.isStoragePrepared)
        XCTAssertFalse(recorder.isSpareStoragePrepared)
        XCTAssertFalse(diagnosticsEventRecorder.isVerboseStoragePrepared)
        XCTAssertEqual(coordinator.status.phase, .idle)
    }

    @MainActor
    func testFailedInitialPartialWriteReleasesRecorderStorage() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Release Probe", capacity: 8) { $0 }
        let diagnosticsEventRecorder = DiagnosticsEventRecorder()
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [recorder],
            diagnosticsEventRecorder: diagnosticsEventRecorder
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        guard case .writeFailed = await coordinator.toggle(desiredState: .active, reportProvider: { "report" }) else {
            return XCTFail("expected the initial partial write to fail")
        }
        XCTAssertFalse(recorder.isStoragePrepared)
        XCTAssertFalse(recorder.isSpareStoragePrepared)
        XCTAssertFalse(diagnosticsEventRecorder.isVerboseStoragePrepared)
    }

    @MainActor
    func testPerformanceCaptureNeverPreparesDetailedRecorderStorage() async throws {
        let directory = try makeDiagnosticsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Release Probe", capacity: 8) { $0 }
        let diagnosticsEventRecorder = DiagnosticsEventRecorder()
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [recorder],
            diagnosticsEventRecorder: diagnosticsEventRecorder,
            processResourceProvider: { nil }
        )

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            profile: .performance,
            reportProvider: { "report" }
        ) else {
            return XCTFail("expected performance capture to start")
        }
        XCTAssertFalse(recorder.isStoragePrepared, "performance capture must not arm detailed trace rings")
        XCTAssertFalse(recorder.isSpareStoragePrepared)
        XCTAssertFalse(diagnosticsEventRecorder.isVerboseStoragePrepared)

        _ = await coordinator.toggle(
            desiredState: .inactive,
            profile: .performance,
            reportProvider: { "report" }
        )
        XCTAssertFalse(recorder.isStoragePrepared)
        XCTAssertFalse(recorder.isSpareStoragePrepared)
        XCTAssertFalse(diagnosticsEventRecorder.isVerboseStoragePrepared)
    }

    private func makeDiagnosticsDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDiagnosticsCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func traceLogs(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("omniwm-trace-") }
            .sorted()
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}

@MainActor
private final class TraceFinalizationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        if let continuation {
            continuation.resume()
            self.continuation = nil
        }
    }
}

private struct OversizedRuntimeTraceRecorder: RuntimeTraceRecording {
    let sectionTitle = "Oversized Records"

    func beginCapture() {}

    func endCapture() {}

    func dump() -> String {
        String(repeating: "x", count: RuntimeTraceLimits.captureBytes * 2)
    }

    func forEachLine(_ body: (String) -> Bool) {
        let line = String(repeating: "🪟", count: 1_024)
        let recordCount = RuntimeTraceLimits.captureBytes / (line.utf8.count + 1) + 2
        for _ in 0 ..< recordCount {
            guard body(line) else { return }
        }
    }
}

private struct SentinelRuntimeTraceRecorder: RuntimeTraceRecording {
    let sectionTitle = "Later Records"

    func beginCapture() {}

    func endCapture() {}

    func dump() -> String {
        "later-sentinel"
    }
}
