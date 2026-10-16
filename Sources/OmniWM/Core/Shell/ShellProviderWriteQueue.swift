// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellProviderWriteQueue {
    static let byteLimit = 1_048_576
    static let workByteLimit = 65_536
    static let workAttemptLimit = 32

    enum WriteResult {
        case written(Int)
        case interrupted
        case wouldBlock
        case failed(String)
    }

    enum Progress: Equatable {
        case empty
        case blocked
        case yielded
        case failed(String)
    }

    private struct Frame {
        let id: ShellServiceID
        let bytes: Data
        var offset = 0
    }

    private var frames: [Frame] = []
    private(set) var pendingBytes = 0

    var count: Int {
        frames.count
    }

    mutating func append(_ bytes: Data, id: ShellServiceID) throws {
        guard !bytes.isEmpty, bytes.count <= ShellProviderProtocol.lineLimit, bytes.last == 10 else {
            throw ShellProviderProtocol.Failure(message: "Invalid provider action frame")
        }
        guard bytes.count <= Self.byteLimit - pendingBytes else {
            throw ShellProviderProtocol.Failure(message: "Provider write backlog exceeds 1048576 bytes")
        }
        frames.append(Frame(id: id, bytes: bytes))
        pendingBytes += bytes.count
    }

    mutating func drain(write: (UnsafeRawBufferPointer) -> WriteResult) -> Progress {
        var bytesLeft = Self.workByteLimit
        var attemptsLeft = Self.workAttemptLimit
        while let first = frames.first {
            guard bytesLeft > 0, attemptsLeft > 0 else { return .yielded }
            let count = min(bytesLeft, first.bytes.count - first.offset)
            attemptsLeft -= 1
            let result = first.bytes.withUnsafeBytes { bytes in
                write(UnsafeRawBufferPointer(rebasing: bytes[first.offset ..< first.offset + count]))
            }
            switch result {
            case let .written(countWritten):
                guard countWritten > 0, countWritten <= count else { return .failed("Invalid provider write progress") }
                frames[0].offset += countWritten
                pendingBytes -= countWritten
                bytesLeft -= countWritten
                if frames[0].offset == frames[0].bytes.count { frames.removeFirst() }
            case .interrupted:
                continue
            case .wouldBlock:
                return .blocked
            case let .failed(error):
                return .failed(String(error.prefix(1024)))
            }
        }
        return .empty
    }

    @discardableResult
    mutating func cancel(_ id: ShellServiceID) -> Bool {
        guard let index = frames.firstIndex(where: { $0.id == id }), frames[index].offset == 0 else { return false }
        pendingBytes -= frames[index].bytes.count
        frames.remove(at: index)
        return true
    }

    mutating func discardUnsent(
        where shouldDiscard: (ShellServiceID) -> Bool,
        onDiscard: (ShellServiceID) -> Void = { _ in }
    ) -> Int {
        var discarded = 0
        frames.removeAll { frame in
            guard frame.offset == 0, shouldDiscard(frame.id) else { return false }
            discarded += frame.bytes.count
            onDiscard(frame.id)
            return true
        }
        pendingBytes -= discarded
        return discarded
    }

    mutating func removeAll() {
        frames.removeAll()
        pendingBytes = 0
    }
}
