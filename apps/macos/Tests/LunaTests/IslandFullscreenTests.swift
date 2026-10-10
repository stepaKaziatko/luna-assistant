import XCTest
@testable import Luna

/// Правило показа свёрнутого острова над полноэкранным приложением: на экране с вырезом — покой без крыльев,
/// в «В фоне» событие его не показывает; на экране без выреза полноэкранный режим ничего не меняет.
@MainActor
final class IslandFullscreenTests: XCTestCase {
    private static let notch = NotchGeometry(notchWidth: 186, barHeight: 32, centerX: 756)
    private static let flat = NotchGeometry(notchWidth: 0, barHeight: 24, centerX: 960)

    final class Clock {
        var now: TimeInterval = 100
    }

    private func waiting(_ id: String) -> AgentSession {
        AgentSession(
            activity: nil, agent: "claude-code", approval: nil, cwd: "/work/shop",
            host: AgentHost(appPath: nil, kind: .unknown, name: nil, tty: nil, workspace: nil), id: id, model: nil, openUrl: nil,
            pid: 1, project: "shop", startedAt: 0, state: .waiting, title: "сессия \(id)", trail: nil, updatedAt: 0, waitingFor: nil
        )
    }

    private func makeState(_ mode: IslandMode, notch: NotchGeometry) -> (AppState, Clock, () -> [SoundEvent]) {
        let suite = "dev.luna.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(mode.rawValue, forKey: "islandMode")
        let state = AppState(settings: LunaSettings(defaults: defaults))
        var played: [SoundEvent] = []
        state.playSound = { played.append($0) }
        let clock = Clock()
        state.clock = { clock.now }
        state.islandPlacement = IslandPlacement(notch: notch, correction: 0)
        // Крылья замерены: при событиях они шире запаса покоя.
        state.pillWings = PillWings(left: 140, right: 90)
        return (state, clock, { played })
    }

    // MARK: - Чистое правило

    func testRuleTable() {
        typealias C = CollapsedIsland
        XCTAssertEqual(C.make(shown: true, hasNotch: true, fullscreen: true, hasEvents: true), .rest, "вырез + полноэкранный + события")
        XCTAssertEqual(C.make(shown: true, hasNotch: true, fullscreen: true, hasEvents: false), .rest)
        XCTAssertEqual(C.make(shown: true, hasNotch: true, fullscreen: false, hasEvents: true), .wings, "вне полноэкранного — как сейчас")
        XCTAssertEqual(C.make(shown: true, hasNotch: false, fullscreen: true, hasEvents: true), .wings, "без выреза полноэкранный не учитывается")
        XCTAssertEqual(C.make(shown: true, hasNotch: false, fullscreen: true, hasEvents: false), .rest)
        XCTAssertEqual(C.make(shown: false, hasNotch: true, fullscreen: true, hasEvents: true), .hidden)
        XCTAssertTrue(C.wingsSuppressed(hasNotch: true, fullscreen: true))
        XCTAssertFalse(C.wingsSuppressed(hasNotch: false, fullscreen: true))
        XCTAssertFalse(C.wingsSuppressed(hasNotch: true, fullscreen: false))
    }

    // MARK: - «Всегда»

    func testNotchFullscreenWithEventsRestsWithoutWings() {
        let (state, _, _) = makeState(.always, notch: Self.notch)
        state.applyAgents([waiting("a")])
        XCTAssertNotNil(state.pillPresentation)
        XCTAssertGreaterThan(state.pillLayout.leftWing, IslandLayout.restMargin, "до полноэкранного — крылья")

        state.screenFullscreen = true
        XCTAssertNil(state.shownPillPresentation)
        XCTAssertEqual(state.pillLayout, IslandLayout.make(notchWidth: 186, barHeight: 32), "покой: тело чуть шире выреза")
        XCTAssertEqual(state.pillLayout.body, CGSize(width: 206, height: 32))
        XCTAssertEqual(state.collapsedIsland, .rest)
        XCTAssertTrue(state.islandShown)

        state.screenFullscreen = false
        XCTAssertEqual(state.collapsedIsland, .wings, "вышли из полноэкранного — крылья вырастают")
        XCTAssertNotNil(state.shownPillPresentation)
    }

