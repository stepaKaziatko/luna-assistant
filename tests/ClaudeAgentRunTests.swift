import Foundation

// Агент в проекте (LUNA-80): аргументы, окружение, план запуска, процесс против поддельного
// `claude` (tests/fake_claude_cli.sh) и маршрут хуков. Живой `claude` не нужен.

final class Box: @unchecked Sendable {
    var value: Result<String, ClaudeCLIError>?
}

@main
enum ClaudeAgentRunTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var fixtures = ""
    nonisolated(unsafe) static var fake = ""
    nonisolated(unsafe) static var work = ""

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func pair(_ args: [String], _ flag: String, _ value: String) -> Bool {
        zip(args, args.dropFirst()).contains { $0 == flag && $1 == value }
    }

    static func main() async {
        fixtures = CommandLine.arguments[1]
        fake = CommandLine.arguments[2]
        work = CommandLine.arguments[3]
        argumentTests()
        environmentTests()
        planTests()
        await processTests()
        hookTests()
        print(failures == 0 ? "\nAll agent run tests passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: 1–2. Аргументы

    static func argumentTests() {
        print("ClaudeAgentArguments")
        let id = "11111111-2222-4333-8444-555555555555"
        let first = ClaudeAgentArguments.build(model: "haiku", sessionID: id, resume: false)
        check("первый ход: -p, stream-json, --verbose, --session-id <uuid>, --model",
              first.first == "-p" && pair(first, "--output-format", "stream-json") && first.contains("--verbose")
                && pair(first, "--session-id", id) && pair(first, "--model", "haiku") && !first.contains("--resume"))
        check("argv первого хода целиком",
              first == ["-p", "--output-format", "stream-json", "--verbose", "--model", "haiku", "--session-id", id])
        for flag in ClaudeAgentArguments.forbidden.sorted() {
            check("нет \(flag)", !first.contains(flag))
        }
        check("список запретов — все флаги из критерия",
              ClaudeAgentArguments.forbidden == [
                "--tools", "--allowedTools", "--disallowedTools", "--permission-mode", "--permission-prompts",
                "--permission-prompt-tool", "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
                "--bare", "--safe-mode", "--strict-mcp-config", "--system-prompt", "--append-system-prompt"])
        let next = ClaudeAgentArguments.build(model: "haiku", sessionID: id, resume: true)
        check("следующий ход: --resume тот же id, без --session-id",
              pair(next, "--resume", id) && !next.contains("--session-id"))
        check("следующий ход: остальное как в первом",
              Array(next.dropLast(2)) == Array(first.dropLast(2))
                && ClaudeAgentArguments.forbidden.allSatisfy { !next.contains($0) })
        let noModel = ClaudeAgentArguments.build(model: nil, sessionID: id, resume: false)
        check("модель не выбрана — без --model", !noModel.contains("--model"))
    }

    // MARK: 3. Окружение

    static func environmentTests() {
        print("ClaudeAgentEnvironment")
        let base = [
            "TERM_PROGRAM": "vscode", "TERM_PROGRAM_VERSION": "1.99", "CLAUDE_CODE_SSE_PORT": "54321",
            "ENABLE_IDE_INTEGRATION": "true", "ANTHROPIC_API_KEY": "sk-secret", "ANTHROPIC_AUTH_TOKEN": "tok",
            "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "LUNA_CHAT_SESSION": "x",
            "HOME": "/Users/me", "PATH": "/usr/bin",
        ]
        let env = ClaudeAgentEnvironment.build(base: base, executable: "/opt/claude/bin/claude", home: "/Users/me")
        for key in ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "CLAUDE_CODE_SSE_PORT", "ENABLE_IDE_INTEGRATION",
                    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
            check("нет \(key)", env[key] == nil)
        }
        check("нет LUNA_CHAT_SESSION: хуки агента — сессия в острове", env["LUNA_CHAT_SESSION"] == nil)
        check("PATH — как у CLIResolver.environment",
              env["PATH"] == CLIResolver.environment(base: base, executable: "/opt/claude/bin/claude", home: "/Users/me")["PATH"])
        check("остальное окружение сохраняется", env["HOME"] == "/Users/me")
    }

    // MARK: 4–5. Запрос и план

    static func planTests() {
        print("ClaudeAgentLaunchPlan")
        let ready = ChatProjectFolder.ready(claudeMD: false, agentsMD: false)
        let ok = CLIStatus.ready(authMethod: "claude.ai")
        func refusal(exe: String? = "/bin/claude", status: CLIStatus = ok, folder: ChatProjectFolder = ready,
                     hooks: Bool = true) -> ClaudeAgentRefusal? {
            ClaudeAgentLaunchPlan.refusal(executable: exe, status: status, folder: "/w/shop",
                                          folderState: folder, hooksPresent: hooks)
        }
        check("всё готово — план годится", refusal() == nil)
        check("claude не найден", refusal(exe: nil) == .notFound)
        check("claude не найден (статус)", refusal(status: .missing) == .notFound)
        check("не вошёл", refusal(status: .notLoggedIn) == .notLoggedIn)
        check("папки нет", refusal(folder: .missing) == .folderMissing("/w/shop"))
        check("нет доступа", refusal(folder: .noAccess) == .folderNoAccess("/w/shop"))
        check("хуков Luna для Claude Code нет", refusal(hooks: false) == .noHooks)
        let all: [ClaudeAgentRefusal] = [.notFound, .notLoggedIn, .folderMissing("/w/shop"),
                                         .folderNoAccess("/w/shop"), .noHooks]
        let texts = all.map(ClaudeAgentMessages.text(for:))
        check("у каждого отказа свой текст", Set(texts).count == all.count && texts.allSatisfy { !$0.isEmpty })
        check("отказ без хуков ведёт в Настройки → Агенты", ClaudeAgentMessages.text(for: .noHooks).contains("Settings → Agents"))
        check("сессия недоступна — свой текст, без подсказки про ключ",
              ClaudeAgentMessages.text(for: ClaudeCLIError.sessionNotFound).contains("not available")
                && !ClaudeAgentMessages.text(for: ClaudeCLIError.notLoggedIn).contains("API key"))

        print("ClaudeAgentLaunchPlan.prompt")
        let first = ClaudeAgentLaunchPlan.prompt(query: "сделай X", resume: false,
                                                 window: (app: "Safari", title: "Docs", url: nil))
        check("первый ход: контекст окна перед запросом", first.hasPrefix("Context — App: Safari") && first.hasSuffix("сделай X"))
        let file = ClaudeAgentLaunchPlan.prompt(query: "q", resume: false, file: .text(name: "a.txt", contents: "abc"))
        check("первый ход: файл перед запросом", file.contains("File: a.txt") && file.contains("abc") && file.hasSuffix("q"))
        check("--resume: только текст", ClaudeAgentLaunchPlan.prompt(query: "дальше", resume: true,
                                                                       window: (app: "Safari", title: "Docs", url: nil)) == "дальше")
    }

    // MARK: 4, 6, 7. Процесс

    static func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
    static func pid(_ name: String) -> Int32? { Int32(read("\(work)/\(name)/pid").trimmingCharacters(in: .whitespacesAndNewlines)) }

    static func waitFor(_ condition: () -> Bool, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    static func request(mode: String, name: String, id: String = UUID().uuidString.lowercased(), resume: Bool = false,
                        extra: [String: String] = [:], folder: String? = nil) -> ClaudeAgentRequest {
        let dir = "\(work)/\(name)"
        let project = folder ?? "\(dir)/project"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if folder == nil { try? FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true) }
        var env = ClaudeAgentEnvironment.build(base: ProcessInfo.processInfo.environment.merging(extra) { $1 },
                                               executable: fake)
        env["FAKE_CLAUDE_MODE"] = mode
        env["FAKE_CLAUDE_FIXTURE"] = "\(fixtures)/success-turn1.jsonl"
        env["FAKE_CLAUDE_ARGS_FILE"] = "\(dir)/args"
        env["FAKE_CLAUDE_STDIN_FILE"] = "\(dir)/stdin"
        env["FAKE_CLAUDE_ENV_FILE"] = "\(dir)/env"
        env["FAKE_CLAUDE_PID_FILE"] = "\(dir)/pid"
        env["FAKE_CLAUDE_CWD_FILE"] = "\(dir)/cwd-seen"
        return ClaudeAgentRequest(executable: fake, prompt: "Секретная задача", model: "haiku", sessionID: id,
                                  resume: resume, workingDirectory: URL(fileURLWithPath: project, isDirectory: true),
                                  environment: env)
    }

    static func processTests() async {
        print("ClaudeAgentProcess: ход")
        let id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let r1 = request(mode: "stream", name: "turn", id: id,
                         extra: ["TERM_PROGRAM": "vscode", "CLAUDE_CODE_SSE_PORT": "1", "ANTHROPIC_API_KEY": "sk"])
        let res1 = await ClaudeAgentProcess().run(r1)
        check("ответ получен", res1 == .success("Привет"))
        let args = read("\(work)/turn/args").split(separator: "\n").map(String.init)
        check("процессу ушли аргументы построителя",
              args == ClaudeAgentArguments.build(model: "haiku", sessionID: id, resume: false))
        check("текст запроса в stdin, не в argv",
              read("\(work)/turn/stdin") == "Секретная задача" && !args.contains { $0.contains("Секретная") })
        let env = read("\(work)/turn/env")
        check("в окружении процесса нет TERM_PROGRAM, CLAUDE_CODE_SSE_PORT, ключа API и LUNA_CHAT_SESSION",
              !env.contains("TERM_PROGRAM=") && !env.contains("CLAUDE_CODE_SSE_PORT=")
                && !env.contains("ANTHROPIC_API_KEY=") && !env.contains("LUNA_CHAT_SESSION="))
        check("рабочая папка — папка проекта",
              read("\(work)/turn/cwd-seen").trimmingCharacters(in: .whitespacesAndNewlines)
                == (ChatProjectPath.normalize("\(work)/turn/project") ?? ""))
        check("после хода живых запусков нет", ClaudeAgentProcess.liveCount == 0)

        let r2 = request(mode: "stream", name: "resume", id: id, resume: true)
        _ = await ClaudeAgentProcess().run(r2)
        let args2 = read("\(work)/resume/args").split(separator: "\n").map(String.init)
        check("продолжение: --resume того же id", pair(args2, "--resume", id) && !args2.contains("--session-id"))

        print("ClaudeAgentProcess: папка проекта")
        let gone = request(mode: "stream", name: "gone", folder: "\(work)/нет-такого-проекта")
        let resGone = await ClaudeAgentProcess().run(gone)
        check("папки нет → отказ, claude не запускался, папку Luna не создала",
              resGone == .failure(.projectFolderMissing("\(work)/нет-такого-проекта"))
                && !FileManager.default.fileExists(atPath: "\(work)/gone/args")
                && !FileManager.default.fileExists(atPath: "\(work)/нет-такого-проекта"))

        print("ClaudeAgentProcess: сторожа тишины нет")
        let t0 = Date()
        let quiet = request(mode: "quiet", name: "quiet", extra: ["FAKE_CLAUDE_QUIET": "3"])
        let resQuiet = await ClaudeAgentProcess().run(quiet)
        check("молчит 3 с (у чата порог тишины 1 с убил бы его) — не убит, ответ получен",
              resQuiet == .success("Привет") && Date().timeIntervalSince(t0) >= 3)

        print("ClaudeAgentProcess: остановка")
        let sid = "dddddddd-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let stubborn = ClaudeAgentProcess()
        let r3 = request(mode: "stubborn", name: "stubborn", id: sid)
        let box = Box()
        let task = Task { box.value = await stubborn.run(r3) }
        let started = await waitFor({ pid("stubborn") != nil && ClaudeAgentProcess.liveCount == 1 })
        check("ход идёт, сессия видна как идущая", started && ClaudeAgentProcess.isRunning(sessionID: sid.uppercased()))
        let child = pid("stubborn") ?? 0
        let stopAt = Date()
        stubborn.cancel()
        try? await Task.sleep(for: .milliseconds(1200))
        check("SIGTERM: процесс, который его не слушает, ещё жив через 1,2 с", isAlive(child))
        await task.value
        let killedAfter = Date().timeIntervalSince(stopAt)
        check("через ~2 с — SIGKILL", !isAlive(child) && killedAfter >= ClaudeAgentProcess.killDelay - 0.1 && killedAfter < 5)
        check("итог — остановлен (.cancelled)", box.value == .failure(.cancelled))
        check("сессия больше не идёт", !ClaudeAgentProcess.isRunning(sessionID: sid))

        print("ClaudeAgentProcess: выход из Luna")
        let a = request(mode: "hang", name: "quit-a")
        let b = request(mode: "stubborn", name: "quit-b")
        let ta = Task { await ClaudeAgentProcess().run(a) }
        let tb = Task { await ClaudeAgentProcess().run(b) }
        _ = await waitFor({ pid("quit-a") != nil && pid("quit-b") != nil && ClaudeAgentProcess.liveCount == 2 })
        check("два хода идут", ClaudeAgentProcess.liveCount == 2)
        let quitStart = Date()
        await Task.detached { ClaudeAgentProcess.terminateAllAndWait() }.value
        check("terminateAllAndWait уложился в ~2 с", Date().timeIntervalSince(quitStart) < 4)
        let ra = await ta.value, rb = await tb.value
        let dead = await waitFor({ !isAlive(pid("quit-a") ?? 0) && !isAlive(pid("quit-b") ?? 0) }, seconds: 2)
        check("после terminateAll живых запусков агента 0, процессов нет",
              ClaudeAgentProcess.liveCount == 0 && dead && ra == .failure(.cancelled) && rb == .failure(.cancelled))
    }

    // MARK: 8–9. Маршрут хуков

    static func hookTests() {
        print("LunaHookOrigin")
        let lunaId = "eeeeeeee-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        LunaAgentSessions.register(lunaId.uppercased())
        let chatId = "ffffffff-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        LunaChatSessions.register(chatId)
        check("сессия агента Luna, без терминала и редактора → агент",
              LunaHookOrigin.of(["session_id": lunaId, "term_program": "", "bundle_id": ""]) == .agent)
        check("сессия агента Luna с term_program=vscode → всё равно агент Luna",
              LunaHookOrigin.of(["session_id": lunaId, "term_program": "vscode"]) == .agent)
        check("чужая сессия → прежний маршрут",
              LunaHookOrigin.of(["session_id": UUID().uuidString, "term_program": ""]) == .other)
        check("сессия без id → прежний маршрут", LunaHookOrigin.of(["term_program": ""]) == .other)
        check("сессия чата по-прежнему отбрасывается", LunaHookOrigin.of(["session_id": chatId]) == .chat)
        check("хост агента Luna — «Luna (в фоне)», не VS Code",
              ClaudeHost.name(for: AgentHost.lunaBackground) == AgentHost.lunaBackgroundName
                && AgentHost.lunaBackground == "dev.luna.Luna")
        check("«Перейти к агенту» для агента Luna не показывается",
              !AgentJumpPlan.make(pill: "integration_claude", sessionId: lunaId,
                                  who: AgentSessionWho(project: "shop", agent: "Claude Code",
                                                       hostBundleId: AgentHost.lunaBackground, cwd: "/w/shop")).isAvailable)

        var queue = ApprovalQueue()
        let entry = QueuedApproval(id: UUID(), fd: -1, sessionId: lunaId, pillId: "integration_claude",
                                   projectName: "shop", cwd: "/w/shop", tool: "Bash", command: "touch x",
                                   inputKey: "", hostApp: AgentHost.lunaBackground)
        check("PermissionRequest агента Luna → в очередь острова (accepted)", queue.enqueue(entry) == .accepted)
    }
}
