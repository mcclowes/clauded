import Foundation

/// Hook event names forwarded by `clauded-notify`. These map 1:1 to Claude Code's
/// hook events; Clauded installs hooks for the subset it cares about.
enum HookEventKind: String, Codable {
    case sessionStart = "session-start"
    case sessionEnd = "session-end"
    case notification
    case stop
    case userPromptSubmit = "prompt"
}

/// Wire format written by `clauded-notify` to the daemon socket. One JSON object per line.
///
/// The shim enriches the raw hook stdin JSON with the event kind, pid, project dir,
/// and a timestamp so the daemon doesn't need to trust clocks or re-derive context.
struct HookEvent: Codable {
    let kind: HookEventKind
    let sessionId: String
    let projectDir: String
    let pid: Int32?
    let timestamp: Date
    let message: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case sessionId = "session_id"
        case projectDir = "project_dir"
        case pid
        case timestamp
        case message
    }

    /// Produces a decoder that accepts ISO-8601 timestamps both with and without
    /// fractional seconds. `JSONDecoder.DateDecodingStrategy.iso8601` only matches
    /// `.withInternetDateTime`, so a naive `.iso8601` will silently reject the
    /// `2026-04-10T12:00:00.000Z` timestamps the shim writes.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            // Build formatters per-call: ISO8601DateFormatter isn't Sendable, and the
            // allocation cost is dwarfed by the network/pipe latency of hook events.
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Not a recognisable ISO-8601 date: \(raw)"
            )
        }
        return decoder
    }
}
