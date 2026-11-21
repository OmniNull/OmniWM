// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct DiagnosticsFile: Identifiable, Sendable, Equatable {
    let url: URL
    let name: String
    let sizeBytes: Int64
    let modified: Date

    var id: URL {
        url
    }
}

enum DiagnosticsFileScanner {
    static func scan(_ directory: URL) -> [DiagnosticsFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let keySet = Set(keys)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        )) ?? []
        return contents
            .compactMap { url -> DiagnosticsFile? in
                guard url.lastPathComponent.hasPrefix("omniwm-") else { return nil }
                let values = try? url.resourceValues(forKeys: keySet)
                guard values?.isRegularFile == true else { return nil }
                return DiagnosticsFile(
                    url: url,
                    name: url.lastPathComponent,
                    sizeBytes: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted {
                if $0.modified != $1.modified {
                    return $0.modified > $1.modified
                }
                return $0.name > $1.name
            }
    }
}
