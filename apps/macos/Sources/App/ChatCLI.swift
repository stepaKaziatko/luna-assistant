import Foundation

// MARK: - Чат по подписке: поиск CLI, состояние, выбор источника, подпись
//
// Только Foundation: файл собирается тестами одним `swiftc` (scripts/test-chat-cli.sh).
// Запуск процесса — в ClaudeCLIChat.swift (только сборка GitHub).

/// Установленные у пользователя CLI с входом по подписке.
/// Codex — каркас: поиск бинаря уже общий, адаптера чата пока нет (отдельная задача: нужны
/// записанные фикстуры с машины, где Codex установлен).
enum ChatCLIKind: String, Sendable {
    case claude, codex
}

// MARK: Поиск бинаря и окружение

enum CLIResolver {
    /// Куда обычно ставят CLI: у приложения нет PATH оболочки.
    static func candidates(for kind: ChatCLIKind, home: String, nodeVersions: [String] = []) -> [String] {
        let name = kind.rawValue
        var list: [String] = []
        if kind == .claude { list.append("\(home)/.claude/local/claude") }
        list += [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            "\(home)/.volta/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
            "\(home)/Library/pnpm/\(name)",
        ]
        // nvm: по папке bin на каждую версию Node, новые первыми.
        let sorted = nodeVersions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        list += sorted.map { "\(home)/.nvm/versions/node/\($0)/bin/\(name)" }
        return list
    }

    static func executable(
        _ kind: ChatCLIKind,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        nodeVersions: (() -> [String])? = nil
    ) -> String? {
        let versions = nodeVersions?()
            ?? ((try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node")) ?? [])
        return candidates(for: kind, home: home, nodeVersions: versions).first(where: isExecutable)
    }

    /// Переменные, которые CLI не должен получить от Luna:
    /// - ключ API и токен: иначе CLI тихо уйдёт на оплату по ключу, а не по подписке;
    /// - метки родительской сессии Claude Code (Luna могли запустить из неё): подпроцесс
    ///   не должен выдавать себя за её дочернюю сессию.
    static let strippedEnvironment: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
    ]

    static func environment(
        base: [String: String],
        executable: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        var env = base.filter { !strippedEnvironment.contains($0.key) }
        env["PATH"] = [
            URL(fileURLWithPath: executable).deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.local/bin", base["PATH"] ?? "",
        ].filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }
}

// MARK: Состояние источника

enum CLIStatus: Equatable, Sendable {
    case unknown                        // ещё не проверяли
    case missing                        // CLI не найден
    case notLoggedIn
    case ready(authMethod: String?)     // "claude.ai" — подписка

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Подпиской называем только вход через claude.ai; ключ API внутри CLI, Bedrock и Vertex —
    /// не подписка, и слово «подписка» к ним не применяется.
    var isSubscription: Bool {
        if case .ready(let method) = self { return method == "claude.ai" }
        return false
    }
}

enum ClaudeAuthStatus {
    /// Вывод `claude auth status`: JSON с `loggedIn` и `authMethod`, код выхода 1, если не вошёл.
    /// Невалидный вывод — «не вошёл»: ошибка разбора не должна ронять интерфейс.
    static func parse(output: String, exitCode: Int32) -> CLIStatus {
        guard let data = output.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["loggedIn"] as? Bool == true, exitCode == 0 else { return .notLoggedIn }
        return .ready(authMethod: json["authMethod"] as? String)
    }
}

// MARK: Выбор источника

enum ChatSourceChoice: Equatable {
    case anthropic, claudeCode
}

enum NoKeyAdvice: Equatable {
    case offerClaudeCode    // «Нет ключа API. Ответить через Claude Code по подписке?»
    case keyMissing         // прежний текст «API key missing»
}

enum ChatSourceSelection {
    /// Первый запуск: в `UserDefaults` нет `chatProvider`. Готовый Claude Code выбирается сам,
    /// но только если пользователь не завёл ключ API: с ключом он до сих пор отвечал по ключу,
    /// и молча переводить его на другой тариф нельзя. Явный выбор не переопределяется никогда.
    static func initialChoice(savedProvider: String?, claude: CLIStatus, hasAnthropicKey: Bool) -> ChatSourceChoice {
        if savedProvider == nil, claude.isReady, !hasAnthropicKey { return .claudeCode }
        return .anthropic
    }

