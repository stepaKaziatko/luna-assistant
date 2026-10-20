import Foundation

// Разбор потока Claude Code (фикстуры) и запуск против поддельного `claude`.
// argv: <папка фикстур> <поддельный claude> <рабочая папка теста>

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

@main
enum ClaudeCLIChatTests {
    static var failures = 0
    static var fixtures = ""
    static var fake = ""
    static var work = ""

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func fixture(_ name: String) -> Data {
        (try? Data(contentsOf: URL(fileURLWithPath: "\(fixtures)/\(name)"))) ?? Data()
    }

    static func parse(_ name: String, exit: Int32 = 0) -> (ClaudeStreamParser, Result<String, ClaudeCLIError>) {
        var parser = ClaudeStreamParser()
        parser.feed(fixture(name))
        parser.finish()
        return (parser, parser.outcome(exitStatus: exit))
    }

    static func main() async {
        fixtures = CommandLine.arguments[1]
        fake = CommandLine.arguments[2]
        work = CommandLine.arguments[3]
        parserTests()
        argumentTests()
        messageTests()
        await runnerTests()
        await authProbeTests()
        if failures > 0 { print("\n\(failures) test(s) failed."); exit(1) }
        print("\nAll tests passed.")
    }

    // MARK: Разбор потока

    static func parserTests() {
        print("ClaudeStreamParser: успешный ответ")
        let (ok, okResult) = parse("success-turn1.jsonl")
        check("текст из дельт", ok.text == "Привет")
        check("итог — успех с тем же текстом", okResult == .success("Привет"))
        check("session_id прочитан", ok.sessionID == "00000000-0000-4000-8000-000000000001")
        check("rate_limit_event allowed — не лимит", !ok.rateLimited)
        let (resume, resumeResult) = parse("success-turn2-resume.jsonl")
        check("ответ второго хода (resume)", resume.text == "Hi" && resumeResult == .success("Hi"))

        print("ClaudeStreamParser: порции любого размера")
        var chunked = ClaudeStreamParser()
        let data = fixture("success-turn1.jsonl")
        var changes: [String] = []
        var i = 0
        while i < data.count {
            let end = min(i + 7, data.count)
            if chunked.feed(data.subdata(in: i..<end)) { changes.append(chunked.text) }
            i = end
        }
        chunked.finish()
        check("тот же текст при разбиении по 7 байт (в т.ч. посреди UTF-8)", chunked.text == "Привет")
        check("изменение текста сообщено", changes == ["Привет"])

        print("ClaudeStreamParser: вход не выполнен")
        let (_, noLogin) = parse("not-logged-in.jsonl", exit: 1)
        check("authentication_failed → «не вошёл»", noLogin == .failure(.notLoggedIn))

        print("ClaudeStreamParser: лимит подписки")
        let (limited, limitResult) = parse("rate-limited.jsonl", exit: 1)
        check("rate_limit_event не allowed → лимит", limited.rateLimited)
        check("итог — лимит со временем сброса из resetsAt",
              limitResult == .failure(.rateLimited(resetsAt: Date(timeIntervalSince1970: 1792357800))))

        print("ClaudeStreamParser: мусор")
        var garbage = ClaudeStreamParser()
        garbage.feed(Data("not json\n{broken\n\n[]\n{\"type\":5}\n".utf8))
        garbage.finish()
        check("битые строки не роняют разбор", garbage.text.isEmpty)
        check("мусор и код 0 → пустой ответ", garbage.outcome(exitStatus: 0) == .failure(.empty))
        check("мусор и код 2 → сбой с хвостом stderr",
              garbage.outcome(exitStatus: 2, stderrTail: "oops") == .failure(.failed(status: 2, tail: "oops")))
        let empty = ClaudeStreamParser()
        check("пустой вывод не роняет разбор", empty.outcome(exitStatus: 0) == .failure(.empty))
        var noNewline = ClaudeStreamParser()
        noNewline.feed(Data(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"A"}}}"#.utf8))
        check("строка без перевода строки ждёт конца вывода", noNewline.text.isEmpty)
        noNewline.finish()
        check("…и разбирается по finish()", noNewline.text == "A")

