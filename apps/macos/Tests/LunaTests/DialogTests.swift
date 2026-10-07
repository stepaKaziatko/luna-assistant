import XCTest
@testable import Luna

@MainActor
final class DialogTests: XCTestCase {
    private func task(
        _ id: String, _ status: TaskStatus, thread: String? = nil, createdAt: Int,
        sessionId: String? = "s", error: TaskErrorKind? = nil
    ) -> TaskInfo {
        TaskInfo(
            approval: nil, context: nil, createdAt: createdAt, error: error.map { TaskError(kind: $0, message: "ошибка") },
            executor: .claudeCode, finishedAt: nil, id: id, model: nil, progress: nil, prompt: "запрос \(id)", result: nil,
            sessionId: sessionId, status: status, threadId: thread ?? id
        )
    }

    // MARK: - Группировка

    func testGroupsByThreadInCreationOrderNewestDialogFirst() {
        let tasks = [
            task("a", .done, createdAt: 1),
            task("b", .done, createdAt: 2),
            task("a2", .done, thread: "a", createdAt: 3),
            task("c", .failed, createdAt: 4),
            task("a3", .running, thread: "a", createdAt: 5),
        ]
        let dialogs = Dialog.group(tasks)
        XCTAssertEqual(dialogs.map(\.threadId), ["a", "c", "b"])

        let a = dialogs[0]
        XCTAssertEqual(a.tasks.map(\.id), ["a", "a2", "a3"])
        XCTAssertEqual(a.title, "запрос a")
        XCTAssertEqual(a.last.status, .running)
        XCTAssertEqual(a.followUpCount, 2)
        XCTAssertEqual(a.activeTask?.id, "a3")
        XCTAssertEqual(dialogs[1].followUpCount, 0)
        XCTAssertNil(dialogs[1].activeTask)
    }

    func testDialogWithoutFirstTaskGroupsTheRest() {
        // Начало диалога не попало в task.list: заголовок — от самой ранней известной задачи.
        let dialogs = Dialog.group([
            task("x3", .done, thread: "x", createdAt: 30),
            task("x2", .done, thread: "x", createdAt: 20),
        ])
        XCTAssertEqual(dialogs.count, 1)
        XCTAssertEqual(dialogs[0].threadId, "x")
        XCTAssertEqual(dialogs[0].title, "запрос x2")
        XCTAssertEqual(dialogs[0].last.id, "x3")
        XCTAssertEqual(dialogs[0].followUpCount, 1)
    }

    // MARK: - Точка продолжения

    func testContinuesLastDoneWithSession() {
        let tasks = [task("a", .done, createdAt: 1), task("a2", .done, thread: "a", createdAt: 2)]
        XCTAssertEqual(Dialog.continuationPoint(of: tasks)?.id, "a2")
    }

    func testFailedOrCancelledFollowUpKeepsDialogOpen() {
        let tasks = [
            task("a", .done, createdAt: 1),
            task("a2", .failed, thread: "a", createdAt: 2, error: .rateLimit),
            task("a3", .cancelled, thread: "a", createdAt: 3),
        ]
        XCTAssertEqual(Dialog.continuationPoint(of: tasks)?.id, "a")
    }

    func testNoContinuationWhileActive() {
        let tasks = [task("a", .done, createdAt: 1), task("a2", .queued, thread: "a", createdAt: 2)]
        XCTAssertNil(Dialog.continuationPoint(of: tasks))
    }

    func testNoContinuationAfterLostSession() {
        let tasks = [task("a", .done, createdAt: 1), task("a2", .failed, thread: "a", createdAt: 2, error: .sessionNotFound)]
        XCTAssertNil(Dialog.continuationPoint(of: tasks))
    }

    func testNoContinuationWithoutDoneOrSession() {
        XCTAssertNil(Dialog.continuationPoint(of: [task("a", .failed, createdAt: 1, error: .auth)]))
        XCTAssertNil(Dialog.continuationPoint(of: [task("a", .done, createdAt: 1, sessionId: nil)]))
    }

    // MARK: - AppState

    func testFollowUpFinishedWhileDialogIsOpenIsNotUnseen() {
        let state = AppState()
        state.applyHistory([task("a", .done, createdAt: 1)])
        state.open(threadId: "a")
        XCTAssertEqual(state.mode, .result(threadId: "a"))

        state.apply(task("a2", .running, thread: "a", createdAt: 2))
        state.apply(task("a2", .done, thread: "a", createdAt: 2))
        XCTAssertTrue(state.unseen.isEmpty)
        XCTAssertEqual(state.mode, .result(threadId: "a"), "карточка остаётся на диалоге")

        state.collapse()
        state.apply(task("a3", .done, thread: "a", createdAt: 3))
        XCTAssertEqual(state.unseen, ["a3"])
        // Клик по pill ведёт в карточку этого диалога.
        state.pillClicked()
        XCTAssertEqual(state.mode, .result(threadId: "a"))
        XCTAssertTrue(state.unseen.isEmpty)
    }

    func testTaskListShowsOneRowPerDialog() {
        let state = AppState()
        state.applyHistory([
            task("b", .done, createdAt: 3),
            task("a2", .done, thread: "a", createdAt: 2),
            task("a", .done, createdAt: 1),
        ])
        state.showTasks()
        XCTAssertEqual(state.listedDialogs.map(\.threadId), ["b", "a"])
        state.moveSelection(by: 1)
        state.openSelectedTask()
        XCTAssertEqual(state.mode, .result(threadId: "a"))
    }

    func testTabFocusesFollowUpOnlyWhenDialogCanContinue() {
        let state = AppState()
        state.applyHistory([task("a", .done, createdAt: 1), task("b", .failed, createdAt: 2, error: .auth)])
        state.open(threadId: "a")
        XCTAssertTrue(state.focusFollowUp())
        XCTAssertEqual(state.followUpFocusRequest, 1)
        state.open(threadId: "b")
        XCTAssertFalse(state.focusFollowUp())
    }

    func testFollowUpWithoutCoreKeepsText() {
        let state = AppState()
        state.applyHistory([task("a", .done, createdAt: 1)])
        state.open(threadId: "a")
        state.followUpDraft = "  \n "
        state.submitFollowUp()
        XCTAssertNil(state.followUpError, "пустое уточнение не отправляется")

        state.followUpDraft = "а покороче?"
        state.submitFollowUp()
        XCTAssertEqual(state.followUpDraft, "а покороче?")
        XCTAssertNotNil(state.followUpError)
    }
}
