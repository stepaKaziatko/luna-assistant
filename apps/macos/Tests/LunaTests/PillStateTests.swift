import XCTest
@testable import Luna

final class PillStateTests: XCTestCase {
    private func task(_ id: String, _ status: TaskStatus) -> TaskInfo {
        TaskInfo(
            approval: nil, context: nil, createdAt: 0, error: nil, executor: .claudeCode, finishedAt: nil,
            id: id, model: nil, progress: nil, prompt: "p", result: nil, sessionId: nil, status: status, threadId: id
        )
    }

    func testIdleWithoutTasks() {
        XCTAssertEqual(PillState.aggregate(tasks: [], unseen: [], hasProblem: false), .idle)
    }

    func testCountsQueuedAndRunningAsRunning() {
        let tasks = [task("a", .queued), task("b", .running), task("c", .cancelled)]
        XCTAssertEqual(PillState.aggregate(tasks: tasks, unseen: [], hasProblem: false), .running(2))
    }

    func testDoneOutranksRunningUntilSeen() {
        let tasks = [task("a", .running), task("b", .done)]
        XCTAssertEqual(PillState.aggregate(tasks: tasks, unseen: ["b"], hasProblem: false), .done(1))
        XCTAssertEqual(PillState.aggregate(tasks: tasks, unseen: [], hasProblem: false), .running(1))
    }

    func testErrorOutranksDone() {
        let tasks = [task("a", .done), task("b", .failed)]
        XCTAssertEqual(PillState.aggregate(tasks: tasks, unseen: ["a", "b"], hasProblem: false), .error(1))
    }

    func testCoreProblemShowsError() {
        XCTAssertEqual(PillState.aggregate(tasks: [], unseen: [], hasProblem: true), .error(1))
    }
}

/// Подтверждение действия исполнителя в агрегатах шторки.
final class PillApprovalTests: XCTestCase {
    private func task(_ id: String, _ status: TaskStatus, approval: Bool = false) -> TaskInfo {
        let request = ApprovalRequest(
            createdAt: 1, detail: "hi", id: "req-\(id)", kind: .write, summary: "Записать файл", target: "/work/hello.txt", tool: "Write"
        )
        return TaskInfo(
            approval: approval ? request : nil, context: nil, createdAt: 0, error: nil, executor: .claudeCode, finishedAt: nil,
            id: id, model: nil, progress: nil, prompt: "p", result: nil, sessionId: nil, status: status, threadId: id
        )
    }

    private func session(_ id: String, _ state: AgentState, approval: ApprovalRequest? = nil) -> AgentSession {
        AgentSession(
            activity: nil, agent: "claude-code", approval: approval, cwd: "/work/shop",
            host: AgentHost(appPath: nil, kind: .unknown, name: nil, tty: nil, workspace: nil), id: id, model: nil, openUrl: nil,
            pid: 1, project: "shop", startedAt: 0, state: state, title: "сессия \(id)", trail: nil, updatedAt: 0, waitingFor: nil
        )
    }

    func testApprovalOutranksErrorAndCountsOnlyRunningWithApproval() {
        let tasks = [task("a", .running, approval: true), task("b", .failed)]
        XCTAssertEqual(PillState.aggregate(tasks: tasks, unseen: ["b"], hasProblem: false), .needsApproval(1))
        XCTAssertEqual(PillState.aggregate(tasks: tasks, unseen: ["b"], hasProblem: true), .needsApproval(1))
        XCTAssertEqual(PillState.aggregate(tasks: [task("a", .running), task("b", .failed)], unseen: ["b"], hasProblem: false), .error(1))
        // approval у завершённой задачи — остаток, ждать нечего.
        XCTAssertEqual(PillState.aggregate(tasks: [task("a", .done, approval: true)], unseen: ["a"], hasProblem: false), .done(1))
        XCTAssertEqual(
            PillState.aggregate(tasks: [task("a", .running, approval: true), task("b", .running, approval: true)], unseen: [], hasProblem: false),
            .needsApproval(2)
        )
    }

