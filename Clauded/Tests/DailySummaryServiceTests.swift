@testable import Clauded
import Foundation
import XCTest

@MainActor
final class DailySummaryServiceTests: XCTestCase {
    private let suiteName = "com.mcclowes.clauded.tests.dailySummary"
    private var defaults: UserDefaults!

    /// A fixed-zone calendar so day boundaries are deterministic regardless of where the
    /// tests run.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testRecordIncrementsCountersPerKind() {
        let service = makeService(now: { self.date(2026, 6, 10) })
        service.record(event: makeEvent(.sessionStart))
        service.record(event: makeEvent(.sessionStart))
        service.record(event: makeEvent(.userPromptSubmit))
        service.record(event: makeEvent(.notification))

        XCTAssertEqual(service.sessionsStarted, 2)
        XCTAssertEqual(service.promptsSubmitted, 1)
        XCTAssertEqual(service.attentionEvents, 1)
    }

    func testStopAndSessionEndAreIgnored() {
        let service = makeService(now: { self.date(2026, 6, 10) })
        service.record(event: makeEvent(.stop))
        service.record(event: makeEvent(.sessionEnd))

        XCTAssertEqual(service.sessionsStarted, 0)
        XCTAssertEqual(service.promptsSubmitted, 0)
        XCTAssertEqual(service.attentionEvents, 0)
    }

    func testCountsPersistAcrossRelaunchOnTheSameDay() {
        let first = makeService(now: { self.date(2026, 6, 10, hour: 9) })
        first.record(event: makeEvent(.sessionStart))
        first.record(event: makeEvent(.userPromptSubmit))

        // Fresh instance reading the same defaults later the same day restores the totals.
        let second = makeService(now: { self.date(2026, 6, 10, hour: 17) })
        XCTAssertEqual(second.sessionsStarted, 1)
        XCTAssertEqual(second.promptsSubmitted, 1)
    }

    func testRelaunchOnANewDayStartsFresh() {
        let first = makeService(now: { self.date(2026, 6, 10) })
        first.record(event: makeEvent(.sessionStart))
        XCTAssertEqual(first.sessionsStarted, 1)

        let second = makeService(now: { self.date(2026, 6, 11) })
        XCTAssertEqual(second.sessionsStarted, 0, "Yesterday's counts must not carry into a new day")
    }

    func testRolloverIfNeededResetsWhenClockCrossesMidnight() {
        var clock = date(2026, 6, 10, hour: 23)
        let service = makeService(now: { clock })
        service.record(event: makeEvent(.sessionStart))
        service.record(event: makeEvent(.notification))
        XCTAssertEqual(service.sessionsStarted, 1)

        clock = date(2026, 6, 11, hour: 0)
        service.rolloverIfNeeded()

        XCTAssertEqual(service.sessionsStarted, 0)
        XCTAssertEqual(service.attentionEvents, 0)
    }

    func testRolloverIfNeededIsNoopWithinTheSameDay() {
        var clock = date(2026, 6, 10, hour: 1)
        let service = makeService(now: { clock })
        service.record(event: makeEvent(.sessionStart))

        clock = date(2026, 6, 10, hour: 23)
        service.rolloverIfNeeded()

        XCTAssertEqual(service.sessionsStarted, 1, "Same-day rollover check must not reset counts")
    }

    func testFirstEventAfterMidnightStartsAFreshDay() {
        var clock = date(2026, 6, 10, hour: 23)
        let service = makeService(now: { clock })
        service.record(event: makeEvent(.sessionStart))

        clock = date(2026, 6, 11, hour: 0)
        service.record(event: makeEvent(.userPromptSubmit))

        XCTAssertEqual(service.sessionsStarted, 0, "Prior day's sessions cleared on first event of new day")
        XCTAssertEqual(service.promptsSubmitted, 1)
    }

    private func makeService(now: @escaping () -> Date) -> DailySummaryService {
        DailySummaryService(defaults: defaults, calendar: utcCalendar, now: now)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        // Components are hardcoded valid dates, so the fallback is unreachable in practice.
        return utcCalendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    private func makeEvent(_ kind: HookEventKind) -> HookEvent {
        HookEvent(kind: kind, sessionId: "s", projectDir: "/p", pid: 1, timestamp: Date(), message: nil)
    }
}
