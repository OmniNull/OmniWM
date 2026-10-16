// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import Observation

enum TraceCaptureDesiredState {
    case active
    case inactive
    case toggle
}

enum TraceCaptureProfile: String, Equatable, Sendable {
    case problem
    case performance
}

enum TraceCapturePhase: Equatable {
    case idle
    case starting
    case recording
    case finalizing
}

struct TraceCaptureSession: Sendable {
    let profile: TraceCaptureProfile
    let startedAt: Date
    let startReport: String
    let processResourceStart: ProcessResourceSnapshot?
}

struct TraceCaptureArtifact: Equatable, Sendable {
    let profile: TraceCaptureProfile
    let url: URL
    let startedAt: Date
    let endedAt: Date
}

extension TraceCaptureArtifact {
    init(session: TraceCaptureSession, url: URL, endedAt: Date) {
        self.init(profile: session.profile, url: url, startedAt: session.startedAt, endedAt: endedAt)
    }
}

struct TraceCaptureStatus: Equatable {
    let phase: TraceCapturePhase
    let profile: TraceCaptureProfile?
    let startedAt: Date?
    let lastArtifact: TraceCaptureArtifact?

    var isActive: Bool {
        phase != .idle
    }
}

enum TraceCaptureOutcome {
    case started
    case stopped(TraceCaptureArtifact)
    case noChange
    case writeFailed(String)
}

@MainActor @Observable
final class RuntimeTraceCaptureCoordinator {
    private static let flushIntervalSeconds = 15
    private static let maxCaptureSeconds = 600

    private var phase: TraceCapturePhase = .idle
    private var startingProfile: TraceCaptureProfile?
    private var session: TraceCaptureSession?
    private var reportProvider: (() -> String)?
    private var automaticEvidenceProvider: (() async -> String)?
    private var performanceMetricsEnd: (() -> Void)?
    private var traceMetricsEnd: (() async -> Void)?
    private var captureTask: Task<Void, Never>?
    private var captureGeneration: UInt64 = 0
    private(set) var lastArtifact: TraceCaptureArtifact?
    var onStateChange: (() -> Void)?
    private let resources: TraceCaptureResources
    private let processResourceProvider: () -> ProcessResourceSnapshot?
    private let captureSleeper: @Sendable (Duration) async throws -> Void

    init(
        diagnosticsDirectory: URL = OmniWMStoragePaths.live.diagnosticsDirectory,
        recorders: [any RuntimeTraceRecording] = TraceCaptureResources.defaultRecorders,
        diagnosticsEventRecorder: DiagnosticsEventRecorder = .shared,
        processResourceProvider: @escaping () -> ProcessResourceSnapshot? = ProcessResourceSnapshot.capture,
        captureSleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        resources = TraceCaptureResources(
            diagnosticsDirectory: diagnosticsDirectory,
            recorders: recorders,
            diagnosticsEventRecorder: diagnosticsEventRecorder
        )
        self.processResourceProvider = processResourceProvider
        self.captureSleeper = captureSleeper
    }

    var isActive: Bool {
        phase != .idle
    }

    var status: TraceCaptureStatus {
        TraceCaptureStatus(
            phase: phase,
            profile: session?.profile ?? startingProfile,
            startedAt: session?.startedAt,
            lastArtifact: lastArtifact
        )
    }

    func toggle(
        desiredState: TraceCaptureDesiredState,
        profile: TraceCaptureProfile = .problem,
        reportProvider: @escaping () -> String,
        performanceMetricsBegin: @escaping () -> Void = {},
        performanceMetricsEnd: @escaping () -> Void = {},
        traceMetricsBegin: @escaping () async -> Void = {},
        traceMetricsEnd: @escaping () async -> Void = {},
        automaticEvidenceProvider: @escaping () async -> String = { "none" }
    ) async -> TraceCaptureOutcome {
        switch desiredState {
        case .active:
            guard phase == .idle else { return .noChange }
        case .inactive:
            return phase == .recording ? await stop() : .noChange
        case .toggle:
            guard phase == .idle else {
                return phase == .recording ? await stop() : .noChange
            }
        }
        return await start(
            profile: profile,
            hooks: Hooks(
                report: reportProvider,
                performanceBegin: performanceMetricsBegin,
                performanceEnd: performanceMetricsEnd,
                traceBegin: traceMetricsBegin,
                traceEnd: traceMetricsEnd,
                automaticEvidence: automaticEvidenceProvider
            )
        )
    }

