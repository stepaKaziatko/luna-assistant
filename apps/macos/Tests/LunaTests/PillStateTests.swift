import XCTest
@testable import Luna

final class PillStateTests: XCTestCase {
    private func task(_ id: String, _ status: TaskStatus) -> TaskInfo {
        TaskInfo(
            context: nil, createdAt: 0, error: nil, executor: .claudeCode, finishedAt: nil,
            id: id, progress: nil, prompt: "p", result: nil, sessionId: nil, status: status
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
