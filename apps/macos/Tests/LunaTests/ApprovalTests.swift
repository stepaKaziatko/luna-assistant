import XCTest
@testable import Luna

/// Подтверждение действия исполнителя в карточке диалога: pill, открытие карточки, ответ ядру, клавиши и закрытие.
@MainActor
final class ApprovalTests: XCTestCase {
    private func request(_ id: String = "req-1", createdAt: Int = 10) -> ApprovalRequest {
        ApprovalRequest(
            createdAt: createdAt, detail: "hi\n\nРазмер: 2 знака", id: id, kind: .write, summary: "Записать файл",
            target: "/work/hello.txt", tool: "Write"
        )
    }

    private func task(
        _ id: String, _ status: TaskStatus = .running, thread: String? = nil, createdAt: Int = 1, approval: ApprovalRequest? = nil,
        sessionId: String? = nil
    ) -> TaskInfo {
        TaskInfo(
            approval: approval, context: nil, createdAt: createdAt, error: nil, executor: .claudeCode, finishedAt: nil, id: id,
            model: nil, progress: "пишет hello.txt", prompt: "запрос \(id)", result: nil, sessionId: sessionId, status: status,
            threadId: thread ?? id
        )
    }

    private func session(_ id: String, _ state: AgentState) -> AgentSession {
        AgentSession(
            activity: nil, agent: "claude-code", cwd: "/work/shop",
            host: AgentHost(appPath: nil, kind: .unknown, name: nil, tty: nil, workspace: nil), id: id, model: nil, openUrl: nil,
            pid: 1, project: "shop", startedAt: 0, state: state, title: "сессия \(id)", trail: nil, updatedAt: 0, waitingFor: nil
        )
    }

