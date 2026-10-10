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
            activity: nil, agent: "claude-code", approval: nil, cwd: "/work/shop",
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

    // MARK: Несколько запросов, отмена и устаревший ответ (LUNA-49)

    func testOthersLineCountsOtherWaitingTasksAndOpensEarliestOther() {
        let (state, _) = makeState()
        state.apply(task("late", createdAt: 1, approval: request("req-late", createdAt: 30)))
        XCTAssertTrue(state.otherApprovals(than: "late").isEmpty, "одна задача — строки нет")
        XCTAssertNil(ApprovalPresentation.othersLine(state.otherApprovals(than: "late").count))

        state.apply(task("early", createdAt: 2, approval: request("req-early", createdAt: 20)))
        state.apply(task("plain", createdAt: 3))
        XCTAssertEqual(state.approvalQueue.map(\.id), ["early", "late"], "порядок — по createdAt запроса")
        XCTAssertEqual(ApprovalPresentation.othersLine(state.otherApprovals(than: "early").count), "ещё 1 ждёт подтверждения")
        XCTAssertEqual(ApprovalPresentation.othersLine(state.otherApprovals(than: "late").count), "ещё 1 ждёт подтверждения")

        state.pillClicked()
        XCTAssertEqual(state.mode, .result(threadId: "early"))
        state.openNextApproval(after: "early")
        XCTAssertEqual(state.mode, .result(threadId: "late"), "строка ведёт к самой ранней другой")
        state.openNextApproval(after: "late")
        XCTAssertEqual(state.mode, .result(threadId: "early"))

        // Ответ на открытую задачу карточку на следующую не переключает.
        state.apply(task("early"))
        XCTAssertEqual(state.mode, .result(threadId: "early"))
        XCTAssertEqual(state.approvalQueue.map(\.id), ["late"])
        state.openNextApproval(after: "late")
        XCTAssertEqual(state.mode, .result(threadId: "early"), "других ждущих нет — клик ничего не открывает")
    }

    func testApprovalOrderTiesAndPlurals() {
        let (state, _) = makeState()
        state.apply(task("b", createdAt: 5, approval: request("r-b", createdAt: 10)))
        state.apply(task("a", createdAt: 4, approval: request("r-a", createdAt: 10)))
        state.apply(task("c", createdAt: 1, approval: request("r-c", createdAt: 11)))
        XCTAssertEqual(state.approvalQueue.map(\.id), ["a", "b", "c"], "равный createdAt запроса — по createdAt задачи")
        XCTAssertEqual(state.otherApprovals(than: "c").map(\.id), ["a", "b"])
        XCTAssertEqual(ApprovalPresentation.othersLine(2), "ещё 2 ждут подтверждения")
        XCTAssertEqual(ApprovalPresentation.othersLine(5), "ещё 5 ждут подтверждения")
        XCTAssertEqual(ApprovalPresentation.othersLine(11), "ещё 11 ждут подтверждения")
        XCTAssertEqual(ApprovalPresentation.othersLine(21), "ещё 21 ждёт подтверждения")
        XCTAssertNil(ApprovalPresentation.othersLine(0))
    }

    func testCancelledSnapshotWithoutApprovalClearsPendingAndErrorAndBlock() async throws {
        let (state, core) = makeState()
        state.apply(task("a", approval: request()))
        state.pillClicked()
        state.approve(taskId: "a", allow: true)
        try await until("запроса task.approve") { core.calls.count == 1 }
        XCTAssertEqual(state.approvalPending, ["req-1"])

        state.apply(task("a", .cancelled))
        XCTAssertTrue(state.approvalPending.isEmpty)
        XCTAssertNil(state.approvalError)
        XCTAssertNil(state.task(id: "a")?.approval)
        XCTAssertFalse(state.task(id: "a")?.isAwaitingApproval ?? true, "блока нет")
        XCTAssertTrue(state.approvalQueue.isEmpty)

        // Ядро отклонило ответ на снятый запрос уже после снимка: блока нет, ошибку показывать некуда, ждать нечего.
        core.calls[0].reply(.failure(RpcFailure(code: -32602, message: "task not found or finished: a")))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(state.approvalPending.isEmpty)
        XCTAssertNil(state.approvalError)
        XCTAssertFalse(state.task(id: "a")?.isAwaitingApproval ?? true)
    }

    func testNextApprovalOfSameTaskHasActiveButtons() async throws {
        let (state, core) = makeState()
        state.apply(task("a", approval: request("req-1")))
        state.pillClicked()
        state.approve(taskId: "a", allow: true)
        try await until("запроса task.approve") { core.calls.count == 1 }
        XCTAssertEqual(state.approvalPending, ["req-1"])

        // Следующий запрос той же задачи из очереди ядра.
        state.apply(task("a", approval: request("req-2", createdAt: 11)))
        XCTAssertTrue(state.approvalPending.isEmpty, "кнопки нового запроса активны")
        XCTAssertFalse(state.approvalPending.contains("req-2"))
        XCTAssertEqual(state.task(id: "a")?.approval?.id, "req-2")
        XCTAssertEqual(state.mode, .result(threadId: "a"))

        // Ответ на первый приходит позже — новый запрос он не трогает, даже отказом ядра.
        core.calls[0].reply(.failure(RpcFailure(code: -32602, message: "approval is outdated: req-1")))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(state.approvalPending.isEmpty)
        XCTAssertNil(state.approvalError)

        state.approve(taskId: "a", allow: false)
        try await until("второго task.approve") { core.calls.count == 2 }
        let params = try JSONDecoder().decode(ApproveParams.self, from: core.calls[1].params)
        XCTAssertEqual(params.approvalId, "req-2")
        XCTAssertFalse(params.allow)
    }

    func testOutdatedAnswerErrorReenablesButtonsAndNextSnapshotClearsIt() async throws {
        let (state, core) = makeState()
        state.apply(task("a", approval: request()))
        state.pillClicked()
        state.approve(taskId: "a", allow: true)
        try await until("запроса task.approve") { core.calls.count == 1 }
        core.calls[0].reply(.failure(RpcFailure(code: -32602, message: "approval is outdated: req-1")))
        try await until("ошибки") { state.approvalError != nil }
        XCTAssertTrue(state.approvalPending.isEmpty, "кнопки снова активны")
        XCTAssertEqual(state.approvalError, "approval is outdated: req-1")
        XCTAssertTrue(state.task(id: "a")?.isAwaitingApproval ?? false, "блок на месте до снимка")

        state.apply(task("a", .failed))
        XCTAssertNil(state.approvalError, "снимок без approval убирает ошибку")
        XCTAssertFalse(state.task(id: "a")?.isAwaitingApproval ?? true)
    }

    // MARK: Команда shell (LUNA-48)

    private func shell(_ command: String) -> ApprovalRequest {
        ApprovalRequest(
            createdAt: 10, detail: "Размер: 4 строки, 9 знаков\nКаталог задачи: /work\nПодпись агента: собрать", id: "req-sh",
            kind: .shell, summary: "Выполнить команду", target: command, tool: "Bash"
        )
    }

    func testShellPresentationKeepsCommandExactlyAsTarget() {
        let multiline = "a\n  b\n\nc"
        let presentation = ApprovalPresentation(shell(multiline))
        XCTAssertEqual(presentation.command, multiline, "переводы строк и отступы на месте")
        XCTAssertEqual(presentation.command?.split(separator: "\n", omittingEmptySubsequences: false).count, 4, "строки не схлопнуты")
        XCTAssertNil(presentation.inlineTarget, "команда не попадает в строку с кнопками")
        XCTAssertEqual(presentation.summary, "Выполнить команду")
        XCTAssertEqual(presentation.detail, "Размер: 4 строки, 9 знаков\nКаталог задачи: /work\nПодпись агента: собрать")

        let long = String(repeating: "я", count: 20_000)
        XCTAssertEqual(ApprovalPresentation(shell(long)).command, long, "длинная команда — без обрезки")
        XCTAssertEqual(ApprovalPresentation(shell(long)).command?.count, 20_000)

        let spaced = "  echo 1  \n"
        XCTAssertEqual(ApprovalPresentation(shell(spaced)).command, spaced, "пробелы по краям и последний перевод строки не срезаны")
    }

    func testCommandScrollerThumb() {
        XCTAssertNil(CommandText.thumb(content: 100, visible: 100, offset: 0), "всё помещается — полосы нет")
        let top = try! XCTUnwrap(CommandText.thumb(content: 680, visible: 170, offset: 0))
        XCTAssertEqual(top.y, 3, "в начале бегунок наверху")
        XCTAssertEqual(top.height, 164 * 170 / 680, accuracy: 0.01, "высота — доля видимого")
        let bottom = try! XCTUnwrap(CommandText.thumb(content: 680, visible: 170, offset: 510))
        XCTAssertEqual(bottom.y + bottom.height, 167, accuracy: 0.01, "в конце бегунок внизу")
        let huge = try! XCTUnwrap(CommandText.thumb(content: 1_000_000, visible: 170, offset: 0))
        XCTAssertEqual(huge.height, 16, "у очень длинной команды бегунок не исчезает")
    }

    func testWritePresentationUnchanged() {
        let presentation = ApprovalPresentation(request())
        XCTAssertEqual(presentation.inlineTarget, "/work/hello.txt")
        XCTAssertNil(presentation.command)
        XCTAssertEqual(presentation.summary, "Записать файл")
        XCTAssertEqual(presentation.detail, "hi\n\nРазмер: 2 знака")

        let empty = ApprovalRequest(createdAt: 1, detail: "", id: "r", kind: .other, summary: "Использовать инструмент X", target: nil, tool: "X")
        XCTAssertNil(ApprovalPresentation(empty).detail, "пустые подробности не показываются")
        XCTAssertNil(ApprovalPresentation(empty).command)
    }
}

private struct EmptyReply: Encodable {}
