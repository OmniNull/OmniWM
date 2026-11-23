// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMMetadata

do {
    let encoder = JSONEncoder()
    var result = Data("{".utf8)
    for (index, path) in CommandLine.arguments.dropFirst().enumerated() {
        let source = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let document = try LuauLiteralMetadata.json(source, filename: path)
        if index != 0 { result.append(contentsOf: ",".utf8) }
        result.append(try encoder.encode(path))
        result.append(contentsOf: ":".utf8)
        result.append(document)
    }
    result.append(contentsOf: "}\n".utf8)
    try FileHandle.standardOutput.write(contentsOf: result)
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
