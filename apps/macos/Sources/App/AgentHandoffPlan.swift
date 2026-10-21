#if !APPSTORE
import Foundation

// MARK: - «Открыть в…»: перенос сессии агента в другое приложение (LUNA-79)
//
// Сессию Claude Code, которую видно на странице агента, можно продолжить в VS Code (таб
// расширения Claude Code) или в Claude Desktop. Разговор нельзя открывать в двух местах сразу:
// VS Code на открытую сессию показывает «Open here anyway», а ссылка Claude Desktop открытость не
// проверяет и завела бы вторую копию. А плитка Luna живёт ровно до `SessionEnd` — любая сессия на
// странице агента ещё открыта. Поэтому (решение человека В1 = A) клик ставит **перенос**: Luna
// ждёт `SessionEnd` этой сессии и только тогда открывает её в выбранном приложении. Перенос
// снимается кнопкой «Отменить», новым ходом сессии и через 5 минут.
//
// Здесь только решение — что предложить, какие ссылки, когда открывать. Без AppKit, под тестом
// `scripts/test-agent-handoff.sh`. Исполняет план `AgentHandoff` (папка и ссылки через
// `NSWorkspace`, команда — в буфер обмена). Переиспользуются проверки `AgentJumpPlan` и
// `AgentLaunchPlan`: id — только UUID, папка — абсолютная, без управляющих символов и `..`.
// App Store-сборке перенос не нужен (песочница не читает папку расширений VS Code): весь код — под `#if !APPSTORE`.

/// Куда перенести сессию.
enum AgentHandoffTarget: String, CaseIterable, Equatable, Sendable {
    case vscode
    case claudeDesktop

    /// Порядок в меню — постоянный: последняя цель не запоминается.
    static let order: [AgentHandoffTarget] = [.vscode, .claudeDesktop]

    /// Приложение цели — те же, что у запуска агента (LUNA-77).
    var bundleId: String {
        switch self {
        case .vscode:        return AgentLaunchTarget.vscode.bundleId ?? ""
        case .claudeDesktop: return AgentLaunchTarget.claudeDesktop.bundleId ?? ""
        }
    }
}

/// Почему пункт меню неактивен.
enum AgentHandoffBlocked: Equatable, Sendable {
    /// Агент сейчас работает: перенос посреди хода прервал бы его.
    case agentWorking
    /// Агент ждёт ответа на вопрос или запрос разрешения.
    case agentWaiting
    /// VS Code есть, расширения Claude Code в нём нет.
    case noVSCodeExtension
    /// Папки проекта нет на диске или путь не годится.
    case folderMissing
}

// MARK: - План

struct AgentHandoffPlan: Equatable, Sendable {
    let target: AgentHandoffTarget
    let sessionId: String
    /// VS Code — папка проекта, затем ссылка на сессию; Claude Desktop — одна ссылка.
    let steps: [AgentLaunchPlan.Step]

    /// Схемы, которые открывает перенос: константы плана, не данные хука.
    static let allowedSchemes: Set<String> = ["vscode", "claude"]

    /// Хозяин сессии, которой «Открыть в…» не предлагается (решение В5): что Claude Desktop хранит
    /// свои сессии так, чтобы их нашёл VS Code, не проверено.
    static let desktopBundleId = AgentHandoffTarget.claudeDesktop.bundleId

    /// Годится ли сессия для «Открыть в…» вообще: Claude Code (`integration_claude`), id — UUID
    /// (у анонимной сессии ключ из pill и cwd — не id), идёт не в Claude Desktop.
    static func isEligible(pill: String, sessionId: String, hostBundleId: String) -> Bool {
        AgentJumpPlan.linkablePills.contains(pill)
            && AgentJumpPlan.isUUID(sessionId)
            && hostBundleId != desktopBundleId
    }

    /// Папка сессии для VS Code и команды терминала: корень проекта (`projectDir`, иначе `cwd`,
    /// как у «Перейти к агенту»), абсолютный путь без `..`. Иначе nil.
    static func folder(of who: AgentSessionWho) -> String? {
        AgentJumpPlan.folder(of: who).flatMap(AgentLaunchPlan.launchFolder)
    }

