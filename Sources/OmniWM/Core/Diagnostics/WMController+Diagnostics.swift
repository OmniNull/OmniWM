// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
extension WMController {
    func refreshDiagnosticsIssues() {
        diagnosticsIssues = DiagnosticsIssueAggregator.applicableIssues(controller: self)
    }

    func diagnosticsReportText(traceLimit: Int = 200) -> String {
        RuntimeDiagnosticsReport.build(self, traceLimit: traceLimit)
    }

    @discardableResult
    func writeDiagnosticsReport(traceLimit: Int = 200) throws -> URL {
        let directory = diagnosticsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "omniwm-diagnostics-\(Int(Date().timeIntervalSince1970 * 1000)).log"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try diagnosticsReportText(traceLimit: traceLimit).write(to: url, atomically: true, encoding: .utf8)
        DiagnosticsRetention.wipe(directory: directory, prefixes: ["omniwm-diagnostics-"], except: [url])
        return url
    }
}