    static func shouldAutoSelectClaudeCode(savedProvider: String?, claude: CLIStatus, hasAnthropicKey: Bool) -> Bool {
        savedProvider == nil
            && initialChoice(savedProvider: savedProvider, claude: claude, hasAnthropicKey: hasAnthropicKey) == .claudeCode
    }

    static func adviceForMissingAnthropicKey(claude: CLIStatus) -> NoKeyAdvice {
        claude.isReady ? .offerClaudeCode : .keyMissing
    }
}

// MARK: Подпись источника под ответом

enum ChatSourceLabel {
    /// «Claude Code · подписка · sonnet»; при входе не по подписке — «Claude Code · <способ> · sonnet».
    static func claudeCode(model: String, status: CLIStatus, subscriptionWord: String) -> String {
        var parts = ["Claude Code"]
        if status.isSubscription {
            parts.append(subscriptionWord)
        } else if case .ready(let method?) = status, !method.isEmpty {
            parts.append(method)
        }
        parts.append(model)
        return parts.joined(separator: " · ")
    }

    /// «Anthropic API · claude-sonnet-4-6», «Ollama · llama3.2».
    static func api(name: String, isLocal: Bool, model: String) -> String {
        "\(name)\(isLocal ? "" : " API") · \(model)"
    }
}

// MARK: Модели CLI-источника

enum ClaudeCodeModels {
    static let defaultID = "default"
    /// Алиасы `--model`: статический список, CLI не опрашивается.
    static let ids = [defaultID, "sonnet", "opus", "haiku"]

    /// Что передать в `--model`; nil — не передавать, действует настройка самого CLI.
    static func cliModel(for id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == defaultID ? nil : trimmed
    }
}

// MARK: Промпт для CLI

enum ChatCLIPrompt {
    enum FileContext: Equatable {
        case text(name: String, contents: String)   // текстовый файл ≤ 200 КБ
        case notPassed(name: String)                // PDF, картинки, слишком большой: CLI не получает
    }

    /// Текстовый файл крупнее этого в промпт не идёт (тот же порог, что для API).
    static let maxFileBytes = 200_000
    static let binaryExtensions: Set<String> = ["pdf", "jpg", "jpeg", "png", "gif", "webp", "heic", "tiff"]

    /// Контекст — данные, а не инструкции: он стоит перед вопросом отдельным блоком и подписан.
    static func build(query: String,
                      window: (app: String, title: String, url: String?)? = nil,
                      file: FileContext? = nil) -> String {
        var blocks: [String] = []
        if let window {
            var line = "Context — App: \(window.app), Window: \(window.title)"
            if let url = window.url { line += ", URL: \(url)" }
            blocks.append(line)
        }
        switch file {
        case .text(let name, let contents)?:
            blocks.append("File: \(name)\nFile contents:\n\(contents)")
        case .notPassed(let name)?:
            blocks.append("File: \(name) (the file itself is not available to you: only its name is known)")
        case nil:
            break
        }
        blocks.append(query)
        return blocks.joined(separator: "\n\n")
    }

    /// Файл → контекст: читаем только текст до порога, остальное — только имя.
    static func fileContext(name: String, fileExtension: String, data: Data?) -> FileContext {
        guard let data, data.count <= maxFileBytes,
              !binaryExtensions.contains(fileExtension.lowercased()),
              let text = String(data: data, encoding: .utf8) else { return .notPassed(name: name) }
        return .text(name: name, contents: text)
    }
}
