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
                approval: nil, context: nil, createdAt: 1_000, error: nil, executor: .claudeCode, finishedAt: finishedAt, id: "t",
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

    // MARK: - Уточнение

    private func answer(
        _ id: String, thread: String? = nil, _ status: TaskStatus = .done, model: String?, createdAt: Int, sessionId: String? = "s"
    ) -> TaskInfo {
        TaskInfo(
            approval: nil, context: nil, createdAt: createdAt, error: nil, executor: .claudeCode, finishedAt: createdAt + 1, id: id, model: model,
            progress: nil, prompt: "запрос \(id)", result: "ответ \(id)", sessionId: sessionId, status: status, threadId: thread ?? id
        )
    }

    /// Карточка диалога `a`, открытая поверх подставного ядра.
    private func card(_ tasks: [TaskInfo]) -> (AppState, FakeCore) {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults()))
        let core = FakeCore()
        state.core = core
        state.applyHistory(tasks)
        state.open(threadId: "a")
        return (state, core)
    }

    private var opusAnswer: TaskInfo { answer("a", model: "claude-opus-4-8", createdAt: 1) }

    func testFollowUpWithoutChangeOmitsModel() async throws {
        let (state, core) = card([opusAnswer])
        state.settings.setModel("opus", for: claude)
        state.followUpDraft = "ещё"
        state.submitFollowUp()
        try await until("запроса к ядру") { core.calls.count == 1 }
        let sent = try submitted(core, 0)
        XCTAssertEqual(sent.followUpOf, "a")
        XCTAssertNil(sent.model)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: core.calls[0].params) as? [String: Any])
        XCTAssertNil(raw["model"], "поле model не передаётся")
    }

    func testFollowUpSendsChosenModelAndKeepsInputPanelChoice() async throws {
        let (state, core) = card([opusAnswer])
        state.settings.setModel("sonnet", for: claude)
        state.selectFollowUpModel("haiku")
        XCTAssertEqual(state.followUpModel, "haiku")
        XCTAssertEqual(state.settings.model(for: claude), "sonnet", "последний выбор панели ввода не меняется")

        state.followUpDraft = "ещё"
        state.submitFollowUp()
        try await until("запроса к ядру") { core.calls.count == 1 }
        XCTAssertEqual(try submitted(core, 0).model, "haiku")

        // Ответ ядра принят — выбор сброшен, диалог снова предвыбирает модель точки.
        core.reply(0, TaskSubmitResult(task: answer("a2", thread: "a", .queued, model: "haiku", createdAt: 3, sessionId: nil)))
        try await until("сброса выбора") { state.followUpModel == nil }
        XCTAssertEqual(state.settings.model(for: claude), "sonnet")
    }

    func testChoosingPointModelIsNoChange() async throws {
        let (state, core) = card([opusAnswer])
        state.selectFollowUpModel("haiku")
        state.selectFollowUpModel("claude-opus-4-8")
        XCTAssertNil(state.followUpModel)

        state.followUpDraft = "ещё"
        state.submitFollowUp()
        try await until("запроса к ядру") { core.calls.count == 1 }
        XCTAssertNil(try submitted(core, 0).model)
    }

    func testFollowUpOfDialogWithoutModelDefaultsAndSendsChoice() async throws {
        let (state, core) = card([answer("a", model: nil, createdAt: 1)])
        let dialog = try XCTUnwrap(state.dialog(threadId: "a"))
        XCTAssertNil(state.followUpChoice(for: dialog).shown)
        XCTAssertEqual(state.followUpChoice(for: dialog).label, "Claude Code · Модель CLI")

        state.selectFollowUpModel("sonnet")
        XCTAssertEqual(state.followUpChoice(for: dialog).label, "Claude Code · Sonnet")
        state.selectFollowUpModel(nil)
        XCTAssertNil(state.followUpModel, "«Модель CLI» у диалога без модели — не менял")

        state.selectFollowUpModel("sonnet")
        state.followUpDraft = "ещё"
        state.submitFollowUp()
        try await until("запроса к ядру") { core.calls.count == 1 }
        XCTAssertEqual(try submitted(core, 0).model, "sonnet")
    }

    func testPreselectionFollowsContinuationPointNotLastTask() throws {
        // Уточнение на другой модели не удалось: последняя задача — failed на haiku, а ядро продолжит ответ на Opus.
        let failed = answer("a2", thread: "a", .failed, model: "haiku", createdAt: 3, sessionId: nil)
        let (state, _) = card([opusAnswer, failed])
        let dialog = try XCTUnwrap(state.dialog(threadId: "a"))
        XCTAssertEqual(dialog.last.id, "a2")
        XCTAssertEqual(dialog.continuationPoint?.id, "a")
        XCTAssertEqual(state.followUpChoice(for: dialog).shown, "claude-opus-4-8")
        XCTAssertNil(state.followUpChoice(for: dialog).requestModel)
        // А подпись окна — модель последней задачи.
        XCTAssertEqual(dialog.modelTitle, "Haiku")
    }

    func testFailedSubmitKeepsChoiceAndDraft() async throws {
        let (state, core) = card([opusAnswer])
        state.selectFollowUpModel("--x")
        state.followUpDraft = "ещё"
        state.submitFollowUp()
        try await until("запроса к ядру") { core.calls.count == 1 }
        core.calls[0].reply(.failure(RpcFailure(code: -32602, message: "invalid model")))
        try await until("ошибки под полем") { state.followUpError != nil }
        XCTAssertEqual(state.followUpModel, "--x")
        XCTAssertEqual(state.followUpDraft, "ещё")
    }

    func testChoiceResetsWhenDialogChanges() {
        let (state, _) = card([opusAnswer, answer("b", model: "claude-sonnet-4-6", createdAt: 2)])
        state.selectFollowUpModel("haiku")
        state.open(threadId: "b")
        XCTAssertNil(state.followUpModel)
        state.selectFollowUpModel("haiku")
        XCTAssertEqual(state.followUpModel, "haiku")
        state.open(threadId: "b")
        XCTAssertEqual(state.followUpModel, "haiku", "тот же диалог — выбор остаётся")
    }

    func testRequestModelOnlyForChangedSelection() {
        XCTAssertNil(FollowUpModelChoice(pointModel: "haiku", selection: nil).requestModel, "не менял — поля нет")
        XCTAssertNil(FollowUpModelChoice(pointModel: "haiku", selection: "haiku").requestModel, "выбрана модель точки — поля нет")
        XCTAssertEqual(FollowUpModelChoice(pointModel: "haiku", selection: "opus").requestModel, "opus")
        XCTAssertEqual(FollowUpModelChoice(pointModel: nil, selection: "opus").requestModel, "opus", "у диалога без модели любая выбранная уходит")
        XCTAssertNil(FollowUpModelChoice(pointModel: nil, selection: nil).requestModel)
    }

    func testFollowUpMenuSections() {
        let models = ["opus", "sonnet", "haiku"]
        // Диалог с моделью: она первой, «Модель CLI» нет.
        let known = FollowUpModelChoice(pointModel: "claude-sonnet-4-6", selection: nil)
        XCTAssertEqual(known.sections(models: models).map { $0.map(\.title) }, [["Sonnet 4.6"], ["Opus", "Sonnet", "Haiku"]])
        XCTAssertEqual(known.sections(models: models).flatMap { $0 }.map(\.model), ["claude-sonnet-4-6", "opus", "sonnet", "haiku"])
        // Модель точки, совпавшая со списком, не дублируется.
        let alias = FollowUpModelChoice(pointModel: "sonnet", selection: nil)
        XCTAssertEqual(alias.sections(models: models).map { $0.map(\.title) }, [["Sonnet"], ["Opus", "Haiku"]])
        // Без модели: «Модель CLI» и список.
        let unknown = FollowUpModelChoice(pointModel: nil, selection: nil)
        XCTAssertEqual(unknown.sections(models: models).map { $0.map(\.title) }, [["Модель CLI"], ["Opus", "Sonnet", "Haiku"]])
        XCTAssertEqual(FollowUpModelChoice(pointModel: "", selection: nil).sections(models: []).map { $0.map(\.title) }, [["Модель CLI"]])
        // Панель ввода — прежнее меню.
        XCTAssertEqual(ModelMenu.inputSections(models: models).map { $0.map(\.title) }, [["Модель CLI"], ["Opus", "Sonnet", "Haiku"]])
        XCTAssertEqual(known.label, "Claude Code · Sonnet 4.6")
    }

    func testDialogModelTitle() {
        func dialog(_ models: [String?]) -> Dialog {
            Dialog(threadId: "a", tasks: models.enumerated().map { answer("t\($0.offset)", thread: "a", model: $0.element, createdAt: $0.offset) })
        }
        XCTAssertEqual(dialog(["claude-sonnet-4-6"]).modelTitle, "Sonnet 4.6")
        XCTAssertEqual(dialog(["claude-sonnet-4-6", "haiku"]).modelTitle, "Haiku", "у задач диалога модели могут различаться — последняя")
        XCTAssertNil(dialog([nil]).modelTitle)
        XCTAssertNil(dialog([""]).modelTitle)
        XCTAssertNil(dialog(["claude-sonnet-4-6", nil]).modelTitle, "у последней задачи без модели ничего не показывается")
    }
}
