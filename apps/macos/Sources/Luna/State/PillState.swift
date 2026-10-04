import Foundation

/// Агрегированное состояние pill по всем задачам.
enum PillState: Equatable {
    case idle
    case running(Int)
    case done(Int)
    case error(Int)

    /// Приоритет отображения: error > done > running. Завершённые задачи учитываются,
    /// пока пользователь не открыл их результат (`unseen`).
    static func aggregate(tasks: [TaskInfo], unseen: Set<String>, hasProblem: Bool) -> PillState {
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

    /// Сколько секунд заняла завершённая задача.
    var durationSeconds: Int? {
        finishedAt.map { max(1, ($0 - createdAt + 500) / 1000) }
    }
}
