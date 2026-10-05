import XCTest
@testable import Luna

@MainActor
final class ModelTests: XCTestCase {
    private let claude = ExecutorId.claudeCode.rawValue

    private func scratchDefaults() -> UserDefaults {
        let suite = "dev.luna.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("не дождались: \(what)") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - Короткие имена

    func testShortNames() {
        let expected = [
            "claude-sonnet-4-6": "Sonnet 4.6",
            "claude-haiku-4-5-20251001": "Haiku 4.5",
            "claude-opus-5-5": "Opus 5.5",
            "claude-fable-5": "Fable 5",
            "claude-opus-4-8[1m]": "Opus 4.8 1M",
            "claude-sonnet-4-20250514": "Sonnet 4",
            "opus": "Opus",
            "sonnet": "Sonnet",
            "haiku": "Haiku",
            "sonnet[1m]": "Sonnet 1M",
            "no-such-model-x": "no-such-model-x",
            "claude-sonnet": "claude-sonnet",
            "claude-sonnet-4-6-beta": "claude-sonnet-4-6-beta",
            "claude-Sonnet-4-6": "claude-Sonnet-4-6",
            "gpt-5": "gpt-5",
            "": "",
        ]
        for (id, title) in expected {
            XCTAssertEqual(ModelName.short(id), title, id)
        }
    }

    func testResultCaption() {
        func task(model: String?, finishedAt: Int?) -> TaskInfo {
            TaskInfo(
                context: nil, createdAt: 1_000, error: nil, executor: .claudeCode, finishedAt: finishedAt, id: "t",
                model: model, progress: nil, prompt: "p", result: "r", sessionId: nil, status: .done, threadId: "t"
            )
        }
        XCTAssertEqual(task(model: "claude-sonnet-4-6", finishedAt: 13_000).resultCaption, "Claude Code · Sonnet 4.6 · 12 с")
        XCTAssertEqual(task(model: nil, finishedAt: 13_000).resultCaption, "Claude Code · 12 с")
        XCTAssertEqual(task(model: "claude-sonnet-4-6", finishedAt: nil).resultCaption, "Claude Code · Sonnet 4.6")
        XCTAssertEqual(task(model: nil, finishedAt: nil).resultCaption, "Claude Code")
    }

    func testTaskInfoDecodesWithAndWithoutModel() throws {
        let base = #"{"id":"a","threadId":"a","prompt":"p","status":"done","executor":"claude-code","createdAt":1"#
        let with = try JSONDecoder().decode(TaskInfo.self, from: Data((base + #","model":"claude-opus-4-8[1m]"}"#).utf8))
        XCTAssertEqual(with.model, "claude-opus-4-8[1m]")
        let without = try JSONDecoder().decode(TaskInfo.self, from: Data((base + "}").utf8))
        XCTAssertNil(without.model)
    }

    // MARK: - Настройки

    func testDefaultModelList() {
        let settings = LunaSettings(defaults: scratchDefaults())
        XCTAssertEqual(settings.models(for: claude), ["opus", "sonnet", "haiku"])
        XCTAssertNil(settings.model(for: claude))
        XCTAssertEqual(settings.models(for: "other"), [])
    }

    func testChoiceSurvivesNewInstance() {
        let defaults = scratchDefaults()
        let first = LunaSettings(defaults: defaults)
        first.setModel("sonnet", for: claude)
        XCTAssertEqual(first.model(for: claude), "sonnet")
        XCTAssertEqual(LunaSettings(defaults: defaults).model(for: claude), "sonnet")

        first.setModel(nil, for: claude)
        XCTAssertNil(LunaSettings(defaults: defaults).model(for: claude))
    }

    func testChoiceMissingFromListReadsAsDefaultAndIsErased() {
        let defaults = scratchDefaults()
        defaults.set([claude: "gpt-9"], forKey: "executorModelChoices")
        let settings = LunaSettings(defaults: defaults)
        XCTAssertNil(settings.model(for: claude))
        XCTAssertEqual((defaults.dictionary(forKey: "executorModelChoices") as? [String: String]) ?? [:], [:])

        // Модель вне списка не принимается и сбрасывает прежний выбор.
        settings.setModel("opus", for: claude)
        settings.setModel("--x", for: claude)
        XCTAssertNil(settings.model(for: claude))
    }

    func testChangingListResetsChoiceThatDisappeared() {
        let defaults = scratchDefaults()
        let settings = LunaSettings(defaults: defaults)
        settings.setModel("haiku", for: claude)
        settings.setModels(["opus", "claude-sonnet-4-6", "", "opus"], for: claude)
        XCTAssertEqual(settings.models(for: claude), ["opus", "claude-sonnet-4-6"])
        XCTAssertNil(settings.model(for: claude))
        XCTAssertNil(LunaSettings(defaults: defaults).model(for: claude))

        // Выбор, оставшийся в списке, сохраняется.
        settings.setModel("claude-sonnet-4-6", for: claude)
        settings.setModels(["claude-sonnet-4-6", "haiku"], for: claude)
        XCTAssertEqual(LunaSettings(defaults: defaults).model(for: claude), "claude-sonnet-4-6")

        // Пустой список возвращает встроенный.
        settings.setModels([], for: claude)
        XCTAssertEqual(LunaSettings(defaults: defaults).models(for: claude), ["opus", "sonnet", "haiku"])
    }

    // MARK: - Отправка

    /// Поля `task.submit`, которые ушли ядру: `model` — nil, если поля нет в запросе.
    private func submitted(_ core: FakeCore, _ index: Int) throws -> (model: String?, followUpOf: String?, prompt: String?) {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: core.calls[index].params) as? [String: Any])
        XCTAssertEqual(core.calls[index].method, "task.submit")
        return (object["model"] as? String, object["followUpOf"] as? String, object["prompt"] as? String)
    }

    func testSubmitSendsSelectedModel() async throws {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults()))
        let core = FakeCore()
        state.core = core

        state.settings.setModel("opus", for: claude)
        state.draft = "привет"
        state.submit()
        try await until("запроса к ядру") { core.calls.count == 1 }
        let sent = try submitted(core, 0)
        XCTAssertEqual(sent.model, "opus")
        XCTAssertEqual(sent.prompt, "привет")
    }

