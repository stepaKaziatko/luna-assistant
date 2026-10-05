// СГЕНЕРИРОВАНО из protocol/schema/protocol.schema.json — не редактировать.
// Обновить: npm run generate

export interface HelloResult {
    executors: ExecutorStatus[];
    version:   string;
}

export interface ExecutorStatus {
    available: boolean;
    id:        ExecutorId;
    path?:     string;
}

export type ExecutorId = "claude-code";

export interface TaskSubmitParams {
    context?:  TaskContext;
    executor?: ExecutorId;
    /**
     * id задачи диалога, которую продолжает уточнение; вместе с ним context и executor не
     * передаются
     */
    followUpOf?: string;
    prompt:      string;
}

export interface TaskContext {
    app?:       AppInfo;
    selection?: string;
    title?:     string;
    url?:       string;
}

export interface AppInfo {
    bundleId: string;
    name:     string;
}

export interface TaskSubmitResult {
    task: TaskInfo;
}

export interface TaskInfo {
    context?: TaskContext;
    /**
     * Unix time, ms
     */
    createdAt: number;
    error?:    TaskError;
    executor:  ExecutorId;
    /**
     * Unix time, ms
     */
    finishedAt?: number;
    id:          string;
    progress?:   string;
    prompt:      string;
    result?:     string;
    sessionId?:  string;
    status:      TaskStatus;
    /**
     * id первой задачи диалога; у задачи без уточнений равен id
     */
    threadId: string;
}

export interface TaskError {
    kind:    TaskErrorKind;
    message: string;
}

export type TaskErrorKind = "auth" | "rate_limit" | "not_installed" | "session_not_found" | "unknown";

export type TaskStatus = "queued" | "running" | "done" | "failed" | "cancelled";

export interface TaskCancelParams {
    taskId: string;
}

export interface TaskListParams {
    /**
     * подстрока запроса или ответа задачи без учёта регистра; пустая — обычный список
     */
    query?: string;
}

export interface TaskListResult {
    tasks: TaskInfo[];
}

export interface TaskDeleteParams {
    /**
     * любая задача диалога: удаляется весь диалог
     */
    taskId: string;
}

export interface TaskDeleteResult {
    /**
     * id удалённых задач
     */
    deleted: string[];
}

export interface TaskClearResult {
    /**
     * id задач удалённых диалогов: всех, где нет задачи queued или running
     */
    deleted: string[];
}

export interface TaskEventParams {
    task: TaskInfo;
}
