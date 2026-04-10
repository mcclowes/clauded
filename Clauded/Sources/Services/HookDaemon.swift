import Darwin
import Foundation
import os

/// Unix domain datagram socket listener that receives hook events from `clauded-notify`.
///
/// Why datagrams not streams: each hook invocation is a single self-contained JSON
/// message. Datagrams preserve message boundaries atomically, which means the shim
/// never has to buffer, frame, or reconnect. Hook firing latency is the whole ball
/// game here — we need to minimise it or every Claude interaction gets slower.
///
/// The socket path is `~/Library/Application Support/Clauded/daemon.sock`. The same
/// path is baked into `clauded-notify` at build time via the shared
/// `HookDaemon.socketURL` helper.
@MainActor
final class HookDaemon {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "HookDaemon")

    /// Max size of a single datagram we'll accept. JSON payloads are tiny (a few hundred bytes);
    /// 64KB leaves enormous headroom for future fields without risk of truncation.
    private static let maxDatagramSize = 65536

    static var socketURL: URL {
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fallback
        let dir = appSupport.appendingPathComponent("Clauded", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("daemon.sock")
    }

    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let registry: InstanceRegistry
    private let decoder: JSONDecoder

    init(registry: InstanceRegistry) {
        self.registry = registry
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func start() {
        let socketPath = Self.socketURL.path

        // Unlink any stale socket from a previous run. bind(2) will fail with EADDRINUSE
        // otherwise, even if no process is listening.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            Self.logger.error("socket() failed: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Self.logger.error("Socket path too long: \(socketPath, privacy: .public)")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dest, src.baseAddress, pathBytes.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            Self.logger.error("bind() failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return
        }

        // Permissive perms on the socket itself (user-only).
        chmod(socketPath, 0o600)

        fileDescriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        self.source = source

        Self.logger.info("HookDaemon listening on \(socketPath, privacy: .public)")
    }

    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
        unlink(Self.socketURL.path)
    }

    private func drain() {
        // The read source coalesces multiple datagrams — loop until recvfrom returns EAGAIN.
        var buffer = [UInt8](repeating: 0, count: Self.maxDatagramSize)
        while true {
            let received = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                recv(fileDescriptor, ptr.baseAddress, ptr.count, MSG_DONTWAIT)
            }
            if received <= 0 {
                return
            }
            let data = Data(bytes: buffer, count: received)
            process(datagram: data)
        }
    }

    private func process(datagram: Data) {
        do {
            let event = try decoder.decode(HookEvent.self, from: datagram)
            registry.apply(event: event)
        } catch {
            let preview = String(data: datagram.prefix(256), encoding: .utf8) ?? "<binary>"
            Self.logger.error(
                "Failed to decode hook event: \(error.localizedDescription, privacy: .public) payload=\(preview, privacy: .public)"
            )
        }
    }
}
