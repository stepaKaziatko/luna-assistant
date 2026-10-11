import XCTest
@testable import Luna

/// Подтверждение действий чужой сессии агента (LUNA-53): запрос от хука приходит в `AgentSession.approval`,
/// блок показывают плитка, карточка и окно сессии, ответ уходит ядру как `agents.approve`.
@MainActor
final class AgentApprovalTests: XCTestCase {
    private func request(_ id: String = "req-1", createdAt: Int = 10, kind: ApprovalKind = .write) -> ApprovalRequest {
        ApprovalRequest(
            createdAt: createdAt, detail: "hi\n\nРазмер: 2 знака", id: id, kind: kind, summary: "Записать файл",
            target: "/work/shop/a.txt", tool: "Write"
        )
    }

    private func session(
        _ id: String, _ state: AgentState = .waiting, approval: ApprovalRequest? = nil, startedAt: Int = 0, waitingFor: String? = "permission prompt"
    ) -> AgentSession {
        AgentSession(
            activity: nil, agent: "claude-code", approval: approval, cwd: "/work/shop",
            host: AgentHost(appPath: nil, kind: .unknown, name: nil, tty: nil, workspace: nil), id: id, model: nil, openUrl: nil,
            pid: 1, project: "shop", startedAt: startedAt, state: state, title: "сессия \(id)", trail: nil, updatedAt: 0, waitingFor: waitingFor
        )
    }

