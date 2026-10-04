import Foundation

/// Диалог — задачи с общим `threadId`: первый запрос и уточнения к нему.
struct Dialog: Equatable, Identifiable {
    let threadId: String
    /// В порядке создания, не пусто. Начала диалога может не быть: история загружается не целиком.
    let tasks: [TaskInfo]

    var id: String { threadId }
    /// Самая ранняя известная задача: от неё заголовок и источник.
    var first: TaskInfo { tasks[0] }
    /// От неё состояние и время диалога.
    var last: TaskInfo { tasks[tasks.count - 1] }
    var title: String { first.prompt }
    var followUpCount: Int { tasks.count - 1 }
    var activeTask: TaskInfo? { tasks.last { $0.isActive } }
    /// Задача, к которой уйдёт уточнение (`followUpOf`); нет — поле продолжения не показывается.
    var continuationPoint: TaskInfo? { Self.continuationPoint(of: tasks) }

    func contains(taskId: String) -> Bool {
        tasks.contains { $0.id == taskId }
    }

    /// Группирует задачи по диалогам: внутри — в порядке создания, сами диалоги — по последней
    /// задаче, новые первыми.
    static func group(_ tasks: [TaskInfo]) -> [Dialog] {
        var order: [String] = []
        var byThread: [String: [TaskInfo]] = [:]
        for task in tasks {
            if byThread[task.threadId] == nil { order.append(task.threadId) }
            byThread[task.threadId, default: []].append(task)
        }
        let dialogs = order.map { threadId in
            // Сортировка устойчива: при равном времени остаётся порядок, в котором задачи пришли.
            Dialog(threadId: threadId, tasks: byThread[threadId, default: []].sorted { $0.createdAt < $1.createdAt })
        }
        return dialogs.enumerated()
            .sorted { lhs, rhs in
                lhs.element.last.createdAt != rhs.element.last.createdAt
                    ? lhs.element.last.createdAt > rhs.element.last.createdAt
                    : lhs.offset > rhs.offset
            }
            .map(\.element)
    }

    /// Те же правила, что у ядра: последняя `done` с `sessionId`; после неё — только `failed`
    /// и `cancelled`, но не потерянная сессия; активных задач в диалоге нет.
    static func continuationPoint(of tasks: [TaskInfo]) -> TaskInfo? {
        guard !tasks.contains(where: \.isActive),
              let index = tasks.lastIndex(where: { $0.status == .done }),
              tasks[index].sessionId != nil,
              !tasks[(index + 1)...].contains(where: { $0.error?.kind == .sessionNotFound })
        else { return nil }
        return tasks[index]
    }
}
