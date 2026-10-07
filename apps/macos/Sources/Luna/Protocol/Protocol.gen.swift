// СГЕНЕРИРОВАНО из protocol/schema/protocol.schema.json — не редактировать.
// Обновить: npm run generate

import Foundation

// MARK: - HelloResult
struct HelloResult: Codable, Equatable, Sendable {
    let executors: [ExecutorStatus]
    let version: String
}

// MARK: - ExecutorStatus
struct ExecutorStatus: Codable, Equatable, Sendable {
    let available: Bool
    let id: ExecutorId
    let path: String?
}

enum ExecutorId: String, Codable, Equatable, Sendable {
    case claudeCode = "claude-code"
}

// MARK: - TaskSubmitParams
struct TaskSubmitParams: Codable, Equatable, Sendable {
    let context: TaskContext?
    let executor: ExecutorId?
    /// id задачи диалога, которую продолжает уточнение; вместе с ним context и executor не
    /// передаются, model — можно (модель уточнения)
    let followUpOf: String?
    /// модель для этой задачи; строка непрозрачна для протокола, её смысл знает исполнитель (для
    /// Claude Code — алиас opus/sonnet/haiku или полный идентификатор); не передана — модель по
    /// умолчанию исполнителя; с followUpOf — модель этого уточнения; без неё уточнение
    /// продолжается на модели продолжаемой задачи
    let model: String?
    let prompt: String
}

// MARK: - TaskContext
struct TaskContext: Codable, Equatable, Sendable {
    let app: AppInfo?
    let selection, title, url: String?
}

// MARK: - AppInfo
struct AppInfo: Codable, Equatable, Sendable {
    let bundleId, name: String
}

// MARK: - TaskSubmitResult
struct TaskSubmitResult: Codable, Equatable, Sendable {
    let task: TaskInfo
}

// MARK: - TaskInfo
struct TaskInfo: Codable, Equatable, Sendable {
    /// действие, которого исполнитель ждёт от человека; есть только у задачи running, пока ответ
    /// не дан
    let approval: ApprovalRequest?
    let context: TaskContext?
    /// Unix time, ms
    let createdAt: Int
    let error: TaskError?
    let executor: ExecutorId
    /// Unix time, ms
    let finishedAt: Int?
    let id: String
    /// модель, на которой выполняется задача: как выбрана при отправке, а когда исполнитель
    /// сообщил точную — она (алиас sonnet → claude-sonnet-4-6); нет — модель по умолчанию
    /// исполнителя ещё не известна
    let model: String?
    let progress: String?
    let prompt: String
    let result, sessionId: String?
    let status: TaskStatus
    /// id первой задачи диалога; у задачи без уточнений равен id
    let threadId: String
}

/// Действие исполнителя, которое ждёт ответа человека. Все строки — чистый текст: оболочка
/// показывает их как есть, не Markdown и не ссылками
///
/// действие, которого исполнитель ждёт от человека; есть только у задачи running, пока ответ
/// не дан
// MARK: - ApprovalRequest
struct ApprovalRequest: Codable, Equatable, Sendable {
    /// Unix time, ms
    let createdAt: Int
    /// подробности многострочным текстом: начало содержимого, заменяемый и новый фрагмент;
    /// длинное обрезано с пометкой
    let detail: String?
    /// id запроса; ответ task.approve должен назвать именно его
    let id: String
    let kind: ApprovalKind
    /// одна строка о действии: «Записать файл»
    let summary: String
    /// над чем действие: абсолютный путь к файлу
    let target: String?
    /// инструмент исполнителя, как он его называет: «Write»
    let tool: String
}

/// write — запись файла; edit — правка файла или блокнота; shell — команда; other — другой
/// инструмент
enum ApprovalKind: String, Codable, Equatable, Sendable {
    case edit = "edit"
    case other = "other"
    case shell = "shell"
    case write = "write"
}

// MARK: - TaskError
struct TaskError: Codable, Equatable, Sendable {
    let kind: TaskErrorKind
    let message: String
}

enum TaskErrorKind: String, Codable, Equatable, Sendable {
    case auth = "auth"
    case notInstalled = "not_installed"
    case rateLimit = "rate_limit"
    case sessionNotFound = "session_not_found"
    case unknown = "unknown"
}

enum TaskStatus: String, Codable, Equatable, Sendable {
    case cancelled = "cancelled"
    case done = "done"
    case failed = "failed"
    case queued = "queued"
    case running = "running"
}

// MARK: - TaskCancelParams
struct TaskCancelParams: Codable, Equatable, Sendable {
    let taskId: String
}

// MARK: - TaskApproveParams
struct TaskApproveParams: Codable, Equatable, Sendable {
    /// true — разрешить действие, false — отклонить
    let allow: Bool
    /// id запроса из TaskInfo.approval; устаревший — InvalidParams
    let approvalId: String
    let taskId: String
}

