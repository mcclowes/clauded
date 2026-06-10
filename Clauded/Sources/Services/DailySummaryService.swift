import Foundation
import Observation

/// Running tally of today's Claude Code activity, surfaced in the popover's "Today"
/// section. Counts are cumulative across the local calendar day, roll over at midnight,
/// and survive app restarts via `UserDefaults`.
///
/// The clock and calendar are injectable so tests can drive the midnight rollover
/// without waiting for real time to pass.
@MainActor
@Observable
final class DailySummaryService {
    private(set) var sessionsStarted: Int
    private(set) var promptsSubmitted: Int
    private(set) var attentionEvents: Int

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: () -> Date

    /// Start-of-day the current counts belong to. When `now()` crosses into a new day the
    /// counters reset — see `rolloverIfNeeded()`.
    @ObservationIgnored private var currentDay: Date

    private enum Key {
        static let day = "com.mcclowes.clauded.dailySummary.day"
        static let sessionsStarted = "com.mcclowes.clauded.dailySummary.sessionsStarted"
        static let promptsSubmitted = "com.mcclowes.clauded.dailySummary.promptsSubmitted"
        static let attentionEvents = "com.mcclowes.clauded.dailySummary.attentionEvents"
    }

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now

        let today = calendar.startOfDay(for: now())
        if let storedDay = defaults.object(forKey: Key.day) as? Date,
           calendar.isDate(storedDay, inSameDayAs: today)
        {
            // Same day as last launch — restore the running totals.
            currentDay = today
            sessionsStarted = defaults.integer(forKey: Key.sessionsStarted)
            promptsSubmitted = defaults.integer(forKey: Key.promptsSubmitted)
            attentionEvents = defaults.integer(forKey: Key.attentionEvents)
        } else {
            // First launch, or the stored counts belong to a previous day — start fresh.
            currentDay = today
            sessionsStarted = 0
            promptsSubmitted = 0
            attentionEvents = 0
            persist()
        }
    }

    /// Folds a hook event into today's tally. `stop`/`sessionEnd` carry no daily signal and
    /// are ignored. Safe to call for every event the registry sees.
    func record(event: HookEvent) {
        rolloverIfNeeded()
        switch event.kind {
        case .sessionStart: sessionsStarted += 1
        case .userPromptSubmit: promptsSubmitted += 1
        case .notification: attentionEvents += 1
        case .stop, .sessionEnd: return
        }
        persist()
    }

    /// Resets the counters if the clock has crossed into a new day. Called on every record,
    /// and also driven by the app's periodic sweep so the "Today" section clears shortly
    /// after midnight even when no new events arrive.
    func rolloverIfNeeded() {
        let today = calendar.startOfDay(for: now())
        guard !calendar.isDate(currentDay, inSameDayAs: today) else { return }
        currentDay = today
        sessionsStarted = 0
        promptsSubmitted = 0
        attentionEvents = 0
        persist()
    }

    private func persist() {
        defaults.set(currentDay, forKey: Key.day)
        defaults.set(sessionsStarted, forKey: Key.sessionsStarted)
        defaults.set(promptsSubmitted, forKey: Key.promptsSubmitted)
        defaults.set(attentionEvents, forKey: Key.attentionEvents)
    }
}