    private struct Hooks {
        let report: () -> String
        let performanceBegin: () -> Void
        let performanceEnd: () -> Void
        let traceBegin: () async -> Void
        let traceEnd: () async -> Void
        let automaticEvidence: () async -> String
    }

    private func start(profile: TraceCaptureProfile, hooks: Hooks) async -> TraceCaptureOutcome {
        guard phase == .idle else { return .noChange }
        captureGeneration &+= 1
        let generation = captureGeneration
        startingProfile = profile
        phase = .starting
        onStateChange?()
        let startedAt = Date()
        resources.begin(for: profile, generation: generation)
        do {
            if profile == .problem {
                self.traceMetricsEnd = hooks.traceEnd
                await hooks.traceBegin()
            }
            if profile == .performance {
                try await resources.writer.preparePerformanceCapture()
            }
            guard captureGeneration == generation, phase == .starting, startingProfile == profile else {
                return .noChange
            }
            let session = makeSession(profile: profile, startedAt: startedAt, hooks: hooks)
            beginRecording(session: session, hooks: hooks)
            if profile == .problem {
                _ = try await resources.writer.writeInitialPartial(session: session, recorders: resources.recorders)
            }
            guard captureGeneration == generation,
                  phase == .recording,
                  self.session?.startedAt == session.startedAt
            else { return .noChange }
            if profile == .problem, lastArtifact?.profile == .problem {
                lastArtifact = nil
                onStateChange?()
            }
        } catch {
            guard captureGeneration == generation,
                  phase == .starting && startingProfile == profile
                  || phase == .recording && self.session?.profile == profile
            else { return .noChange }
            await abandonStart(profile: profile, generation: generation)
            return .writeFailed(error.localizedDescription)
        }

        startCaptureTask(profile: profile, generation: generation)
        return .started
    }

    private func beginRecording(session: TraceCaptureSession, hooks: Hooks) {
        reportProvider = hooks.report
        automaticEvidenceProvider = session.profile == .problem ? hooks.automaticEvidence : nil
        self.session = session
        startingProfile = nil
        phase = .recording
        onStateChange?()
    }

    private func makeSession(
        profile: TraceCaptureProfile,
        startedAt: Date,
        hooks: Hooks
    ) -> TraceCaptureSession {
        var sessionStartedAt = startedAt
        var processResourceStart: ProcessResourceSnapshot?
        if profile == .performance {
            hooks.performanceBegin()
            self.performanceMetricsEnd = hooks.performanceEnd
            sessionStartedAt = Date()
            processResourceStart = processResourceProvider()
        }
        let startReport = RuntimeTraceLimits.boundedString(
            hooks.report(),
            maxBytes: RuntimeTraceLimits.stateReportBytes
        )
        return TraceCaptureSession(
            profile: profile,
            startedAt: sessionStartedAt,
            startReport: startReport,
            processResourceStart: processResourceStart
        )
    }

    private func abandonStart(profile: TraceCaptureProfile, generation: UInt64) async {
        phase = .finalizing
        if profile == .problem {
            await finishTraceMetrics()
            guard captureGeneration == generation, phase == .finalizing else { return }
            resources.end(for: profile)
            resources.releaseStorage(for: profile)
        }
        startingProfile = nil
        self.session = nil
        self.reportProvider = nil
        self.automaticEvidenceProvider = nil
        self.performanceMetricsEnd = nil
        phase = .idle
        onStateChange?()
    }

    private func finishTraceMetrics() async {
        let end = traceMetricsEnd
        traceMetricsEnd = nil
        await end?()
    }

