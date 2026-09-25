// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import UniformTypeIdentifiers

enum FileSuggestionsReader {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DuetExpertCenter/caches/ATXDocumentPredictorScores-DocumentSpotlight")

    static func read(from cacheURL: URL = defaultURL, acceptedTypes: [UTType] = [.item], limit: Int = 5)
        -> [LauncherFileResult]
    {
        guard limit > 0,
              let data = try? Data(contentsOf: cacheURL),
              let archive = decodedArchive(in: data),
              let root = referencedObject(archive.root, in: archive.objects) as? [String: Any],
              let list = referencedObject(root["predictedDocuments"], in: archive.objects) as? [String: Any],
              let entries = list["NS.objects"] as? [Any]
        else {
            return []
        }

        var seenPaths = Set<String>()
        var results: [LauncherFileResult] = []
        results.reserveCapacity(min(limit, entries.count))

        for reference in entries {
            guard let record = referencedObject(reference, in: archive.objects) as? [String: Any],
                  record["predictionType"] as? Int == 1,
                  let url = resolvedURL(for: record, objects: archive.objects)?.standardizedFileURL,
                  !isInTrash(url),
                  FileManager.default.fileExists(atPath: url.path),
                  seenPaths.insert(url.path).inserted
            else {
                continue
            }

            let values = try? url.resourceValues(forKeys: [
                .contentTypeKey,
                .isDirectoryKey,
                .localizedNameKey,
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey
            ])
            let contentType = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
            guard acceptedTypes.isEmpty || contentType.map({ type in
                acceptedTypes.contains { type.conforms(to: $0) }
            }) == true else {
                continue
            }

            results.append(LauncherFileResult(
                fileURL: url,
                displayName: values?.localizedName ?? url.lastPathComponent,
                contentTypeIdentifier: contentType?.identifier,
                isDirectory: values?.isDirectory ?? false,
                size: values?.fileSize.map(Int64.init),
                createdAt: values?.creationDate,
                modifiedAt: values?.contentModificationDate
            ))
            if results.count == limit { break }
        }
        return results
    }

    static func modificationDate(of cacheURL: URL = defaultURL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
    }

    static func filter(_ results: [LauncherFileResult], acceptedTypes: [UTType], limit: Int = 5)
        -> [LauncherFileResult]
    {
        Array(results.filter { result in
            let accepted = acceptedTypes.isEmpty || result.contentTypeIdentifier.flatMap(UTType.init).map { type in
                acceptedTypes.contains { type.conforms(to: $0) }
            } == true
            return accepted && FileManager.default.fileExists(atPath: result.fileURL.path)
        }.prefix(limit))
    }

    private static func decodedArchive(in data: Data) -> (objects: [Any], root: Any)? {
        guard let archive = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let xml = try? PropertyListSerialization.data(fromPropertyList: archive, format: .xml, options: 0)
        else {
            return nil
        }
        let normalized = String(decoding: xml, as: UTF8.self)
            .replacingOccurrences(of: "<key>CF$UID</key>", with: "<key>OmniWMUID</key>")
        guard let decoded = try? PropertyListSerialization.propertyList(from: Data(normalized.utf8), format: nil)
            as? [String: Any]
        else {
            return nil
        }
        guard let objects = decoded["$objects"] as? [Any],
              let top = decoded["$top"] as? [String: Any],
              let root = top["root"]
        else {
            return nil
        }
        return (objects, root)
    }

    private static func referencedObject(_ reference: Any?, in objects: [Any]) -> Any? {
        guard let reference = reference as? [String: Int],
              let index = reference["OmniWMUID"],
              objects.indices.contains(index)
        else {
            return nil
        }
        return objects[index]
    }

    private static func resolvedURL(for record: [String: Any], objects: [Any]) -> URL? {
        if let bookmark = referencedObject(record["bookmarkData"], in: objects) as? Data {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        guard let encodedURL = referencedObject(record["documentURL"], in: objects) as? [String: Any],
              let relative = referencedObject(encodedURL["NS.relative"], in: objects) as? String,
              let url = URL(string: relative),
              url.isFileURL
        else {
            return nil
        }
        return url
    }

    private static func isInTrash(_ url: URL) -> Bool {
        let components = url.pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }
}
