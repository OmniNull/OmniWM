// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
import OmniWMIPC

enum CLILauncherHelper {
    static func launch(socket path: String) throws -> Int32 {
        let request = try readRequest(from: path)
        try validate(request)
        let status = try run(request)
        try write(Data("\n\(request.exitStatusLabel) \(status).\n".utf8), to: STDOUT_FILENO)
        if request.holdOutput {
            try write(Data((request.holdPrompt + "\n").utf8), to: STDOUT_FILENO)
            try awaitReturn()
        }
        return status
    }

    static func environment(marker: String) throws -> Int32 {
        guard !marker.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        var output = Data((marker + "\0").utf8)
        var index = 0
        while let entry = environ[index] {
            output.append(Data(bytes: entry, count: strlen(entry) + 1))
            index += 1
        }
        try write(output, to: STDOUT_FILENO)
        return 0
    }

    private static func readRequest(from path: String) throws -> LauncherHelperRequest {
        let descriptor = try connectSocket(path: path)
        defer { close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { break }
            else if errno != EINTR { throw posixError() }
        }
        return try JSONDecoder().decode(LauncherHelperRequest.self, from: data)
    }

    private static func connectSocket(path: String) throws -> Int32 {
        guard !path.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            for (index, byte) in bytes.enumerated() { storage[index] = UInt8(bitPattern: byte) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError() }
        do {
            while true {
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                if connected == 0 || errno == EISCONN { return descriptor }
                if errno != EINTR { throw posixError() }
            }
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func validate(_ request: LauncherHelperRequest) throws {
        guard let executable = request.argv.first, !executable.isEmpty,
              !request.directory.isEmpty,
              !request.directory.utf8.contains(0),
              request.argv.allSatisfy({ !$0.utf8.contains(0) }),
              request.environment.allSatisfy({ key, value in
                  !key.isEmpty && !key.contains("=") && !key.utf8.contains(0) && !value.utf8.contains(0)
              })
        else { throw POSIXError(.EINVAL) }
    }

    private static func run(_ request: LauncherHelperRequest) throws -> Int32 {
        let inherited = ProcessInfo.processInfo.environment
        var environment = request.isolateEnvironment
            ? inherited.filter { LauncherHelperRequest.terminalEnvironmentKeys.contains($0.key) }
            : inherited
        environment.merge(request.environment) { _, captured in captured }
        var arguments = request.argv.map { strdup($0) } + [nil]
        var variables = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer {
            arguments.forEach { free($0) }
            variables.forEach { free($0) }
        }
        guard arguments.dropLast().allSatisfy({ $0 != nil }), variables.dropLast().allSatisfy({ $0 != nil }) else {
            throw POSIXError(.ENOMEM)
        }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addchdir(&actions, request.directory))
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGQUIT)
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
        let interrupt = signal(SIGINT, SIG_IGN)
        let quit = signal(SIGQUIT, SIG_IGN)
        defer {
            signal(SIGINT, interrupt)
            signal(SIGQUIT, quit)
        }
        var child: pid_t = 0
        let error = posix_spawn(&child, request.argv[0], &actions, &attributes, &arguments, &variables)
        guard error == 0 else {
            try write(Data((request.argv[0] + ": " + String(cString: strerror(error)) + "\n").utf8), to: STDERR_FILENO)
            return error == ENOENT ? 127 : 126
        }
        return try awaitExit(of: child)
    }

    private static func awaitExit(of child: pid_t) throws -> Int32 {
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 {
            if errno != EINTR { throw posixError() }
        }
        let terminationSignal = status & 0x7F
        return terminationSignal == 0 ? (status >> 8) & 0xFF : 128 + terminationSignal
    }

    private static func awaitReturn() throws {
        var byte: UInt8 = 0
        while true {
            let count = read(STDIN_FILENO, &byte, MemoryLayout.size(ofValue: byte))
            if count == 0 || (count > 0 && byte == 10) { return }
            if count < 0, errno != EINTR { throw posixError() }
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count == 0 { throw POSIXError(.EIO) }
                else if errno != EINTR { throw posixError() }
            }
        }
    }

    private static func check(_ error: Int32) throws {
        if error != 0 { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
