#if !APPSTORE
import Foundation

// MARK: - Агент в проекте (LUNA-80)
//
// Запрос на странице вопроса с выбранным проектом — не чат, а задача агенту: Luna запускает
// обычный `claude -p` в папке проекта, в фоне. Это сессия Claude Code со всеми инструментами,
// которые разрешают настройки пользователя и проекта. Что выполнять без вопроса, решают эти
// настройки; остальное спрашивается хуком `PermissionRequest` в острове (`HookServer`,
// `ApprovalQueue`) — не ответили, агенту отказ.
//
// - Без флагов, которые отключают или подменяют запросы разрешений: ни `--permission-mode`,
//   ни `--permission-prompts`, ни `--permission-prompt-tool`, ни `--dangerously-skip-permissions`.
//   Без `--bare` (он отключает вход по подписке) и без `--safe-mode`.
// - Luna не ограничивает инструменты агента (`--tools`, `--allowedTools`, `--disallowedTools`)
//   и не дописывает ему свой промпт (`--system-prompt`, `--append-system-prompt`).
// - Запрос — в stdin, не в argv. Своя сессия: `--session-id <uuid>`, дальше `--resume <uuid>`.
// - Окружение — `CLIResolver.environment` (ключ API и метки родительской сессии убраны), и ещё
//   `TERM_PROGRAM*`, `CLAUDE_CODE_SSE_PORT`, `ENABLE_IDE_INTEGRATION`: Luna, запущенная из
//   терминала редактора, не выдаёт агента за сессию редактора и не подключает его к IDE.
//   `LUNA_CHAT_SESSION` агенту не ставится: его хуки — сессия в острове.
// - Сторожа тишины нет: сборка или долгая команда идут, сколько нужно. Остановка — кнопкой
//   «Остановить» или выходом из Luna: SIGTERM, через 2 с SIGKILL.
//
// Только Foundation: аргументы, окружение, план запуска и процесс проверяются без окна
// (`scripts/test-agent-run.sh`). Только сборка GitHub: песочница App Store не даёт запускать CLI.

enum ClaudeAgentArguments {
    /// Аргументы хода агента: `resume` — продолжение той же сессии.
    static func build(model: String?, sessionID: String, resume: Bool) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--verbose"]
        if let model { args += ["--model", model] }
        args += resume ? ["--resume", sessionID] : ["--session-id", sessionID]
        return args
    }

    /// Флаги, которых в аргументах агента не бывает (инвариант CLAUDE.md, проверяется тестом).
    static let forbidden: Set<String> = [
        "--tools", "--allowedTools", "--disallowedTools",
        "--permission-mode", "--permission-prompts", "--permission-prompt-tool",
        "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
        "--bare", "--safe-mode", "--strict-mcp-config",
        "--system-prompt", "--append-system-prompt",
    ]
}

enum ClaudeAgentEnvironment {
    /// Что убирается у агента сверх `CLIResolver.strippedEnvironment`.
    static let stripped: Set<String> = [
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "CLAUDE_CODE_SSE_PORT", "ENABLE_IDE_INTEGRATION",
        LunaChatSessions.environmentKey,
    ]

    static func build(base: [String: String], executable: String,
                      home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String: String] {
        CLIResolver.environment(base: base, executable: executable, home: home)
            .filter { !stripped.contains($0.key) }
    }
}

// MARK: План запуска

/// Почему агент не запускается. У каждого отказа свой текст (`ClaudeAgentMessages`).
enum ClaudeAgentRefusal: Error, Equatable, Sendable {
    case notFound
    case notLoggedIn
    case folderMissing(String)
    case folderNoAccess(String)
    /// Хуков Luna для Claude Code нет: без них нет плитки, а разрешения отклоняются сразу.
    case noHooks
}