    private func task(_ id: String, approval: ApprovalRequest? = nil, createdAt: Int = 1) -> TaskInfo {
        TaskInfo(
            approval: approval, context: nil, createdAt: createdAt, error: nil, executor: .claudeCode, finishedAt: nil, id: id,
            model: nil, progress: nil, prompt: "запрос \(id)", result: nil, sessionId: nil, status: .running, threadId: id
        )
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("не дождались: \(what)") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func makeState() -> (AppState, FakeCore) {
        let state = AppState()
        let core = FakeCore()
        state.core = core
        // Переход к окну сессии по ↩ в тесте ничего не открывает.
        state.jump = { _ in }
        return (state, core)
    }

    /// Запросы `agents.approve` среди вызовов ядра: карточка заодно просит шаги (`agents.steps`).
    private func approveCalls(_ core: FakeCore) -> [FakeCore.Call] {
        core.calls.filter { $0.method == "agents.approve" }
    }

    private struct ApproveParams: Decodable {
        let sessionId: String
        let approvalId: String
        let allow: Bool
    }

    // MARK: - Показ

    func testBlockPresentationIsTheSameAsInTaskCard() {
        let shell = ApprovalRequest(
            createdAt: 1, detail: "Размер: 1 строка, 8 знаков\nКаталог сессии: /work/shop", id: "r", kind: .shell,
            summary: "Выполнить команду", target: "npm test\n&& echo ok", tool: "Bash"
        )
        let presentation = ApprovalPresentation(shell)
        XCTAssertEqual(presentation.summary, "Выполнить команду")
        XCTAssertEqual(presentation.command, "npm test\n&& echo ok", "команда — целиком, как у задач")
        XCTAssertNil(presentation.inlineTarget)
        XCTAssertEqual(presentation.detail, "Размер: 1 строка, 8 знаков\nКаталог сессии: /work/shop")

        let write = ApprovalPresentation(request())
        XCTAssertEqual(write.inlineTarget, "/work/shop/a.txt")
        XCTAssertNil(write.command)
    }

    func testTileAndStatusSayWaitingForConfirmationInsteadOfRawReason() {
        let waiting = session("a", .waiting)
        XCTAssertEqual(waiting.tileCaption, "permission prompt", "без хука — причина реестра, как сегодня")
        XCTAssertEqual(waiting.statusLine, "ждёт вас: permission prompt")

        let asked = session("a", .waiting, approval: request())
        XCTAssertEqual(asked.tileCaption, "ждёт подтверждения")
        XCTAssertEqual(asked.statusLine, "ждёт подтверждения")
        XCTAssertEqual(asked.mood(finished: false), .waiting)
        // Реестр агента мог отстать от хука: сессия ещё working, а запрос уже есть — зовёт человека всё равно.
        let lagging = session("b", .working, approval: request())
        XCTAssertEqual(lagging.mood(finished: false), .waiting)
        XCTAssertEqual(AgentsSummary(sessions: [lagging], finished: []).waiting.map(\.id), ["b"])
    }

    // MARK: - Ответ ядру

    func testApproveAgentSendsOneRequestWithSessionApprovalAndAllow() async throws {
        let (state, core) = makeState()
        state.applyAgents([session("s1", approval: request("req-9"))])
        state.openAgent(id: "s1")

        state.approveAgent(sessionId: "s1", allow: true)
        state.approveAgent(sessionId: "s1", allow: false)
        XCTAssertEqual(state.approvalPending, ["req-9"])
        try await until("запроса agents.approve") { !approveCalls(core).isEmpty }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(approveCalls(core).count, 1, "повторный клик, пока ответ в пути, не уходит")
        let params = try JSONDecoder().decode(ApproveParams.self, from: approveCalls(core)[0].params)
        XCTAssertEqual(params.sessionId, "s1")
        XCTAssertEqual(params.approvalId, "req-9")
        XCTAssertTrue(params.allow)
        XCTAssertEqual(state.mode, .agent(sessionId: "s1"), "карточка остаётся открытой")

        approveCalls(core)[0].reply(.success(Data("{}".utf8)))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(state.approvalPending, ["req-9"], "ответ {} — ждём снимка")

        // Снимок без запроса: ожидание снято, блока нет.
        state.applyAgents([session("s1", .working)])
        XCTAssertTrue(state.approvalPending.isEmpty)
        XCTAssertNil(state.agent(id: "s1")?.approval)
        XCTAssertNil(state.approvalError)
    }

    func testCoreErrorShowsReasonAndNextSnapshotClearsIt() async throws {
        let (state, core) = makeState()
        state.applyAgents([session("s1", approval: request("req-1"))])
        state.approveAgent(sessionId: "s1", allow: false)
        try await until("запроса agents.approve") { approveCalls(core).count == 1 }
        approveCalls(core)[0].reply(.failure(RpcFailure(code: -32602, message: "approval is outdated: req-1")))
        try await until("ошибки") { state.approvalError != nil }
        XCTAssertTrue(state.approvalPending.isEmpty, "кнопки снова активны")
        XCTAssertEqual(state.approvalError, "approval is outdated: req-1")

        state.applyAgents([session("s1", approval: request("req-2"))])
        XCTAssertNil(state.approvalError, "следующий снимок стирает ошибку")
    }

    func testStaleErrorIsNotShownWhenRequestAlreadyGone() async throws {
        let (state, core) = makeState()
        state.applyAgents([session("s1", approval: request("req-1"))])
        state.approveAgent(sessionId: "s1", allow: true)
        try await until("запроса agents.approve") { approveCalls(core).count == 1 }
        // Ответили в терминале: снимок без запроса пришёл раньше отказа ядра.
        state.applyAgents([session("s1", .working)])
        approveCalls(core)[0].reply(.failure(RpcFailure(code: -32602, message: "session is not waiting for approval: s1")))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(state.approvalError, "блока уже нет — ошибке некуда показываться")
        XCTAssertTrue(state.approvalPending.isEmpty)
    }

    func testApproveIgnoresSessionsWithoutApprovalAndWithoutCore() async throws {
        let (state, core) = makeState()
        state.applyAgents([session("s1")])
        state.approveAgent(sessionId: "s1", allow: true)
        state.approveAgent(sessionId: "missing", allow: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(approveCalls(core).isEmpty)

        let offline = AppState()
        offline.applyAgents([session("s1", approval: request())])
        offline.approveAgent(sessionId: "s1", allow: true)
        XCTAssertTrue(offline.approvalPending.isEmpty)
        XCTAssertNotNil(offline.approvalError)
    }

    func testEnterAndSpaceNeverAnswerTheRequest() async throws {
        let (state, core) = makeState()
        state.applyAgents([session("s1", approval: request())])
        state.openAgent(id: "s1")

        // ↩ — переход к окну сессии, пробел — окно Luna; ни то ни другое ядру не отвечает.
        XCTAssertTrue(state.handleAgentKey(keyCode: 49, command: false))
        state.openAgent(id: "s1")
        XCTAssertTrue(state.handleAgentKey(keyCode: 36, command: false))
        state.openAgent(id: "s1")
        // Esc закрывает карточку, не отвечая.
        XCTAssertTrue(state.handleAgentKey(keyCode: 53, command: false))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(approveCalls(core).isEmpty)
        XCTAssertNotNil(state.agent(id: "s1")?.approval, "запрос на месте")
        XCTAssertTrue(state.approvalPending.isEmpty)
    }

    // MARK: - Pill и порядок

    func testPillCountsSessionsWithApprovalAlongsideTasks() {
        let (state, _) = makeState()
        XCTAssertEqual(state.pillState, .idle)
        state.applyAgents([session("waiting-only"), session("asked", approval: request())])
        XCTAssertEqual(state.pillState, .needsApproval(1), "ждущая сессия без запроса в needsApproval не входит")
        XCTAssertEqual(state.statusChips.first { $0.kind == .approval }?.count, 1, "число чипа совпадает с needsApproval")
        XCTAssertEqual(state.statusChips.first { $0.kind == .attention }?.count, 1, "без запроса ждёт одна сессия")

        state.apply(task("t", approval: request("req-task", createdAt: 20)))
        XCTAssertEqual(state.pillState, .needsApproval(2))
        XCTAssertEqual(state.statusChips.first { $0.kind == .approval }?.count, 2)
        XCTAssertEqual(state.shownPillPresentation?.text ?? state.pillPresentation?.text, "Нужно подтверждений: 2")

        XCTAssertEqual(PillState.aggregate(tasks: [], unseen: [], hasProblem: true, agentApprovals: 1), .needsApproval(1), "запрос главнее ошибки")
        XCTAssertEqual(PillState.aggregate(tasks: [], unseen: [], hasProblem: false), .idle)
    }

    func testPillClickOpensEarliestRequestAmongTasksAndSessions() {
        let (state, _) = makeState()
        state.apply(task("t", approval: request("req-task", createdAt: 30)))
        state.applyAgents([session("late", approval: request("r-late", createdAt: 40)), session("early", approval: request("r-early", createdAt: 20), startedAt: 5)])
        XCTAssertEqual(state.pendingApprovals.map(\.subject), [.session(id: "early"), .task(id: "t"), .session(id: "late")])

        state.pillClicked()
        XCTAssertEqual(state.mode, .agent(sessionId: "early"), "самый ранний запрос — у сессии")
        XCTAssertEqual(state.otherPendingApprovals(than: .session(id: "early")).count, 2)
        XCTAssertEqual(ApprovalPresentation.othersLine(state.otherPendingApprovals(than: .session(id: "early")).count), "ещё 2 ждут подтверждения")

        state.openNextApproval(after: .session(id: "early"))
        XCTAssertEqual(state.mode, .result(threadId: "t"), "следующий по порядку — задача")
        state.openNextApproval(after: .task(id: "t"))
        XCTAssertEqual(state.mode, .agent(sessionId: "early"))
    }

    func testNewRequestEnlivensIslandWithoutStateChange() {
        let (state, _) = makeState()
        var enlivened = 0
        state.enliven = { enlivened += 1 }
        state.applyAgents([session("s1")])
        let base = enlivened
        state.applyAgents([session("s1", approval: request("r1"))])
        XCTAssertEqual(enlivened, base + 1, "запрос у уже ждущей сессии — событие")
        state.applyAgents([session("s1", approval: request("r1"))])
        XCTAssertEqual(enlivened, base + 1, "тот же запрос повторно — не событие")
    }

    func testAnswerRoutesToTaskOrSession() async throws {
        let (state, core) = makeState()
        state.apply(task("t", approval: request("req-task")))
        state.applyAgents([session("s1", approval: request("req-session"))])
        state.answerApproval(.task(id: "t"), allow: true)
        state.answerApproval(.session(id: "s1"), allow: false)
        try await until("двух запросов") { core.calls.count == 2 }
        XCTAssertEqual(Set(core.calls.map(\.method)), ["task.approve", "agents.approve"])
    }
}
