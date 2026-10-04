import XCTest
@testable import Luna

@MainActor
final class TaskHistoryTests: XCTestCase {
    private func task(_ id: String, _ status: TaskStatus, createdAt: Int, result: String? = nil) -> TaskInfo {
        TaskInfo(
            context: nil, createdAt: createdAt, error: nil, executor: .claudeCode, finishedAt: nil,
            id: id, progress: nil, prompt: "p", result: result, sessionId: nil, status: status
        )
    }

    func testHistoryIsAddedInCreationOrder() {
        // task.list отдаёт новые первыми.
        let listed = [task("c", .failed, createdAt: 3), task("b", .done, createdAt: 2), task("a", .cancelled, createdAt: 1)]
        XCTAssertEqual(TaskHistory.merge(current: [], listed: listed).map(\.id), ["a", "b", "c"])
    }

    func testEventSnapshotIsNotOverwrittenByHistory() {
        let fromEvent = task("b", .done, createdAt: 2, result: "свежий")
        let listed = [task("b", .running, createdAt: 2), task("a", .done, createdAt: 1)]
        let merged = TaskHistory.merge(current: [fromEvent, task("new", .running, createdAt: 5)], listed: listed)
        XCTAssertEqual(merged.map(\.id), ["a", "b", "new"])
        XCTAssertEqual(merged[1].status, .done)
        XCTAssertEqual(merged[1].result, "свежий")
    }

    func testHistoryKeepsPillIdleAndUnseenEmpty() {
        let state = AppState()
        state.applyHistory([task("b", .failed, createdAt: 2), task("a", .done, createdAt: 1)])
        XCTAssertEqual(state.tasks.map(\.id), ["a", "b"])
        XCTAssertTrue(state.unseen.isEmpty)
        XCTAssertEqual(state.pillState, .idle)
        XCTAssertEqual(state.listedTasks.map(\.id), ["b", "a"])
    }

    func testTaskFromEventStaysUnseenAfterHistoryLoad() {
        let state = AppState()
        state.apply(task("live", .done, createdAt: 10, result: "ok"))
        state.applyHistory([task("old", .done, createdAt: 1)])
        XCTAssertEqual(state.tasks.map(\.id), ["old", "live"])
        XCTAssertEqual(state.unseen, ["live"])
        XCTAssertEqual(state.pillState, .done(1))
    }

    func testLastResultOpensNewestHistoryTask() {
        let state = AppState()
        state.applyHistory([task("b", .done, createdAt: 2), task("a", .done, createdAt: 1)])
        state.openLastResult()
        XCTAssertEqual(state.mode, .result(taskId: "b"))
    }
}
