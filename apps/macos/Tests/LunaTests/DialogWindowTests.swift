import Combine
import XCTest
@testable import Luna

/// Окна «Открыть полностью»: какие диалоги открыты — состояние `AppState`, проверяемое без окон.
@MainActor
final class DialogWindowTests: XCTestCase {
    private func task(_ id: String, _ status: TaskStatus = .done, thread: String? = nil, createdAt: Int) -> TaskInfo {
        TaskInfo(
            approval: nil, context: nil, createdAt: createdAt, error: nil, executor: .claudeCode, finishedAt: nil, id: id,
            model: nil, progress: nil, prompt: "запрос \(id)", result: "ответ \(id)", sessionId: "s", status: status, threadId: thread ?? id
        )
    }

    private func state(_ tasks: [TaskInfo]) -> AppState {
        let state = AppState()
        state.applyHistory(tasks)
        return state
    }

    func testReopeningSameDialogRaisesWindowInsteadOfAddingSecond() {
        let state = state([task("a", createdAt: 1), task("a2", thread: "a", createdAt: 2)])
        var raised: [String] = []
        let subscription = state.windowRaised.sink { raised.append($0) }
        defer { subscription.cancel() }

        state.openWindow(threadId: "a")
        XCTAssertEqual(state.openWindows, ["a"])
        XCTAssertEqual(raised, [])

        state.openWindow(threadId: "a")
        XCTAssertEqual(state.openWindows, ["a"])
        XCTAssertEqual(raised, ["a"])
    }

    func testWindowsOfDifferentDialogsAreOpenTogetherAndCloseSeparately() {
        let state = state([task("a", createdAt: 1), task("b", createdAt: 2)])
        state.openWindow(threadId: "a")
        state.openWindow(threadId: "b")
        XCTAssertEqual(state.openWindows, ["a", "b"])

        state.closeWindow(threadId: "a")
        XCTAssertEqual(state.openWindows, ["b"])
        state.closeWindow(threadId: "missing")
        XCTAssertEqual(state.openWindows, ["b"])
    }

    func testUnknownDialogDoesNotOpenWindow() {
        let state = state([task("a", createdAt: 1)])
        state.openWindow(threadId: "missing")
        XCTAssertEqual(state.openWindows, [])
    }

    func testDeletedDialogClosesItsWindowOnly() {
        let state = state([task("a", createdAt: 1), task("a2", thread: "a", createdAt: 2), task("b", createdAt: 3)])
        state.openWindow(threadId: "a")
        state.openWindow(threadId: "b")

        // Пока у диалога осталась хоть одна задача, окно на месте.
        state.removeDeleted(["a2"])
        XCTAssertEqual(state.openWindows, ["a", "b"])

        state.removeDeleted(["a"])
        XCTAssertEqual(state.openWindows, ["b"])
    }

    func testCardAndListDoNotTouchWindows() {
        let state = state([task("a", createdAt: 1), task("b", createdAt: 2)])
        state.open(threadId: "a")
        state.openWindow(threadId: "a")
        state.openWindow(threadId: "b")

        state.collapse()
        XCTAssertEqual(state.mode, .pill)
        XCTAssertEqual(state.openWindows, ["a", "b"])

        state.showTasks()
        XCTAssertEqual(state.mode, .tasks)
        XCTAssertEqual(state.openWindows, ["a", "b"])

        state.open(threadId: "b")
        XCTAssertEqual(state.openWindows, ["a", "b"])
    }

    func testOpenWindowDoesNotChangeCardOrUnseen() {
        let state = state([task("a", .running, createdAt: 1)])
        state.open(threadId: "a")
        state.openWindow(threadId: "a")
        state.collapse()

        // Логика непросмотренных не меняется: открытое окно задачу просмотренной не делает.
        state.apply(task("a", createdAt: 1))
        XCTAssertEqual(state.unseen, ["a"])
        XCTAssertEqual(state.mode, .pill)
        XCTAssertEqual(state.openWindows, ["a"])
    }
}
