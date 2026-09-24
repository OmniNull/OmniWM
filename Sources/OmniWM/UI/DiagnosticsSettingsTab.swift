// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import SwiftUI

enum DiagnosticsActionStatus: Equatable {
    case idle
    case success(String)
    case failure(String)
}

func diagnosticsRecordingStartStatus(for outcome: TraceCaptureOutcome) -> DiagnosticsActionStatus {
    switch outcome {
    case .started:
        .success(String(localized: "Recording started"))
    case .noChange:
        .failure(String(localized: "A recording is already running"))
    case .stopped:
        .failure(String(localized: "Unexpected recording state"))
    case let .writeFailed(reason):
        .failure(reason)
    }
}

func privateAPIProbePresentationStatus(for report: PrivateAPIProbeReport) -> DiagnosticsActionStatus {
    let failures = report.selfTests.filter { $0.outcome == .failed }.count
    let checks = String(localized: "\(report.selfTests.count) checks, \(failures) failures")
    guard let foreign = report.foreign else {
        return .failure(failures == 0
            ? String(localized: "Inconclusive: \(checks) · no unmanaged foreign window probed")
            : String(localized: "\(checks) · no unmanaged foreign window probed"))
    }
    let moved = foreign.skylightMoved ? String(localized: "yes") : String(localized: "no")
    let restored = foreign.restored ? String(localized: "yes") : String(localized: "no")
    let foreignResult = String(localized: "foreign transaction move=\(moved), restored=\(restored)")
    guard failures == 0 else {
        return .failure(String(localized: "\(checks) · \(foreignResult)"))
    }
    switch foreign.outcome {
    case .works where foreign.skylightMoved && foreign.restored:
        return .success(String(localized: "\(checks) · \(foreignResult)"))
    case .inconclusive:
        return .failure(String(localized: "Inconclusive: \(checks) · \(foreignResult)"))
    case .works,
         .failed:
        return .failure(String(localized: "\(checks) · \(foreignResult)"))
    }
}

struct DiagnosticsSettingsTab: View {
    @Bindable var controller: WMController
    let navigation: SettingsNavigationModel

    @State private var traceStatus: DiagnosticsActionStatus = .idle
    @State private var probeStatus: DiagnosticsActionStatus = .idle
    @State private var isPrivateAPIProbeRunning = false
    @State private var recentFiles: [DiagnosticsFile] = []
    @State private var reloadToken = 0

    private var directory: URL {
        OmniWMStoragePaths.live.diagnosticsDirectory
    }

    var body: some View {
        Form {
            crashBannerSection
            DiagnosticsHealthSection(issues: controller.diagnosticsIssues)
            privateAPICapabilitySection
            recordingSection
            performanceRecordingSection
            SavedDiagnosticsSection(
                files: recentFiles,
                onRevealFolder: revealFolder,
                onRefresh: { reloadToken += 1 },
                copyFile: copyFile
            )
        }
        .formStyle(.grouped)
        .task(id: reloadToken) {
            let directory = directory
            recentFiles = await Task.detached { DiagnosticsFileScanner.scan(directory) }.value
            controller.refreshDiagnosticsIssues()
        }
        .onChange(of: controller.traceCaptureStatus.lastArtifact) { _, artifact in
            guard let artifact else { return }
            NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
            traceStatus = .success(
                artifact.profile == .performance
                    ? "Performance capture saved \(artifact.url.lastPathComponent)"
                    : "Recording saved \(artifact.url.lastPathComponent)"
            )
            reloadToken += 1
        }
    }

