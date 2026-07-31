@testable import Clauded
import Foundation
import XCTest

@MainActor
final class IdleReaperStoreTests: XCTestCase {
    private let suiteName = "com.mcclowes.clauded.tests.idleReaper"
    private var defaults: UserDefaults!

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

    func testDefaultsToOffWithFourHourThreshold() {
        let store = IdleReaperStore(storage: defaults)
        XCTAssertEqual(store.behavior, .off)
        XCTAssertEqual(store.threshold, IdleReaperStore.defaultThreshold)
    }

    func testBehaviorPersistsAcrossRelaunch() {
        let first = IdleReaperStore(storage: defaults)
        first.setBehavior(.autoClose)

        let second = IdleReaperStore(storage: defaults)
        XCTAssertEqual(second.behavior, .autoClose)
    }

    func testThresholdPersistsAcrossRelaunch() {
        let first = IdleReaperStore(storage: defaults)
        first.setThreshold(7200)

        let second = IdleReaperStore(storage: defaults)
        XCTAssertEqual(second.threshold, 7200)
    }

    func testThresholdRejectsNonPositiveValues() {
        let store = IdleReaperStore(storage: defaults)
        store.setThreshold(0)
        store.setThreshold(-100)
        XCTAssertEqual(store.threshold, IdleReaperStore.defaultThreshold)
    }
}