// MARK: - TaskListParams
struct TaskListParams: Codable, Equatable, Sendable {
    /// подстрока запроса или ответа задачи без учёта регистра; пустая — обычный список
    let query: String?
}

// MARK: - TaskListResult
struct TaskListResult: Codable, Equatable, Sendable {
    let tasks: [TaskInfo]
}

// MARK: - TaskDeleteParams
struct TaskDeleteParams: Codable, Equatable, Sendable {
    /// любая задача диалога: удаляется весь диалог
    let taskId: String
}

// MARK: - TaskDeleteResult
struct TaskDeleteResult: Codable, Equatable, Sendable {
    /// id удалённых задач
    let deleted: [String]
}

// MARK: - TaskClearResult
struct TaskClearResult: Codable, Equatable, Sendable {
    /// id задач удалённых диалогов: всех, где нет задачи queued или running
    let deleted: [String]
}

// MARK: - TaskEventParams
struct TaskEventParams: Codable, Equatable, Sendable {
    let task: TaskInfo
}

// MARK: - AgentListResult
struct AgentListResult: Codable, Equatable, Sendable {
    let sessions: [AgentSession]
}

// MARK: - AgentSession
struct AgentSession: Codable, Equatable, Sendable {
    /// что агент делает сейчас: «читает main.ts»
    let activity: String?
    /// чей это агент: «claude-code». Строка, а не перечисление: оболочка показывает и незнакомых
    /// агентов
    let agent: String
    let cwd: String
    let host: AgentHost
    /// id сессии агента
    let id: String
    /// модель последнего ответа агента в журнале сессии, как её записал агент
    /// («claude-opus-5-5»); нет, пока агент не отвечал или журнал не прочитан
    let model: String?
    /// ссылка, по которой приложение-хозяин открывает именно эту сессию; есть не у всех хозяев
    let openUrl: String?
    let pid: Int
    /// имя проекта: последняя часть cwd
    let project: String
    /// Unix time, ms
    let startedAt: Int
    let state: AgentState
    /// о чём сессия: заголовок от агента, а пока его нет — последний запрос человека
    let title: String?
    /// несколько последних шагов сессии, старые первыми: по ним оболочка рисует превью работы,
    /// не запрашивая ленту
    let trail: [AgentStep]?
    /// Unix time, ms: последняя смена состояния или запись в журнале сессии
    let updatedAt: Int
    /// чего ждёт агент в состоянии waiting, словами агента
    let waitingFor: String?
}

// MARK: - AgentHost
struct AgentHost: Codable, Equatable, Sendable {
    /// путь к бандлу приложения-хозяина, если его удалось найти
    let appPath: String?
    let kind: AgentHostKind
    /// имя приложения: «Visual Studio Code», «iTerm2»
    let name: String?
    /// терминал сессии, например /dev/ttys003
    let tty: String?
    /// папка, открытая в окне редактора-хозяина; рабочая директория сессии бывает глубже неё
    let workspace: String?
}

/// ide — редактор с расширением агента; terminal — окно терминала; unknown — хозяин процесса
/// не определён
enum AgentHostKind: String, Codable, Equatable, Sendable {
    case ide = "ide"
    case terminal = "terminal"
    case unknown = "unknown"
}

/// working — агент занят; waiting — ждёт ответа или разрешения человека; idle — ход завершён
enum AgentState: String, Codable, Equatable, Sendable {
    case idle = "idle"
    case waiting = "waiting"
    case working = "working"
}

// MARK: - AgentStep
struct AgentStep: Codable, Equatable, Sendable {
    /// Unix time, ms
    let at: Int
    let kind: AgentStepKind
    /// у шага tool — над чем работает инструмент, коротко: имя файла, подпись команды, запрос
    let target: String?
    let text: String
    /// у шага tool — род инструмента: read, edit, write, shell, search, web, agent, plan, ask,
    /// skill, mcp, other. Строка, а не перечисление: незнакомый род оболочка показывает общим
    /// значком
    let tool: String?
}

/// prompt — запрос человека; tool — вызов инструмента; text — текст агента
enum AgentStepKind: String, Codable, Equatable, Sendable {
    case prompt = "prompt"
    case text = "text"
    case tool = "tool"
}

// MARK: - AgentStepsParams
struct AgentStepsParams: Codable, Equatable, Sendable {
    /// true — подробная лента для окна сессии: больше шагов, текст длиннее и с переносами строк
    let detail: Bool?
    let sessionId: String
}

// MARK: - AgentStepsResult
struct AgentStepsResult: Codable, Equatable, Sendable {
    /// последние шаги сессии, старые первыми
    let steps: [AgentStep]
}

// MARK: - AgentsEventParams
struct AgentsEventParams: Codable, Equatable, Sendable {
    /// полный список живых сессий
    let sessions: [AgentSession]
}
