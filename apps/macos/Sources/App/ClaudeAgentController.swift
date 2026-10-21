#if !APPSTORE
import Foundation

// MARK: - Агенты, запущенные Luna (LUNA-80)
//
// Страница вопроса с выбранным проектом отправляет запрос агенту: каждая отправка — новый агент
// (решение В6), продолжение — со страницы этого агента (`--resume` той же сессии). Ход — отдельный
// процесс `claude -p` (`ClaudeAgentProcess`), между ходами процесса нет. Сессия видна в Luna как
// любой агент: плитка «Luna (в фоне)» на «Агентах» (её Luna кладёт сама до первого хука), запросы
// разрешений — карточкой в острове через хуки Luna (`HookServer`). Запуски живут в памяти до выхода
// из Luna; в историю чатов они не пишутся (решение В5).

@MainActor
final class ClaudeAgentController {
    static let shared = ClaudeAgentController()

    /// Где идёт сессия: папка проекта, его имя и модель первого хода.
    private struct Run {
        var folder: String
        var project: String
        var model: String?
    }

    private var runs: [String: Run] = [:]
    private var processes: [String: ClaudeAgentProcess] = [:]

    private init() {}

    /// Ходов, которые идут сейчас: при выходе из Luna их нужно остановить.
    var workingCount: Int { processes.count }

    func isRunning(sessionId: String) -> Bool { processes[sessionId.lowercased()] != nil }

    /// Сессию запустила Luna в этом запуске: её можно продолжить со страницы агента.
    func knows(sessionId: String) -> Bool { runs[sessionId.lowercased()] != nil }

    // MARK: Запуск

    /// Новый агент в папке проекта. Отказ — причина, агент не запускался. Запущен — ключ его плитки:
    /// страница вопроса ведёт на страницу этого агента.
    func start(query: String, context: PromptContext?, project: ChatProject,
               state: AppState) async -> Result<AgentSessionKey, ClaudeAgentRefusal> {
        let executable = CLIResolver.executable(.claude)
        let status = await loginStatus(executable: executable, state: state)
        let folderState = ChatProjectFolder.inspect(project.path)
        if let refusal = ClaudeAgentLaunchPlan.refusal(
            executable: executable, status: status, folder: project.path, folderState: folderState,
            hooksPresent: HookServer.claudeHooksInstalled()) {
            if case .folderMissing = refusal { state.chatProjectsChanged() }
            if case .folderNoAccess = refusal { state.chatProjectsChanged() }
            return .failure(refusal)
        }
        guard let executable else { return .failure(.notFound) }

        // Контекст окна или файла — в первом ходе, как у чата.
        var window: (app: String, title: String, url: String?)?
        var file: ChatCLIPrompt.FileContext?
        switch context {
        case .window(let app, let title, let url)?:
            window = (app, title, url)
        case .file(let name, let fileURL)?:
            file = ChatCLIPrompt.fileContext(name: name, fileExtension: fileURL?.pathExtension ?? "",
                                             data: fileURL.flatMap { try? Data(contentsOf: $0) })
        case nil:
            break
        }

        let sessionId = ChatCLISession.newID()
        let run = Run(folder: project.path, project: project.name,
                      model: ClaudeCodeModels.cliModel(for: state.claudeCodeChatModel))
        runs[sessionId] = run
        // До запуска: первый же хук сессии должен узнать её как агента Luna.
        LunaAgentSessions.register(sessionId)
        launch(sessionId: sessionId, run: run, executable: executable,
               prompt: ClaudeAgentLaunchPlan.prompt(query: query, resume: false, window: window, file: file),
               query: query, resume: false)
        return .success(HookServer.lunaRunKey(sessionId: sessionId))
    }