    /// План переноса или nil, если сессия или папка не годятся.
    static func make(target: AgentHandoffTarget, pill: String, sessionId: String,
                     who: AgentSessionWho) -> AgentHandoffPlan? {
        guard isEligible(pill: pill, sessionId: sessionId, hostBundleId: who.hostBundleId),
              let link = link(target: target, sessionId: sessionId) else { return nil }
        switch target {
        case .vscode:
            // Ссылку VS Code отдаёт окну в фокусе: сначала папка проекта, потом ссылка.
            guard let folder = folder(of: who) else { return nil }
            return AgentHandoffPlan(target: target, sessionId: sessionId,
                                    steps: [.openFolder(folder), .openURL(link)])
        case .claudeDesktop:
            return AgentHandoffPlan(target: target, sessionId: sessionId, steps: [.openURL(link)])
        }
    }

    /// Ссылка цели на сессию:
    /// - VS Code — `vscode://anthropic.claude-code/open?session=<uuid>` (та же, что строит
    ///   «Перейти к агенту»);
    /// - Claude Desktop — `claude://resume?session=<uuid>`, ей пользуется сам
    ///   `claude --desktop --resume` (решение В4).
    static func link(target: AgentHandoffTarget, sessionId: String) -> URL? {
        guard AgentJumpPlan.isUUID(sessionId) else { return nil }
        switch target {
        case .vscode:
            guard let editor = AgentEditors.editor(bundleId: target.bundleId),
                  allowedSchemes.contains(editor.scheme) else { return nil }
            return AgentJumpPlan.sessionLink(editor: editor, pill: "integration_claude", sessionId: sessionId)
        case .claudeDesktop:
            var parts = URLComponents()
            parts.scheme = "claude"
            parts.host = "resume"
            parts.queryItems = [URLQueryItem(name: "session", value: sessionId)]
            guard let url = parts.url, url.scheme.map(allowedSchemes.contains) == true else { return nil }
            return url
        }
    }

    // MARK: Команда для терминала (решение В2 = b)

    /// `cd '<папка>' && claude --resume <uuid>` — человек вставляет её в терминал сам. Luna ничего
    /// не печатает в чужие окна и `claude` не запускает. nil, если папка или id не годятся.
    static func terminalCommand(who: AgentSessionWho, sessionId: String) -> String? {
        guard AgentJumpPlan.isUUID(sessionId), let folder = folder(of: who) else { return nil }
        return "cd \(shellQuote(folder)) && claude --resume \(sessionId)"
    }

    /// Путь в одинарных кавычках для sh: внутри них ничего не раскрывается (`$`, `` ` ``, `;`,
    /// пробел), а сама кавычка записывается как `'\''`.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

// MARK: - Меню «Открыть в…»

enum AgentHandoffMenu {

    struct Item: Equatable, Sendable {
        enum Action: Equatable, Sendable {
            case open(AgentHandoffTarget)
            case copyCommand
        }
        let action: Action
        /// Почему пункт неактивен; nil — активен.
        let blocked: AgentHandoffBlocked?

        var isEnabled: Bool { blocked == nil }
    }

    /// Пункты меню для сессии; пусто — кнопки «Открыть в…» нет.
    /// - VS Code и Claude Desktop — только установленные и только не то приложение, где сессия
    ///   идёт (туда ведёт «Перейти к агенту»). Пока агент работает или ждёт ответа — неактивны.
    ///   VS Code без расширения или без папки проекта — неактивен.
    /// - «Скопировать команду для терминала» — всегда; без папки неактивен. Скопировать команду
    ///   ничему не мешает, поэтому ход агента его не блокирует.
    /// `folderExists` — есть ли на диске `AgentHandoffPlan.folder(of:)`.
    static func items(pill: String, sessionId: String, who: AgentSessionWho, phase: AgentPhase,
                      waiting: Bool, apps: AgentLaunchApps, folderExists: Bool) -> [Item] {
        guard AgentHandoffPlan.isEligible(pill: pill, sessionId: sessionId, hostBundleId: who.hostBundleId) else {
            return []
        }
        let folderBlocked: AgentHandoffBlocked? =
            (AgentHandoffPlan.folder(of: who) != nil && folderExists) ? nil : .folderMissing
        let busy: AgentHandoffBlocked? = waiting ? .agentWaiting : (phase == .working ? .agentWorking : nil)
        var items: [Item] = []
        for target in AgentHandoffTarget.order where target.bundleId != who.hostBundleId {
            switch target {
            case .vscode:
                guard apps.vscode else { continue }
                let noExtension: AgentHandoffBlocked? = apps.vscodeExtension ? nil : .noVSCodeExtension
                items.append(Item(action: .open(target), blocked: busy ?? noExtension ?? folderBlocked))
            case .claudeDesktop:
                guard apps.claudeDesktop else { continue }
                // Папку Claude Desktop из Luna не получает: только ссылку на сессию.
                items.append(Item(action: .open(target), blocked: busy))
            }
        }
        items.append(Item(action: .copyCommand, blocked: folderBlocked))
        return items
    }
}

// MARK: - Ожидающий перенос

/// Перенос, который ждёт `SessionEnd` своей сессии. Только в памяти: на диск, в UserDefaults и
/// Keychain не пишется, выход из Luna его снимает.
struct AgentHandoffPending: Equatable, Sendable {
    /// `AgentSessionKey.id` сессии.
    let sessionKey: String
    let plan: AgentHandoffPlan
    /// Где сессия идёт сейчас — для строки «Закройте сессию в …».
    let hostBundleId: String
    let deadline: Date
}

/// Почему перенос снят без открытия.
enum AgentHandoffCancel: Equatable, Sendable {
    /// «Отменить» на странице.
    case byUser
    /// Сессия начала новый ход: человек продолжил там, где она идёт.
    case resumed
    /// За `AgentHandoffBook.waitLimit` сессия не закрылась.
    case timedOut
}

/// Что сделать после события.
enum AgentHandoffStep: Equatable, Sendable {
    case none
    /// Сессия закрылась — открыть её по плану.
    case open(AgentHandoffPlan, sessionKey: String)
    case cancelled(AgentHandoffCancel, sessionKey: String)
}

/// Автомат переноса: ждёт один перенос; новый клик заменяет прежний. Реагирует только на события
/// хуков — сессия, пропавшая из списка по тишине (`AgentSessionBook.prune`), без `SessionEnd`
/// перенос не исполняет: он истекает по сроку.
struct AgentHandoffBook: Equatable, Sendable {

