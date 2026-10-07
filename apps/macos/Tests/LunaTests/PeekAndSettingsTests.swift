import XCTest
@testable import Luna

@MainActor
final class PeekAndSettingsTests: XCTestCase {
    private func session(_ id: String, _ state: AgentState = .idle) -> AgentSession {
        AgentSession(
            activity: nil, agent: "claude-code", cwd: "/work/shop",
            host: AgentHost(appPath: nil, kind: .unknown, name: nil, tty: nil, workspace: nil), id: id, model: nil, openUrl: nil,
            pid: 1, project: "shop", startedAt: 0, state: state, title: "сессия \(id)", trail: nil, updatedAt: 0, waitingFor: nil
        )
    }

    private func task(_ id: String, _ status: TaskStatus, createdAt: Int = 0) -> TaskInfo {
        TaskInfo(
            approval: nil, context: nil, createdAt: createdAt, error: nil, executor: .claudeCode, finishedAt: nil, id: id,
            model: nil, progress: nil, prompt: "запрос \(id)", result: nil, sessionId: nil, status: status, threadId: id
        )
    }

    /// Состояние, которое записывает проигранные звуки и не трогает настройки пользователя.
    private func makeState() -> (AppState, () -> [SoundEvent]) {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults()))
        var played: [SoundEvent] = []
        state.playSound = { played.append($0) }
        return (state, { played })
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "dev.luna.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - Блок по наведению

    func testHoverOpensAfterDwellAndClosesAfterGrace() {
        var hover = HoverIntent()
        XCTAssertNil(hover.update(inside: false, at: 0), "курсор в стороне — обычное состояние")
        XCTAssertNil(hover.update(inside: false, at: 10))

        XCTAssertNil(hover.update(inside: true, at: 10.0))
        XCTAssertNil(hover.update(inside: true, at: 10.1), "пролетевший мимо курсор блок не раскрывает")
        XCTAssertEqual(hover.update(inside: true, at: 10.16), .open)
        XCTAssertNil(hover.update(inside: true, at: 11), "раскрывается один раз")

        XCTAssertNil(hover.update(inside: false, at: 11.0))
        XCTAssertNil(hover.update(inside: true, at: 11.2), "промах мимо края на долю секунды блок не закрывает")
        XCTAssertNil(hover.update(inside: false, at: 11.3))
        XCTAssertNil(hover.update(inside: false, at: 11.6))
        XCTAssertEqual(hover.update(inside: false, at: 11.71), .close)
        XCTAssertNil(hover.update(inside: false, at: 20))
    }

    func testPeekShowsEverySessionUntilTwoRowsOverflow() {
        let eight = (1...8).map { session("s\($0)") }
        let fits = AgentsSummary.peek(eight, finished: [], limit: 8)
        XCTAssertEqual(fits.shown.map(\.id), eight.map(\.id), "помещаются — порядок как у ядра: плитки не скачут")
        XCTAssertEqual(fits.hidden, 0)

        // Девятая не помещается: вперёд выходят те, кто зовёт человека, последнее место — счётчику.
        let nine = eight + [session("ждёт", .waiting)]
        let overflow = AgentsSummary.peek(nine, finished: ["s8"], limit: 8)
        XCTAssertEqual(overflow.shown.map(\.id), ["ждёт", "s8", "s1", "s2", "s3", "s4", "s5"])
        XCTAssertEqual(overflow.hidden, 2)
    }

    // MARK: - Расход процессора

    func testCollapsedPillIsLivelyOnlyInBurstsAndNearThePointer() {
        let gate = MotionGate()
        XCTAssertFalse(gate.isLively, "свёрнутая шторка по умолчанию неподвижна: кадры не рисуются")

        gate.pointerNear = true
        XCTAssertTrue(gate.isLively)
        gate.pointerNear = false
        XCTAssertFalse(gate.isLively)

        gate.burst()
        XCTAssertTrue(gate.isLively, "событие оживляет шторку сразу")
        XCTAssertLessThan(MotionGate.burstLength / MotionGate.burstPeriod, 0.25, "оживление — малая доля времени")
    }

    func testStateChangesEnlivenThePill() {
        let (state, _) = makeState()
        var bursts = 0
        state.enliven = { bursts += 1 }
        state.applyAgents([session("a", .working)])
        XCTAssertEqual(bursts, 1)
        state.applyAgents([session("a", .working)])
        XCTAssertEqual(bursts, 1, "ничего не изменилось — шторка не дёргается")
        state.applyAgents([session("a", .waiting)])
        XCTAssertEqual(bursts, 2)
        state.apply(task("t", .running))
        state.apply(task("t", .running))
        XCTAssertEqual(bursts, 3, "повтор того же состояния задачи — не событие")
    }

    func testHoverThatStartsInsideOpens() {
        var hover = HoverIntent()
        XCTAssertNil(hover.update(inside: true, at: 5))
        XCTAssertEqual(hover.update(inside: true, at: 5.2), .open)
    }

    func testShortPassOverPillDoesNothing() {
        var hover = HoverIntent()
        _ = hover.update(inside: false, at: 0)
        XCTAssertNil(hover.update(inside: true, at: 1.0))
        XCTAssertNil(hover.update(inside: false, at: 1.1))
        XCTAssertNil(hover.update(inside: false, at: 1.4))
        XCTAssertEqual(hover.update(inside: false, at: 1.6), .close, "закрытие закрытого блока состояние не меняет")
    }

    func testPeekOpensOnlyFromPillAndClosesOnlyItself() {
        let (state, _) = makeState()
        state.applyAgents([session("a", .working)])
        state.openPeek()
        XCTAssertEqual(state.mode, .peek)
        state.closePeek()
        XCTAssertEqual(state.mode, .pill)

        state.showAgents()
        state.openPeek()
        XCTAssertEqual(state.mode, .agents, "раскрытую карточку блок не подменяет")
        state.closePeek()
        XCTAssertEqual(state.mode, .agents, "уход курсора карточку не закрывает")
    }

    func testPeekRowsLeadToCards() {
        let (state, _) = makeState()
        state.applyAgents([session("a", .working)])
        state.apply(task("t1", .done))
        state.openPeek()
        state.openAgent(id: "a")
        XCTAssertEqual(state.mode, .agent(sessionId: "a"))

        state.collapse()
        state.openPeek()
        state.open(threadId: "t1")
        XCTAssertEqual(state.mode, .result(threadId: "t1"))
        XCTAssertEqual(state.unseen, [])
    }

    func testPeekShowsNewestDialogs() {
        let (state, _) = makeState()
        state.applyHistory((1...6).map { task("t\($0)", .done, createdAt: $0) })
        XCTAssertEqual(state.peekDialogs.map(\.threadId), ["t6", "t5", "t4", "t3"])
    }

    func testOpenSettingsCollapsesIsland() {
        let (state, _) = makeState()
        var shown = 0
        state.showSettings = { shown += 1 }
        state.openPeek()
        state.openSettings()
        XCTAssertEqual(state.mode, .pill)
        XCTAssertEqual(shown, 1)
    }

    // MARK: - Звуки

    func testAgentSoundsFollowStateChanges() {
        let (state, played) = makeState()
        state.applyAgents([session("a", .waiting), session("b", .working)])
        XCTAssertEqual(played(), [], "то, что было до запуска Luna, — не новость")

        state.applyAgents([session("a", .waiting), session("b")])
        XCTAssertEqual(played(), [.finished])

        state.applyAgents([session("a", .working), session("b")])
        XCTAssertEqual(played(), [.finished], "повтор того же состояния не звучит")

        state.applyAgents([session("a", .waiting), session("b", .working)])
        XCTAssertEqual(played(), [.finished, .attention])
    }

    func testOneSoundPerSnapshotAndWaitingWins() {
        let (state, played) = makeState()
        state.applyAgents([session("a", .working), session("b", .working), session("c", .working)])
        state.applyAgents([session("a"), session("b", .waiting), session("c")])
        XCTAssertEqual(played(), [.attention])
    }

    func testSessionInOpenCardIsSilent() {
        let (state, played) = makeState()
        state.applyAgents([session("a", .working)])
        state.openAgent(id: "a")
        state.applyAgents([session("a", .waiting)])
        state.applyAgents([session("a")])
        XCTAssertEqual(played(), [])
    }

    func testTaskSoundsPlayOncePerOutcome() {
        let (state, played) = makeState()
        state.apply(task("t1", .running))
        state.apply(task("t1", .done))
        state.apply(task("t1", .done))
        state.apply(task("t2", .failed))
        XCTAssertEqual(played(), [.done, .failure])

        state.applyHistory([task("t3", .done, createdAt: 5)])
        XCTAssertEqual(played(), [.done, .failure], "история — не новость")
    }

    // MARK: - Настройки

    func testSettingsDefaultsAndPersistence() {
        let defaults = scratchDefaults()
        let settings = LunaSettings(defaults: defaults)
        XCTAssertTrue(settings.hoverPeek)
        XCTAssertFalse(settings.pillText, "по умолчанию в шторке только значки и числа")
        XCTAssertTrue(settings.soundsEnabled)
        XCTAssertEqual(settings.lunaLook, AvatarLook.luna, "облик по умолчанию — серебристая Luna без аксессуаров")
        XCTAssertEqual(settings.sound(for: .attention), "Ping")

        settings.hoverPeek = false
        settings.pillText = true
        settings.tint = .gold
        settings.accessory = .cap
        settings.soundVolume = 0.2
        settings.setSound("Hero", for: .done)
        settings.setSound(nil, for: .finished)

        let reloaded = LunaSettings(defaults: defaults)
        XCTAssertFalse(reloaded.hoverPeek)
        XCTAssertTrue(reloaded.pillText)
        XCTAssertEqual(reloaded.tint, .gold)
        XCTAssertEqual(reloaded.lunaLook.accessory, .cap)
        XCTAssertEqual(reloaded.soundVolume, 0.2)
        XCTAssertEqual(reloaded.sound(for: .done), "Hero")
        XCTAssertNil(reloaded.sound(for: .finished), "событие без звука остаётся без звука")
        XCTAssertEqual(reloaded.sound(for: .failure), "Basso")
    }

    func testUnknownStoredValuesFallBackToDefaults() {
        let defaults = scratchDefaults()
        defaults.set("plaid", forKey: "avatarTint")
        defaults.set("monocle", forKey: "avatarAccessory")
        defaults.set(7.5, forKey: "soundVolume")
        let settings = LunaSettings(defaults: defaults)
        XCTAssertEqual(settings.tint, .silver)
        XCTAssertEqual(settings.accessory, .none)
        XCTAssertEqual(settings.soundVolume, 1)
    }

    func testDefaultSoundsExistOnThisMac() {
        for event in SoundEvent.allCases {
            XCTAssertTrue(SoundPlayer.available.contains(event.defaultSound), "нет системного звука \(event.defaultSound)")
        }
    }
}
