@testable import Clauded
import Foundation
import XCTest

@MainActor
final class AutoYesRulesStoreTests: XCTestCase {
    func testDefaultStateIsApproveWithNoRules() {
        let store = AutoYesRulesStore(storage: makeEphemeralDefaults())

        XCTAssertTrue(store.globalRules.isEmpty)
        XCTAssertTrue(store.codebases.isEmpty)
        XCTAssertEqual(store.globalDefaultAction, .approve)
        XCTAssertEqual(
            store.resolveAction(message: "anything", projectDir: "/tmp/x"),
            .approve
        )
    }

    func testGlobalRuleFirstMatchWins() {
        let store = AutoYesRulesStore(storage: makeEphemeralDefaults())
        store.addGlobalRule(pattern: "rm -rf", action: .skip)
        store.addGlobalRule(pattern: "Bash", action: .approve)

        XCTAssertEqual(
            store.resolveAction(
                message: "Claude needs your permission to use Bash(rm -rf tmp)",
                projectDir: nil
            ),
            .skip
        )
    }

    func testGlobalRuleIsCaseInsensitive() {
        let store = AutoYesRulesStore(storage: makeEphemeralDefaults())
        store.addGlobalRule(pattern: "GIT PUSH", action: .skip)

        XCTAssertEqual(
            store.resolveAction(
                message: "Claude needs your permission to use Bash(git push origin main)",
                projectDir: nil
            ),
            .skip
        )
    }

    func testUnmatchedFallsThroughToDefault() {
        let store = AutoYesRulesStore(storage: makeEphemeralDefaults())
        store.setGlobalDefaultAction(.skip)
        store.addGlobalRule(pattern: "ls", action: .approve)

        XCTAssertEqual(
            store.resolveAction(message: "permission for rm", projectDir: nil),
            .skip
        )
    }

    func testDisabledCodebaseAlwaysSkipsEvenWithApprovingRule() {
        let store = AutoYesRulesStore(storage: makeEphemeralDefaults())
        store.addGlobalRule(pattern: "ls", action: .approve)
        guard let added = store.addCodebase(name: "payments") else {
            return XCTFail("expected codebase to be added")
        }
        store.setCodebaseEnabled(id: added.id, enabled: false)

        XCTAssertEqual(
            store.resolveAction(
                message: "Claude needs your permission to use Bash(ls)",
                projectDir: "/Users/me/work/payments"
            ),
            .skip
        )
    }

    func testCodebaseRuleTakesPriorityOverGlobal() {
        let store = AutoYesRulesStore(storage: makeEphemeralDefaults())
        store.addGlobalRule(pattern: "git", action: .approve)
        guard let payments = store.addCodebase(name: "payments") else {
            return XCTFail("expected codebase to be added")
        }
        store.addRule(toCodebase: payments.id, pattern: "git push", action: .skip)

        // Inside the "payments" codebase, the more specific rule wins.
        XCTAssertEqual(
            store.resolveAction(
                message: "permission to use Bash(git push origin main)",
                projectDir: "/Users/me/work/payments"
            ),
            .skip
        )
        // Outside it, the global rule still applies.
        XCTAssertEqual(
            store.resolveAction(
                message: "permission to use Bash(git push origin main)",
                projectDir: "/Users/me/work/other"
            ),
            .approve
        )
    }

    func testCodebaseRuleNoMatchFallsThroughToGlobal() {
        let store = AutoYesRulesStore(storage: makeEphemeralDefaults())
        store.setGlobalDefaultAction(.skip)
        store.addGlobalRule(pattern: "ls", action: .approve)
        guard let payments = store.addCodebase(name: "payments") else {
            return XCTFail("expected codebase to be added")
        }
        store.addRule(toCodebase: payments.id, pattern: "git push", action: .skip)

        XCTAssertEqual(
            store.resolveAction(
                message: "permission to use Bash(ls -la)",
                projectDir: "/Users/me/work/payments"
            ),
            .approve
        )
    }

    func testCodebaseMatchesBasenameCaseInsensitively() {
        let store = AutoYesRulesStore(storage: makeEphemeralDefaults())
        store.setGlobalDefaultAction(.approve)
        guard let cb = store.addCodebase(name: "Payments") else {
            return XCTFail("expected codebase to be added")
        }
        store.setCodebaseEnabled(id: cb.id, enabled: false)

        XCTAssertEqual(
            store.resolveAction(
                message: "permission to use Bash",
                projectDir: "/Users/me/PAYMENTS"
            ),
            .skip
        )
        XCTAssertEqual(
            store.resolveAction(
                message: "permission to use Bash",
                projectDir: "/Users/me/other-project"
            ),
            .approve
        )
    }

    func testAddCodebaseRejectsDuplicateCaseInsensitive() {
        let store = AutoYesRulesStore(storage: makeEphemeralDefaults())
        XCTAssertNotNil(store.addCodebase(name: "Clauded"))
        XCTAssertNil(store.addCodebase(name: "clauded"))
        XCTAssertEqual(store.codebases.count, 1)
    }

    func testAddRejectsEmptyPattern() {
        let store = AutoYesRulesStore(storage: makeEphemeralDefaults())
        store.addGlobalRule(pattern: "   ", action: .skip)

        XCTAssertTrue(store.globalRules.isEmpty)
    }

    func testPersistenceRoundtrip() {
        let defaults = makeEphemeralDefaults()
        let storeA = AutoYesRulesStore(storage: defaults)
        storeA.setGlobalDefaultAction(.skip)
        storeA.addGlobalRule(pattern: "rm -rf", action: .skip)
        guard let cb = storeA.addCodebase(name: "payments") else {
            return XCTFail("expected codebase to be added")
        }
        storeA.addRule(toCodebase: cb.id, pattern: "git push", action: .approve)
        storeA.setCodebaseEnabled(id: cb.id, enabled: false)

        let storeB = AutoYesRulesStore(storage: defaults)

        XCTAssertEqual(storeB.globalDefaultAction, .skip)
        XCTAssertEqual(storeB.globalRules.count, 1)
        XCTAssertEqual(storeB.globalRules.first?.pattern, "rm -rf")
        XCTAssertEqual(storeB.codebases.count, 1)
        XCTAssertEqual(storeB.codebases.first?.name, "payments")
        XCTAssertFalse(storeB.codebases.first?.enabled ?? true)
        XCTAssertEqual(storeB.codebases.first?.rules.count, 1)
    }
}
