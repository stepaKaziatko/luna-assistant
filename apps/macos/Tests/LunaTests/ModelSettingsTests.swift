import XCTest
@testable import Luna

/// Список моделей и модель по умолчанию в настройках: разбор, предвыбор панели ввода и правила сбросов.
@MainActor
final class ModelSettingsTests: XCTestCase {
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

    // MARK: - Имя и разбор списка

    func testValidModelName() {
        for name in ["opus", "claude-opus-4-8[1m]", "claude-sonnet-4-6", "a", "0x", "a.b_c:d/e-f", String(repeating: "a", count: 100)] {
            XCTAssertTrue(ModelList.isValid(name), name)
        }
        for name in ["", "--x", "-opus", "a b", "opus\n", "\nopus", "opus ", String(repeating: "a", count: 101), "модель", "opus;rm", "a\u{0301}"] {
            XCTAssertFalse(ModelList.isValid(name), name.debugDescription)
        }
    }

    func testParseListText() {
        let parsed = ModelList.parse("opus\n  claude-opus-4-8[1m]  \n\n\nbad model\nsonnet\nopus\n--x\r\nhaiku")
        XCTAssertEqual(parsed.accepted, ["opus", "claude-opus-4-8[1m]", "sonnet", "haiku"])
        XCTAssertEqual(parsed.rejected, ["bad model", "--x"])
        XCTAssertEqual(ModelList.parse(""), ModelList.Parsed())
        XCTAssertEqual(ModelList.parse("\n  \n"), ModelList.Parsed())
        XCTAssertEqual(ModelList.parse("только плохое").accepted, [])
    }

    func testVerdictForDraft() {
        let existing = ["opus", "sonnet"]
        XCTAssertEqual(ModelList.verdict(for: "", existing: existing), .empty)
        XCTAssertEqual(ModelList.verdict(for: "  ", existing: existing), .empty)
        XCTAssertEqual(ModelList.verdict(for: " claude-opus-4-8[1m] ", existing: existing), .valid)
        XCTAssertEqual(ModelList.verdict(for: "opus", existing: existing), .duplicate)
        XCTAssertEqual(ModelList.verdict(for: "bad model", existing: existing), .invalid)
        XCTAssertEqual(ModelList.verdict(for: "opu s", existing: existing), .invalid)
    }

    // MARK: - Хранилище

