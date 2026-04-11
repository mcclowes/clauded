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
/// Socket I/O is isolated to this actor so the main thread never blocks on recv().
/// Decoded events hop back to `@MainActor` to mutate the registry.
///
/// The default socket path is `~/Library/Application Support/Clauded/daemon.sock`, but
/// tests can inject an alternate support directory via `init(supportDirectory:)` so
/// they never touch the user's real state.
actor HookDaemon {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "HookDaemon")

    /// Max size of a single datagram we'll accept. JSON payloads are tiny (a few hundred bytes);
    /// 64KB leaves enormous headroom for future fields without risk of truncation.
    private static let maxDatagramSize = 65536

    /// Default production location. Tests should construct a HookDaemon with an
    /// injected `supportDirectory` and call `HookDaemon.socketURL(in:)` / `pidFileURL(in:)`.
    static var defaultSupportDirectory: URL {
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fallback
        let dir = appSupport.appendingPathComponent("Clauded", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var socketURL: URL {
        socketURL(in: defaultSupportDirectory)
    }

    static var pidFileURL: URL {
        pidFileURL(in: defaultSupportDirectory)
    }

    static func socketURL(in directory: URL) -> URL {
        directory.appendingPathComponent("daemon.sock")
    }

    static func pidFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("daemon.pid")
    }

    private let supportDirectory: URL
    private var fileDescriptor: Int32 = -1
    private var pidFileDescriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let registry: InstanceRegistry
    private let decoder: JSONDecoder

    init(registry: InstanceRegistry, supportDirectory: URL = HookDaemon.defaultSupportDirectory) {
        self.registry = registry
        self.supportDirectory = supportDirectory
        decoder = HookEvent.makeDecoder()
    }

    var socketPath: String {
        Self.socketURL(in: supportDirectory).path
    }

    func start() {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        // Single-instance guard. Acquire an exclusive non-blocking flock on a pidfile
        // before touching the socket; if another Clauded is already running we bail out
        // rather than kidnapping its socket.
        let pidPath = Self.pidFileURL(in: supportDirectory).path
        let pidFD = open(pidPath, O_RDWR | O_CREAT, 0o600)
        guard pidFD >= 0 else {
            Self.logger.error("Could not open pidfile: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        if flock(pidFD, LOCK_EX | LOCK_NB) != 0 {
            Self.logger
                .warning("Another Clauded daemon already holds the pidfile lock — this instance will be idle")
            close(pidFD)
            return
        }
        pidFileDescriptor = pidFD

        let boundSocketPath = socketPath

        // Safe to unlink now that we hold the single-instance lock: no one else owns it.
        unlink(boundSocketPath)

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            Self.logger.error("socket() failed: \(String(cString: strerror(errno)), privacy: .public)")
            releasePidLock()
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = boundSocketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Self.logger.error("Socket path too long: \(boundSocketPath, privacy: .public)")
            close(fd)
            releasePidLock()
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
            releasePidLock()
            return
        }

        // Restrict the socket to the owning user only.
        chmod(boundSocketPath, 0o600)

        fileDescriptor = fd
        // Dedicated I/O queue keeps recv() off the main thread. The event handler hops
        // into this actor's executor via `Task { await self.drain() }`, which preserves
        // actor isolation for all state touches.
        let ioQueue = DispatchQueue(label: "com.mcclowes.clauded.HookDaemon.io", qos: .userInitiated)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.drain() }
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        self.source = source

        Self.logger.info("HookDaemon listening on \(boundSocketPath, privacy: .public)")
    }

    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
        unlink(socketPath)
        releasePidLock()
    }

    private func releasePidLock() {
        if pidFileDescriptor >= 0 {
            _ = flock(pidFileDescriptor, LOCK_UN)
            close(pidFileDescriptor)
            pidFileDescriptor = -1
        }
    }

    /// Exposed for tests: decode a single datagram and apply it to the registry as if it
    /// had been received on the socket. Avoids needing a real socket in unit tests.
    func ingest(datagram: Data) async {
        await process(datagram: datagram)
    }

    private func drain() async {
        // The read source coalesces multiple datagrams — loop until recv returns EAGAIN.
        var buffer = [UInt8](repeating: 0, count: Self.maxDatagramSize)
        while true {
            let received = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                recv(fileDescriptor, ptr.baseAddress, ptr.count, MSG_DONTWAIT)
            }
            if received > 0 {
                let data = Data(bytes: buffer, count: received)
                if received == Self.maxDatagramSize {
                    // Datagram likely truncated to buffer size. Drop it and warn.
                    Self.logger.error("Received maximum-size datagram; payload may be truncated")
                }
                await process(datagram: data)
                continue
            }
            if received == 0 {
                // Empty datagram. Nothing to decode, keep draining.
                continue
            }
            // received < 0
            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK {
                return
            }
            if err == EINTR {
                continue
            }
            Self.logger.error("recv() failed: \(String(cString: strerror(err)), privacy: .public)")
            return
        }
    }

    private func process(datagram: Data) async {
        do {
            let event = try decoder.decode(HookEvent.self, from: datagram)
            await MainActor.run {
                registry.apply(event: event)
            }
        } catch {
            let preview = String(data: datagram.prefix(256), encoding: .utf8) ?? "<binary>"
            Self.logger.error(
                "Failed to decode hook event: \(error.localizedDescription, privacy: .public) payload=\(preview, privacy: .public)"
            )
        }
    }
}
