// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import UniformTypeIdentifiers

struct ShellProviderActionRequest: Sendable {
    let name: String
    let arguments: Data
    let inputs: [ShellResourceID]
}

extension ShellResourceStore {
    func prepareProviderAction(
        _ key: ShellResourceLeaseKey,
        action: ShellProviderActionRequest,
        operation: ShellResourceOperation,
        completion: @escaping @Sendable (Result<Data, ShellResourceFailure>) -> Void
    ) {
        beginAction(key, inputs: action.inputs, operation: operation) { result in
            completion(result.flatMap { files in
                do { return .success(try ShellProviderResourceProtocol.action(
                    id: key.id.request,
                    name: action.name,
                    arguments: action.arguments,
                    files: files
                )) } catch { return .failure(ShellResourceFailure(String(describing: error))) }
            })
        }
    }

    func decodeProviderOutputs(_ data: Data) -> Result<ShellPreparedProviderOutputs, ShellResourceFailure> {
        do { return .success(try ShellProviderResourceProtocol.outputs(data)) }
        catch { return .failure(ShellResourceFailure("invalid_response")) }
    }
}

enum ShellProviderResourceProtocol {
    private struct Input: Encodable { let name: String
        let path: String
    }

    private struct Metadata: Encodable { let files: [Input]
        let outputDirectory: String
    }

    static func action(
        id: UInt64,
        name: String,
        arguments: Data,
        files: ShellResourceStore.ActionFiles
    ) throws -> Data {
        guard ShellProviderProtocol.validToken(name) else { throw ShellResourceFailure("invalid_provider_action") }
        let metadata = Metadata(
            files: files.files.map { Input(name: $0.name, path: $0.url.path) },
            outputDirectory: files.outputDirectory.path
        )
        let encoded = try JSONEncoder().encode(metadata)
        var result = Data("[\"action\",\"r\(id)\",\"\(name)\",".utf8)
        guard result.count + arguments.count + encoded.count + 3 <= ShellProviderProtocol.lineLimit else {
            throw ShellResourceFailure("provider_action_too_large")
        }
        result.append(arguments)
        result.append(44)
        result.append(encoded)
        result.append(contentsOf: [93, 10])
        return result
    }

    static func outputs(_ data: Data) throws -> ShellPreparedProviderOutputs {
        guard data.count <= ShellProviderProtocol.lineLimit,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object.count == 1,
              let entries = object["files"] as? [[String: Any]], entries.count <= ShellResourceStore.attachmentLimit
        else { throw ShellResourceFailure("invalid_response") }
        var files: [ShellResourceOutput] = []
        var descriptors: [ShellPickedResource] = []
        for entry in entries {
            guard entry.count == 2, let name = entry["name"] as? String, let path = entry["path"] as? String,
                  !name.isEmpty, name.utf8.count <= 1024, !name.contains("\0"),
                  !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0"), !path.hasPrefix("/"),
                  path.split(separator: "/", omittingEmptySubsequences: false)
                      .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            else { throw ShellResourceFailure("invalid_response") }
            files.append(ShellResourceOutput(name: name, path: path))
            let suffix = (name as NSString).pathExtension
            let uti = UTType(filenameExtension: suffix)?.identifier ?? UTType.data.identifier
            descriptors.append(ShellPickedResource(name: name, kind: "file", uti: uti))
        }
        return ShellPreparedProviderOutputs(files: files, descriptors: descriptors)
    }
}
