// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

public enum IPCWire {
    public static func makeEncoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    public static func encodeRequestLine(_ request: IPCRequest) throws -> Data {
        do {
            var writer = IPCJSONWriter(prettyPrinted: false)
            try writer.value(request)
            return writer.finishLine()
        } catch IPCJSONWriter.Failure.nonFiniteNumber {
            var data = try makeEncoder(prettyPrinted: false).encode(request)
            data.append(0x0A)
            return data
        }
    }

    public static func encodeResponseLine(_ response: IPCResponse, prettyPrinted: Bool = false) throws -> Data {
        do {
            var writer = IPCJSONWriter(prettyPrinted: prettyPrinted)
            try writer.value(response)
            return writer.finishLine()
        } catch IPCJSONWriter.Failure.nonFiniteNumber {
            var data = try makeEncoder(prettyPrinted: prettyPrinted).encode(response)
            data.append(0x0A)
            return data
        }
    }

    public static func encodeEventLine(_ event: IPCEventEnvelope, prettyPrinted: Bool = false) throws -> Data {
        do {
            var writer = IPCJSONWriter(prettyPrinted: prettyPrinted)
            try writer.value(event)
            return writer.finishLine()
        } catch IPCJSONWriter.Failure.nonFiniteNumber {
            var data = try makeEncoder(prettyPrinted: prettyPrinted).encode(event)
            data.append(0x0A)
            return data
        }
    }

    public static func decodeRequest(from data: Data) throws -> IPCRequest {
        try makeDecoder().decode(IPCRequest.self, from: data)
    }

    public static func decodeRequestEnvelope(from data: Data) -> IPCRequestEnvelope? {
        try? makeDecoder().decode(IPCRequestEnvelope.self, from: data)
    }

    public static func decodeResponse(from data: Data) throws -> IPCResponse {
        try makeDecoder().decode(IPCResponse.self, from: data)
    }

    public static func decodeEvent(from data: Data) throws -> IPCEventEnvelope {
        try makeDecoder().decode(IPCEventEnvelope.self, from: data)
    }
}
