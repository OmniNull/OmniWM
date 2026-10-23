// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct WindowAdmissionRulesSnapshots {
    private struct StoredRulesSnapshot {
        let snapshot: WindowClassificationRulesSnapshot
        let estimatedBytes: Int
    }

    private var rulesSnapshots: [UInt64: StoredRulesSnapshot] = [:]
    private var rulesSnapshotReferenceCounts: [UInt64: Int] = [:]
    private var rulesRevisionOrder: [UInt64] = []
    private var rulesSnapshotStorageOrder: [UInt64] = []

    mutating func update(for event: WindowAdmissionTraceEvent, evicting evicted: WindowAdmissionTraceRecord?) {
        if let revision = evicted?.observation?.rulesRevision,
           let count = rulesSnapshotReferenceCounts[revision]
        {
            if count == 1 {
                rulesSnapshotReferenceCounts.removeValue(forKey: revision)
                rulesSnapshots.removeValue(forKey: revision)
                rulesRevisionOrder.removeAll { $0 == revision }
                rulesSnapshotStorageOrder.removeAll { $0 == revision }
            } else {
                rulesSnapshotReferenceCounts[revision] = count - 1
            }
        }
        guard let observation = event.observation else { return }
        let revision = observation.rulesRevision
        if rulesSnapshotReferenceCounts[revision] == nil {
            rulesRevisionOrder.append(revision)
        }
        rulesSnapshotReferenceCounts[revision, default: 0] += 1
        if rulesSnapshots[revision] == nil,
           let snapshot = event.classificationRulesSnapshot
        {
            rulesSnapshots[revision] = StoredRulesSnapshot(
                snapshot: snapshot,
                estimatedBytes: snapshot.estimatedDiagnosticBytes
            )
            rulesSnapshotStorageOrder.append(revision)
        }
        enforceBudget()
    }

    private mutating func enforceBudget() {
        var storedBytes = rulesSnapshots.values.reduce(0) { $0 + $1.estimatedBytes }
        while storedBytes > RuntimeTraceLimits.cumulativeRulesSnapshotBytes {
            guard let oldestRevision = rulesSnapshotStorageOrder.first(where: {
                      rulesSnapshots[$0] != nil
                  }),
                  let removed = rulesSnapshots.removeValue(forKey: oldestRevision)
            else { return }
            storedBytes -= removed.estimatedBytes
            rulesSnapshotStorageOrder.removeAll { $0 == oldestRevision }
        }
    }

    func snapshot() -> WindowAdmissionRulesSnapshotOutput {
        WindowAdmissionRulesSnapshotOutput(
            rulesSnapshots: rulesRevisionOrder.compactMap { revision in
                rulesSnapshots[revision]?.snapshot
            },
            referencedRulesSnapshotCount: rulesSnapshotReferenceCounts.count,
            omittedRulesSnapshotCount: rulesSnapshotReferenceCounts.count - rulesSnapshots.count
        )
    }
}

struct WindowAdmissionRulesSnapshotOutput {
    let rulesSnapshots: [WindowClassificationRulesSnapshot]
    let referencedRulesSnapshotCount: Int
    let omittedRulesSnapshotCount: Int

    func forEachLine(using encoder: JSONEncoder, _ body: (String) -> Bool) -> Bool {
        let encodedSnapshots = rulesSnapshots.map { rulesSnapshot in
            rulesSnapshot.encodedLine(using: encoder)
        }
        var selectedLines: [String] = []
        var selectedBytes = 0
        for line in encodedSnapshots.reversed() {
            let candidateCount = selectedLines.count + 1
            let omittedCount = omittedRulesSnapshotCount
                + encodedSnapshots.count
                - candidateCount
            let markerBytes = omittedCount > 0
                ? rulesTruncationMarker(omittedCount: omittedCount).utf8.count + 1
                : 0
            let lineBytes = line.utf8.count + 1
            guard selectedBytes + lineBytes + markerBytes
                <= RuntimeTraceLimits.cumulativeRulesSnapshotBytes
            else {
                continue
            }
            selectedLines.append(line)
            selectedBytes += lineBytes
        }
        for line in selectedLines.reversed() {
            guard body(line) else { return false }
        }
        let omittedCount = referencedRulesSnapshotCount - selectedLines.count
        if omittedCount > 0 {
            let marker = rulesTruncationMarker(
                omittedCount: omittedCount
            )
            guard body(marker) else { return false }
        }
        return true
    }

    private func rulesTruncationMarker(omittedCount: Int) -> String {
        "{\"kind\":\"rules_snapshots_truncated\",\"omittedCount\":\(omittedCount)}"
    }
}