enum ClaudeAgentLaunchPlan {
    /// nil — всё готово, агент запускается. Порядок проверок: `claude`, вход, папка, хуки.
    static func refusal(executable: String?, status: CLIStatus, folder: String,
                        folderState: ChatProjectFolder, hooksPresent: Bool) -> ClaudeAgentRefusal? {
        guard executable != nil else { return .notFound }
        if status == .missing { return .notFound }
        if status == .notLoggedIn { return .notLoggedIn }
        switch folderState {
        case .missing:  return .folderMissing(folder)
        case .noAccess: return .folderNoAccess(folder)
        case .ready:    break
        }
        return hooksPresent ? nil : .noHooks
    }

    /// Запрос первого хода: контекст окна или файла — перед текстом, как у чата. Продолжение —
    /// только текст: контекст у сессии уже есть.
    static func prompt(query: String, resume: Bool,
                       window: (app: String, title: String, url: String?)? = nil,
                       file: ChatCLIPrompt.FileContext? = nil) -> String {
        resume ? query : ChatCLIPrompt.build(query: query, window: window, file: file)
    }
}

enum ClaudeAgentMessages {
    static func text(for refusal: ClaudeAgentRefusal) -> String {
        switch refusal {
        case .notFound:
            return String(localized: "agent.run.refusal.not-found",
                          defaultValue: "Claude Code not found. Install the CLI, run `claude` and sign in with /login.")
        case .notLoggedIn:
            return String(localized: "agent.run.refusal.not-logged-in",
                          defaultValue: "Claude Code is not signed in. In Terminal: `claude auth login`.")
        case .folderMissing(let path):
            return String(localized: "agent.run.refusal.folder-missing",
                          defaultValue: "Project folder not found: \(path)")
        case .folderNoAccess(let path):
            return String(localized: "agent.run.refusal.folder-no-access",
                          defaultValue: "No access to the project folder: \(path). Allow it in System Settings → Privacy & Security → Files and Folders.")
        case .noHooks:
            return String(localized: "agent.run.refusal.no-hooks",
                          defaultValue: "To see the agent and confirm its actions, connect Claude Code in Settings → Agents.")
        }
    }

    /// Ход кончился сбоем: текст для страницы агента. Ключ API не предлагается — агент только
    /// по подписке, Luna сама между подпиской и ключом не переключается.
    static func text(for error: ClaudeCLIError) -> String {
        switch error {
        case .sessionNotFound:
            return String(localized: "agent.run.error.session-not-found",
                          defaultValue: "The session is not available: Claude Code no longer has it.")
        default:
            return ChatCLIMessages.text(for: error, hasAPIKey: false, keyHint: false)
        }
    }
}

// MARK: Процесс

struct ClaudeAgentRequest: Sendable {
    var executable: String
    var prompt: String
    var model: String?
    var sessionID: String
    var resume: Bool
    /// Папка проекта: Luna её не создаёт, а проверяет перед запуском.
    var workingDirectory: URL
    var environment: [String: String]
}

/// Один ход агента. Объект одноразовый: `run` один раз, `cancel` — из любого потока.
final class ClaudeAgentProcess: @unchecked Sendable {
    /// Сколько ждать выхода по SIGTERM, прежде чем добить SIGKILL.
    static let killDelay: TimeInterval = 2

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var stderrBuffer = Data()
    private(set) var sessionID: String = ""

    // Живые ходы: при выходе из Luna их нужно погасить, осиротевших `claude` быть не должно.
    nonisolated(unsafe) private static var live: [ObjectIdentifier: ClaudeAgentProcess] = [:]
    private static let liveLock = NSLock()

    static func terminateAll() {
        let all = liveLock.withLock { Array(live.values) }
        all.forEach { $0.cancel() }
    }

    static var liveCount: Int { liveLock.withLock { live.count } }

    /// Выход из Luna: SIGTERM всем ходам и ожидание до `timeout`; кто не вышел — SIGKILL сразу.
    /// После этого ни одного `claude`, запущенного Luna, не остаётся.
    static func terminateAllAndWait(timeout: TimeInterval = killDelay) {
        terminateAll()
        let deadline = Date().addingTimeInterval(timeout)
        while liveCount > 0, Date() < deadline { usleep(50_000) }
        let rest = liveLock.withLock { Array(live.values) }
        rest.forEach { $0.kill() }
    }

