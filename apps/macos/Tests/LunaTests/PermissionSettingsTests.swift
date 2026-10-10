import XCTest
@testable import Luna

/// Уровень разрешений (LUNA-52): хранение по исполнителю, уровни из `core.hello` и уровень в `task.submit`.
@MainActor
final class PermissionSettingsTests: XCTestCase {
    private let claude = ExecutorId.claudeCode.rawValue

    private func scratchDefaults() -> (UserDefaults, String) {
        let suite = "dev.luna.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (defaults, suite)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("не дождались: \(what)") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func hello(_ levels: [PermissionLevel]?, available: Bool = true) -> HelloResult {
        HelloResult(agentHookPath: nil, executors: [ExecutorStatus(available: available, id: .claudeCode, path: nil, permissionLevels: levels)], version: "0")
    }

    private func sentPermission(_ core: FakeCore, _ index: Int) throws -> String? {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: core.calls[index].params) as? [String: Any])
        return object["permission"] as? String
    }

    // MARK: - Хранилище

    func testPermissionIsStoredPerExecutorAndSurvivesNewInstance() {
        let (defaults, _) = scratchDefaults()
        let first = LunaSettings(defaults: defaults)
        XCTAssertEqual(first.permission(for: claude), .manual, "по умолчанию — manual")
        first.setPermission(.editAutomatically, for: claude)
        XCTAssertEqual(first.permission(for: claude), .editAutomatically)
        XCTAssertEqual(first.permission(for: "other"), .manual, "уровень — свой у каждого исполнителя")

        let second = LunaSettings(defaults: defaults)
        XCTAssertEqual(second.permission(for: claude), .editAutomatically)
        second.setPermission(.manual, for: claude)
        XCTAssertEqual(LunaSettings(defaults: defaults).permission(for: claude), .manual)
    }

    func testUnknownOrCorruptedPermissionReadsAsManual() {
        let (defaults, _) = scratchDefaults()
        defaults.set([claude: "full_access", "other": "edit_automatically", "third": 42] as [String: Any], forKey: "executorPermissions")
        let settings = LunaSettings(defaults: defaults)
        XCTAssertEqual(settings.permission(for: claude), .manual, "незнакомое значение")
        XCTAssertEqual(settings.permission(for: "third"), .manual, "не строка")
        XCTAssertEqual(settings.permission(for: "other"), .editAutomatically, "соседние значения не теряются")

        defaults.set("edit_automatically", forKey: "executorPermissions")
        XCTAssertEqual(LunaSettings(defaults: defaults).permission(for: claude), .manual, "хранилище не того типа")
    }

    // MARK: - Уровни из hello

    func testRequestLevelGoesDownNotUp() {
        XCTAssertEqual(PermissionLevel.request(saved: .editAutomatically, declared: [.manual, .editAutomatically]), .editAutomatically)
        XCTAssertEqual(PermissionLevel.request(saved: .editAutomatically, declared: [.manual]), .manual, "не объявлен — manual")
        XCTAssertEqual(PermissionLevel.request(saved: .editAutomatically, declared: []), .manual)
        XCTAssertEqual(PermissionLevel.request(saved: .editAutomatically, declared: nil), .manual, "hello ещё не пришёл")
        XCTAssertEqual(PermissionLevel.request(saved: .manual, declared: [.manual, .editAutomatically]), .manual)
    }

    func testHelloLevelsAreKeptEvenWithoutCliAndResetWhenCoreStops() {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults().0))
        XCTAssertNil(state.permissions.levels(for: claude), "до hello выбор неактивен")
        state.apply(hello([.manual, .editAutomatically], available: false))
        XCTAssertEqual(state.permissions.levels(for: claude), [.manual, .editAutomatically])
        XCTAssertNotNil(state.problem, "CLI не найден — подсказка остаётся")
        state.apply(hello(nil))
        XCTAssertEqual(state.permissions.levels(for: claude), [], "исполнитель без уровней — выбирать не из чего")
        state.coreStopped(status: 1)
        XCTAssertNil(state.permissions.levels(for: claude))
    }

    func testSettingsShowOnlyDeclaredLevelsAndAreInactiveWithoutHello() {
        let before = PermissionLevel.choices(declared: nil, saved: .editAutomatically)
        XCTAssertEqual(before.levels, [.editAutomatically], "без hello — только сохранённое")
        XCTAssertFalse(before.enabled)
        let declared = PermissionLevel.choices(declared: [.manual], saved: .editAutomatically)
        XCTAssertEqual(declared.levels, [.manual], "необъявленный уровень не показывается")
        XCTAssertTrue(declared.enabled)
        XCTAssertEqual(PermissionLevel.choices(declared: [.manual, .editAutomatically], saved: .manual).levels, [.manual, .editAutomatically])
    }

    func testLevelTitlesAndExplanationsCoverEveryLevel() {
        let all: [PermissionLevel] = [.manual, .editAutomatically]
        XCTAssertEqual(all.map(\.title), ["Спрашивать", "Править файлы без вопросов"])
        for level in all { XCTAssertFalse(level.explanation.isEmpty, level.rawValue) }
    }

    // MARK: - Отправка

    func testSubmitCarriesSavedLevelOnlyWhenDeclared() async throws {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults().0))
        let core = FakeCore()
        state.core = core
        state.settings.setPermission(.editAutomatically, for: claude)

        // hello не пришёл — вниз, до manual.
        state.draft = "раз"
        state.submit()
        try await until("первого запроса") { core.calls.count == 1 }
        XCTAssertEqual(try sentPermission(core, 0), "manual")

        state.apply(hello([.manual, .editAutomatically]))
        XCTAssertEqual(state.requestPermission, .editAutomatically)
        state.draft = "два"
        state.submit()
        try await until("второго запроса") { core.calls.count == 2 }
        XCTAssertEqual(try sentPermission(core, 1), "edit_automatically")

        // Исполнитель уровня не объявил — сохранённый уходит как manual, а сама настройка не меняется.
        state.apply(hello([.manual]))
        state.draft = "три"
        state.submit()
        try await until("третьего запроса") { core.calls.count == 3 }
        XCTAssertEqual(try sentPermission(core, 2), "manual")
        XCTAssertEqual(state.settings.permission(for: claude), .editAutomatically)
    }

    func testFollowUpCarriesCurrentLevel() async throws {
        let state = AppState(settings: LunaSettings(defaults: scratchDefaults().0))
        let core = FakeCore()
        state.core = core
        state.apply(hello([.manual, .editAutomatically]))
        state.applyHistory([
            TaskInfo(
                approval: nil, context: nil, createdAt: 1, error: nil, executor: .claudeCode, finishedAt: 2, id: "a", model: nil,
                progress: nil, prompt: "запрос", result: "ответ", sessionId: "s", status: .done, threadId: "a"
            ),
        ])
        state.open(threadId: "a")

        state.settings.setPermission(.editAutomatically, for: claude)
        state.followUpDraft = "ещё"
        state.submitFollowUp()
        try await until("запроса к ядру") { core.calls.count == 1 }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: core.calls[0].params) as? [String: Any])
        XCTAssertEqual(object["followUpOf"] as? String, "a")
        XCTAssertEqual(object["permission"] as? String, "edit_automatically", "уточнение берёт текущую настройку")
    }
}
