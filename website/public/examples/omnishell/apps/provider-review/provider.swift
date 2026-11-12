// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

func emit(_ frame: [Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: frame)
    data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
}

try emit(["state", "summary", "Ready"])
while let line = readLine() {
    guard let frame = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any],
          frame.count == 4,
          frame[0] as? String == "action",
          let request = frame[1] as? String,
          let action = frame[2] as? String
    else { continue }
    try emit(["result", request, true, [:] as [String: Any]])
    if action == "check" {
        try emit(["event", "confirm-delete", ["itemId": "selected-item"]])
    }
}