    private func startCaptureTask(profile: TraceCaptureProfile, generation: UInt64) {
        let sleeper = captureSleeper
        captureTask = Task { [weak self] in
            if profile == .problem {
                let maxFlushes = Self.maxCaptureSeconds / Self.flushIntervalSeconds
                for _ in 0 ..< maxFlushes {
                    do {
                        try await sleeper(.seconds(Self.flushIntervalSeconds))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, let self else { return }
                    await self.writePartial(generation: generation)
                }
            } else {
                do {
                    try await sleeper(.seconds(Self.maxCaptureSeconds))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            guard self.captureGeneration == generation else { return }
            self.captureTask = nil
            _ = await self.finalize(generation: generation)
        }
    }

    private func stop() async -> TraceCaptureOutcome {
        let activeTask = captureTask
        captureTask = nil
        activeTask?.cancel()
        return await finalize(generation: captureGeneration)
    }

    private func finalize(generation: UInt64) async -> TraceCaptureOutcome {
        guard captureGeneration == generation, phase == .recording, let session else { return .noChange }
        let processResourceEnd: ProcessResourceSnapshot?
        if session.profile == .performance {
            performanceMetricsEnd?()
            performanceMetricsEnd = nil
            processResourceEnd = processResourceProvider()
        } else {
            processResourceEnd = nil
        }
        var endedAt = Date()
        phase = .finalizing
        onStateChange?()

        if session.profile == .problem {
            await finishTraceMetrics()
            guard captureGeneration == generation, phase == .finalizing else { return .noChange }
            endedAt = Date()
        }
        resources.end(for: session.profile)
        let endReport = RuntimeTraceLimits.boundedString(
            reportProvider?() ?? "report unavailable",
            maxBytes: RuntimeTraceLimits.stateReportBytes
        )
        let evidenceProvider = automaticEvidenceProvider
        reportProvider = nil
        automaticEvidenceProvider = nil

        defer {
            if captureGeneration == generation {
                resources.releaseStorage(for: session.profile)
            }
        }

        return await finishFinalization(
            session: session,
            generation: generation,
            report: FinalReport(
                endedAt: endedAt,
                processResourceEnd: processResourceEnd,
                report: endReport,
                evidenceProvider: evidenceProvider
            )
        )
    }
}

extension RuntimeTraceCaptureCoordinator {
    private struct FinalReport {
        let endedAt: Date
        let processResourceEnd: ProcessResourceSnapshot?
        let report: String
        let evidenceProvider: (() async -> String)?
    }

    private func finishFinalization(
        session: TraceCaptureSession, generation: UInt64, report: FinalReport
    ) async -> TraceCaptureOutcome {
        do {
            let url = try await writeFinalArtifact(
                for: session,
                endedAt: report.endedAt,
                processResourceEnd: report.processResourceEnd,
                endReport: report.report,
                evidenceProvider: report.evidenceProvider
            )
            guard captureGeneration == generation, phase == .finalizing else { return .noChange }
            let artifact = TraceCaptureArtifact(session: session, url: url, endedAt: report.endedAt)
            lastArtifact = artifact
            self.session = nil
            phase = .idle
            onStateChange?()
            return .stopped(artifact)
        } catch {
            guard captureGeneration == generation else { return .noChange }
            self.session = nil
            phase = .idle
            onStateChange?()
            return .writeFailed(error.localizedDescription)
        }
    }

    private func writeFinalArtifact(
        for session: TraceCaptureSession,
        endedAt: Date,
        processResourceEnd: ProcessResourceSnapshot?,
        endReport: String,
        evidenceProvider: (() async -> String)?
    ) async throws -> URL {
        if session.profile == .performance {
            let processResourceDelta = session.processResourceStart.flatMap { start in
                processResourceEnd.flatMap { start.delta(to: $0) }
            }
            return try await resources.writer.writePerformanceFinal(
                session: session,
                endedAt: endedAt,
                processResourceDelta: processResourceDelta,
                endReport: endReport
            )
        } else {
            let automaticEvidence = RuntimeTraceLimits.boundedString(
                await evidenceProvider?() ?? "none",
                maxBytes: RuntimeTraceLimits.automaticEvidenceBytes
            )
            return try await resources.writer.writeFinal(
                session: session,
                endedAt: endedAt,
                recorders: resources.recorders,
                automaticEvidence: automaticEvidence,
                endReport: endReport
            )
        }
    }

    private func writePartial(generation: UInt64) async {
        guard captureGeneration == generation,
              phase == .recording,
              let session,
              session.profile == .problem
        else { return }
        _ = try? await resources.writer.writePartial(session: session, recorders: resources.recorders)
    }
}
