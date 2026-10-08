import Combine
import Foundation

/// Уровни разрешений, которые исполнители объявили в `core.hello` (`ExecutorStatus.permissionLevels`).
/// Набор статичен и приходит, даже когда CLI не установлен. Настройки показывают только объявленное.
@MainActor
final class ExecutorPermissions: ObservableObject {
    /// Уровни по id исполнителя; nil — ядро ещё не ответило на `core.hello` (или остановилось).
    @Published private(set) var declared: [String: [PermissionLevel]]?

    func apply(_ hello: HelloResult) {
        declared = Dictionary(hello.executors.map { ($0.id.rawValue, $0.permissionLevels ?? []) }, uniquingKeysWith: { first, _ in first })
    }

    func reset() {
        declared = nil
    }

    /// Объявленные уровни исполнителя в порядке ядра; nil — ядро ещё не ответило.
    func levels(for executor: String) -> [PermissionLevel]? {
        declared.map { $0[executor] ?? [] }
    }
}

extension PermissionLevel {
    /// Уровень, с которым уходит `task.submit`: сохранённый, если исполнитель его объявил, иначе `manual` —
    /// вниз, а не вверх. Пока ядро не ответило на `core.hello`, тоже `manual`.
    static func request(saved: PermissionLevel, declared: [PermissionLevel]?) -> PermissionLevel {
        declared?.contains(saved) == true ? saved : .manual
    }

    /// Что показывает раздел «Разрешения»: объявленные исполнителем уровни, и выбор активен. Пока ядро не
    /// ответило — только сохранённый уровень, выбор неактивен.
    static func choices(declared: [PermissionLevel]?, saved: PermissionLevel) -> (levels: [PermissionLevel], enabled: Bool) {
        guard let declared else { return ([saved], false) }
        return (declared, true)
    }

    /// Подпись в настройках.
    var title: String {
        switch self {
        case .manual: "Спрашивать"
        case .editAutomatically: "Править файлы без вопросов"
        }
    }

    /// Одна строка пояснения под выбором.
    var explanation: String {
        switch self {
        case .manual: "Claude Code спрашивает перед записью файлов и командами; чтение — без вопросов."
        case .editAutomatically: "Файлы в домашней папке правятся без вопросов; команды и служебные файлы (.git, .zshrc) — с вопросом."
        }
    }
}