    func testPanelsOpenOverFullscreen() {
        let (state, _, _) = makeState(.always, notch: Self.notch)
        state.applyAgents([waiting("a")])
        state.screenFullscreen = true
        state.toggleInput()
        XCTAssertEqual(state.mode, .input, "хоткей открывает панель как обычно")
        state.collapse()
        XCTAssertEqual(state.mode, .pill)
        XCTAssertEqual(state.collapsedIsland, .rest, "свернулись — снова покой")
    }

    func testNoNotchFullscreenChangesNothingInAlways() {
        let (state, _, _) = makeState(.always, notch: Self.flat)
        state.applyAgents([waiting("a")])
        let before = state.pillLayout
        state.screenFullscreen = true
        XCTAssertEqual(state.pillLayout, before)
        XCTAssertEqual(state.collapsedIsland, .wings)
        XCTAssertTrue(state.islandShown)
    }

    // MARK: - «В фоне»

    func testBackgroundEventOverNotchFullscreenDoesNotShowIsland() {
        let (state, _, played) = makeState(.background, notch: Self.notch)
        state.screenFullscreen = true
        state.notify(.attention)
        XCTAssertFalse(state.islandShown, "событие над полноэкранным остров не показывает")
        XCTAssertEqual(played(), [.attention], "звук играет как обычно")
        XCTAssertEqual(state.collapsedIsland, .hidden)
    }

    func testEnteringFullscreenHidesIslandShownByEvent() {
        let (state, _, _) = makeState(.background, notch: Self.notch)
        state.notify(.attention)
        XCTAssertTrue(state.islandShown)
        state.screenFullscreen = true
        XCTAssertFalse(state.islandShown, "уже показанный по событию уходит")
        state.screenFullscreen = false
        XCTAssertFalse(state.islandShown, "выход из полноэкранного остров сам не показывает")
    }

    func testOpenPanelOverFullscreenInBackgroundIsShown() {
        let (state, _, _) = makeState(.background, notch: Self.notch)
        state.screenFullscreen = true
        state.toggleInput()
        XCTAssertTrue(state.islandShown, "открытая панель не подавляется")
        state.notify(.attention)
        XCTAssertTrue(state.islandShown)
        state.collapse()
        XCTAssertFalse(state.islandShown, "закрылась — остров уходит")
    }

    func testPeekClosedOverFullscreenHidesIsland() {
        let (state, _, _) = makeState(.background, notch: Self.notch)
        state.notify(.attention)
        state.openPeek()
        state.screenFullscreen = true
        XCTAssertTrue(state.islandShown, "блок под курсором держит остров")
        state.closePeek()
        XCTAssertFalse(state.islandShown)
    }

    func testNoNotchFullscreenChangesNothingInBackground() {
        let (state, clock, _) = makeState(.background, notch: Self.flat)
        state.screenFullscreen = true
        state.notify(.attention)
        XCTAssertTrue(state.islandShown, "без выреза событие показывает остров, как без полноэкранного")
        clock.now += IslandPresence.pause + 0.1
        state.pointerMoved(overIsland: false)
        XCTAssertFalse(state.islandShown, "и уходит по своему сроку")
    }

    func testMovingToNotchScreenWhileFullscreenHides() {
        // Флаг уже стоит (подмена), остров переезжает с экрана без выреза на экран с вырезом.
        let (state, _, _) = makeState(.background, notch: Self.flat)
        state.screenFullscreen = true
        state.notify(.attention)
        XCTAssertTrue(state.islandShown)
        state.islandPlacement = IslandPlacement(notch: Self.notch, correction: 0)
        XCTAssertFalse(state.islandShown)
    }
}