        print("ClaudeStreamParser: несколько текстовых блоков")
        var blocks = ClaudeStreamParser()
        func delta(_ t: String) -> Data {
            Data((#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""#
                  + t + #""}}}"# + "\n").utf8)
        }
        let start = Data((#"{"type":"stream_event","event":{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}}"# + "\n").utf8)
        blocks.feed(delta("Ищу.")); blocks.feed(start); blocks.feed(delta("Нашёл."))
        check("между блоками — пустая строка", blocks.text == "Ищу.\n\nНашёл.")

        print("ClaudeStreamParser: запасной путь без дельт")
        var fallback = ClaudeStreamParser()
        fallback.feed(Data((#"{"type":"assistant","message":{"content":[{"type":"text","text":"Целиком"}]}}"# + "\n").utf8))
        check("полное assistant-сообщение, если дельт не было", fallback.outcome(exitStatus: 0) == .success("Целиком"))

        print("ClaudeStreamParser: ошибки CLI")
        var apiError = ClaudeStreamParser()
        apiError.feed(Data((#"{"type":"result","is_error":true,"result":"Model not found","api_error_status":404}"# + "\n").utf8))
        check("ошибка API → .api с текстом", apiError.outcome(exitStatus: 1) == .failure(.api("Model not found")))
        var tooMany = ClaudeStreamParser()
        tooMany.feed(Data((#"{"type":"result","is_error":true,"result":"x","api_error_status":429}"# + "\n").utf8))
        check("429 без rate_limit_event → лимит без времени", tooMany.outcome(exitStatus: 1) == .failure(.rateLimited(resetsAt: nil)))
    }

    // MARK: Аргументы

    static func argumentTests() {
        print("ClaudeCLIArguments")
        let id = "11111111-2222-4333-8444-555555555555"
        let first = ClaudeCLIArguments.build(systemPrompt: "SYS", model: "sonnet", sessionID: id, resume: false)
        check("есть --safe-mode, --strict-mcp-config, --output-format stream-json",
              first.contains("--safe-mode") && first.contains("--strict-mcp-config")
                && zip(first, first.dropFirst()).contains { $0 == "--output-format" && $1 == "stream-json" })
        check("инструменты — только WebSearch,WebFetch",
              zip(first, first.dropFirst()).contains { $0 == "--tools" && $1 == "WebSearch,WebFetch" }
                && zip(first, first.dropFirst()).contains { $0 == "--allowedTools" && $1 == "WebSearch,WebFetch" })
        check("системный промпт Luna передан", zip(first, first.dropFirst()).contains { $0 == "--system-prompt" && $1 == "SYS" })
        check("запрещённого нет: --dangerously-skip-permissions, --bare, --no-session-persistence",
              !first.contains("--dangerously-skip-permissions") && !first.contains("--bare") && !first.contains("--no-session-persistence"))
        check("первый ход: --session-id, без --resume",
              zip(first, first.dropFirst()).contains { $0 == "--session-id" && $1 == id } && !first.contains("--resume"))
        check("модель передана", zip(first, first.dropFirst()).contains { $0 == "--model" && $1 == "sonnet" })
        let second = ClaudeCLIArguments.build(systemPrompt: "SYS", model: nil, sessionID: id, resume: true)
        check("второй ход: --resume тот же uuid, без --session-id",
              zip(second, second.dropFirst()).contains { $0 == "--resume" && $1 == id } && !second.contains("--session-id"))
        check("модель default — без --model", !second.contains("--model"))

        print("ClaudeCLIArguments: вопрос в проекте (решение В1 = B)")
        let proj = ClaudeCLIArguments.build(systemPrompt: "SYS", model: "sonnet", sessionID: id, resume: false, inProject: true)
        check("без --safe-mode и --strict-mcp-config: CLAUDE.md, хуки и MCP проекта работают",
              !proj.contains("--safe-mode") && !proj.contains("--strict-mcp-config"))
        check("без ограничения --tools, веб разрешён заранее",
              !proj.contains("--tools")
                && zip(proj, proj.dropFirst()).contains { $0 == "--allowedTools" && $1 == "WebSearch,WebFetch" })
        check("промпт Luna дописан к промпту Claude Code, не заменяет его",
              zip(proj, proj.dropFirst()).contains { $0 == "--append-system-prompt" && $1 == "SYS" } && !proj.contains("--system-prompt"))
        check("запрещённого нет и в проекте: --dangerously-skip-permissions, --bare, --permission-mode",
              !proj.contains("--dangerously-skip-permissions") && !proj.contains("--bare") && !proj.contains("--permission-mode"))
        check("stream-json, --session-id, модель — как без проекта",
              zip(proj, proj.dropFirst()).contains { $0 == "--output-format" && $1 == "stream-json" }
                && zip(proj, proj.dropFirst()).contains { $0 == "--session-id" && $1 == id }
                && zip(proj, proj.dropFirst()).contains { $0 == "--model" && $1 == "sonnet" })
        check("без проекта аргументы те же, что раньше (по умолчанию inProject = false)",
              first == ClaudeCLIArguments.build(systemPrompt: "SYS", model: "sonnet", sessionID: id, resume: false, inProject: false))
    }

    // MARK: Сообщения

    static func messageTests() {
        print("ChatCLIMessages")
        let t = ChatCLIMessages.text(for: .notFound, hasAPIKey: false)
        check("нет CLI: сообщение и подсказка про ключ в настройках", t.contains("not found") && t.contains("API key in Settings"))
        let t2 = ChatCLIMessages.text(for: .notLoggedIn, hasAPIKey: true)
        check("не вошёл: `claude auth login` и предложение переключиться на ключ",
              t2.contains("claude auth login") && t2.contains("switch to your API key"))
        let limit = ChatCLIMessages.text(for: .rateLimited(resetsAt: Date(timeIntervalSince1970: 1792357800)), hasAPIKey: true, locale: Locale(identifier: "en_GB"))
        check("лимит: время сброса в сообщении", limit.contains("limit") && limit.contains("resets at") && limit.contains(":"))
        check("лимит без времени", ChatCLIMessages.text(for: .rateLimited(resetsAt: nil), hasAPIKey: false).contains("limit"))
        let tail = String(repeating: "x", count: 400)
        check("сбой процесса: хвост stderr в сообщении", ChatCLIMessages.text(for: .failed(status: 3, tail: tail), hasAPIKey: false).contains(tail))
        check("таймаут", ChatCLIMessages.text(for: .timeout, hasAPIKey: false).contains("did not answer"))
        check("ошибка API не получает подсказку про ключ", !ChatCLIMessages.text(for: .api("boom"), hasAPIKey: false).contains("API key"))
        check("длинное сообщение CLI обрезается", ChatCLIMessages.clip(String(repeating: "я", count: 500)).count == 401)
        let missing = ChatCLIMessages.text(for: .projectFolderMissing("/w/gone"), hasAPIKey: false)
        check("папка проекта пропала: путь в сообщении, без подсказки про ключ",
              missing.contains("Project folder not found") && missing.contains("/w/gone") && !missing.contains("API key"))
        check("нет доступа к папке проекта",
              ChatCLIMessages.text(for: .projectFolderNoAccess("/w/x"), hasAPIKey: true).contains("No access to the project folder"))
    }

    // MARK: Запуск против поддельного claude

    static func request(mode: String, fixture fx: String = "success-turn1.jsonl", id: String = UUID().uuidString.lowercased(),
                        resume: Bool = false, name: String, env extra: [String: String] = [:],
                        idle: TimeInterval = 20, executable: String? = nil) -> ClaudeCLIRequest {
        let dir = "\(work)/\(name)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var env = CLIResolver.environment(base: ProcessInfo.processInfo.environment.merging(extra) { $1 }, executable: fake)
        env["FAKE_CLAUDE_MODE"] = mode
        env["FAKE_CLAUDE_FIXTURE"] = "\(fixtures)/\(fx)"
        env["FAKE_CLAUDE_ARGS_FILE"] = "\(dir)/args"
        env["FAKE_CLAUDE_STDIN_FILE"] = "\(dir)/stdin"
        env["FAKE_CLAUDE_ENV_FILE"] = "\(dir)/env"
        env["FAKE_CLAUDE_PID_FILE"] = "\(dir)/pid"
        env["FAKE_CLAUDE_CWD_FILE"] = "\(dir)/cwd-seen"
        var r = ClaudeCLIRequest(executable: executable ?? fake, prompt: "Секретный вопрос пользователя", systemPrompt: "SYS",
                                 model: "haiku", sessionID: id, resume: resume,
                                 workingDirectory: URL(fileURLWithPath: "\(dir)/cwd"), environment: env)
        r.idleTimeout = idle
        return r
    }

    static func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    static func waitFor(_ condition: () -> Bool, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    static func pid(_ name: String) -> Int32? { Int32(read("\(work)/\(name)/pid").trimmingCharacters(in: .whitespacesAndNewlines)) }

    static func runnerTests() async {
        print("ClaudeCLIProcess: стрим")
        let seen = Collector()
        let id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let r1 = request(mode: "stream", id: id, name: "stream", env: [
            "ANTHROPIC_API_KEY": "sk-test-secret", "ANTHROPIC_AUTH_TOKEN": "tok-secret", "CLAUDECODE": "1",
        ])
        let result = await ClaudeCLIProcess().run(r1) { seen.add($0) }
        check("успешный ответ", result == .success("Привет"))
        check("текст пришёл в onText", seen.all.last == "Привет")
        let args = read("\(work)/stream/args").split(separator: "\n").map(String.init)
        check("в argv --safe-mode и --session-id <uuid>", args.contains("--safe-mode") && args.contains(id))
        check("текст запроса в argv не встречается", !args.contains { $0.contains("Секретный вопрос") })
        check("запрос пришёл в stdin", read("\(work)/stream/stdin") == "Секретный вопрос пользователя")
        let env = read("\(work)/stream/env")
        check("в окружении подпроцесса нет ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, CLAUDECODE",
              !env.contains("ANTHROPIC_API_KEY") && !env.contains("ANTHROPIC_AUTH_TOKEN") && !env.contains("CLAUDECODE="))
        check("PATH содержит папку бинаря", env.contains("PATH=") && env.components(separatedBy: "\n").first { $0.hasPrefix("PATH=") }!.contains(URL(fileURLWithPath: fake).deletingLastPathComponent().path))
        check("рабочая папка создана", FileManager.default.fileExists(atPath: "\(work)/stream/cwd"))
        check("без проекта: запуск в служебной папке, метки чата в окружении нет",
              read("\(work)/stream/cwd-seen").trimmingCharacters(in: .whitespacesAndNewlines)
                == (ChatProjectPath.normalize("\(work)/stream/cwd") ?? "")
                && !env.contains("LUNA_CHAT_SESSION"))
        check("после ответа живых запусков нет", ClaudeCLIProcess.liveCount == 0)

        print("ClaudeCLIProcess: второй ход")
        let r2 = request(mode: "stream", fixture: "success-turn2-resume.jsonl", id: id, resume: true, name: "resume")
        let result2 = await ClaudeCLIProcess().run(r2) { _ in }
        let args2 = read("\(work)/resume/args").split(separator: "\n").map(String.init)
        check("--resume с тем же uuid", result2 == .success("Hi") && args2.contains("--resume") && args2.contains(id) && !args2.contains("--session-id"))

        print("ClaudeCLIProcess: вопрос в проекте")
        let projectDir = "\(work)/project-луна"
        try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        let projectSession = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        var p1 = request(mode: "stream", id: projectSession, name: "project1", env: ["ANTHROPIC_API_KEY": "sk-test-secret"])
        p1.workingDirectory = URL(fileURLWithPath: projectDir, isDirectory: true)
        p1.inProject = true
        let pr1 = await ClaudeCLIProcess().run(p1) { _ in }
        let pargs1 = read("\(work)/project1/args").split(separator: "\n").map(String.init)
        let penv1 = read("\(work)/project1/env")
        let realProject = ChatProjectPath.normalize(projectDir) ?? projectDir
        check("ответ получен", pr1 == .success("Привет"))
        check("рабочая папка — папка проекта", read("\(work)/project1/cwd-seen").trimmingCharacters(in: .whitespacesAndNewlines) == realProject)
        check("аргументы проекта: без --safe-mode, с --append-system-prompt, --session-id",
              !pargs1.contains("--safe-mode") && pargs1.contains("--append-system-prompt") && pargs1.contains("--session-id") && pargs1.contains(projectSession))
        check("в окружении метка чата LUNA_CHAT_SESSION=<id> и нет ключа API",
              penv1.contains("LUNA_CHAT_SESSION=\(projectSession)") && !penv1.contains("ANTHROPIC_API_KEY") && !penv1.contains("CLAUDECODE="))
        check("запрос в stdin без изменений", read("\(work)/project1/stdin") == "Секретный вопрос пользователя")
        var p2 = request(mode: "stream", fixture: "success-turn2-resume.jsonl", id: projectSession, resume: true, name: "project2")
        p2.workingDirectory = URL(fileURLWithPath: projectDir, isDirectory: true)
        p2.inProject = true
        let pr2 = await ClaudeCLIProcess().run(p2) { _ in }
        let pargs2 = read("\(work)/project2/args").split(separator: "\n").map(String.init)
        check("второй ход: --resume тот же id из той же папки",
              pr2 == .success("Hi") && pargs2.contains("--resume") && pargs2.contains(projectSession) && !pargs2.contains("--session-id")
                && read("\(work)/project2/cwd-seen").trimmingCharacters(in: .whitespacesAndNewlines) == realProject)

        print("ClaudeCLIProcess: папка проекта пропала")
        var p3 = request(mode: "stream", name: "project-gone")
        p3.workingDirectory = URL(fileURLWithPath: "\(work)/нет-такого-проекта", isDirectory: true)
        p3.inProject = true
        let pr3 = await ClaudeCLIProcess().run(p3) { _ in }
        check("ошибка «папка проекта не найдена»", pr3 == .failure(.projectFolderMissing("\(work)/нет-такого-проекта")))
        check("claude не запускался: файла аргументов нет", !FileManager.default.fileExists(atPath: "\(work)/project-gone/args"))
        check("папку проекта Luna не создала", !FileManager.default.fileExists(atPath: "\(work)/нет-такого-проекта"))

        print("ClaudeCLIProcess: вход не выполнен и лимит")
        let r3 = request(mode: "stream", fixture: "not-logged-in.jsonl", name: "nologin")
        let res3 = await ClaudeCLIProcess().run(r3) { _ in }
        check("fixture «не вошёл» → .notLoggedIn", res3 == .failure(.notLoggedIn))
        let r4 = request(mode: "stream", fixture: "rate-limited.jsonl", name: "limit")
        let res4 = await ClaudeCLIProcess().run(r4) { _ in }
        check("fixture «лимит» → .rateLimited",
              res4 == .failure(.rateLimited(resetsAt: Date(timeIntervalSince1970: 1792357800))))

        print("ClaudeCLIProcess: код выхода ≠ 0")
        let r5 = request(mode: "fail", name: "fail")
        let failed = await ClaudeCLIProcess().run(r5) { _ in }
        if case .failure(.failed(let status, let tail)) = failed {
            check("код 3 и хвост stderr ≤ 400 символов с причиной", status == 3 && tail.count <= 400 && tail.hasSuffix("the real reason"))
        } else {
            check("код 3 и хвост stderr ≤ 400 символов с причиной (получено \(failed))", false)
        }

        print("ClaudeCLIProcess: нет бинаря")
        let r6 = request(mode: "stream", name: "missing", executable: "\(work)/нет-такого-claude")
        let res6 = await ClaudeCLIProcess().run(r6) { _ in }
        check("несуществующий путь → .notFound", res6 == .failure(.notFound))

        print("ClaudeCLIProcess: отмена")
        let hung = ClaudeCLIProcess()
        let r7 = request(mode: "hang", name: "cancel")
        let task = Task { await hung.run(r7) { _ in } }
        let started = await waitFor({ pid("cancel") != nil && ClaudeCLIProcess.liveCount == 1 })
        check("процесс запущен", started)
        let childPid = pid("cancel") ?? 0
        hung.cancel()
        let cancelResult = await task.value
        check("отмена → .cancelled", cancelResult == .failure(.cancelled))
        let dead7 = await waitFor({ !isAlive(childPid) })
        check("дочерний процесс завершён (kill -0)", dead7)
        check("живых запусков нет", ClaudeCLIProcess.liveCount == 0)

        print("ClaudeCLIProcess: отмена задачи Swift")
        let r8 = request(mode: "hang", name: "taskcancel")
        let task8 = Task { await ClaudeCLIProcess().run(r8) { _ in } }
        _ = await waitFor({ pid("taskcancel") != nil })
        let pid8 = pid("taskcancel") ?? 0
        task8.cancel()
        let res8 = await task8.value
        let dead8 = await waitFor({ !isAlive(pid8) })
        check("отмена задачи останавливает процесс", res8 == .failure(.cancelled) && dead8)

        print("ClaudeCLIProcess: terminateAll (выход из Luna)")
        let r9 = request(mode: "hang", name: "quit")
        let task9 = Task { await ClaudeCLIProcess().run(r9) { _ in } }
        _ = await waitFor({ pid("quit") != nil && ClaudeCLIProcess.liveCount == 1 })
        let pid9 = pid("quit") ?? 0
        ClaudeCLIProcess.terminateAll()
        let res9 = await task9.value
        let dead9 = await waitFor({ !isAlive(pid9) })
        check("terminateAll гасит все запуски", res9 == .failure(.cancelled) && dead9)

        print("ClaudeCLIProcess: таймаут")
        let r10 = request(mode: "silent", name: "timeout", idle: 1)
        let t0 = Date()
        let timeoutResult = await ClaudeCLIProcess().run(r10) { _ in }
        check("тишина дольше таймаута → .timeout", timeoutResult == .failure(.timeout))
        check("…за разумное время", Date().timeIntervalSince(t0) < 8)
        let deadT = await waitFor({ !isAlive(pid("timeout") ?? 0) })
        check("…и процесс убит", deadT)
    }

    // MARK: claude auth status

    static func authProbeTests() async {
        print("ClaudeAuthProbe")
        func probe(json: String?, exit: Int32, hang: Bool = false, timeout: TimeInterval = 5) async -> CLIStatus {
            var env = ProcessInfo.processInfo.environment
            if let json {
                let file = "\(work)/auth-\(UUID().uuidString).json"
                try? json.write(toFile: file, atomically: true, encoding: .utf8)
                env["FAKE_CLAUDE_AUTH_JSON"] = file
            }
            env["FAKE_CLAUDE_AUTH_EXIT"] = String(exit)
            if hang { env["FAKE_CLAUDE_AUTH_MODE"] = "hang" }
            return await ClaudeAuthProbe.check(executable: fake, timeout: timeout, baseEnvironment: env)
        }
        let a1 = await probe(json: #"{"loggedIn":true,"authMethod":"claude.ai"}"#, exit: 0)
        check("вошёл по подписке", a1 == .ready(authMethod: "claude.ai"))
        let a2 = await probe(json: #"{"loggedIn":false,"authMethod":"none"}"#, exit: 1)
        check("не вошёл", a2 == .notLoggedIn)
        let a3 = await probe(json: "oops", exit: 0)
        check("мусор вместо JSON", a3 == .notLoggedIn)
        let t0 = Date()
        let a4 = await probe(json: nil, exit: 0, hang: true, timeout: 1)
        check("зависший `auth status` обрывается по таймауту", a4 == .notLoggedIn && Date().timeIntervalSince(t0) < 6)
        let a5 = await ClaudeAuthProbe.check(executable: nil)
        check("нет бинаря → .missing", a5 == .missing)
    }
}
