import Foundation

/// Сведение списка задач оболочки с историей из ответа `task.list`.
enum TaskHistory {
    /// Задачи из истории добавляются к уже известным; задача, пришедшая событием, не
    /// перезаписывается снимком из истории — событие свежее. Итог — в порядке создания.
    static func merge(current: [TaskInfo], listed: [TaskInfo]) -> [TaskInfo] {
        let known = Set(current.map(\.id))
        // task.list отдаёт новые первыми; разворот сохраняет порядок создания при равном времени.
        let added = listed.reversed().filter { !known.contains($0.id) }
        return (added + current).sorted { $0.createdAt < $1.createdAt }
    }
}
