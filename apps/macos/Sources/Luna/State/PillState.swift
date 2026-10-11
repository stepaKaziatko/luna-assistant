import Foundation

/// Агрегированное состояние pill по всем задачам.
enum PillState: Equatable {
    case idle
    case running(Int)
    case done(Int)
    case error(Int)
    /// Ждут ответа человека: задачи Luna с `approval` и сессии агентов с запросом подтверждения.
    case needsApproval(Int)

    /// Приоритет отображения: needsApproval > error > done > running. Завершённые задачи учитываются,
    /// пока пользователь не открыл их результат (`unseen`); ожидание ответа — пока исполнитель стоит.
    /// `agentApprovals` — сколько сессий агентов ждут ответа через хук; ждущая сессия без запроса сюда не входит:
    /// она остаётся в счётчике «ждут вас» (`StatusChip.Kind.attention`).
    static func aggregate(tasks: [TaskInfo], unseen: Set<String>, hasProblem: Bool, agentApprovals: Int = 0) -> PillState {
        let waiting = tasks.count { $0.isAwaitingApproval } + agentApprovals
        if waiting > 0 { return .needsApproval(waiting) }

        let failed = tasks.count { $0.status == .failed && unseen.contains($0.id) }
        if failed > 0 || hasProblem { return .error(max(failed, 1)) }

        let done = tasks.count { $0.status == .done && unseen.contains($0.id) }
        if done > 0 { return .done(done) }

        let active = tasks.count { $0.isActive }
        return active > 0 ? .running(active) : .idle
    }
}

extension TaskInfo {
    var isActive: Bool { status == .queued || status == .running }

    /// Исполнитель остановился перед действием и ждёт «Разрешить» или «Отклонить».
    var isAwaitingApproval: Bool { status == .running && approval != nil }

    /// Сколько секунд заняла завершённая задача.
    var durationSeconds: Int? {
        finishedAt.map { max(1, ($0 - createdAt + 500) / 1000) }
    }
}

/// Настроение аватара: от него зависят глаза, движение и значок.
enum AvatarMood: Equatable {
    case sleeping
    /// Слушает человека: следит за курсором, моргает.
    case listening
    case working
    /// Зовёт человека: подпрыгивает и смотрит на курсор.
    case waiting
    case happy
    case error
}

extension AgentSession {
    func mood(finished: Bool) -> AvatarMood {
        // Запрос подтверждения зовёт человека, даже пока реестр агента ещё не показал `waiting`.
        if approval != nil { return .waiting }
        switch state {
        case .working: return .working
        case .waiting: return .waiting
        case .idle: return finished ? .happy : .sleeping
        }
    }
}

/// Счётчик шторки: значок и число вместо фразы.
struct StatusChip: Equatable, Identifiable {
    enum Kind: String {
        /// Ждут «Разрешить» или «Отклонить»: задачи Luna и сессии агентов с запросом подтверждения.
        /// Число совпадает с `PillState.needsApproval`.
        case approval
        /// Задачи Luna с ошибкой или неполадка ядра.
        case failure
        /// Сессии агентов, которые ждут человека без запроса подтверждения.
        case attention
        /// Готовые ответы Luna и сессии, закончившие ход, — то, что ещё не смотрели.
        case success
        /// Задачи и сессии в работе.
        case working
    }

    let kind: Kind
    let count: Int

    var id: Kind { kind }

    /// В порядке важности (как у `PillState.aggregate`): подтверждение, ошибка, ждут вас, готово, в работе;
    /// нулевые счётчики не показываются.
    static func make(tasks: [TaskInfo], unseen: Set<String>, hasProblem: Bool, agents: AgentsSummary) -> [StatusChip] {
        let failed = tasks.count { $0.status == .failed && unseen.contains($0.id) }
        let done = tasks.count { $0.status == .done && unseen.contains($0.id) }
        let active = tasks.count { $0.isActive }
        let approvals = tasks.count { $0.isAwaitingApproval } + agents.waiting.count { $0.approval != nil }
        // Сессия с запросом лежит в `agents.waiting` тоже: во второй раз её считать не нужно.
        let calling = agents.waiting.count { $0.approval == nil }
        return [
            StatusChip(kind: .approval, count: approvals),
            StatusChip(kind: .failure, count: max(failed, hasProblem ? 1 : 0)),
            StatusChip(kind: .attention, count: calling),
            StatusChip(kind: .success, count: done + agents.finished.count),
            StatusChip(kind: .working, count: active + agents.working.count),
        ].filter { $0.count > 0 }
    }
}

/// Что показывает развёрнутый pill: настроение Luna, строка и сессии, которым нужны аватары.
struct PillPresentation: Equatable {
    enum Tone: Equatable {
        case neutral
        case attention
        case success
        case failure
    }

    let mood: AvatarMood
    /// Фраза о главном событии: подпись для VoiceOver, а на экране — только если включена в настройках.
    let text: String
    let tone: Tone
    /// Сессии агентов для мини-аватаров: сначала те, что зовут человека.
    let sessions: [AgentSession]

    /// Сколько мини-аватаров помещается в pill; остальные — числом.
    static let avatarLimit = 4

    /// nil — показывать нечего: pill сворачивается в полоску.
    /// Порядок: задача ждёт подтверждения > ошибка задачи > агент ждёт человека > готовый ответ > агент закончил ход > работа.
    static func make(tasks: PillState, taskProgress: String?, agents: AgentsSummary) -> PillPresentation? {
        let sessions = agents.visible
        func present(_ mood: AvatarMood, _ text: String, _ tone: Tone) -> PillPresentation {
            PillPresentation(mood: mood, text: text, tone: tone, sessions: sessions)
        }

        if case .needsApproval(let count) = tasks {
            return present(.waiting, count == 1 ? "Нужно подтверждение" : "Нужно подтверждений: \(count)", .attention)
        }
        if case .error = tasks { return present(.error, "Ошибка", .failure) }
        if let first = agents.waiting.first {
            return present(.waiting, agents.waiting.count == 1 ? "\(first.project) ждёт вас" : "Ждут вас: \(agents.waiting.count)", .attention)
        }
        if case .done(let count) = tasks { return present(.happy, count == 1 ? "Готово" : "Готово: \(count)", .success) }
        if let first = agents.finished.first {
            return present(.happy, agents.finished.count == 1 ? "\(first.project): ход завершён" : "Завершили ход: \(agents.finished.count)", .success)
        }
        if case .running(let count) = tasks {
            return present(.working, count == 1 ? (taskProgress ?? "Думаю…") : "Задач в работе: \(count)", .neutral)
        }
        // Из нескольких работающих показываем того, кто отчитался последним.
        if let latest = agents.working.max(by: { $0.updatedAt < $1.updatedAt }) {
            return present(.working, "\(latest.project) · \(latest.statusLine)", .neutral)
        }
        return nil
    }
}