    static func isRunning(sessionID: String) -> Bool {
        let id = sessionID.lowercased()
        return liveLock.withLock { live.values.contains { $0.sessionID == id } }
    }

    /// Запускает ход и возвращает итог: текст ответа или сбой. Отмена задачи останавливает процесс.
    func run(_ request: ClaudeAgentRequest) async -> Result<String, ClaudeCLIError> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: self.runBlocking(request))
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// SIGTERM; не вышел за `killDelay` — SIGKILL.
    func cancel() {
        let running: Process? = lock.withLock {
            cancelled = true
            return process
        }
        guard let running, running.isRunning else { return }
        running.terminate()
        let pid = running.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killDelay) {
            if running.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    private func kill() {
        let running: Process? = lock.withLock {
            cancelled = true
            return process
        }
        guard let running, running.isRunning else { return }
        Darwin.kill(running.processIdentifier, SIGKILL)
    }

    private func runBlocking(_ request: ClaudeAgentRequest) -> Result<String, ClaudeCLIError> {
        guard FileManager.default.isExecutableFile(atPath: request.executable) else { return .failure(.notFound) }
        // Папку проекта Luna не создаёт: пропала или нет доступа — `claude` не запускается.
        let path = request.workingDirectory.path
        switch ChatProjectFolder.inspect(path) {
        case .missing: return .failure(.projectFolderMissing(path))
        case .noAccess: return .failure(.projectFolderNoAccess(path))
        case .ready: break
        }
        sessionID = request.sessionID.lowercased()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = ClaudeAgentArguments.build(model: request.model, sessionID: request.sessionID,
                                                       resume: request.resume)
        process.currentDirectoryURL = request.workingDirectory
        process.environment = request.environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        signal(SIGPIPE, SIG_IGN)
        let alreadyCancelled = lock.withLock { () -> Bool in
            if !cancelled { self.process = process }
            return cancelled
        }
        if alreadyCancelled { return .failure(.cancelled) }
        do {
            try process.run()
        } catch {
            lock.withLock { self.process = nil }
            return .failure(.failed(status: -1, tail: ClaudeCLIProcess.tail(of: error.localizedDescription)))
        }
        Self.liveLock.withLock { Self.live[ObjectIdentifier(self)] = self }
        defer { Self.liveLock.withLock { _ = Self.live.removeValue(forKey: ObjectIdentifier(self)) } }
        // Отмена пришла между проверкой и запуском.
        if lock.withLock({ cancelled }) { cancel() }

        // Запрос — в stdin, из отдельного потока: большой файл не должен блокировать чтение вывода.
        let prompt = Data(request.prompt.utf8)
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: prompt)
            try? stdin.fileHandleForWriting.close()
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.appendStderr(data)
        }

        var parser = ClaudeStreamParser()
        let reader = stdout.fileHandleForReading
        while true {
            let data = reader.availableData
            if data.isEmpty { break }
            parser.feed(data)
        }
        parser.finish()
        process.waitUntilExit()
        stderr.fileHandleForReading.readabilityHandler = nil
        if let rest = try? stderr.fileHandleForReading.readToEnd(), !rest.isEmpty { appendStderr(rest) }

        if lock.withLock({ cancelled }) { return .failure(.cancelled) }
        return parser.outcome(exitStatus: process.terminationStatus,
                              stderrTail: ClaudeCLIProcess.tail(of: stderrString()))
    }

    private func appendStderr(_ data: Data) {
        lock.withLock {
            stderrBuffer.append(data)
            if stderrBuffer.count > 4096 { stderrBuffer = stderrBuffer.suffix(4096) }
        }
    }

    private func stderrString() -> String {
        lock.withLock { String(decoding: stderrBuffer, as: UTF8.self) }
    }
}
#endif