    @ViewBuilder
    private var crashBannerSection: some View {
        if let crash = controller.pendingCrashReport {
            Section {
                LabeledContent {
                    Button("Report Crash…") {
                        navigation.section = .reportIssue
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } label: {
                    Label("OmniWM recovered from a crash", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(crash.reason)
                    .font(.callout)
                SettingsCaption(localized: "Report it to open a pre-filled issue with the crash details.")
                HStack(spacing: 8) {
                    Button("Copy File") {
                        copyFile(crash.url)
                    }
                    .accessibilityLabel("Copy crash log file")
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([crash.url])
                    }
                    .accessibilityLabel("Reveal crash log in Finder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var privateAPICapabilitySection: some View {
        Section("Private-API Capability") {
            Button("Run Private-API Probe") {
                runPrivateAPIProbe()
            }
            .disabled(isPrivateAPIProbeRunning)
            DiagnosticsStatusLabel(status: probeStatus)
            SettingsCaption(
                localized: "On-demand check of every private window-server API on this Mac, confirming each actually works. It briefly nudges one unmanaged open window a few pixels and restores its verified starting position, so you may see a window jump for an instant. The full result is written into the Private API Capability section of your next diagnostics report."
            )
        }
    }

    @ViewBuilder
    private var recordingSection: some View {
        Section("Record a Problem") {
            switch controller.traceCaptureStatus.phase {
            case .idle:
                Button("Start Recording") {
                    startRecording()
                }
            case .starting:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        controller.traceCaptureStatus.profile == .problem
                            ? String(localized: "Starting diagnostics…")
                            : String(localized: "A performance capture is starting.")
                    )
                }
            case .recording:
                if controller.traceCaptureStatus.profile == .problem {
                    DiagnosticsRecordingProgress(startedAt: controller.traceCaptureStatus.startedAt)
                    Button("Stop & Save Recording") {
                        stopRecording()
                    }
                } else {
                    Text("A performance capture is running.")
                        .foregroundStyle(.secondary)
                }
            case .finalizing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finalizing diagnostics…")
                }
            }
            DiagnosticsStatusLabel(status: traceStatus)
            SettingsCaption(
                localized: "Start recording, reproduce one problem, then stop and attach the saved trace log. The app and window evidence is captured automatically. This detailed recording changes runtime work and must not be used for energy comparisons."
            )
        }
    }

    @ViewBuilder
    private var performanceRecordingSection: some View {
        Section("Measure Performance") {
            switch controller.traceCaptureStatus.phase {
            case .idle:
                Button("Start Performance Capture") {
                    startPerformanceCapture()
                }
            case .starting:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        controller.traceCaptureStatus.profile == .performance
                            ? String(localized: "Starting performance capture…")
                            : String(localized: "A detailed problem recording is starting.")
                    )
                }
            case .recording:
                if controller.traceCaptureStatus.profile == .performance {
                    Label("Performance capture in progress", systemImage: "gauge.with.dots.needle.67percent")
                    Button("Stop & Save Performance Capture") {
                        stopPerformanceCapture()
                    }
                } else {
                    Text("A detailed problem recording is running.")
                        .foregroundStyle(.secondary)
                }
            case .finalizing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finalizing capture…")
                }
            }
            SettingsCaption(
                localized: "Records aggregate operation counts, CPU energy, CPU time, wakeups and memory with one final write. It does not enable detailed event traces. Use Instruments or powermetrics separately to measure WindowServer and GPU energy."
            )
        }
    }

    private func runPrivateAPIProbe() {
        guard !isPrivateAPIProbeRunning else { return }
        isPrivateAPIProbeRunning = true
        Task {
            defer { isPrivateAPIProbeRunning = false }
            let report = await controller.runPrivateAPIProbe()
            probeStatus = privateAPIProbePresentationStatus(for: report)
        }
    }

    private func startRecording() {
        Task {
            let outcome = await controller.toggleTraceCapture(desiredState: .active)
            traceStatus = diagnosticsRecordingStartStatus(for: outcome)
        }
    }

    private func stopRecording() {
        Task {
            switch await controller.toggleTraceCapture(desiredState: .inactive) {
            case .stopped:
                break
            case let .writeFailed(reason):
                traceStatus = .failure(String(localized: "Failed to write the recording: \(reason)"))
            case .noChange:
                traceStatus = .failure(String(localized: "No recording is running"))
            case .started:
                traceStatus = .failure(String(localized: "Unexpected recording state"))
            }
        }
    }

    private func startPerformanceCapture() {
        Task {
            let outcome = await controller.toggleTraceCapture(
                desiredState: .active,
                profile: .performance
            )
            traceStatus = diagnosticsRecordingStartStatus(for: outcome)
        }
    }

    private func stopPerformanceCapture() {
        Task {
            switch await controller.toggleTraceCapture(
                desiredState: .inactive,
                profile: .performance
            ) {
            case .stopped:
                break
            case let .writeFailed(reason):
                traceStatus = .failure(String(localized: "Failed to write the performance capture: \(reason)"))
            case .noChange:
                traceStatus = .failure(String(localized: "No performance capture is running"))
            case .started:
                traceStatus = .failure(String(localized: "Unexpected capture state"))
            }
        }
    }

    private func revealFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private func copyFile(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }
}
