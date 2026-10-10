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

    private func session(_ id: String, _ state: AgentState) -> AgentSession {
        AgentSession(
            activity: nil, agent: "claude-code", approval: nil, cwd: "/work/shop",
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

    func testAttentionChipCountsWaitingTasks() {
        let agents = AgentsSummary(sessions: [session("s", .waiting)], finished: [])
        let chips = StatusChip.make(tasks: [task("a", .running, approval: true)], unseen: [], hasProblem: false, agents: agents)
        XCTAssertEqual(chips.first { $0.kind == .attention }?.count, 2)
        XCTAssertEqual(chips.first { $0.kind == .working }?.count, 1, "ждущая задача по-прежнему в работе")
        let plain = StatusChip.make(tasks: [task("a", .running)], unseen: [], hasProblem: false, agents: AgentsSummary(sessions: [], finished: []))
        XCTAssertNil(plain.first { $0.kind == .attention })
    }
}
