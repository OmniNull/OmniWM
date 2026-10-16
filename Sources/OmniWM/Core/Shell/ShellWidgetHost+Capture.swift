// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

extension ShellWidgetHost {
    static func sealTraceCapture() {
        if let context = ShellFrameTrace.shared.makeContext() { sealedTraceCapture = context.capture }
    }

    func joinTraceCapture() {
        guard let context = ShellFrameTrace.shared.makeContext(), context.capture != Self.sealedTraceCapture,
              traceCaptureContext?.capture != context.capture
        else { return }
        traceCaptureContext = context
        if let images = resources.resourceImages {
            traceImagesBegin = Task { await images.captureBegin(context.capture) }
        }
    }

    static func joinTraceCapture(_ package: ShellWidgetPackage) {
        guard let context = ShellFrameTrace.shared.makeContext(), context.capture != sealedTraceCapture else { return }
        _ = package.capture.request(packageContext(context, package), .begin(joined: true))
    }

    func beginTraceCapture() async {
        joinTraceCapture()
        guard let context = traceCaptureContext, context.capture != Self.sealedTraceCapture else { return }
        var requests = widgets.values.compactMap(\.package).map {
            $0.capture.request(Self.packageContext(context, $0), .begin(joined: false))
        }
        if let package = hiddenBarMenu?.tracePackage {
            requests.append(package.capture.request(Self.packageContext(context, package), .begin(joined: false)))
        }
        let images = traceImagesBegin
        for request in requests { _ = await request.wait() }
        await images?.value
    }

    func endTraceCapture() async {
        Self.sealTraceCapture()
        guard let context = traceCaptureContext else { return }
        traceCaptureContext = nil
        let images = resources.resourceImages
        let imageBegin = traceImagesBegin
        traceImagesBegin = nil
        var requests = widgets.values.compactMap(\.package).compactMap { package -> ShellCaptureRequest? in
            guard let joined = package.capture.context, joined.capture == context.capture else { return nil }
            return package.capture.request(joined, .end(retired: false))
        }
        if let package = hiddenBarMenu?.tracePackage,
           let joined = package.capture.context, joined.capture == context.capture
        {
            requests.append(package.capture.request(joined, .end(retired: false)))
        }
        for request in requests { _ = await request.wait() }
        await imageBegin?.value
        if let images, let capture = await images.captureEnd(context.capture) {
            Self.recordImageCapture(capture.detail, context: context, retired: false)
        }
    }

    static func retireTraceCapture(_ package: ShellWidgetPackage?) {
        guard let package, let context = package.capture.context else { return }
        let id = ObjectIdentifier(package)
        guard traceRetiringTasks[id] == nil else { return }
        let request = package.capture.request(context, .end(retired: true))
        traceRetiringTasks[id] = Task {
            _ = await request.wait()
            traceRetiringTasks.removeValue(forKey: id)
        }
    }

    func retireTraceImages(_ images: ShellResourceImages) -> Task<Void, Never>? {
        guard let context = traceCaptureContext else { return nil }
        traceCaptureContext = nil
        let begin = traceImagesBegin
        traceImagesBegin = nil
        let id = ObjectIdentifier(images)
        let task = Task {
            await begin?.value
            if let capture = await images.captureEnd(context.capture) {
                Self.recordImageCapture(capture.detail, context: context, retired: true)
            }
            Self.traceRetiringTasks.removeValue(forKey: id)
        }
        Self.traceRetiringTasks[id] = task
        return task
    }

    static func finishTraceRetirements() async {
        sealTraceCapture()
        while !traceRetiringTasks.isEmpty {
            for task in Array(traceRetiringTasks.values) { await task.value }
        }
    }

    private static func packageContext(
        _ context: ShellFrameTraceContext,
        _ package: ShellWidgetPackage
    ) -> ShellFrameTraceContext {
        var context = context
        context.widget = RuntimeTraceLimits.boundedString(package.name, maxBytes: 128)
        context.generation = package.generation
        return context
    }

    private static func recordImageCapture(_ detail: String, context: ShellFrameTraceContext, retired: Bool) {
        ShellFrameTrace.shared.record(.init(
            event: .counters,
            context: context,
            detail: "scope=resource_images boundary=\(retired ? "retire" : "end") " + detail
        ))
    }
}
