import Darwin
import Foundation

// MARK: - clauded-notify

//
// Tiny CLI shipped inside Clauded.app/Contents/MacOS/ that Claude Code hooks invoke.
// It reads the hook's stdin JSON, enriches it with the event kind (argv[1]) and
// ambient env, and fire-and-forgets one datagram to the daemon socket.
//
// Performance contract: this runs on every Claude Code interaction. It MUST exit in
// well under 50ms and MUST NOT block when the daemon is down. That means:
//   - No Swift string allocations on the hot path where avoidable
//   - connect() uses SOCK_DGRAM (no handshake)
//   - send() is non-blocking; we don't care about delivery
//   - stdin is read with a hard ceiling so a misbehaving caller can't hang us
//
// Exit code is always 0 so we never block Claude Code.

private let maxStdinBytes = 64 * 1024

private func socketPath() -> String {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    return "\(home)/Library/Application Support/Clauded/daemon.sock"
}

private func readStdin() -> Data {
    // Read until EOF or the hard ceiling. The previous heuristic — "stop when a chunk
    // is smaller than 4 KB" — falsely terminated on slow writers that flushed partial
    // payloads, truncating the JSON. The only correct stop conditions are real EOF
    // (empty chunk) or the byte ceiling.
    let handle = FileHandle.standardInput
    var collected = Data()
    while collected.count < maxStdinBytes {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        collected.append(chunk)
    }
    return collected
}

private func extractSessionId(from stdinJSON: [String: Any]) -> String {
    if let id = stdinJSON["session_id"] as? String { return id }
    if let id = stdinJSON["sessionId"] as? String { return id }
    // Fall back to pid+projectDir so we still have a stable key.
    let pid = getppid()
    let project = ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"] ?? ""
    return "\(project):\(pid)"
}

private func extractMessage(from stdinJSON: [String: Any], kind: String) -> String? {
    if let msg = stdinJSON["message"] as? String { return msg }
    if let prompt = stdinJSON["prompt"] as? String { return String(prompt.prefix(200)) }
    if kind == "notification", let reason = stdinJSON["reason"] as? String { return reason }
    return nil
}

private func isoNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

private func sendDatagram(_ payload: Data) {
    let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }

    // Non-blocking so a full kernel buffer or missing daemon doesn't stall us.
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = socketPath()
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return }
    withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
        pathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
            _ = pathBytes.withUnsafeBufferPointer { src in
                memcpy(dest, src.baseAddress, pathBytes.count)
            }
        }
    }

    payload.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        _ = withUnsafePointer(to: &addr) { addrPtr -> Int in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                sendto(
                    fd,
                    base,
                    bytes.count,
                    0,
                    sockaddrPtr,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
    }
}

// MARK: - Entry

let args = CommandLine.arguments
guard args.count >= 2 else {
    // Silent exit — never want to spam Claude's stderr.
    exit(0)
}

let kind = args[1]

let stdinData = readStdin()
let stdinJSON = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] ?? [:]

let sessionId = extractSessionId(from: stdinJSON)
let projectDir = (stdinJSON["cwd"] as? String)
    ?? ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"]
    ?? ""
let pid = getppid()

var event: [String: Any] = [
    "kind": kind,
    "session_id": sessionId,
    "project_dir": projectDir,
    "pid": pid,
    "timestamp": isoNow(),
]
if let message = extractMessage(from: stdinJSON, kind: kind) {
    event["message"] = message
}

if let payload = try? JSONSerialization.data(withJSONObject: event, options: []) {
    sendDatagram(payload)
}

exit(0)