    /// Отправка со страницы вопроса с проектом: новый агент и переход на его страницу; отказ —
    /// заметка с причиной (без хуков — с кнопкой в Настройки → Агенты). true — агент запущен.
    func send(query: String, project: ChatProject, state: AppState) async -> Bool {
        switch await start(query: query, context: state.promptContext, project: project, state: state) {
        case .success(let key):
            // Чат из истории, открытый на странице, остаётся в истории; страница — пустая.
            if !state.chatHistory.isEmpty { state.startNewChat() }
            if state.stateOverride == .thinking { state.stateOverride = nil }
            state.openAgent(id: key.id)
            return true
        case .failure(let refusal):
            state.noteMessage = ClaudeAgentMessages.text(for: refusal)
            state.noteAction = refusal == .noHooks
                ? NoteAction(title: String(localized: "agent.run.refusal.open-settings",
                                           defaultValue: "Open Settings → Agents"),
                             provider: .claudeCode, query: "", settingsSection: "agents")
                : nil
            state.stateOverride = .error
            state.view = .note
            return false
        }
    }

    /// «Продолжить» на странице агента: следующий ход той же сессии в той же папке. nil — ход пошёл;
    /// иначе — текст, почему нет.
    func continueRun(sessionId: String, query: String, state: AppState) async -> String? {
        let id = sessionId.lowercased()
        guard let run = runs[id], processes[id] == nil else { return nil }
        let executable = CLIResolver.executable(.claude)
        let status = await loginStatus(executable: executable, state: state)
        if let refusal = ClaudeAgentLaunchPlan.refusal(
            executable: executable, status: status, folder: run.folder,
            folderState: ChatProjectFolder.inspect(run.folder),
            hooksPresent: HookServer.claudeHooksInstalled()) {
            return ClaudeAgentMessages.text(for: refusal)
        }
        guard let executable else { return ClaudeAgentMessages.text(for: ClaudeAgentRefusal.notFound) }
        launch(sessionId: id, run: run, executable: executable,
               prompt: ClaudeAgentLaunchPlan.prompt(query: query, resume: true), query: query, resume: true)
        return nil
    }

    /// «Остановить»: SIGTERM, через 2 с SIGKILL. Плитка — «остановлен», сессию можно продолжить.
    func stop(sessionId: String) {
        processes[sessionId.lowercased()]?.cancel()
    }

    /// Выход из Luna: все идущие ходы останавливаются.
    func stopAll() {
        ClaudeAgentProcess.terminateAll()
    }

    // MARK: Ход

    private func launch(sessionId: String, run: Run, executable: String, prompt: String,
                        query: String, resume: Bool) {
        let process = ClaudeAgentProcess()
        processes[sessionId] = process
        HookServer.shared.registerLunaRun(sessionId: sessionId, cwd: run.folder, project: run.project, prompt: query)
        let request = ClaudeAgentRequest(
            executable: executable, prompt: prompt, model: run.model, sessionID: sessionId, resume: resume,
            workingDirectory: URL(fileURLWithPath: run.folder, isDirectory: true),
            environment: ClaudeAgentEnvironment.build(base: ProcessInfo.processInfo.environment,
                                                      executable: executable))
        appendAppLog("luna.log", "[Agent] \(resume ? "continue" : "start") \(sessionId) in \(run.project)")
        Task { @MainActor in
            let result = await process.run(request)
            if self.processes[sessionId] === process { self.processes[sessionId] = nil }
            let outcome: AgentSessionBook.LunaRunOutcome
            switch result {
            case .success(let text):
                outcome = .finished(text: text)
            case .failure(.cancelled):
                outcome = .stopped
            case .failure(.empty):
                // Ход без текста (только действия): ответ уже пришёл хуком `Stop`, если был.
                outcome = .finished(text: nil)
            case .failure(let error):
                if error == .notLoggedIn { AppState.shared.claudeCodeStatus = .notLoggedIn }
                if error == .notFound { AppState.shared.claudeCodeStatus = .missing }
                outcome = .failed(ClaudeAgentMessages.text(for: error))
            }
            appendAppLog("luna.log", "[Agent] \(sessionId) ended: \(outcome)")
            HookServer.shared.lunaRunEnded(sessionId: sessionId, outcome: outcome)
        }
    }

    private func loginStatus(executable: String?, state: AppState) async -> CLIStatus {
        guard executable != nil else { return .missing }
        var status = await state.resolvedClaudeCodeStatus()
        if !status.isReady {
            // Кэш мог устареть: человек мог войти минуту назад.
            status = await ClaudeAuthProbe.check(executable: executable)
            state.claudeCodeStatus = status
        }
        return status
    }
}
#endif
