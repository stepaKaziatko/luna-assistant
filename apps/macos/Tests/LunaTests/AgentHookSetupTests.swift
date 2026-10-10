import XCTest
@testable import Luna

/// Блок «Подтверждение в сессиях агентов» в настройках (LUNA-53): фрагмент для `~/.claude/settings.json`
/// и признак «хук найден». Luna в файл ничего не пишет — только читает.
@MainActor
final class AgentHookSetupTests: XCTestCase {
    private let wrapper = "/Users/me/Library/Application Support/Luna/bin/luna-agent-hook"

    func testSnippetIsValidJSONWithPermissionRequestMatcherTimeoutAndWrapper() throws {
        let text = AgentHookSnippet.settingsJSON(wrapperPath: wrapper)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["PermissionRequest"], "только событие диалога разрешения, не PreToolUse")
        let groups = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["matcher"] as? String, "Write|Edit|NotebookEdit|Bash")
        let commands = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0]["type"] as? String, "command")
        XCTAssertEqual(commands[0]["timeout"] as? Int, AgentHookSnippet.timeoutSeconds)
        // Путь с пробелом — в кавычках оболочки: CLI запускает команду через shell.
        XCTAssertEqual(commands[0]["command"] as? String, "'\(wrapper)'")
        XCTAssertTrue(text.contains("/Application Support/"), "слэши не экранированы — фрагмент читается человеком")
    }

    func testCommandQuotesApostropheForShell() {
        XCTAssertEqual(AgentHookSnippet.command(wrapperPath: "/Users/o'neil/luna-agent-hook"), "'/Users/o'\\''neil/luna-agent-hook'")
    }

    func testSnippetRoundTripsThroughStatusCheck() {
        let settings = Data(AgentHookSnippet.settingsJSON(wrapperPath: wrapper).utf8)
        XCTAssertEqual(AgentHookSnippet.status(settings: settings, wrapperPath: wrapper), .found, "вставленный фрагмент признаётся хуком")
    }

    func testStatusFoundOnlyForPermissionRequestWithWrapperPath() {
        func data(_ json: String) -> Data { Data(json.utf8) }
        let withOthers = data("""
        {"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo"}]}],
         "PermissionRequest":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/bin/true"},
           {"type":"command","command":"'\(wrapper)'"}]}]}}
        """)
        XCTAssertEqual(AgentHookSnippet.status(settings: withOthers, wrapperPath: wrapper), .found, "среди чужих хуков")

        let otherEvent = data("""
        {"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"'\(wrapper)'"}]}]}}
        """)
        XCTAssertEqual(AgentHookSnippet.status(settings: otherEvent, wrapperPath: wrapper), .notFound, "тот же путь в PreToolUse — не хук Luna")

        let otherPath = data("""
        {"hooks":{"PermissionRequest":[{"matcher":"Bash","hooks":[{"type":"command","command":"/opt/other-hook"}]}]}}
        """)
        XCTAssertEqual(AgentHookSnippet.status(settings: otherPath, wrapperPath: wrapper), .notFound)
    }

    func testStatusSurvivesMissingEmptyAndBrokenFiles() {
        XCTAssertEqual(AgentHookSnippet.status(settings: nil, wrapperPath: wrapper), .notFound, "нет файла")
        XCTAssertEqual(AgentHookSnippet.status(settings: Data(), wrapperPath: wrapper), .notFound, "пустой файл")
        for text in ["{", "не json", "[]", "null", "{\"hooks\":42}", "{\"hooks\":{\"PermissionRequest\":\"x\"}}", "{\"hooks\":{\"PermissionRequest\":[1,{\"hooks\":5}]}}"] {
            XCTAssertEqual(AgentHookSnippet.status(settings: Data(text.utf8), wrapperPath: wrapper), .notFound, text)
        }
    }

    func testUserSettingsLocation() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(AgentHookSnippet.userSettingsURL(environment: [:], home: home).path, "/Users/me/.claude/settings.json")
        XCTAssertEqual(AgentHookSnippet.userSettingsURL(environment: ["CLAUDE_CONFIG_DIR": "/cfg/claude"], home: home).path, "/cfg/claude/settings.json")
        XCTAssertEqual(AgentHookSnippet.userSettingsURL(environment: ["CLAUDE_CONFIG_DIR": ""], home: home).path, "/Users/me/.claude/settings.json")
    }

    func testSetupFollowsCoreHelloAndReadsSettingsInBackground() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("luna-hook-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let setup = AgentHookSetup(settingsURL: { file })
        XCTAssertNil(setup.snippet, "пока ядро не ответило, фрагмента нет")
        setup.check()
        XCTAssertEqual(setup.status, .unknown)

        setup.apply(HelloResult(agentHookPath: wrapper, executors: [], version: "0"))
        XCTAssertEqual(setup.wrapperPath, wrapper)
        XCTAssertNotNil(setup.snippet)
        setup.check()
        try await until { setup.status == .notFound }

        try Data(AgentHookSnippet.settingsJSON(wrapperPath: wrapper).utf8).write(to: file)
        setup.check()
        try await until { setup.status == .found }

        setup.reset()
        XCTAssertNil(setup.wrapperPath)
        XCTAssertEqual(setup.status, .unknown)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("не дождались") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
