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

        // Вопрос в проекте (LUNA-75): без --safe-mode Claude Code сам читает CLAUDE.md папки проекта.
        let project = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("project")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try? "# Test project\n\nThe project codeword is ZEBRA-42. When asked for the codeword, reply with it.\n"
            .write(to: project.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        var inProject = ClaudeCLIRequest(
            executable: executable,
            prompt: "What is the project codeword? Reply with the codeword only.",
            systemPrompt: "You are a test. Answer briefly.",
            model: "haiku",
            sessionID: UUID().uuidString.lowercased(),
            resume: false,
            workingDirectory: project,
            environment: CLIResolver.environment(base: ProcessInfo.processInfo.environment, executable: executable))
        inProject.inProject = true
        let projectResult = await ClaudeCLIProcess().run(inProject) { _ in }
        switch projectResult {
        case .success(let text) where text.contains("ZEBRA-42"):
            print("  ✓ в проекте ответ называет кодовое слово из CLAUDE.md: \(text.prefix(40))")
        default:
            print("  ✗ в проекте: \(projectResult)"); exit(1)
        }

        // Разрешённый список в проекте (LUNA-75, П3): в `system/init` — только чтение, поиск по файлам
        // и поиск в сети, без MCP. Тот же argv, что у чата; процесс гасится сразу после `init`.
        let allowed: Set<String> = ["Read", "Glob", "Grep", "WebSearch", "WebFetch"]
        let initTools = initTools(executable: executable, project: project)
        print("  tools в system/init проекта: \(initTools?.sorted().joined(separator: ", ") ?? "нет события")")
        guard let initTools, !initTools.isEmpty, Set(initTools).isSubset(of: allowed),
              !initTools.contains(where: { $0.hasPrefix("mcp__") }) else {
            print("  ✗ в проекте инструменты вне разрешённого списка"); exit(1)
        }
        print("  ✓ в проекте tools ⊆ {Read, Glob, Grep, WebSearch, WebFetch}, MCP-инструментов нет")

        // В проекте чат только читает (LUNA-75, П1): правка и команда не выполняются даже тогда, когда
        // `.claude/settings.json` проекта их разрешает заранее, — запрет `--disallowedTools` сильнее.
        let claudeDir = project.appendingPathComponent(".claude")
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try? #"{"permissions":{"defaultMode":"acceptEdits","allow":["Bash","Edit","Write","NotebookEdit"]}}"#
            .write(to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let created = project.appendingPathComponent("created.txt")
        let ran = project.appendingPathComponent("ran.txt")
        var attempt = ClaudeCLIRequest(
            executable: executable,
            prompt: "Use your tools now, without asking: 1) create the file created.txt in the current folder "
                + "with the text hi; 2) run the shell command `touch ran.txt`. Then reply DONE or NOTOOLS.",
            systemPrompt: "You are a test. Answer briefly.",
            model: "haiku",
            sessionID: UUID().uuidString.lowercased(),
            resume: false,
            workingDirectory: project,
            environment: CLIResolver.environment(base: ProcessInfo.processInfo.environment, executable: executable))
        attempt.inProject = true
        let attemptResult = await ClaudeCLIProcess().run(attempt) { _ in }
        print("  ответ на просьбу о правке и команде: \(attemptResult)")
        let fm = FileManager.default
        if fm.fileExists(atPath: created.path) || fm.fileExists(atPath: ran.path) {
            print("  ✗ в проекте выполнилась правка или команда: created.txt=\(fm.fileExists(atPath: created.path)) "
                + "ran.txt=\(fm.fileExists(atPath: ran.path))"); exit(1)
        }
        print("  ✓ в проекте правка и команда не выполнились (created.txt и ran.txt нет), хотя настройки проекта их разрешают")
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

    /// Поле `tools` события `system/init` при запуске с аргументами чата в проекте. Окружение — как у
    /// `ClaudeCLIProcess`: метка `LUNA_CHAT_SESSION`, чтобы хуки Luna пропустили этот запуск.
    static func initTools(executable: String, project: URL) -> [String]? {
        let sessionID = UUID().uuidString.lowercased()
        var environment = CLIResolver.environment(base: ProcessInfo.processInfo.environment, executable: executable)
        environment[LunaChatSessions.environmentKey] = sessionID
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ClaudeCLIArguments.build(
            systemPrompt: "You are a test. Answer with one word.", model: "haiku",
            sessionID: sessionID, resume: false, inProject: true)
        process.currentDirectoryURL = project
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        try? stdin.fileHandleForWriting.write(contentsOf: Data("Reply with the single word: ok".utf8))
        try? stdin.fileHandleForWriting.close()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        var buffer = Data()
        let reader = stdout.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      event["type"] as? String == "system", event["subtype"] as? String == "init" else { continue }
                return event["tools"] as? [String] ?? []
            }
        }
    }
}
