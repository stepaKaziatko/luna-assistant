#if !APPSTORE
import Foundation

// MARK: - Чат через установленный Claude Code (по подписке)
//
// Подпроцесс `claude -p` из приложения, без ядра. Только сборка GitHub: в App Store-сборке
// песочница не даёт запускать чужие программы.
//
// - Запрос идёт в stdin, не в argv: его не видно в `ps`, длина не ограничена.
// - Свои сессии: `--session-id <uuid>` на первом ходе, `--resume <uuid>` дальше. Чужие
//   идущие сессии агентов не затрагиваются.
// - `--safe-mode`: без хуков, плагинов, CLAUDE.md и MCP пользователя. Подпроцесс не шлёт
//   события хуков, поэтому ответ чата не появляется в острове как сессия агента.
// - Без `--bare` (он отключает вход по подписке) и без флагов, отключающих запросы разрешений.
// - Из окружения убираются ключ API и метки родительской сессии (`CLIResolver.environment`).

enum ClaudeCLIArguments {
    /// Инструменты чата: поиск и чтение страниц в сети, как web_search у API-пути. Файлы
    /// пользователя CLI не читает (`Read` не включён), оболочки у него нет.
    static let tools = "WebSearch,WebFetch"

    static func build(systemPrompt: String, model: String?, sessionID: String, resume: Bool) -> [String] {
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--safe-mode",
            "--strict-mcp-config",
            "--tools", tools,
            "--allowedTools", tools,
            "--system-prompt", systemPrompt,
        ]
        if let model { args += ["--model", model] }
        args += resume ? ["--resume", sessionID] : ["--session-id", sessionID]
        return args
    }
}

struct ClaudeCLIRequest: Sendable {
    var executable: String
    var prompt: String
    var systemPrompt: String
    var model: String?
    var sessionID: String
    var resume: Bool
    var workingDirectory: URL
    var environment: [String: String]
    /// Сколько ждать нового вывода. Куски ответа и события сбрасывают отсчёт.
    var idleTimeout: TimeInterval = 120
}

/// Один запуск. Объект одноразовый: `run` один раз, `cancel` — из любого потока.
final class ClaudeCLIProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var lastActivity = Date()
    private var stderrBuffer = Data()

    // Живые запуски: при выходе из Luna их нужно погасить, осиротевших `claude` быть не должно.
    nonisolated(unsafe) private static var live: [ObjectIdentifier: ClaudeCLIProcess] = [:]
    private static let liveLock = NSLock()

    static func terminateAll() {
        let all = liveLock.withLock { Array(live.values) }
        all.forEach { $0.cancel() }
    }

    static var liveCount: Int { liveLock.withLock { live.count } }

    /// Запускает `claude`, отдаёт нарастающий текст ответа в `onText` (на фоновой очереди, по порядку)
    /// и возвращает итог. Отмена задачи останавливает процесс.
    func run(_ request: ClaudeCLIRequest, onText: @escaping @Sendable (String) -> Void) async -> Result<String, ClaudeCLIError> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: self.runBlocking(request, onText: onText))
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let running: Process? = lock.withLock {
            cancelled = true
            return process
        }
        guard let running, running.isRunning else { return }
        running.terminate()
        // Не завершился по SIGTERM — добиваем: чат не оставляет `claude` на фоне.
        let pid = running.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if running.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func runBlocking(_ request: ClaudeCLIRequest, onText: @escaping @Sendable (String) -> Void) -> Result<String, ClaudeCLIError> {
        guard FileManager.default.isExecutableFile(atPath: request.executable) else { return .failure(.notFound) }
        try? FileManager.default.createDirectory(at: request.workingDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = ClaudeCLIArguments.build(
            systemPrompt: request.systemPrompt, model: request.model,
            sessionID: request.sessionID, resume: request.resume)
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
            return .failure(.failed(status: -1, tail: Self.tail(of: error.localizedDescription)))
        }
        Self.liveLock.withLock { Self.live[ObjectIdentifier(self)] = self }
        defer { Self.liveLock.withLock { _ = Self.live.removeValue(forKey: ObjectIdentifier(self)) } }
        // Отмена пришла между проверкой и запуском.
        if lock.withLock({ cancelled }) { process.terminate() }

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

        // Сторож: тишина дольше таймаута — убить и сообщить.
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            let expired = self.lock.withLock { () -> Bool in
                if Date().timeIntervalSince(self.lastActivity) > request.idleTimeout, !self.timedOut {
                    self.timedOut = true
                    return true
                }
                return false
            }
            if expired { self.cancel() }
        }
        watchdog.resume()
        defer { watchdog.cancel() }

        var parser = ClaudeStreamParser()
        let reader = stdout.fileHandleForReading
        while true {
            let data = reader.availableData
            if data.isEmpty { break }
            lock.withLock { lastActivity = Date() }
            if parser.feed(data) { onText(parser.text) }
        }
        if parser.finish() { onText(parser.text) }
        process.waitUntilExit()
        stderr.fileHandleForReading.readabilityHandler = nil
        if let rest = try? stderr.fileHandleForReading.readToEnd(), !rest.isEmpty { appendStderr(rest) }

        let (wasCancelled, didTimeOut) = lock.withLock { (cancelled, timedOut) }
        if didTimeOut { return .failure(.timeout) }
        if wasCancelled { return .failure(.cancelled) }
        return parser.outcome(exitStatus: process.terminationStatus, stderrTail: Self.tail(of: stderrString()))
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

    /// Последние ≤ 400 символов в одну строку.
    static func tail(of text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .suffix(400))
    }
}

// MARK: - Вход: `claude auth status`

enum ClaudeAuthProbe {
    /// В фоне, с таймаутом 5 с. Не найден бинарь — `.missing`. Остальное разбирает `ClaudeAuthStatus`.
    static func check(executable: String? = CLIResolver.executable(.claude),
                      timeout: TimeInterval = 5,
                      baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) async -> CLIStatus {
        guard let executable else { return .missing }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: probe(executable: executable, timeout: timeout, baseEnvironment: baseEnvironment))
            }
        }
    }

    private static func probe(executable: String, timeout: TimeInterval, baseEnvironment: [String: String]) -> CLIStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "status"]
        process.environment = CLIResolver.environment(base: baseEnvironment, executable: executable)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .missing }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer { killer.cancel() }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ClaudeAuthStatus.parse(output: String(decoding: data, as: UTF8.self), exitCode: process.terminationStatus)
    }
}

// MARK: - Рабочая папка чата

enum ClaudeCLIChatFolder {
    /// `~/Library/Application Support/Luna/chat`: не папка пользователя. Транскрипты чата
    /// Claude Code кладёт в `~/.claude/projects/…Luna-chat`.
    static var url: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Luna/chat", isDirectory: true)
    }
}
#endif
