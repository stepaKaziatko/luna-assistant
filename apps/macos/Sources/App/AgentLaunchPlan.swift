import Foundation

// MARK: - Запуск агента из Luna: план (LUNA-77)
//
// Luna не запускает агента сама: она передаёт задачу в приложение, где человек привык работать
// с Claude Code, — VS Code (расширение Claude Code), терминал (`claude-cli://`) или Claude Desktop.
// Задача вписывается в поле ввода нового чата в папке проекта, отправляет её человек — Enter в
// целевом приложении (решение человека В1 = A). Агент дальше приходит в Luna хуками, как любой.
//
// Здесь только решение: проект, текст и цель превращаются в шаги или в причину отказа. Без
// AppKit — проверяется тестом `scripts/test-agent-launch.sh`; исполняет план `AgentLaunch`
// (только открытие папки и ссылок через `NSWorkspace`).

/// Куда передать задачу. `rawValue` хранится в UserDefaults (`agentLaunchTarget`).
enum AgentLaunchTarget: String, CaseIterable, Equatable, Sendable {
    case vscode
    case terminal
    case claudeDesktop

    /// Порядок в меню, пока человек ничего не выбирал.
    static let defaultOrder: [AgentLaunchTarget] = [.vscode, .terminal, .claudeDesktop]

    /// Приложение, которому Luna отдаёт папку и ссылку. У терминала своего приложения нет:
    /// ссылку `claude-cli://` система отдаёт обработчику Claude Code, а он — терминалу.
    var bundleId: String? {
        switch self {
        case .vscode:        return "com.microsoft.VSCode"
        case .terminal:      return nil
        case .claudeDesktop: return "com.anthropic.claudefordesktop"
        }
    }

    var scheme: String {
        switch self {
        case .vscode:        return "vscode"
        case .terminal:      return "claude-cli"
        case .claudeDesktop: return "claude"
        }
    }
}

/// Почему запуска нет. Этой же причиной кнопка объясняет, почему она неактивна.
enum AgentLaunchRefusal: Error, Equatable, Sendable {
    /// На странице запроса не выбран проект.
    case noProject
    /// В поле ничего нет (или одни пробелы): пустую задачу никто не просил.
    case emptyText
    /// Задача длиннее `AgentLaunchPlan.maxTextLength`. Молча не обрезается.
    case textTooLong
    /// Путь проекта не абсолютный, пустой, с управляющими символами или с сегментом `..`.
    case invalidFolder
    /// Папки проекта нет на диске.
    case folderMissing
    /// macOS не даёт Luna прочитать папку проекта.
    case folderNoAccess
}

/// Чем кончился клик по цели.
enum AgentLaunchOutcome: Equatable, Sendable {
    /// Папка и ссылка ушли в приложение цели.
    case launched
    case refused(AgentLaunchRefusal)
    /// Приложения цели уже нет (удалили, пока меню было открыто).
    case appMissing
}

struct AgentLaunchPlan: Equatable, Sendable {

    enum Step: Equatable, Sendable {
        /// Открыть папку проекта в приложении цели: окно с ней выходит вперёд или открывается новое.
        case openFolder(String)
        /// Открыть ссылку цели с вписанной задачей.
        case openURL(URL)
    }

    let target: AgentLaunchTarget
    /// Папка проекта — проверенный абсолютный путь.
    let folder: String
    let steps: [Step]

    /// Предел длины задачи в единицах UTF-16 — так длину считает обработчик `claude-cli://`
    /// (строка JavaScript, `q` не длиннее 5000). Тот же предел у всех целей.
    static let maxTextLength = 5000

    /// Схемы, которые Luna открывает при запуске: константы плана, не данные.
    static let allowedSchemes: Set<String> = ["vscode", "claude-cli", "claude"]

    /// Сколько ждать окна VS Code с папкой, если VS Code не был запущен: он сперва стартует.
    /// Запущенный ждёт, как «Перейти к агенту», `AgentJumpPlan.linkWaitLimit`.
    static let coldStartLinkWaitLimit: TimeInterval = 10

    // MARK: План

    /// План запуска или причина отказа. `folderState` — состояние папки на диске
    /// (`ChatProjectFolder.inspect`), nil — не проверялось.
    static func make(target: AgentLaunchTarget, folder rawFolder: String?, folderState: ChatProjectFolder? = nil,
                     text rawText: String) -> Result<AgentLaunchPlan, AgentLaunchRefusal> {
        if let refusal = refusal(folder: rawFolder, folderState: folderState, text: rawText) { return .failure(refusal) }
        // После `refusal` путь и текст заведомо годятся.
        guard let folder = rawFolder.flatMap(launchFolder),
              let link = link(target: target, folder: folder, text: task(rawText)) else {
            return .failure(.invalidFolder)
        }
        let steps: [Step]
        switch target {
        case .vscode:
            // Ссылку VS Code отдаёт окну в фокусе: сначала папка, потом ссылка.
            steps = [.openFolder(folder), .openURL(link)]
        case .terminal, .claudeDesktop:
            steps = [.openURL(link)]
        }
        return .success(AgentLaunchPlan(target: target, folder: folder, steps: steps))
    }

