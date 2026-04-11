@testable import Clauded
import SwiftUI
import XCTest

@MainActor
final class KeyBindingsStoreTests: XCTestCase {
    private var suite: UserDefaults!
    private let suiteName = "com.mcclowes.clauded.tests.keyBindings"

    override func setUp() async throws {
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        suite.removePersistentDomain(forName: suiteName)
    }

    func testStartsWithDefaults() {
        let store = KeyBindingsStore(storage: suite)

        XCTAssertEqual(store.binding(for: .selectNext), KeyBindingsStore.defaults[.selectNext])
        XCTAssertEqual(store.binding(for: .selectPrevious), KeyBindingsStore.defaults[.selectPrevious])
        XCTAssertEqual(store.binding(for: .activate), KeyBindingsStore.defaults[.activate])
        XCTAssertEqual(store.binding(for: .toggleAutoYes), KeyBindingsStore.defaults[.toggleAutoYes])
    }

    func testSetBindingPersistsAcrossInstances() {
        let store = KeyBindingsStore(storage: suite)
        let newBinding = KeyBinding(character: Character("j"))

        store.setBinding(newBinding, for: .selectNext)

        let reloaded = KeyBindingsStore(storage: suite)
        XCTAssertEqual(reloaded.binding(for: .selectNext), newBinding)
    }

    func testSetBindingStealsFromConflictingAction() {
        // Default owner of Space is .toggleAutoYes; assigning it to .activate
        // should strip it from .toggleAutoYes.
        let store = KeyBindingsStore(storage: suite)
        let spaceBinding = KeyBinding(character: Character(" "))

        store.setBinding(spaceBinding, for: .activate)

        XCTAssertEqual(store.binding(for: .activate), spaceBinding)
        XCTAssertNil(store.binding(for: .toggleAutoYes), "Previous owner should lose its binding")
    }

    func testActionLookupByCharacter() {
        let store = KeyBindingsStore(storage: suite)

        let upArrow = Character("\u{F700}")
        XCTAssertEqual(store.action(forCharacter: upArrow, modifiers: []), .selectPrevious)

        let space = Character(" ")
        XCTAssertEqual(store.action(forCharacter: space, modifiers: []), .toggleAutoYes)

        XCTAssertNil(store.action(forCharacter: Character("x"), modifiers: []))
    }

    func testActionLookupRespectsModifiers() {
        let store = KeyBindingsStore(storage: suite)
        store.setBinding(KeyBinding(character: Character("j"), modifiers: [.command]), for: .selectNext)

        XCTAssertEqual(
            store.action(forCharacter: Character("j"), modifiers: [.command]),
            .selectNext
        )
        XCTAssertNil(
            store.action(forCharacter: Character("j"), modifiers: []),
            "Bare j (no modifiers) must not match a ⌘J binding"
        )
    }

    func testClearBinding() {
        let store = KeyBindingsStore(storage: suite)

        store.clearBinding(for: .activate)

        XCTAssertNil(store.binding(for: .activate))
        XCTAssertEqual(store.binding(for: .selectNext), KeyBindingsStore.defaults[.selectNext])
    }

    func testResetRestoresDefaults() {
        let store = KeyBindingsStore(storage: suite)
        store.setBinding(KeyBinding(character: Character("x")), for: .activate)
        store.clearBinding(for: .toggleAutoYes)

        store.resetToDefaults()

        XCTAssertEqual(store.binding(for: .activate), KeyBindingsStore.defaults[.activate])
        XCTAssertEqual(store.binding(for: .toggleAutoYes), KeyBindingsStore.defaults[.toggleAutoYes])
    }
}