    func testSubmitWithoutChoiceOmitsModel() async throws {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults()))
        let core = FakeCore()
        state.core = core

        state.draft = "привет"
        state.submit()
        try await until("запроса к ядру") { core.calls.count == 1 }
        XCTAssertNil(try submitted(core, 0).model)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: core.calls[0].params) as? [String: Any])
        XCTAssertNil(raw["model"], "поле model не передаётся")
    }

    func testRejectedModelKeepsDraftAndShowsProblem() async throws {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults()))
        let core = FakeCore()
        state.core = core

        state.draft = "привет"
        state.submit(model: "--x")
        try await until("запроса к ядру") { core.calls.count == 1 }
        XCTAssertEqual(try submitted(core, 0).model, "--x")
        core.calls[0].reply(.failure(RpcFailure(code: -32602, message: "invalid model")))
        try await until("ошибки в панели") { state.problem != nil }
        XCTAssertEqual(state.draft, "привет")
    }

    func testFollowUpDoesNotSendModel() async throws {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults()))
        let core = FakeCore()
        state.core = core
        state.settings.setModel("opus", for: claude)
        state.applyHistory([
            TaskInfo(
                context: nil, createdAt: 1, error: nil, executor: .claudeCode, finishedAt: 2, id: "a", model: "claude-opus-4-8",
                progress: nil, prompt: "первый", result: "ответ", sessionId: "s", status: .done, threadId: "a"
            ),
        ])
        state.open(threadId: "a")
        state.followUpDraft = "ещё"
        state.submitFollowUp()
        try await until("запроса к ядру") { core.calls.count == 1 }
        let sent = try submitted(core, 0)
        XCTAssertEqual(sent.followUpOf, "a")
        XCTAssertNil(sent.model)
    }
}