    /// Причина отказа, без построения ссылки: ею кнопка решает, активна ли она.
    static func refusal(folder: String?, folderState: ChatProjectFolder? = nil, text: String) -> AgentLaunchRefusal? {
        guard let folder else { return .noProject }
        let task = task(text)
        if task.isEmpty { return .emptyText }
        if task.utf16.count > maxTextLength { return .textTooLong }
        guard launchFolder(folder) != nil else { return .invalidFolder }
        switch folderState {
        case .missing?:  return .folderMissing
        case .noAccess?: return .folderNoAccess
        case .ready?, nil: return nil
        }
    }

    /// Текст задачи: без пробелов и переводов строк по краям; внутри — как написан.
    static func task(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Абсолютный путь без управляющих символов (`AgentJumpPlan.validFolder`) и без сегмента `..`
    /// (его не пропускает и обработчик `claude-cli://`). Иначе nil.
    static func launchFolder(_ path: String) -> String? {
        guard let path = AgentJumpPlan.validFolder(path),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
        return path
    }

    // MARK: Ссылки

    /// Ссылка цели с вписанной задачей:
    /// - VS Code — `vscode://anthropic.claude-code/open?prompt=<задача>`;
    /// - терминал — `claude-cli://open?cwd=<папка>&q=<задача>`;
    /// - Claude Desktop — `claude://code/new?folder=<папка>&q=<задача>`.
    static func link(target: AgentLaunchTarget, folder: String, text: String) -> URL? {
        guard allowedSchemes.contains(target.scheme) else { return nil }
        switch target {
        case .vscode:
            // VS Code раскодирует запрос ссылки один раз сам (`URI.parse`), а расширение разбирает
            // то, что осталось, ещё раз (`URLSearchParams`). Поэтому значение кодируется дважды:
            // иначе `&`, `+` и `%` из текста задачи порвали бы параметр.
            guard AgentEditors.allowedSchemes.contains(target.scheme),
                  let once = encode(text), let twice = encode(once) else { return nil }
            return URL(string: "\(target.scheme)://\(AgentEditors.extensionId)/open?prompt=\(twice)")
        case .terminal:
            guard let cwd = encode(folder), let q = encode(text) else { return nil }
            return URL(string: "\(target.scheme)://open?cwd=\(cwd)&q=\(q)")
        case .claudeDesktop:
            guard let path = encode(folder), let q = encode(text) else { return nil }
            return URL(string: "\(target.scheme)://code/new?folder=\(path)&q=\(q)")
        }
    }

    /// Незарезервированные символы RFC 3986 — всё остальное кодируется: `&`, `=`, `+`, `#`, `?`,
    /// пробел (`%20`), перевод строки (`%0A`), кириллица и эмодзи (UTF-8).
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }
}

// MARK: - Меню целей

/// Что установлено на Mac — проверяет `AgentLaunch` (AppKit), здесь только данные.
struct AgentLaunchApps: Equatable, Sendable {
    var vscode = false
    /// В папке расширений VS Code есть каталог расширения Claude Code (решение В3).
    var vscodeExtension = false
    /// Зарегистрирован обработчик `claude-cli://` — Claude Code делает это сам после первого
    /// промпта в интерактивном `claude`.
    var terminalHandler = false
    var claudeDesktop = false
}

enum AgentLaunchMenu {
    /// UserDefaults: последняя выбранная цель (`AgentLaunchTarget.rawValue`).
    static let defaultsKey = "agentLaunchTarget"

    struct Item: Equatable, Sendable {
        let target: AgentLaunchTarget
        /// Почему пункт неактивен; nil — активен.
        let blocked: Blocked?

        var isEnabled: Bool { blocked == nil }
    }

    enum Blocked: Equatable, Sendable {
        /// VS Code есть, расширения Claude Code в нём нет.
        case noVSCodeExtension
        /// Обработчик `claude-cli://` не зарегистрирован: `claude` не установлен или ни разу не
        /// запускался интерактивно.
        case noTerminalHandler
    }

    /// Пункты меню: VS Code и Claude Desktop — только установленные; терминал есть на любом Mac,
    /// поэтому виден всегда и неактивен без обработчика. Последняя выбранная цель — первой;
    /// неизвестное сохранённое значение — порядок по умолчанию.
    static func items(apps: AgentLaunchApps, last: String?) -> [Item] {
        var order = AgentLaunchTarget.defaultOrder
        if let last, let target = AgentLaunchTarget(rawValue: last), let index = order.firstIndex(of: target) {
            order.remove(at: index)
            order.insert(target, at: 0)
        }
        return order.compactMap { target in
            switch target {
            case .vscode:
                guard apps.vscode else { return nil }
                return Item(target: target, blocked: apps.vscodeExtension ? nil : .noVSCodeExtension)
            case .terminal:
                return Item(target: target, blocked: apps.terminalHandler ? nil : .noTerminalHandler)
            case .claudeDesktop:
                return apps.claudeDesktop ? Item(target: target, blocked: nil) : nil
            }
        }
    }

    /// Ни одна цель не готова — меню говорит, что поставить.
    static func nothingToLaunch(_ items: [Item]) -> Bool { !items.contains(where: \.isEnabled) }

    /// Есть ли расширение Claude Code: каталог `anthropic.claude-code-<версия>[-платформа]` среди
    /// имён в папке расширений VS Code. Содержимое каталогов не читается.
    static func hasClaudeCodeExtension(_ names: [String]) -> Bool {
        let prefix = AgentEditors.extensionId + "-"
        return names.contains { name in
            let lower = name.lowercased()
            guard lower.hasPrefix(prefix), let first = lower.dropFirst(prefix.count).first else { return false }
            return first.isNumber
        }
    }
}