    func testListAndDefaultSurviveNewInstance() {
        let defaults = scratchDefaults()
        let first = LunaSettings(defaults: defaults)
        first.setModels(["opus", "claude-opus-4-8[1m]"], for: claude)
        first.setDefaultModel("claude-opus-4-8[1m]", for: claude)
        let second = LunaSettings(defaults: defaults)
        XCTAssertEqual(second.models(for: claude), ["opus", "claude-opus-4-8[1m]"])
        XCTAssertEqual(second.defaultModel(for: claude), "claude-opus-4-8[1m]")
        XCTAssertEqual(second.model(for: claude), "claude-opus-4-8[1m]")
        XCTAssertTrue(second.hasCustomModels(for: claude))
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: "executorDefaultModels"), "стандартный набор не затронут")
    }

    func testCorruptedStorageReadsAsBuiltInAndCliModel() {
        let defaults = scratchDefaults()
        defaults.set("не словарь", forKey: "executorModelLists")
        defaults.set(["x"], forKey: "executorModelChoices")
        defaults.set(42, forKey: "executorDefaultModels")
        var settings = LunaSettings(defaults: defaults)
        XCTAssertEqual(settings.models(for: claude), ["opus", "sonnet", "haiku"])
        XCTAssertNil(settings.model(for: claude))
        XCTAssertNil(settings.defaultModel(for: claude))

        // Имена не по шаблону отбрасываются, остальное работает; умолчание вне списка стирается.
        defaults.set([claude: ["opus", "--x", "a b", "", "opus", "claude-sonnet-4-6"]], forKey: "executorModelLists")
        defaults.set([claude: "--x"], forKey: "executorModelChoices")
        defaults.set([claude: "haiku"], forKey: "executorDefaultModels")
        settings = LunaSettings(defaults: defaults)
        XCTAssertEqual(settings.models(for: claude), ["opus", "claude-sonnet-4-6"])
        XCTAssertNil(settings.model(for: claude))
        XCTAssertNil(settings.defaultModel(for: claude))
        XCTAssertEqual((defaults.dictionary(forKey: "executorDefaultModels") as? [String: String]) ?? [:], [:])
        XCTAssertEqual((defaults.dictionary(forKey: "executorModelChoices") as? [String: String]) ?? [:], [:])

        // Список из одних некорректных имён — как пустой.
        defaults.set([claude: ["--x", "a b"]], forKey: "executorModelLists")
        XCTAssertEqual(LunaSettings(defaults: defaults).models(for: claude), ["opus", "sonnet", "haiku"])
    }

    func testSetModelsCleansNames() {
        let settings = LunaSettings(defaults: scratchDefaults())
        settings.setModels(["  opus ", "bad model", "", "claude-opus-4-8[1m]", "opus"], for: claude)
        XCTAssertEqual(settings.models(for: claude), ["opus", "claude-opus-4-8[1m]"])
        settings.setModels(["--x"], for: claude)
        XCTAssertEqual(settings.models(for: claude), ["opus", "sonnet", "haiku"])
        XCTAssertFalse(settings.hasCustomModels(for: claude))
    }

    // MARK: - Предвыбор

    func testPreselectionOrder() {
        let settings = LunaSettings(defaults: scratchDefaults())
        XCTAssertNil(settings.model(for: claude), "ничего не задано — «Модель CLI»")

        settings.setDefaultModel("sonnet", for: claude)
        XCTAssertEqual(settings.model(for: claude), "sonnet", "умолчание")

        settings.setModel("haiku", for: claude)
        XCTAssertEqual(settings.model(for: claude), "haiku", "последний выбор главнее умолчания")
        XCTAssertEqual(settings.defaultModel(for: claude), "sonnet")
    }

    func testDefaultOutsideListIsRejected() {
        let settings = LunaSettings(defaults: scratchDefaults())
        settings.setDefaultModel("gpt-9", for: claude)
        XCTAssertNil(settings.defaultModel(for: claude))
        settings.setDefaultModel("opus", for: claude)
        settings.setDefaultModel("--x", for: claude)
        XCTAssertNil(settings.defaultModel(for: claude), "модель вне списка сбрасывает умолчание")
    }

    func testDefaultMissingFromListReadsAsNoneAndIsErased() {
        let defaults = scratchDefaults()
        defaults.set([claude: "gpt-9"], forKey: "executorDefaultModels")
        let settings = LunaSettings(defaults: defaults)
        XCTAssertNil(settings.defaultModel(for: claude))
        XCTAssertNil(settings.model(for: claude))
        XCTAssertEqual((defaults.dictionary(forKey: "executorDefaultModels") as? [String: String]) ?? [:], [:])
    }

    // MARK: - Явная «Модель CLI»

    func testExplicitCliModelIsRememberedWhenDefaultIsSet() {
        let defaults = scratchDefaults()
        let settings = LunaSettings(defaults: defaults)
        settings.setDefaultModel("opus", for: claude)
        XCTAssertEqual(settings.model(for: claude), "opus")

        settings.setModel(nil, for: claude)
        XCTAssertNil(settings.model(for: claude))
        XCTAssertNil(LunaSettings(defaults: defaults).model(for: claude), "после нового экземпляра тоже")
        XCTAssertEqual(LunaSettings(defaults: defaults).defaultModel(for: claude), "opus")

        settings.setModel("haiku", for: claude)
        XCTAssertEqual(settings.model(for: claude), "haiku")
    }

    func testWithoutDefaultNoChoiceAndCliModelAreTheSame() {
        let defaults = scratchDefaults()
        let settings = LunaSettings(defaults: defaults)
        settings.setModel("sonnet", for: claude)
        settings.setModel(nil, for: claude)
        XCTAssertNil(settings.model(for: claude))
        XCTAssertEqual((defaults.dictionary(forKey: "executorModelChoices") as? [String: String]) ?? [:], [:], "выбор стёрт, а не записан пустым")
    }

    // MARK: - Сбросы

    func testRemovingChosenModelFallsBackToDefault() {
        let settings = LunaSettings(defaults: scratchDefaults())
        settings.setDefaultModel("opus", for: claude)
        settings.setModel("haiku", for: claude)
        settings.setModels(["opus", "sonnet"], for: claude)
        XCTAssertEqual(settings.defaultModel(for: claude), "opus", "умолчание живёт")
        XCTAssertEqual(settings.model(for: claude), "opus", "выбор стёрт, предвыбор — умолчание")
    }

    func testRemovingDefaultModelKeepsChoice() {
        let settings = LunaSettings(defaults: scratchDefaults())
        settings.setDefaultModel("opus", for: claude)
        settings.setModel("haiku", for: claude)
        settings.setModels(["sonnet", "haiku"], for: claude)
        XCTAssertNil(settings.defaultModel(for: claude))
        XCTAssertEqual(settings.model(for: claude), "haiku", "выбор живёт")
    }

    func testRemovingBothFallsBackToCliModel() {
        let defaults = scratchDefaults()
        let settings = LunaSettings(defaults: defaults)
        settings.setModels(["opus", "claude-opus-4-8[1m]", "haiku"], for: claude)
        settings.setDefaultModel("claude-opus-4-8[1m]", for: claude)
        settings.setModel("claude-opus-4-8[1m]", for: claude)
        settings.setModels(["opus", "haiku"], for: claude)
        XCTAssertNil(settings.model(for: claude))
        XCTAssertNil(settings.defaultModel(for: claude))
        let reread = LunaSettings(defaults: defaults)
        XCTAssertNil(reread.model(for: claude))
        XCTAssertNil(reread.defaultModel(for: claude))
    }

    func testChangingDefaultErasesLastChoice() {
        let settings = LunaSettings(defaults: scratchDefaults())
        settings.setDefaultModel("opus", for: claude)
        settings.setModel("haiku", for: claude)
        settings.setDefaultModel("sonnet", for: claude)
        XCTAssertEqual(settings.model(for: claude), "sonnet", "выбор стёрт, новое умолчание видно")

        // Явная «Модель CLI» тоже стирается.
        settings.setModel(nil, for: claude)
        XCTAssertNil(settings.model(for: claude))
        settings.setDefaultModel("opus", for: claude)
        XCTAssertEqual(settings.model(for: claude), "opus")

        // Смена умолчания на «нет» — тоже смена.
        settings.setModel("haiku", for: claude)
        settings.setDefaultModel(nil, for: claude)
        XCTAssertNil(settings.model(for: claude))
    }

    func testSettingSameDefaultKeepsChoice() {
        let settings = LunaSettings(defaults: scratchDefaults())
        settings.setDefaultModel("opus", for: claude)
        settings.setModel("haiku", for: claude)
        settings.setDefaultModel("opus", for: claude)
        XCTAssertEqual(settings.model(for: claude), "haiku")

        settings.setModel(nil, for: claude)
        settings.setDefaultModel("opus", for: claude)
        XCTAssertNil(settings.model(for: claude), "явная «Модель CLI» тоже живёт")
    }

    func testEmptyListRestoresBuiltInAndDropsWhatIsNotThere() {
        let settings = LunaSettings(defaults: scratchDefaults())
        settings.setModels(["opus", "claude-opus-4-8[1m]"], for: claude)
        settings.setDefaultModel("claude-opus-4-8[1m]", for: claude)
        settings.setModel("opus", for: claude)
        settings.setModels([], for: claude)
        XCTAssertEqual(settings.models(for: claude), ["opus", "sonnet", "haiku"])
        XCTAssertNil(settings.defaultModel(for: claude), "умолчания нет во встроенном списке")
        XCTAssertEqual(settings.model(for: claude), "opus", "выбор есть во встроенном списке")
    }

    func testChangingListKeepsExplicitCliModel() {
        let settings = LunaSettings(defaults: scratchDefaults())
        settings.setDefaultModel("opus", for: claude)
        settings.setModel(nil, for: claude)
        settings.setModels(["opus", "sonnet"], for: claude)
        XCTAssertNil(settings.model(for: claude))
        XCTAssertEqual(settings.defaultModel(for: claude), "opus")
        settings.setModels(["sonnet"], for: claude)
        XCTAssertNil(settings.defaultModel(for: claude))
        XCTAssertNil(settings.model(for: claude))
    }

    // MARK: - Отправка и меню

    private func sentModel(_ core: FakeCore, _ index: Int) throws -> String? {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: core.calls[index].params) as? [String: Any])
        return object["model"] as? String
    }

    func testSubmitUsesDefaultChoiceAndExplicitCliModel() async throws {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults()))
        let core = FakeCore()
        state.core = core

        state.draft = "раз"
        state.submit()
        try await until("первого запроса") { core.calls.count == 1 }
        XCTAssertNil(try sentModel(core, 0), "без выбора и умолчания поля нет")

        state.settings.setDefaultModel("sonnet", for: claude)
        state.draft = "два"
        state.submit()
        try await until("второго запроса") { core.calls.count == 2 }
        XCTAssertEqual(try sentModel(core, 1), "sonnet", "умолчание")

        state.settings.setModel("haiku", for: claude)
        state.draft = "три"
        state.submit()
        try await until("третьего запроса") { core.calls.count == 3 }
        XCTAssertEqual(try sentModel(core, 2), "haiku", "выбор главнее умолчания")

        state.settings.setModel(nil, for: claude)
        state.draft = "четыре"
        state.submit()
        try await until("четвёртого запроса") { core.calls.count == 4 }
        XCTAssertNil(try sentModel(core, 3), "явная «Модель CLI» при умолчании — поля нет")
    }

    func testShownPreselectionIsWhatIsSent() {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults()))
        state.settings.setDefaultModel("opus", for: claude)
        XCTAssertEqual(state.selectedModel, state.settings.model(for: claude))
        state.settings.setModel("haiku", for: claude)
        XCTAssertEqual(state.selectedModel, state.settings.model(for: claude))
        state.settings.setModel(nil, for: claude)
        XCTAssertEqual(state.selectedModel, state.settings.model(for: claude))
        XCTAssertNil(state.selectedModel)
    }

    func testLabelsUseCliModelTitle() {
        XCTAssertEqual(ModelName.defaultTitle, "Модель CLI")
        XCTAssertEqual(ModelMenu.inputSections(models: ["opus"]).map { $0.map(\.title) }, [["Модель CLI"], ["Opus"]])
        XCTAssertEqual(FollowUpModelChoice(pointModel: nil, selection: nil).label, "Claude Code · Модель CLI")
    }

    func testFollowUpIgnoresSettingsDefaultAndPanelChoice() {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults()))
        let point = FollowUpModelChoice(pointModel: "claude-sonnet-4-6", selection: nil)
        state.settings.setDefaultModel("opus", for: claude)
        state.settings.setModel("haiku", for: claude)
        XCTAssertEqual(point.shown, "claude-sonnet-4-6")
        XCTAssertNil(point.requestModel)

        // Список в меню поля продолжения следует за настройками.
        state.settings.setModels(["opus", "claude-opus-4-8[1m]"], for: claude)
        let titles = point.sections(models: state.settings.models(for: claude)).map { $0.map(\.title) }
        XCTAssertEqual(titles, [["Sonnet 4.6"], ["Opus", "Opus 4.8 1M"]])
    }
}
