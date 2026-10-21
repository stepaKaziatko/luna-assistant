import Foundation

// Живой прогон: настоящий `claude`, модель haiku, один короткий вопрос по подписке.
@main
enum ClaudeCLILiveTest {
    static func main() async {
        guard let executable = CLIResolver.executable(.claude) else {
            print("  ✗ claude не найден"); exit(1)
        }
        let status = await ClaudeAuthProbe.check()
        print("  статус входа: \(status)")
        await historyChecks(executable: executable)
        // LUNA_LIVE_SECTION=history — только проверки истории чатов (меньше расход подписки).
        if ProcessInfo.processInfo.environment["LUNA_LIVE_SECTION"] == "history" { return }
        let request = ClaudeCLIRequest(
            executable: executable,
            prompt: "Reply with the single word: ok",
            systemPrompt: "You are a test. Answer with one word.",
            model: "haiku",
            sessionID: UUID().uuidString.lowercased(),
            resume: false,
            workingDirectory: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("chat"),
            environment: CLIResolver.environment(base: ProcessInfo.processInfo.environment, executable: executable))
        let result = await ClaudeCLIProcess().run(request) { _ in }
        switch result {
        case .success(let text) where !text.isEmpty:
            print("  ✓ ответ получен: \(text.prefix(40))")
        default:
            print("  ✗ \(result)"); exit(1)
        }

        // Вопроса «только чтение» в проекте больше нет: с проектом запускается агент (LUNA-80),
        // его живой прогон — scripts/test-agent-run-live.sh.
    }

    /// История чатов (LUNA-76): сессия чата, записанная в историю и прочитанная обратно, продолжается
    /// `--resume`, и модель помнит первый ход; `--resume` несуществующей сессии распознаётся.
    static func historyChecks(executable: String) async {
        let version = claudeVersion(executable)
        print("  версия claude: \(version)")
        let chatFolder = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("history-chat")
        let environment = CLIResolver.environment(base: ProcessInfo.processInfo.environment, executable: executable)
        func request(_ prompt: String, id: String, resume: Bool) -> ClaudeCLIRequest {
            ClaudeCLIRequest(executable: executable, prompt: prompt,
                             systemPrompt: "You are a test. Answer briefly.", model: "haiku",
                             sessionID: id, resume: resume, workingDirectory: chatFolder, environment: environment)
        }

        // --resume сессии, которой нет: claude отвечает до запроса к модели, токены не тратятся.
        let missing = await ClaudeCLIProcess().run(request("hi", id: UUID().uuidString.lowercased(), resume: true)) { _ in }
        guard missing == .failure(.sessionNotFound) else {
            print("  ✗ --resume несуществующей сессии: \(missing) (claude \(version))"); exit(1)
        }
        print("  ✓ --resume несуществующей сессии → .sessionNotFound (claude \(version))")

        var session = ChatCLISession()
        let first = session.turn(projectPath: nil)
        let r1 = await ClaudeCLIProcess().run(request(
            "Remember the codeword PLUM-71 for later. Reply with the single word: ok", id: first.id, resume: first.resume)) { _ in }
        guard case .success = r1 else { print("  ✗ первый ход: \(r1)"); exit(1) }
        session.markStarted()
        // Как после перезапуска Luna: сессия — из записи истории, через JSON.
        let saved = ChatHistoryCLISession(id: session.id, projectPath: session.projectPath, started: session.started)
        guard let data = try? JSONEncoder().encode(saved),
              let back = try? JSONDecoder().decode(ChatHistoryCLISession.self, from: data) else {
            print("  ✗ сессия не записалась в JSON"); exit(1)
        }
        var restored = ChatCLISession(restoring: back.id, projectPath: back.projectPath, started: back.started)
        let second = restored.turn(projectPath: nil)
        guard second == (first.id, true) else { print("  ✗ восстановленная сессия: \(second)"); exit(1) }
        let r2 = await ClaudeCLIProcess().run(request(
            "What codeword did I ask you to remember? Reply with the codeword only.", id: second.id, resume: second.resume)) { _ in }
        guard case .success(let text) = r2, text.contains("PLUM-71") else {
            print("  ✗ --resume из записи истории: \(r2)"); exit(1)
        }
        print("  ✓ --resume сессии из записи истории: модель помнит первый ход (\(text.prefix(40)))")
    }

    static func claudeVersion(_ executable: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "?" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
