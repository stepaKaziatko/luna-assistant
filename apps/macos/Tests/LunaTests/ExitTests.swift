import AppKit
import XCTest
@testable import Luna

/// Пути выхода из Luna: меню (значок и шторка), окно настроек, повторный запуск.
@MainActor
final class ExitTests: XCTestCase {
    private func makeState() -> AppState {
        let suite = "dev.luna.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppState(settings: LunaSettings(defaults: defaults))
    }

    /// Описание пункта без ссылок на объекты: по нему сравниваются два меню.
    private func describe(_ item: NSMenuItem) -> String {
        let target = item.target.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
        return "\(item.title)|\(item.keyEquivalent)|\(item.keyEquivalentModifierMask.rawValue)|\(item.action.map(NSStringFromSelector) ?? "nil")|\(target)"
    }

    // MARK: - Меню

    func testMenuHasAllItemsWithQuitLast() {
        let owner = LunaMenu(state: makeState(), quit: {})
        let menu = owner.make()
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Спросить…", "Последний результат", "Список задач", "Агенты", "Настройки…", "Выйти из Luna"]
        )
        XCTAssertEqual(menu.items.last?.title, "Выйти из Luna")
    }

    func testStatusItemAndIslandMenusAreIdentical() {
        // Значок и правый клик по шторке берут меню из одного места и получают разные объекты NSMenu.
        let source = LunaMenu(state: makeState(), quit: {})
        let status = source.make()
        let island = source.make()
        XCTAssertFalse(status === island, "один NSMenu двум родителям не отдаётся")
        XCTAssertEqual(status.items.map(describe), island.items.map(describe))
    }

    func testQuitItemHasExplicitTargetAndRunsQuit() throws {
        var quits = 0
        // NSMenuItem.target слабый: меню держит владелец, как AppDelegate.
        let owner = LunaMenu(state: makeState(), quit: { quits += 1 })
        let menu = owner.make()
        let item = try XCTUnwrap(menu.items.first { $0.title == "Выйти из Luna" })
        XCTAssertNotNil(item.target, "у приложения-агента нет главного меню: responder chain пункт не найдёт")
        XCTAssertEqual(item.keyEquivalent, "q")
        let action = try XCTUnwrap(item.action)
        _ = item.target?.perform(action)
        XCTAssertEqual(quits, 1)
        withExtendedLifetime(owner) {}
    }

    func testEveryActionableItemHasTarget() {
        let owner = LunaMenu(state: makeState(), quit: {})
        for item in owner.make().items where !item.isSeparatorItem {
            XCTAssertNotNil(item.action, item.title)
            XCTAssertNotNil(item.target, item.title)
        }
    }

    // MARK: - Окно настроек

    private func key(_ characters: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
    }

    /// Окно, которое считает закрытия: `⌘W` проходит через `windowShouldClose`.
    private final class CloseCounter: NSObject, NSWindowDelegate {
        var closes = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            closes += 1
            return false
        }
    }

    private func makeWindow() -> (CommandClosingWindow, CloseCounter, () -> Int) {
        let window = CommandClosingWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let counter = CloseCounter()
        window.delegate = counter
        var quits = 0
        window.onQuit = { quits += 1 }
        addTeardownBlock { window.delegate = nil }
        return (window, counter, { quits })
    }

    func testCommandQQuitsOnce() throws {
        let (window, counter, quits) = makeWindow()
        XCTAssertTrue(window.performKeyEquivalent(with: try key("q", keyCode: 12, .command, in: window)))
        XCTAssertEqual(quits(), 1)
        XCTAssertEqual(counter.closes, 0)
    }

    func testCommandQOnRussianLayoutQuits() throws {
        let (window, _, quits) = makeWindow()
        XCTAssertTrue(window.performKeyEquivalent(with: try key("й", keyCode: 12, .command, in: window)))
        XCTAssertEqual(quits(), 1, "⌘Q не должен зависеть от раскладки")
    }

    func testOtherQCombinationsDoNotQuit() throws {
        let (window, _, quits) = makeWindow()
        for modifiers: NSEvent.ModifierFlags in [[.command, .shift], .option, [], .control, [.command, .option]] {
            _ = window.performKeyEquivalent(with: try key("q", keyCode: 12, modifiers, in: window))
        }
        // Другая клавиша на нелатинской раскладке — тоже не Q.
        _ = window.performKeyEquivalent(with: try key("ф", keyCode: 0, .command, in: window))
        XCTAssertEqual(quits(), 0)
    }

    func testCommandWStillClosesWindow() throws {
        let (window, counter, quits) = makeWindow()
        XCTAssertTrue(window.performKeyEquivalent(with: try key("w", keyCode: 13, .command, in: window)))
        XCTAssertEqual(counter.closes, 1)
        XCTAssertEqual(quits(), 0)
    }

    // MARK: - Повторный запуск

    func testReopenOpensSettingsAndDoesNotRelaunch() {
        let delegate = AppDelegate()
        var opened = 0
        delegate.state.showSettings = { opened += 1 }
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(delegate.state.mode, .pill, "остров при этом свёрнут")
    }
}