    /// Сколько ждать закрытия сессии.
    static let waitLimit: TimeInterval = 5 * 60

    private(set) var pending: AgentHandoffPending? = nil

    /// Клик по цели: перенос ждёт закрытия сессии. Прежний перенос, если был, заменяется.
    @discardableResult
    mutating func request(_ plan: AgentHandoffPlan, sessionKey: String, hostBundleId: String,
                          now: Date) -> AgentHandoffPending {
        let next = AgentHandoffPending(sessionKey: sessionKey, plan: plan, hostBundleId: hostBundleId,
                                       deadline: now.addingTimeInterval(Self.waitLimit))
        pending = next
        return next
    }

    /// Событие хука `name` сессии `sessionKey`.
    mutating func event(_ name: String, sessionKey: String, now: Date) -> AgentHandoffStep {
        guard let current = pending, current.sessionKey == sessionKey else { return .none }
        if now >= current.deadline {
            pending = nil
            return .cancelled(.timedOut, sessionKey: sessionKey)
        }
        switch AgentTransition.of(event: name) {
        case .end:
            pending = nil
            return .open(current.plan, sessionKey: sessionKey)
        case .working:
            // UserPromptSubmit, PreToolUse…: сессия продолжила работу там, где идёт.
            pending = nil
            return .cancelled(.resumed, sessionKey: sessionKey)
        case .idle, .finished, .error, .none:
            return .none
        }
    }

    /// Срок вышел (одна отложенная задача на перенос, без опроса).
    mutating func expire(now: Date) -> AgentHandoffStep {
        guard let current = pending, now >= current.deadline else { return .none }
        pending = nil
        return .cancelled(.timedOut, sessionKey: current.sessionKey)
    }

    /// «Отменить».
    mutating func cancel() -> AgentHandoffStep {
        guard let current = pending else { return .none }
        pending = nil
        return .cancelled(.byUser, sessionKey: current.sessionKey)
    }
}

// MARK: - Что видно на странице агента

/// Строка переноса на странице агента — для сессии `sessionKey`.
enum AgentHandoffStatus: Equatable, Sendable {
    /// Ждём закрытия сессии; на странице «Отменить».
    case waiting(AgentHandoffPending)
    /// Сессия закрылась, Luna открывает её в цели.
    case opening(AgentHandoffTarget, sessionKey: String)
    case cancelled(AgentHandoffCancel, sessionKey: String)
    /// Сессия закрылась, а приложения цели уже нет.
    case appMissing(AgentHandoffTarget, sessionKey: String)
    /// Сессия закрылась, а папки проекта для VS Code уже нет.
    case folderMissing(sessionKey: String)
    /// Команда для терминала в буфере обмена.
    case copied(sessionKey: String)

    var sessionKey: String {
        switch self {
        case .waiting(let pending):                  return pending.sessionKey
        case .opening(_, let key), .cancelled(_, let key), .appMissing(_, let key): return key
        case .folderMissing(let key), .copied(let key): return key
        }
    }

    var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }
}
#endif
