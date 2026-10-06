import Foundation

/// Что сессии агентов значат для pill.
struct AgentsSummary: Equatable {
    /// Ждут ответа или разрешения человека.
    var waiting: [AgentSession] = []
    var working: [AgentSession] = []
    /// Закончили ход, пока пользователь на них не смотрел.
    var finished: [AgentSession] = []

    init(sessions: [AgentSession], finished unseen: Set<String>) {
        for session in sessions {
            switch session.state {
            case .waiting: waiting.append(session)
            case .working: working.append(session)
            case .idle: if unseen.contains(session.id) { finished.append(session) }
            }
        }
    }

    /// Сессии, которым есть место в pill: сначала те, что ждут человека.
    var visible: [AgentSession] { waiting + finished + working }

    /// Плитки блока под курсором. Пока сессии помещаются, порядок как у ядра — плитки не скачут
    /// под курсором. Не помещаются — вперёд выходят те, кто зовёт человека, а на последнем месте
    /// стоит счётчик остальных (`hidden`).
    static func peek(_ sessions: [AgentSession], finished unseen: Set<String>, limit: Int) -> (shown: [AgentSession], hidden: Int) {
        guard sessions.count > limit else { return (sessions, 0) }
        func rank(_ session: AgentSession) -> Int {
            switch session.state {
            case .waiting: 0
            case .working: 2
            case .idle: unseen.contains(session.id) ? 1 : 3
            }
        }
        let ordered = sessions.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
        return (ordered.prefix(limit - 1).map(\.element), sessions.count - (limit - 1))
    }
}

extension AgentSession {
    /// Строка состояния: что агент делает или чего ждёт.
    var statusLine: String {
        switch state {
        case .working: activity ?? "работает…"
        case .waiting: waitingFor.map { "ждёт вас: \(Self.waitingReason($0))" } ?? "ждёт вас"
        case .idle: "ход завершён"
        }
    }

    var displayTitle: String { title ?? "Без названия" }

    /// Имя агента для подписей.
    var agentName: String {
        switch agent {
        case "claude-code": "Claude Code"
        default: agent
        }
    }

    /// Модель сессии для карточки и окна: короткое имя («Opus 5.5»), незнакомое — как есть; нет модели — nil.
    var modelTitle: String? {
        guard let model, !model.isEmpty else { return nil }
        return ModelName.short(model)
    }

    /// Подпись плитки — пара слов вместо фразы: над чем агент работает или чего ждёт.
    /// У свободной сессии плитка показывает время, а не подпись.
    var tileCaption: String {
        switch state {
        case .working:
            guard let last = trail?.last else { return activity ?? "работает" }
            switch last.kind {
            case .tool: return last.target ?? last.text
            case .text: return "пишет ответ"
            case .prompt: return "думает"
            }
        case .waiting: return waitingFor.map(Self.waitingReason) ?? "ждёт вас"
        case .idle: return "ход завершён"
        }
    }

    /// Причины ожидания Claude Code — по-русски; незнакомая показывается как есть.
    private static func waitingReason(_ raw: String) -> String {
        switch raw {
        case "input needed": "нужен ответ"
        case "dialog open": "открыт диалог"
        case "sandbox request", "worker request": "нужно разрешение"
        default: raw
        }
    }
}

extension AgentStep {
    /// Шаг без рода инструмента и цели: запрос человека или текст агента.
    init(at: Int, kind: AgentStepKind, text: String) {
        self.init(at: at, kind: kind, target: nil, text: text, tool: nil)
    }

    /// Значок шага в ленте и в превью работы; незнакомый род инструмента — общий значок.
    var symbol: String {
        switch kind {
        case .prompt: return "person.fill"
        case .text: return "text.bubble"
        case .tool:
            switch tool {
            case "read": return "doc.text"
            case "edit": return "pencil"
            case "write": return "square.and.pencil"
            case "shell": return "terminal"
            case "search": return "magnifyingglass"
            case "web": return "globe"
            case "agent": return "person.2"
            case "plan": return "checklist"
            case "ask": return "questionmark.bubble"
            case "skill": return "wand.and.stars"
            case "mcp": return "puzzlepiece.extension"
            default: return "wrench.and.screwdriver"
            }
        }
    }

    /// Шаги с устойчивыми id для анимации ленты: у одинаковых шагов id различаются номером повтора.
    static func identified(_ steps: [AgentStep]) -> [(id: String, step: AgentStep)] {
        var seen: [String: Int] = [:]
        return steps.map { step in
            let key = "\(step.at)|\(step.kind.rawValue)|\(step.text)"
            let repeatIndex = seen[key, default: 0]
            seen[key] = repeatIndex + 1
            return ("\(key)#\(repeatIndex)", step)
        }
    }
}

extension AgentHost {
    /// Подпись кнопки перехода к окну сессии.
    var jumpTitle: String {
        if let name { return "Открыть в \(name)" }
        return kind == .terminal ? "Открыть терминал" : "Показать папку"
    }
}

/// Стабильный между запусками хэш: по нему выбираются цвет и рисунок аватара.
/// `hashValue` для этого не годится — он меняется с каждым запуском приложения.
func stableHash(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}
