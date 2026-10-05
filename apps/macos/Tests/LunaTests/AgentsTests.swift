import XCTest
@testable import Luna

@MainActor
final class AgentsTests: XCTestCase {
    private func session(
        _ id: String, _ state: AgentState = .idle, project: String = "shop", updatedAt: Int = 0,
        host: AgentHost = AgentHost(appPath: nil, kind: .unknown, name: nil, tty: nil, workspace: nil),
        openUrl: String? = nil, activity: String? = nil, trail: [AgentStep]? = nil, waitingFor: String? = nil
    ) -> AgentSession {
        AgentSession(
            activity: activity, agent: "claude-code", cwd: "/work/\(project)", host: host, id: id, openUrl: openUrl,
            pid: 1, project: project, startedAt: 0, state: state, title: "сессия \(id)", trail: trail, updatedAt: updatedAt, waitingFor: waitingFor
        )
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("не дождались: \(what)") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func pill(_ state: AppState) -> PillPresentation? {
        PillPresentation.make(tasks: state.pillState, taskProgress: nil, agents: state.agentsSummary)
    }

    // MARK: - Состояние

    func testFinishedTurnIsUnseenUntilSessionIsOpened() {
        let state = AppState()
        state.applyAgents([session("a", .working), session("b")])
        XCTAssertEqual(state.finishedAgents, [], "сессия, которая и была свободна, — не новость")

        state.applyAgents([session("a"), session("b")])
        XCTAssertEqual(state.finishedAgents, ["a"])
        XCTAssertEqual(pill(state)?.text, "shop: ход завершён")
        XCTAssertEqual(pill(state)?.mood, .happy)

        state.openAgent(id: "a")
        XCTAssertEqual(state.finishedAgents, [])
        XCTAssertEqual(state.mode, .agent(sessionId: "a"))
    }

    func testTurnFinishedInOpenCardStaysSeenAndNewTurnClearsMark() {
        let state = AppState()
        state.applyAgents([session("a", .working), session("b", .waiting)])
        state.openAgent(id: "a")
        state.applyAgents([session("a"), session("b")])
        XCTAssertEqual(state.finishedAgents, ["b"], "открытая карточка видна сразу")

        state.applyAgents([session("a"), session("b", .working)])
        XCTAssertEqual(state.finishedAgents, [])
    }

    func testEndedSessionLeavesCardAndSelection() {
        let state = AppState()
        state.applyAgents([session("a", .working), session("b")])
        state.openAgent(id: "a")
        state.applyAgents([session("b")])
        XCTAssertEqual(state.mode, .agents)
        XCTAssertEqual(state.selectedAgentId, "b")
        XCTAssertEqual(state.finishedAgents, [])
    }

    func testPillPriorityWaitingOverFinishedOverWorking() {
        let state = AppState()
        state.applyAgents([
            session("a", .working, project: "api", updatedAt: 1, activity: "читает main.ts"),
            session("b", .working, updatedAt: 2, activity: "правит cart.ts"),
        ])
        XCTAssertEqual(pill(state)?.text, "shop · правит cart.ts", "из работающих — тот, кто отчитался последним")
        XCTAssertEqual(pill(state)?.mood, .working)

        state.applyAgents([session("a", .waiting, project: "api"), session("b")])
        XCTAssertEqual(pill(state)?.text, "api ждёт вас")
        XCTAssertEqual(pill(state)?.tone, .attention)
        XCTAssertEqual(pill(state)?.sessions.map(\.id), ["a", "b"], "сначала тот, кто ждёт человека")

        state.applyAgents([session("a", project: "api"), session("b")])
        XCTAssertEqual(pill(state)?.text, "Завершили ход: 2")

        state.openAgent(id: "a")
        state.openAgent(id: "b")
        state.collapse()
        XCTAssertNil(pill(state), "все просмотрены и свободны — pill сворачивается в полоску")
    }

    func testPillClickLeadsToTheOneWhoCalls() {
        let state = AppState()
        state.applyAgents([session("a"), session("b")])
        state.pillClicked()
        XCTAssertEqual(state.mode, .agents, "никто не зовёт — список агентов")

        state.collapse()
        state.applyAgents([session("a"), session("b", .waiting)])
        state.pillClicked()
        XCTAssertEqual(state.mode, .agent(sessionId: "b"))

        state.collapse()
        state.applyAgents([session("a", .waiting), session("b", .waiting)])
        state.pillClicked()
        XCTAssertEqual(state.mode, .agents)
        XCTAssertEqual(state.selectedAgentId, "a")
    }

    // MARK: - Клавиши

    func testListKeysOpenCardRequestStepsAndJump() async throws {
        let state = AppState()
        let core = FakeCore()
        state.core = core
        var jumped: [String] = []
        state.jump = { jumped.append($0.id) }
        state.applyAgents([session("a"), session("b", .working)])
        state.showAgents()
        XCTAssertEqual(state.selectedAgentId, "a")

        XCTAssertTrue(state.handleAgentKey(keyCode: 124, command: false))
        XCTAssertEqual(state.selectedAgentId, "b")
        XCTAssertTrue(state.handleAgentKey(keyCode: 124, command: false))
        XCTAssertEqual(state.selectedAgentId, "b", "правее последней плитки выбор не уходит")

        XCTAssertTrue(state.handleAgentKey(keyCode: 36, command: false))
        XCTAssertEqual(state.mode, .agent(sessionId: "b"))
        try await until("запроса шагов") { core.calls.count == 1 }
        XCTAssertEqual(core.calls[0].method, "agents.steps")
        XCTAssertEqual(core.params(0), ["sessionId": "b"])
        let steps = [AgentStep(at: 1, kind: .tool, text: "читает cart.ts")]
        core.reply(0, AgentStepsResult(steps: steps))
        try await until("шагов") { state.agentSteps == steps }

        // Сессия изменилась — шаги перечитываются.
        state.applyAgents([session("a"), session("b", .working, updatedAt: 5)])
        try await until("повторного запроса шагов") { core.calls.count == 2 }

        XCTAssertTrue(state.handleAgentKey(keyCode: 53, command: false))
        XCTAssertEqual(state.mode, .agents, "esc в карточке — назад к списку")
        XCTAssertFalse(state.handleAgentKey(keyCode: 0, command: false))

        XCTAssertTrue(state.handleAgentKey(keyCode: 36, command: true))
        XCTAssertEqual(jumped, ["b"])
        XCTAssertEqual(state.mode, .pill, "после перехода к окну остров сворачивается")
        XCTAssertFalse(state.handleAgentKey(keyCode: 36, command: false), "вне агентов клавиши не перехватываются")
    }

    func testStaleStepsOfPreviousCardAreDropped() async throws {
        let state = AppState()
        let core = FakeCore()
        state.core = core
        state.applyAgents([session("a"), session("b")])
        state.openAgent(id: "a")
        state.openAgent(id: "b")
        try await until("двух запросов шагов") { core.calls.count == 2 }
        // Запросы уходят к ядру параллельно — их порядок в записи не определён.
        let late = try XCTUnwrap([0, 1].first { core.params($0) == ["sessionId": "a"] })
        let fresh = [AgentStep(at: 2, kind: .text, text: "b")]
        core.reply(1 - late, AgentStepsResult(steps: fresh))
        try await until("шагов b") { state.agentSteps == fresh }
        core.reply(late, AgentStepsResult(steps: [AgentStep(at: 1, kind: .text, text: "a")]))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(state.agentSteps, fresh)
    }

    func testArrowsWalkTheTileGrid() {
        let state = AppState()
        // Шесть плиток: полный ряд из четырёх и неполный из двух.
        state.applyAgents(["a", "b", "c", "d", "e", "f"].map { session($0) })
        state.showAgents()
        XCTAssertEqual(state.selectedAgentId, "a")

        XCTAssertTrue(state.handleAgentKey(keyCode: 125, command: false))
        XCTAssertEqual(state.selectedAgentId, "e", "↓ — на плитку под выбранной")
        XCTAssertTrue(state.handleAgentKey(keyCode: 125, command: false))
        XCTAssertEqual(state.selectedAgentId, "e", "ниже последнего ряда выбор не уходит")
        XCTAssertTrue(state.handleAgentKey(keyCode: 126, command: false))
        XCTAssertEqual(state.selectedAgentId, "a")
        XCTAssertTrue(state.handleAgentKey(keyCode: 126, command: false))
        XCTAssertEqual(state.selectedAgentId, "a", "выше первого ряда — тоже")

        for _ in 0..<3 { XCTAssertTrue(state.handleAgentKey(keyCode: 124, command: false)) }
        XCTAssertEqual(state.selectedAgentId, "d")
        XCTAssertTrue(state.handleAgentKey(keyCode: 125, command: false))
        XCTAssertEqual(state.selectedAgentId, "f", "под плиткой пусто — выбор встаёт на последнюю")
        XCTAssertTrue(state.handleAgentKey(keyCode: 123, command: false))
        XCTAssertEqual(state.selectedAgentId, "e")
    }

    // MARK: - Окно сессии

    func testSpaceOpensSessionWindowWithDetailedFeed() async throws {
        let state = AppState()
        let core = FakeCore()
        state.core = core
        state.applyAgents([session("a", .working)])
        state.openAgent(id: "a")
        try await until("запроса шагов карточки") { core.calls.count == 1 }

        XCTAssertTrue(state.handleAgentKey(keyCode: 49, command: false))
        XCTAssertEqual(state.agentWindows, ["a"])
        XCTAssertEqual(state.mode, .pill, "окно заменяет карточку: остров сворачивается")
        try await until("запроса подробной ленты") { core.calls.count == 2 }
        let params = try JSONDecoder().decode(AgentStepsParams.self, from: core.calls[1].params)
        XCTAssertEqual(params, AgentStepsParams(detail: true, sessionId: "a"))
        let steps = [AgentStep(at: 1, kind: .text, text: "Первый абзац.\n\nВторой.")]
        core.reply(1, AgentStepsResult(steps: steps))
        try await until("ленты") { state.agentTranscripts["a"] == steps }

        // Сессия изменилась — лента окна перечитывается; повторное открытие второго окна не создаёт.
        state.applyAgents([session("a", .working, updatedAt: 5)])
        try await until("повторного запроса ленты") { core.calls.count == 3 }
        var raised: [String] = []
        let subscription = state.agentWindowRaised.sink { raised.append($0) }
        state.openAgentWindow(id: "a")
        XCTAssertEqual(state.agentWindows, ["a"])
        XCTAssertEqual(raised, ["a"])
        subscription.cancel()

        // Сессия завершилась — окно остаётся с последним известным состоянием и прочитанной лентой.
        state.applyAgents([])
        XCTAssertEqual(state.agentWindows, ["a"])
        XCTAssertEqual(state.agentWindowSessions["a"]?.updatedAt, 5)
        XCTAssertEqual(state.agentTranscripts["a"], steps)

        state.closeAgentWindow(id: "a")
        XCTAssertEqual(state.agentWindows, [])
        XCTAssertNil(state.agentTranscripts["a"])
        XCTAssertNil(state.agentWindowSessions["a"])
    }

    func testWindowOfUnknownSessionIsNotOpened() {
        let state = AppState()
        state.openAgentWindow(id: "нет такой")
        XCTAssertEqual(state.agentWindows, [])
    }

    // MARK: - Превью работы

    func testTileCaptionIsAFewWordsNotASentence() {
        let read = AgentStep(at: 1, kind: .tool, target: "cart.ts", text: "читает cart.ts", tool: "read")
        XCTAssertEqual(session("a", .working, trail: [read]).tileCaption, "cart.ts", "у инструмента — только цель: глагол показывает значок")
        XCTAssertEqual(session("a", .working, trail: [AgentStep(at: 1, kind: .tool, text: "обновляет план")]).tileCaption, "обновляет план")
        XCTAssertEqual(session("a", .working, trail: [read, AgentStep(at: 2, kind: .text, text: "Готово.")]).tileCaption, "пишет ответ")
        XCTAssertEqual(session("a", .working, trail: [AgentStep(at: 1, kind: .prompt, text: "почини")]).tileCaption, "думает")
        XCTAssertEqual(session("a", .working, activity: "думает…").tileCaption, "думает…", "без журнала — то, что сообщило ядро")
        XCTAssertEqual(session("a", .waiting, waitingFor: "sandbox request").tileCaption, "нужно разрешение")
        XCTAssertEqual(session("a", .waiting).tileCaption, "ждёт вас")
    }

    func testStepSymbolsAndStableIds() {
        func tool(_ name: String?) -> AgentStep { AgentStep(at: 1, kind: .tool, target: nil, text: "шаг", tool: name) }
        XCTAssertEqual(tool("read").symbol, "doc.text")
        XCTAssertEqual(tool("shell").symbol, "terminal")
        XCTAssertEqual(tool("mcp").symbol, "puzzlepiece.extension")
        XCTAssertEqual(tool("что-то новое").symbol, tool(nil).symbol, "незнакомый род инструмента — общий значок")
        XCTAssertEqual(AgentStep(at: 1, kind: .prompt, text: "вопрос").symbol, "person.fill")

        // Одинаковые шаги различаются номером повтора; сдвиг окна ленты не меняет id оставшихся разных шагов.
        let steps = [tool("read"), tool("read"), AgentStep(at: 2, kind: .text, text: "текст")]
        let ids = AgentStep.identified(steps).map(\.id)
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertEqual(AgentStep.identified(Array(steps.dropFirst(1))).map(\.id).last, ids.last)
    }

    func testChipsCountEveryStateAtOnce() {
        func task(_ id: String, _ status: TaskStatus) -> TaskInfo {
            TaskInfo(
                context: nil, createdAt: 0, error: nil, executor: .claudeCode, finishedAt: nil, id: id,
                model: nil, progress: nil, prompt: id, result: nil, sessionId: nil, status: status, threadId: id
            )
        }
        let agents = AgentsSummary(
            sessions: [session("w", .waiting), session("x", .working), session("y", .working), session("z"), session("i")],
            finished: ["z"]
        )
        let chips = StatusChip.make(
            tasks: [task("1", .failed), task("2", .done), task("3", .running), task("4", .done)],
            unseen: ["1", "2"], hasProblem: false, agents: agents
        )
        XCTAssertEqual(chips, [
            StatusChip(kind: .failure, count: 1),
            StatusChip(kind: .attention, count: 1),
            StatusChip(kind: .success, count: 2),
            StatusChip(kind: .working, count: 3),
        ], "в порядке важности; просмотренный ответ и спокойная сессия в счёт не идут")
        XCTAssertEqual(chips.map(\.title), ["Ошибок: 1", "Ждут вас: 1", "Готово: 2", "В работе: 3"])

        let empty = AgentsSummary(sessions: [], finished: [])
        XCTAssertEqual(StatusChip.make(tasks: [], unseen: [], hasProblem: false, agents: empty), [])
        XCTAssertEqual(StatusChip.make(tasks: [], unseen: [], hasProblem: true, agents: empty), [StatusChip(kind: .failure, count: 1)])
    }

    // MARK: - Переход к окну

    func testEditorPlanOpensWorkspaceThenSessionLink() {
        let host = AgentHost(appPath: "/Applications/Visual Studio Code.app", kind: .ide, name: "Visual Studio Code", tty: nil, workspace: "/work")
        let plan = AgentJump.plan(for: session("a", host: host, openUrl: "vscode://anthropic.claude-code/open?session=a"))
        XCTAssertEqual(plan, .editor(
            app: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            folder: URL(fileURLWithPath: "/work"),
            session: URL(string: "vscode://anthropic.claude-code/open?session=a")
        ))
        XCTAssertEqual(host.jumpTitle, "Открыть в Visual Studio Code")
    }

    func testUnknownSchemeIsNotOpened() {
        let host = AgentHost(appPath: "/Applications/Cursor.app", kind: .ide, name: "Cursor", tty: nil, workspace: nil)
        for url in ["file:///etc/passwd", "https://example.com", "x-apple.systempreferences:", "не ссылка"] {
            XCTAssertNil(AgentJump.sessionURL(session("a", host: host, openUrl: url)), url)
        }
        guard case .editor(_, let folder, let link) = AgentJump.plan(for: session("a", host: host, openUrl: "https://example.com")) else {
            return XCTFail("ожидался переход в редактор")
        }
        XCTAssertEqual(folder.path, "/work/shop", "без папки окна открывается рабочая директория")
        XCTAssertNil(link)
    }

    func testTerminalPlanKeepsOnlyRealTTY() {
        let terminal = AgentHost(appPath: "/Applications/iTerm.app", kind: .terminal, name: "iTerm", tty: "/dev/ttys003", workspace: nil)
        XCTAssertEqual(AgentJump.plan(for: session("a", host: terminal)), .terminal(app: URL(fileURLWithPath: "/Applications/iTerm.app"), tty: "/dev/ttys003"))

        let hostile = AgentHost(appPath: nil, kind: .terminal, name: nil, tty: "/dev/ttys1\" then do shell script \"x", workspace: nil)
        XCTAssertEqual(AgentJump.plan(for: session("a", host: hostile)), .terminal(app: nil, tty: nil))
        XCTAssertEqual(hostile.jumpTitle, "Открыть терминал")

        XCTAssertNotNil(AgentJump.tabScript(appName: "Terminal", tty: "/dev/ttys003"))
        XCTAssertTrue(AgentJump.tabScript(appName: "iTerm", tty: "/dev/ttys003")?.contains("\"/dev/ttys003\"") ?? false)
        XCTAssertNil(AgentJump.tabScript(appName: "Ghostty", tty: "/dev/ttys003"), "терминал без словаря сценариев просто активируется")
    }

    func testUnknownHostShowsFolder() {
        XCTAssertEqual(AgentJump.plan(for: session("a")), .folder(URL(fileURLWithPath: "/work/shop")))
    }

    // MARK: - Внешность

    func testLookIsStableAcrossLaunches() {
        // FNV-1a: значение не зависит от запуска, в отличие от hashValue.
        XCTAssertEqual(stableHash("shop"), 0x46dc_5e18_e28e_2409)
        let first = AvatarLook.session(session("a"))
        XCTAssertEqual(first.hue, AvatarLook.session(session("b")).hue, "сессии одного проекта — одного цвета")
        XCTAssertNotEqual(first.seed, AvatarLook.session(session("b")).seed)
        XCTAssertEqual(AvatarPainter.craters(seed: first.seed).map(\.x), AvatarPainter.craters(seed: first.seed).map(\.x))
        XCTAssertTrue((2...3).contains(AvatarPainter.craters(seed: first.seed).count))
    }

    func testReducedMotionPoseDoesNotDependOnTime() {
        let engine = AvatarEngine()
        XCTAssertEqual(engine.step(to: 1, mood: .waiting, still: true), engine.step(to: 99, mood: .waiting, still: true))
        XCTAssertEqual(engine.step(to: 1, mood: .sleeping, still: true).open, 0)
    }

    func testIdleSessionAge() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(AgentStatusLine.ago(9_990_000, now: now), "только что")
        XCTAssertTrue(AgentStatusLine.ago(10_000_000 - 5 * 60_000, now: now).contains("5"))
    }
}
