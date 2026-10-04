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
    let context: TaskContext?
    /// Unix time, ms
    let createdAt: Int
    let error: TaskError?
    let executor: ExecutorId
    /// Unix time, ms
    let finishedAt: Int?
    let id: String
    let progress: String?
    let prompt: String
    let result, sessionId: String?
    let status: TaskStatus
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

// MARK: - TaskListResult
struct TaskListResult: Codable, Equatable, Sendable {
    let tasks: [TaskInfo]
}

// MARK: - TaskEventParams
struct TaskEventParams: Codable, Equatable, Sendable {
    let task: TaskInfo
}
