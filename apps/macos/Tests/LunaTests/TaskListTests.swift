import XCTest
@testable import Luna

/// Подставное ядро: запоминает запросы, а отвечает на них тест — в нужном ему порядке.
final class FakeCore: CoreRequesting, @unchecked Sendable {
    struct Call {
        let method: String
        let params: Data
        let reply: (Result<Data, Error>) -> Void
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] { lock.withLock { recorded } }

    func request<P: Encodable, R: Decodable>(_ method: String, _ params: P) async throws -> R {
        let encoded = try JSONEncoder().encode(params)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                recorded.append(Call(method: method, params: encoded) { continuation.resume(with: $0) })
            }
        }
        return try JSONDecoder().decode(R.self, from: data)
    }

    func reply<R: Encodable>(_ index: Int, _ result: R) {
        calls[index].reply(.success(try! JSONEncoder().encode(result)))
    }

    func params(_ index: Int) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: calls[index].params)) ?? [:]
    }
}

@MainActor
final class TaskListTests: XCTestCase {
    private func task(
        _ id: String, _ status: TaskStatus = .done, thread: String? = nil, createdAt: Int, prompt: String? = nil
    ) -> TaskInfo {
        TaskInfo(
            approval: nil, context: nil, createdAt: createdAt, error: nil, executor: .claudeCode, finishedAt: nil, id: id,
            model: nil, progress: nil, prompt: prompt ?? "запрос \(id)", result: nil, sessionId: "s", status: status, threadId: thread ?? id
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

    private func start(_ tasks: [TaskInfo]) -> (AppState, FakeCore) {
        let state = AppState()
        let core = FakeCore()
        state.core = core
        state.applyHistory(tasks)
        state.showTasks()
        return (state, core)
    }

    private func search(_ state: AppState, _ core: FakeCore, _ query: String, results: [TaskInfo]) async throws {
        let index = core.calls.count
        state.searchQuery = query
        try await until("запроса поиска") { core.calls.count == index + 1 }
        XCTAssertEqual(core.calls[index].method, "task.list")
        XCTAssertEqual(core.params(index), ["query": query])
        core.reply(index, TaskListResult(tasks: results))
        try await until("ответа поиска") { state.searchResults == results }
    }

    func testStaleSearchResponseDoesNotReplaceNewer() async throws {
        let (state, core) = start([task("a", createdAt: 1), task("b", createdAt: 2)])
        state.searchQuery = "пер"
        state.searchQuery = "перевод"
        try await until("двух запросов поиска") { core.calls.count == 2 }
        // Запросы уходят из фоновых задач — порядок их прихода в ядро не гарантирован.
        let queries = (0..<2).map { core.params($0)["query"] }
        let short = try XCTUnwrap(queries.firstIndex(of: "пер"))
        let long = try XCTUnwrap(queries.firstIndex(of: "перевод"))

        let newer = [task("translated", createdAt: 5, prompt: "перевод")]
        core.reply(long, TaskListResult(tasks: newer))
        try await until("ответа на «перевод»") { state.searchResults != nil }
        core.reply(short, TaskListResult(tasks: newer + [task("person", createdAt: 6, prompt: "персона")]))
        // Опоздавший ответ отбрасывается: проверяем после того, как он точно обработан.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(state.listedDialogs.map(\.threadId), ["translated"])
        XCTAssertEqual(state.searchQuery, "перевод")
    }

    func testEmptyQueryShowsRegularListWithoutRequest() async throws {
        let (state, core) = start([task("a", createdAt: 1), task("b", createdAt: 2)])
        try await search(state, core, "b", results: [task("b", createdAt: 2)])
        XCTAssertEqual(state.listedDialogs.map(\.threadId), ["b"])
        state.searchQuery = "   "
        XCTAssertNil(state.searchResults)
        XCTAssertEqual(state.listedDialogs.map(\.threadId), ["b", "a"])
        XCTAssertEqual(core.calls.count, 1)
    }

    func testListKeysWorkWhileSearchFieldHasText() async throws {
        let (state, core) = start([task("a", createdAt: 1), task("b", createdAt: 2), task("c", createdAt: 3)])
        try await search(state, core, "запрос", results: [task("a", createdAt: 1), task("b", createdAt: 2)])
        XCTAssertEqual(state.selectedThreadId, "b", "после смены результатов выбрана первая строка")

        XCTAssertTrue(state.handleListKey(keyCode: 125, command: false))
        XCTAssertEqual(state.selectedThreadId, "a")
        XCTAssertTrue(state.handleListKey(keyCode: 126, command: false))
        XCTAssertEqual(state.selectedThreadId, "b")
        XCTAssertEqual(state.searchQuery, "запрос")
        XCTAssertFalse(state.handleListKey(keyCode: 0, command: false), "буквы достаются полю поиска")

        XCTAssertTrue(state.handleListKey(keyCode: 36, command: false))
        XCTAssertEqual(state.mode, .result(threadId: "b"))
        XCTAssertFalse(state.handleListKey(keyCode: 125, command: false), "вне списка клавиши не перехватываются")

        state.showTasks()
        XCTAssertEqual(state.searchQuery, "", "список открывается с пустым поиском")
        try await search(state, core, "a", results: [task("a", createdAt: 1)])
        XCTAssertTrue(state.handleListKey(keyCode: 53, command: false))
        XCTAssertEqual(state.searchQuery, "")
        XCTAssertEqual(state.mode, .tasks, "первый esc очищает поиск")
        XCTAssertTrue(state.handleListKey(keyCode: 53, command: false))
        XCTAssertEqual(state.mode, .pill, "второй esc закрывает список")
    }

    func testDeleteOfDialogWithActiveTaskIsNotSent() async throws {
        let (state, core) = start([task("a", createdAt: 1), task("a2", .running, thread: "a", createdAt: 2)])
        XCTAssertEqual(state.selectedThreadId, "a")
        XCTAssertTrue(state.handleListKey(keyCode: 51, command: true))
        XCTAssertEqual(state.listMessage, "Сначала отмените задачу")
        XCTAssertEqual(state.tasks.count, 2)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(core.calls.isEmpty)
        XCTAssertFalse(state.handleListKey(keyCode: 51, command: false), "⌫ без ⌘ — редактирование поля")
    }

    func testFoundDialogOpensWholeAndStaysSeen() async throws {
        let (state, core) = start([task("new", createdAt: 10)])
        let found = [task("old", createdAt: 1), task("old2", .failed, thread: "old", createdAt: 2)]
        try await search(state, core, "старое", results: found)
        XCTAssertEqual(state.listedDialogs.map(\.threadId), ["old"])
        state.openSelectedTask()
        XCTAssertEqual(state.mode, .result(threadId: "old"))
        XCTAssertEqual(state.tasks.map(\.id), ["old", "old2", "new"])
        XCTAssertTrue(state.unseen.isEmpty)
        XCTAssertEqual(state.pillState, .idle)
    }

    func testDeletedTasksLeaveTasksUnseenAndResultsSelectionMovesToNeighbour() async throws {
        let (state, core) = start([task("a", createdAt: 1), task("b", createdAt: 2), task("c", createdAt: 3)])
        state.apply(task("d", createdAt: 4))
        state.apply(task("d2", thread: "d", createdAt: 5))
        XCTAssertEqual(state.unseen, ["d", "d2"])
        try await search(state, core, "запрос", results: [task("a", createdAt: 1), task("d", createdAt: 4), task("d2", thread: "d", createdAt: 5)])
        XCTAssertEqual(state.selectedThreadId, "d")

        XCTAssertTrue(state.handleListKey(keyCode: 51, command: true))
        try await until("запроса удаления") { core.calls.count == 2 }
        XCTAssertEqual(core.calls[1].method, "task.delete")
        core.reply(1, TaskDeleteResult(deleted: ["d", "d2"]))
        try await until("удаления") { !state.tasks.contains { $0.threadId == "d" } }
        XCTAssertTrue(state.unseen.isEmpty)
        XCTAssertEqual(state.searchResults?.map(\.id), ["a"])
        XCTAssertEqual(state.selectedThreadId, "a")
        XCTAssertEqual(state.tasks.map(\.id), ["a", "b", "c"])
    }

    func testClearNeedsSecondClickAndRemovesWhatCoreDeleted() async throws {
        let (state, core) = start([task("a", createdAt: 1), task("b", .running, createdAt: 2)])
        XCTAssertTrue(state.canClearHistory)
        state.clearHistory()
        XCTAssertTrue(state.clearConfirming)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(core.calls.isEmpty, "первый клик ничего не удаляет")

        state.clearHistory()
        XCTAssertFalse(state.clearConfirming)
        try await until("запроса очистки") { core.calls.count == 1 }
        XCTAssertEqual(core.calls[0].method, "task.clear")
        core.reply(0, TaskClearResult(deleted: ["a"]))
        try await until("очистки") { state.tasks.map(\.id) == ["b"] }
        XCTAssertFalse(state.canClearHistory, "остались только активные")
    }

    func testClearConfirmationResetsWhenListCloses() {
        let (state, _) = start([task("a", createdAt: 1)])
        state.clearHistory()
        XCTAssertTrue(state.clearConfirming)
        state.collapse()
        XCTAssertFalse(state.clearConfirming)
    }
}
