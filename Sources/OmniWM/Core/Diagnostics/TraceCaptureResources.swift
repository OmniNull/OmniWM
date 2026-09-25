// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
struct TraceCaptureResources {
    static let defaultRecorders: [any RuntimeTraceRecording] = [
        AppVisibilityTrace.shared,
        NativeFullscreenPlaceholderTrace.shared,
        NativeFullscreenPlaceholderTrace.motion,
        WindowAdmissionTrace.shared,
        AnimationTickTrace.shared,
        EventIntakeTrace.shared,
        MainThreadAXSpanTrace.shared,
        RawAXNotificationTrace.shared,
        FrameApplyTrace.shared,
        NiriLayoutTrace.shared,
        ParkVisibilityAudit.shared,
        ScrollTickTrace.shared,
        AXWriteLatencyTrace.shared,
        OverviewFrameTrace.shared,
        BorderOpMetricsRecorder.shared,
        MouseTrace.shared,
        TrackpadScrollTrace.shared,
        InputTrace.shared
    ]

    let recorders: [any RuntimeTraceRecording]
    private let diagnosticsEventRecorder: DiagnosticsEventRecorder
    let writer: TraceCaptureFileWriter

    init(
        diagnosticsDirectory: URL,
        recorders: [any RuntimeTraceRecording],
        diagnosticsEventRecorder: DiagnosticsEventRecorder
    ) {
        writer = TraceCaptureFileWriter(
            diagnosticsDirectory: diagnosticsDirectory,
            diagnosticsEventRecorder: diagnosticsEventRecorder
        )
        self.recorders = recorders
        self.diagnosticsEventRecorder = diagnosticsEventRecorder
    }

    func begin(for profile: TraceCaptureProfile, generation: UInt64) {
        if profile == .problem {
            diagnosticsEventRecorder.beginVerboseCapture()
            recorders.forEach { $0.beginCapture() }
            FrameEffectTraceContext.beginCapture(generation: generation)
            FrameEffectObservationTracker.shared.beginCapture(generation: generation)
        }
    }

    func end(for profile: TraceCaptureProfile) {
        if profile == .problem {
            FrameEffectObservationTracker.shared.endCapture()
            FrameEffectTraceContext.endCapture()
            diagnosticsEventRecorder.endVerboseCapture()
            recorders.forEach { $0.endCapture() }
        }
    }

    func releaseStorage(for profile: TraceCaptureProfile) {
        if profile == .problem {
            diagnosticsEventRecorder.releaseVerboseStorage()
        }
        recorders.forEach { $0.releaseStorage() }
    }
}
