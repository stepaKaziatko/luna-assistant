import AppKit
import Foundation

/// Подтверждение действий чужих сессий агентов — установка хука. Luna сама ничего не пишет в настройки Claude Code:
/// она показывает готовый фрагмент для `~/.claude/settings.json`, по кнопке копирует его и читает файл, чтобы
/// сказать, найден ли хук. Путь к обёртке хука приходит от ядра в `core.hello` (`agentHookPath`).

/// Найден ли хук Luna в настройках Claude Code.
enum AgentHookStatus: Equatable {
    /// Файл ещё не читали.
    case unknown
    case found
    /// Файла нет, он пуст или не разобран, или хука Luna в нём нет.
    case notFound
}

enum AgentHookSnippet {
    /// Событие, которое слушает хук: CLI показал диалог разрешения. Не `PreToolUse`: тот срабатывает и там,
    /// где CLI не стал бы спрашивать.
    static let event = "PermissionRequest"
    /// Инструменты, о которых Luna спрашивает человека; остальные запросы остаются в терминале.
    static let matcher = "Write|Edit|NotebookEdit|Bash"
    /// Срок хука, секунды. Хук ничего не блокирует: диалог в терминале виден всё время, а ответ в нём
    /// завершает вызов, не дожидаясь хука.
    static let timeoutSeconds = 600

    /// Команда хука: путь к обёртке в кавычках оболочки — в «Application Support» есть пробел.
    static func command(wrapperPath: String) -> String {
        "'" + wrapperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Фрагмент `settings.json`, который пользователь добавляет в `hooks`; валидный JSON.
    static func settingsJSON(wrapperPath: String) -> String {
        let object: [String: Any] = [
            "hooks": [
                event: [
                    [
                        "matcher": matcher,
                        "hooks": [
                            ["type": "command", "command": command(wrapperPath: wrapperPath), "timeout": timeoutSeconds] as [String: Any],
                        ],
                    ] as [String: Any],
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Найден ли хук `PermissionRequest` с командой на обёртку Luna в содержимом `settings.json`. Нет файла,
    /// пустой или битый JSON, другое событие — «не найден»; чтение не падает.
    static func status(settings: Data?, wrapperPath: String) -> AgentHookStatus {
        guard let settings, !settings.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let entries = hooks[event] as? [Any] else { return .notFound }
        for entry in entries {
            guard let group = entry as? [String: Any], let commands = group["hooks"] as? [Any] else { continue }
            for item in commands {
                if let command = (item as? [String: Any])?["command"] as? String, command.contains(wrapperPath) { return .found }
            }
        }
        return .notFound
    }

    /// Пользовательские настройки Claude Code, где живёт хук: `~/.claude/settings.json`, а при заданном
    /// `CLAUDE_CONFIG_DIR` — в нём (как у ядра при чтении реестра сессий).
    static func userSettingsURL(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let directory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
        return directory.appendingPathComponent("settings.json")
    }
}

/// Состояние блока «Подтверждение в сессиях агентов» в настройках.
@MainActor
final class AgentHookSetup: ObservableObject {
    /// Путь к обёртке хука от ядра; nil — ядро не отвечало или не смогло её создать.
    @Published private(set) var wrapperPath: String?
    @Published private(set) var status = AgentHookStatus.unknown

    private let settingsURL: () -> URL
    private var generation = 0
    #if DEBUG
    /// Файл настроек вместо `~/.claude/settings.json` (`agentHookSettings:`): проверка признака без чужих настроек.
    var debugSettingsPath: String?
    #endif

    init(settingsURL: @escaping () -> URL = { AgentHookSnippet.userSettingsURL() }) {
        self.settingsURL = settingsURL
    }

    func apply(_ hello: HelloResult) {
        guard wrapperPath != hello.agentHookPath else { return }
        wrapperPath = hello.agentHookPath
        status = .unknown
    }

    func reset() {
        wrapperPath = nil
        status = .unknown
    }

    /// Фрагмент для вставки; nil, пока путь неизвестен.
    var snippet: String? {
        wrapperPath.map { AgentHookSnippet.settingsJSON(wrapperPath: $0) }
    }

    func copySnippet() {
        guard let snippet else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
    }

    private func currentSettingsURL() -> URL {
        #if DEBUG
        if let debugSettingsPath { return URL(fileURLWithPath: debugSettingsPath) }
        #endif
        return settingsURL()
    }

    /// Перечитывает `settings.json` в фоне: файл мог быть на медленном диске, а кадр ждать нельзя.
    func check() {
        guard let wrapperPath else {
            status = .unknown
            return
        }
        generation += 1
        let mine = generation
        let url = currentSettingsURL()
        _Concurrency.Task {
            let result = await _Concurrency.Task.detached(priority: .utility) {
                AgentHookSnippet.status(settings: try? Data(contentsOf: url), wrapperPath: wrapperPath)
            }.value
            guard mine == generation else { return }
            status = result
        }
    }
}
