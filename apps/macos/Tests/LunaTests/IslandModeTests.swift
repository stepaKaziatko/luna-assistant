import SwiftUI
import XCTest
@testable import Luna

@MainActor
final class IslandModeTests: XCTestCase {
    private func session(_ id: String, _ state: AgentState = .idle) -> AgentSession {
        AgentSession(
            activity: nil, agent: "claude-code", approval: nil, cwd: "/work/shop",
            host: AgentHost(appPath: nil, kind: .unknown, name: nil, tty: nil, workspace: nil), id: id, model: nil, openUrl: nil,
            pid: 1, project: "shop", startedAt: 0, state: state, title: "сессия \(id)", trail: nil, updatedAt: 0, waitingFor: nil
        )
    }

    private func task(_ id: String, _ status: TaskStatus) -> TaskInfo {
        TaskInfo(
            approval: nil, context: nil, createdAt: 0, error: nil, executor: .claudeCode, finishedAt: nil, id: id,
            model: nil, progress: nil, prompt: "запрос \(id)", result: nil, sessionId: nil, status: status, threadId: id
        )
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "dev.luna.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Состояние в режиме «В фоне» с управляемым временем.
    private func makeBackgroundState() -> (AppState, Clock, () -> [SoundEvent]) {
        let defaults = scratchDefaults()
        defaults.set("background", forKey: "islandMode")
        let state = AppState(settings: LunaSettings(defaults: defaults))
        var played: [SoundEvent] = []
        state.playSound = { played.append($0) }
        let clock = Clock()
        state.clock = { clock.now }
        return (state, clock, { played })
    }

    final class Clock {
        var now: TimeInterval = 100
    }

    // MARK: - Настройка

    func testIslandModeDefaultsToAlwaysAndPersists() {
        let defaults = scratchDefaults()
        XCTAssertEqual(LunaSettings(defaults: defaults).islandMode, .always)

        let settings = LunaSettings(defaults: defaults)
        settings.islandMode = .background
        XCTAssertEqual(LunaSettings(defaults: defaults).islandMode, .background, "значение переживает перезапуск")

        defaults.set("мусор", forKey: "islandMode")
        XCTAssertEqual(LunaSettings(defaults: defaults).islandMode, .always, "неизвестное значение читается как «Всегда»")
    }

    // MARK: - Общий вход события

    func testEveryEventPlaysSoundAndShowsIsland() {
        for event in SoundEvent.allCases {
            let (state, _, played) = makeBackgroundState()
            XCTAssertFalse(state.islandShown, "в фоне шторка скрыта")
            state.notify(event)
            XCTAssertEqual(played(), [event])
            XCTAssertTrue(state.islandShown, "\(event): событие показывает шторку")
        }
    }

    func testEventShowsIslandEvenWithoutSound() {
        let (state, _, _) = makeBackgroundState()
        state.settings.soundsEnabled = false
        for event in SoundEvent.allCases { state.settings.setSound(nil, for: event) }
        state.notify(.attention)
        XCTAssertTrue(state.islandShown, "звук выключен — шторка всё равно появляется")
    }

    func testAgentAndTaskEventsGoThroughNotify() {
        let (state, clock, played) = makeBackgroundState()
        state.applyAgents([])
        XCTAssertFalse(state.islandShown, "первый список агентов — не событие")

        state.applyAgents([session("a", .waiting)])
        XCTAssertTrue(state.islandShown)
        XCTAssertEqual(played(), [.attention])

        clock.now += 20
        state.pointerMoved(overIsland: false)
        XCTAssertFalse(state.islandShown)

        state.applyAgents([session("a", .idle)])
        XCTAssertEqual(played(), [.attention, .finished])
        XCTAssertTrue(state.islandShown, "агент закончил ход")

        clock.now += 20
        state.pointerMoved(overIsland: false)
        state.apply(task("t", .done))
        XCTAssertEqual(played().last, .done)
        XCTAssertTrue(state.islandShown, "ответ готов")

        clock.now += 20
        state.pointerMoved(overIsland: false)
        state.apply(task("u", .failed))
        XCTAssertEqual(played().last, .failure)
        XCTAssertTrue(state.islandShown, "ошибка задачи")
    }

    func testNoPresenceWhereNoSoundPlays() {
        let (state, clock, played) = makeBackgroundState()
        state.applyAgents([session("a", .idle)])
        XCTAssertFalse(state.islandShown, "первый список")

        // Открытая карточка сессии не событие.
        state.openAgent(id: "a")
        state.collapse()
        XCTAssertFalse(state.islandShown)
        state.openAgent(id: "a")
        state.applyAgents([session("a", .waiting)])
        XCTAssertTrue(played().isEmpty, "сессия открытой карточки звука не даёт")
        state.collapse()
        XCTAssertFalse(state.islandShown)

        // Повтор того же статуса задачи и задача, не завершённая и не упавшая, — не события.
        state.apply(task("t", .running))
        XCTAssertFalse(state.islandShown)
        state.apply(task("t", .done))
        clock.now += 20
        state.pointerMoved(overIsland: false)
        XCTAssertFalse(state.islandShown)
        state.apply(task("t", .done))
        XCTAssertFalse(state.islandShown, "повтор статуса")
        XCTAssertEqual(played(), [.done])
    }

    func testAlwaysModeNeverHides() {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults()))
        let clock = Clock()
        state.clock = { clock.now }
        XCTAssertTrue(state.islandShown)
        state.notify(.attention)
        clock.now += 1000
        state.pointerMoved(overIsland: false)
        XCTAssertTrue(state.islandShown)
    }

    func testSwitchingModeActsImmediately() {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults()))
        state.settings.islandMode = .background
        XCTAssertFalse(state.islandShown)
        state.settings.islandMode = .always
        XCTAssertTrue(state.islandShown)
    }

    func testSwitchingToBackgroundKeepsOpenPanelUntilItCloses() {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults()))
        state.toggleTasks()
        state.settings.islandMode = .background
        XCTAssertTrue(state.islandShown, "панель открыта — шторка держится")
        state.collapse()
        XCTAssertFalse(state.islandShown, "закрылась — шторка уходит")
    }

    // MARK: - Логика показа

    func testPresenceShowsOnEventAndHidesAfterPause() {
        var presence = IslandPresence(mode: .background)
        XCTAssertFalse(presence.isShown)
        presence.event(now: 10)
        XCTAssertTrue(presence.isShown)
        presence.update(pointerInside: false, now: 10 + IslandPresence.pause - 0.1)
        XCTAssertTrue(presence.isShown)
        presence.update(pointerInside: false, now: 10 + IslandPresence.pause)
        XCTAssertFalse(presence.isShown)
    }

    func testNewEventExtendsPause() {
        var presence = IslandPresence(mode: .background)
        presence.event(now: 0)
        presence.event(now: 4)
        presence.update(pointerInside: false, now: 7)
        XCTAssertTrue(presence.isShown, "пауза отсчитывается от нового события")
        presence.update(pointerInside: false, now: 10)
        XCTAssertFalse(presence.isShown)
    }

    func testPointerOverIslandHoldsIt() {
        var presence = IslandPresence(mode: .background)
        presence.event(now: 0)
        presence.update(pointerInside: true, now: 1)
        presence.update(pointerInside: true, now: 60)
        XCTAssertTrue(presence.isShown, "курсор над шторкой удерживает её")
    }

    func testPointerLeavingBeforeDeadlineHidesOnDeadline() {
        var presence = IslandPresence(mode: .background)
        presence.event(now: 0)
        presence.update(pointerInside: true, now: 1)
        presence.update(pointerInside: false, now: 3)
        XCTAssertTrue(presence.isShown)
        presence.update(pointerInside: false, now: 6)
        XCTAssertFalse(presence.isShown, "ушёл раньше срока — шторка уходит в срок")
    }

    func testPointerLeavingAfterDeadlineHidesAfterCloseDelay() {
        var presence = IslandPresence(mode: .background)
        presence.event(now: 0)
        presence.update(pointerInside: true, now: 1)
        presence.update(pointerInside: true, now: 20)
        presence.update(pointerInside: false, now: 20)
        presence.update(pointerInside: false, now: 20 + HoverIntent.closeDelay - 0.05)
        XCTAssertTrue(presence.isShown)
        presence.update(pointerInside: false, now: 20 + HoverIntent.closeDelay)
        XCTAssertFalse(presence.isShown, "ушёл после паузы — через HoverIntent.closeDelay")
    }

    func testClosingPanelHidesWithoutPause() {
        for panel: AppState.Mode in [.input, .tasks, .result(threadId: "t"), .agents, .agent(sessionId: "a")] {
            var presence = IslandPresence(mode: .background)
            presence.event(now: 0)
            presence.panelChanged(from: .pill, to: panel, now: 1)
            presence.update(pointerInside: false, now: 50)
            XCTAssertTrue(presence.isShown, "\(panel): панель открыта — шторка держится")
            presence.panelChanged(from: panel, to: .pill, now: 51)
            XCTAssertFalse(presence.isShown, "\(panel): закрылась — сразу, без паузы")
        }
    }

    func testPanelOpenedWhileHiddenShowsIsland() {
        var presence = IslandPresence(mode: .background)
        presence.panelChanged(from: .pill, to: .input, now: 1)
        XCTAssertTrue(presence.isShown)
    }

    func testClosingPeekFollowsTheDeadline() {
        var presence = IslandPresence(mode: .background)
        presence.event(now: 0)
        presence.update(pointerInside: true, now: 1)
        presence.panelChanged(from: .pill, to: .peek, now: 1.2)
        presence.update(pointerInside: true, now: 4)
        presence.update(pointerInside: false, now: 4)
        presence.panelChanged(from: .peek, to: .pill, now: 4.4)
        XCTAssertTrue(presence.isShown, "уход с блока под курсором — не закрытие панели")
        presence.update(pointerInside: false, now: 6)
        XCTAssertFalse(presence.isShown, "уходит по сроку")
    }

    func testPeekHoldsIslandPastDeadline() {
        var presence = IslandPresence(mode: .background)
        presence.event(now: 0)
        presence.panelChanged(from: .pill, to: .peek, now: 1)
        presence.update(pointerInside: true, now: 30)
        XCTAssertTrue(presence.isShown)
        // Блок убрался уже после срока: курсор ушёл больше closeDelay назад — шторка уходит сразу.
        presence.update(pointerInside: false, now: 30.1)
        presence.panelChanged(from: .peek, to: .pill, now: 30.5)
        XCTAssertFalse(presence.isShown)
    }

    func testEventWhilePanelOpenDoesNotDelayHidingAfterClose() {
        var presence = IslandPresence(mode: .background)
        presence.panelChanged(from: .pill, to: .agents, now: 0)
        presence.event(now: 1)
        presence.panelChanged(from: .agents, to: .pill, now: 2)
        XCTAssertFalse(presence.isShown)
    }

    func testSwitchingModes() {
        var presence = IslandPresence(mode: .always)
        XCTAssertTrue(presence.isShown)
        presence.setMode(.background, panel: .pill, now: 0)
        XCTAssertFalse(presence.isShown)
        presence.setMode(.always, panel: .pill, now: 1)
        XCTAssertTrue(presence.isShown)
        presence.setMode(.background, panel: .input, now: 2)
        XCTAssertTrue(presence.isShown, "панель открыта — удержание")
    }

    func testClosingPeekThroughStateKeepsIslandUntilDeadline() {
        let (state, clock, _) = makeBackgroundState()
        state.notify(.attention)
        state.pointerMoved(overIsland: true)
        state.openPeek()
        XCTAssertEqual(state.mode, .peek)
        clock.now += 1
        state.pointerMoved(overIsland: false)
        state.closePeek()
        XCTAssertEqual(state.mode, .pill)
        XCTAssertTrue(state.islandShown)
        clock.now += IslandPresence.pause
        state.pointerMoved(overIsland: false)
        XCTAssertFalse(state.islandShown)
    }

    func testCollapseHidesStateWithoutPause() {
        let (state, _, _) = makeBackgroundState()
        state.toggleInput()
        XCTAssertTrue(state.islandShown)
        state.toggleInput()
        XCTAssertEqual(state.mode, .pill)
        XCTAssertFalse(state.islandShown)
    }

    // MARK: - Опрос курсора

    func testPointerPollingRule() {
        XCTAssertTrue(IslandPresence.needsPointerPolling(mode: .always, isShown: true, hoverPeek: true))
        XCTAssertFalse(IslandPresence.needsPointerPolling(mode: .always, isShown: true, hoverPeek: false))
        XCTAssertFalse(IslandPresence.needsPointerPolling(mode: .background, isShown: false, hoverPeek: true), "скрытая шторка курсора не ждёт")
        XCTAssertTrue(IslandPresence.needsPointerPolling(mode: .background, isShown: true, hoverPeek: false), "показанная удерживается курсором даже без раскрытия")
        XCTAssertTrue(IslandPresence.needsPointerPolling(mode: .background, isShown: true, hoverPeek: true))
    }

    // MARK: - Расход процессора и движение

    func testHiddenMotionGateSchedulesNothing() {
        let gate = MotionGate()
        XCTAssertTrue(gate.isScheduling)
        gate.setActive(false)
        XCTAssertFalse(gate.isScheduling, "скрытая шторка — без таймера")
        gate.burst()
        XCTAssertFalse(gate.isLively, "и без вспышек")
        gate.pointerNear = true
        XCTAssertFalse(gate.isLively)

        gate.setActive(true)
        XCTAssertTrue(gate.isScheduling, "показанная — снова с таймером")
        XCTAssertTrue(gate.isLively, "и одной вспышкой при появлении")
    }

    func testPresenceAnimationDissolvesWhenMotionIsReduced() {
        XCTAssertEqual(IslandMotion.presence(appearing: true, reduced: true), .easeInOut(duration: 0.15))
        XCTAssertEqual(IslandMotion.presence(appearing: false, reduced: true), .easeInOut(duration: 0.15))
        XCTAssertEqual(IslandMotion.presence(appearing: true, reduced: false), .spring(response: 0.42, dampingFraction: 0.78))
        XCTAssertNotEqual(IslandMotion.presence(appearing: false, reduced: false), .easeInOut(duration: 0.15))
    }
}
