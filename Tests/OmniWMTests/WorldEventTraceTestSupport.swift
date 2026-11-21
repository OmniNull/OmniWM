// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM

extension WorkspaceManager {
    private var recordedWorldEventLines: [Substring] {
        reconcileTraceDump().split(separator: "\n").filter { $0.hasPrefix("#") }
    }

    var recordedWorldEventCount: Int {
        recordedWorldEventLines.count
    }

    func worldEvents(after recorded: Int) -> [String] {
        let kept = ["event=", "label=", "workspace="]
        return recordedWorldEventLines.dropFirst(recorded).map { line in
            let fields = line.split(separator: " ").filter { field in kept.contains { field.hasPrefix($0) } }
            return fields.joined(separator: " ")
        }
    }

    func viewportMutationEvent(in workspaceId: WorkspaceDescriptor.ID) -> String {
        "event=user_command label=viewport_mutation workspace=\(workspaceId.uuidString)"
    }
}
