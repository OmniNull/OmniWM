// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

package enum LuauLiteralMetadata {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? {
            message
        }
    }

    package static func json(_ data: Data, filename: String) throws -> Data {
        var json = Data()
        var line: UInt32 = 1
        var error = [CChar](repeating: 0, count: Int(OMNI_CONFIG_ERROR_CAPACITY))
        let status = data.withUnsafeBytes { bytes in
            withUnsafeMutablePointer(to: &json) { output in
                omni_metadata_parse(
                    omni_config_span(data: bytes.bindMemory(to: CChar.self).baseAddress, length: bytes.count),
                    output,
                    { output, bytes, length in
                        output!.assumingMemoryBound(to: Data.self).pointee = Data(bytes: bytes!, count: length)
                    },
                    &line, &error, error.count
                )
            }
        }
        guard status == OMNI_OK else {
            let reason = String(decoding: error.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            throw Failure(message: "\(filename):\(line): \(reason)")
        }
        return json
    }
}