    func testPresentationCallsHumanAboveWaitingAgent() {
        let agents = AgentsSummary(sessions: [session("s", .waiting)], finished: [])
        let one = PillPresentation.make(tasks: .needsApproval(1), taskProgress: "пишет hello.txt", agents: agents)
        XCTAssertEqual(one?.mood, .waiting)
        XCTAssertEqual(one?.tone, .attention)
        XCTAssertEqual(one?.text, "Нужно подтверждение")
        XCTAssertEqual(PillPresentation.make(tasks: .needsApproval(2), taskProgress: nil, agents: agents)?.text, "Нужно подтверждений: 2")
        XCTAssertEqual(PillPresentation.make(tasks: .running(1), taskProgress: nil, agents: agents)?.text, "shop ждёт вас")
    }

    func testStatusLineAndIndicatorForWaitingTask() {
        XCTAssertEqual(task("a", .running, approval: true).statusLine, "ждёт подтверждения")
        XCTAssertEqual(task("a", .running).statusLine, "Думаю…")
        XCTAssertEqual(task("a", .failed).statusLine, "Ошибка")
        XCTAssertEqual(task("a", .queued).statusLine, "В очереди")
        // approval у завершённой задачи — остаток: строка прежняя.
        XCTAssertEqual(task("a", .done, approval: true).statusLine, "Готово")

        XCTAssertEqual(DialogIndicator.glyph(for: task("a", .running, approval: true), isUnseen: false), .awaitingApproval)
        XCTAssertEqual(DialogIndicator.glyph(for: task("a", .running), isUnseen: false), .working)
        XCTAssertEqual(DialogIndicator.glyph(for: task("a", .done, approval: true), isUnseen: true), .doneUnseen)
        XCTAssertEqual(DialogIndicator.glyph(for: task("a", .failed), isUnseen: true), .failed)
    }

    private func request(_ id: String) -> ApprovalRequest {
        ApprovalRequest(createdAt: 1, detail: "hi", id: id, kind: .write, summary: "Записать файл", target: "/work/hello.txt", tool: "Write")
    }

    func testApprovalChipStandsAboveFailureAndCountsTasksWithApproval() {
        let tasks = [
            task("wait", .running, approval: true), task("fail", .failed), task("ok", .done), task("run", .running),
        ]
        let chips = StatusChip.make(
            tasks: tasks, unseen: ["fail", "ok"], hasProblem: false, agents: AgentsSummary(sessions: [], finished: [])
        )
        XCTAssertEqual(chips.map(\.kind), [.approval, .failure, .success, .working], "в порядке needsApproval > error > done > running")
        XCTAssertEqual(chips.first?.count, 1)
        XCTAssertEqual(chips.first { $0.kind == .working }?.count, 2, "ждущая задача по-прежнему в работе")
        XCTAssertNil(chips.first { $0.kind == .attention }, "задача с запросом в «ждут вас» не входит")
        XCTAssertEqual(
            PillState.aggregate(tasks: tasks, unseen: ["fail", "ok"], hasProblem: false), .needsApproval(1),
            "одна ждёт, одна упала — показано ожидание"
        )
        XCTAssertEqual(chips.first?.title, "Ждут подтверждения: 1")
    }

    func testAttentionChipLeavesSessionsWithApprovalToApprovalChip() {
        let sessions = [session("calls", .waiting), session("asked", .working, approval: request("r1"))]
        let agents = AgentsSummary(sessions: sessions, finished: [])
        let chips = StatusChip.make(tasks: [task("a", .running, approval: true)], unseen: [], hasProblem: false, agents: agents)
        XCTAssertEqual(chips.first { $0.kind == .approval }?.count, 2, "задача и сессия с запросом")
        XCTAssertEqual(chips.first { $0.kind == .attention }?.count, 1, "ждёт только сессия без запроса")
        XCTAssertEqual(chips.first { $0.kind == .working }?.count, 1, "ждущая задача по-прежнему в работе")
        let aggregate = PillState.aggregate(
            tasks: [task("a", .running, approval: true)], unseen: [], hasProblem: false,
            agentApprovals: sessions.count { $0.approval != nil }
        )
        XCTAssertEqual(aggregate, .needsApproval(2))
        XCTAssertEqual(chips.first { $0.kind == .approval }?.count, 2, "число чипа совпадает с needsApproval(n)")

        let plain = StatusChip.make(tasks: [task("a", .running)], unseen: [], hasProblem: false, agents: AgentsSummary(sessions: [], finished: []))
        XCTAssertNil(plain.first { $0.kind == .approval })
        XCTAssertNil(plain.first { $0.kind == .attention })
    }
}