    /// Ждёт условия, а не фиксированную паузу: ответы подставного ядра применяются в фоне.
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
        return (state, core)
    }

    private struct ApproveParams: Decodable {
        let taskId: String
        let approvalId: String
        let allow: Bool
    }

    func testNeedsApprovalChangesPillButOpensNothing() {
        let (state, _) = makeState()
        var enlivened = 0
        state.enliven = { enlivened += 1 }
        state.apply(task("a"))
        XCTAssertEqual(enlivened, 1, "новая задача оживляет шторку")

        state.apply(task("a", approval: request()))
        XCTAssertEqual(state.pillState, .needsApproval(1))
        XCTAssertEqual(state.mode, .pill, "карточка сама не открывается")
        XCTAssertTrue(state.unseen.isEmpty)
        XCTAssertEqual(enlivened, 2, "запрос подтверждения оживляет шторку, хотя статус не менялся")

        state.apply(task("a", approval: request()))
        XCTAssertEqual(enlivened, 2, "повторный снимок того же запроса — не событие")
        state.apply(task("a", approval: request("req-2")))
        XCTAssertEqual(enlivened, 3, "новый запрос — событие")
    }

    func testPillClickOpensOldestWaitingDialogAheadOfErrorsAndAgents() {
        let (state, _) = makeState()
        state.apply(task("failed", .failed, createdAt: 1))
        state.applyAgents([session("s", .waiting)])
        state.apply(task("late", createdAt: 2, approval: request("req-late", createdAt: 30)))
        state.apply(task("early", createdAt: 3, approval: request("req-early", createdAt: 20)))
        XCTAssertEqual(state.pillState, .needsApproval(2))
        XCTAssertEqual(state.unseen, ["failed"])

        state.pillClicked()
        XCTAssertEqual(state.mode, .result(threadId: "early"))
        XCTAssertNil(state.dialog(threadId: "early")?.continuationPoint, "у активной задачи поля продолжения нет")
    }

    func testEnterDoesNotApproveAndEscapeClosesWithoutAnswering() async throws {
        let (state, core) = makeState()
        state.apply(task("a", approval: request()))
        state.pillClicked()
        XCTAssertEqual(state.mode, .result(threadId: "a"))

        // ↩ в карточке панель отдаёт `handleCardKey`, который в `.result` знает только Tab; сам Tab здесь ничего
        // не фокусирует — поля продолжения у активной задачи нет. Нажатие ↩ в живой панели проверяет debug-сборка (`key:36`).
        XCTAssertFalse(state.focusFollowUp(), "Tab: поля продолжения у активной задачи нет")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(core.calls.isEmpty, "клавиши не отвечают ядру")

        state.collapse()
        XCTAssertEqual(state.mode, .pill)
        XCTAssertEqual(state.task(id: "a")?.approval?.id, "req-1", "запрос на месте")
        XCTAssertEqual(state.pillState, .needsApproval(1))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(core.calls.isEmpty)

        state.pillClicked()
        XCTAssertEqual(state.mode, .result(threadId: "a"), "повторный клик открывает ту же карточку")
    }

    func testApproveSendsRequestOnceAndWaitsForSnapshot() async throws {
        let (state, core) = makeState()
        state.apply(task("a", approval: request()))
        state.pillClicked()

        state.approve(taskId: "a", allow: true)
        XCTAssertEqual(state.approvalPending, ["req-1"])
        XCTAssertEqual(state.mode, .result(threadId: "a"), "карточка остаётся открытой")
        state.approve(taskId: "a", allow: false)
        try await until("запроса task.approve") { core.calls.count == 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(core.calls.count, 1, "повторный клик, пока ответ в пути, не уходит")
        XCTAssertEqual(core.calls[0].method, "task.approve")
        let params = try JSONDecoder().decode(ApproveParams.self, from: core.calls[0].params)
        XCTAssertEqual(params.taskId, "a")
        XCTAssertEqual(params.approvalId, "req-1")
        XCTAssertTrue(params.allow)

        core.reply(0, EmptyReply())
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(state.approvalPending, ["req-1"], "ответ {} — ждём снимка")
        XCTAssertEqual(state.task(id: "a")?.approval?.id, "req-1")

        state.apply(task("a"))
        XCTAssertTrue(state.approvalPending.isEmpty)
        XCTAssertNil(state.approvalError)
        XCTAssertEqual(state.mode, .result(threadId: "a"))
        XCTAssertEqual(state.pillState, .running(1))
        XCTAssertNil(state.task(id: "a")?.approval)
    }

    func testCoreErrorReenablesButtonsAndShowsReason() async throws {
        let (state, core) = makeState()
        state.apply(task("a", approval: request()))
        state.pillClicked()
        state.approve(taskId: "a", allow: false)
        try await until("запроса task.approve") { core.calls.count == 1 }
        let params = try JSONDecoder().decode(ApproveParams.self, from: core.calls[0].params)
        XCTAssertFalse(params.allow)

        core.calls[0].reply(.failure(RpcFailure(code: -32602, message: "approval is outdated: req-1")))
        try await until("ошибки") { state.approvalError != nil }
        XCTAssertTrue(state.approvalPending.isEmpty)
        XCTAssertEqual(state.approvalError, "approval is outdated: req-1")

        // Следующий снимок задачи стирает ошибку.
        state.apply(task("a", approval: request("req-2")))
        XCTAssertNil(state.approvalError)
        XCTAssertEqual(state.task(id: "a")?.approval?.id, "req-2")
    }

    func testApproveIgnoresTasksWithoutApprovalAndWithoutCore() async throws {
        let (state, core) = makeState()
        state.apply(task("a"))
        state.approve(taskId: "a", allow: true)
        state.approve(taskId: "missing", allow: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(core.calls.isEmpty)
        XCTAssertTrue(state.approvalPending.isEmpty)

        let offline = AppState()
        offline.apply(task("a", approval: request()))
        offline.approve(taskId: "a", allow: true)
        XCTAssertTrue(offline.approvalPending.isEmpty)
        XCTAssertNotNil(offline.approvalError)
    }

    func testSnapshotWithApprovalForAnotherDialogKeepsOpenCard() {
        let (state, _) = makeState()
        state.apply(task("b", .done, sessionId: "s"))
        state.open(threadId: "b")
        XCTAssertEqual(state.mode, .result(threadId: "b"))

        state.apply(task("a", approval: request()))
        XCTAssertEqual(state.mode, .result(threadId: "b"), "запрос другого диалога карточку не меняет")
        XCTAssertEqual(state.pillState, .needsApproval(1))
        XCTAssertTrue(state.unseen.isEmpty)

        // Смена карточки стирает ошибку подтверждения прежней.
        state.approve(taskId: "a", allow: true)
        state.pillClicked()
        XCTAssertEqual(state.mode, .result(threadId: "a"))
        XCTAssertNil(state.approvalError)
    }

    func testFinishedSnapshotClearsPendingAndStaysInCard() {
        let (state, _) = makeState()
        state.apply(task("a", approval: request()))
        state.pillClicked()
        state.approve(taskId: "a", allow: true)
        XCTAssertEqual(state.approvalPending, ["req-1"])

        state.apply(task("a", .cancelled))
        XCTAssertTrue(state.approvalPending.isEmpty)
        XCTAssertEqual(state.mode, .result(threadId: "a"))
        XCTAssertEqual(state.pillState, .idle)
    }
}

private struct EmptyReply: Encodable {}
