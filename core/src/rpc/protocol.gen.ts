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

export interface AgentListResult {
    sessions: AgentSession[];
}

export interface AgentSession {
    /**
     * что агент делает сейчас: «читает main.ts»
     */
    activity?: string;
    /**
     * чей это агент: «claude-code». Строка, а не перечисление: оболочка показывает и незнакомых
     * агентов
     */
    agent: string;
    cwd:   string;
    host:  AgentHost;
    /**
     * id сессии агента
     */
    id: string;
    /**
     * ссылка, по которой приложение-хозяин открывает именно эту сессию; есть не у всех хозяев
     */
    openUrl?: string;
    pid:      number;
    /**
     * имя проекта: последняя часть cwd
     */
    project: string;
    /**
     * Unix time, ms
     */
    startedAt: number;
    state:     AgentState;
    /**
     * о чём сессия: заголовок от агента, а пока его нет — последний запрос человека
     */
    title?: string;
    /**
     * несколько последних шагов сессии, старые первыми: по ним оболочка рисует превью работы,
     * не запрашивая ленту
     */
    trail?: AgentStep[];
    /**
     * Unix time, ms: последняя смена состояния или запись в журнале сессии
     */
    updatedAt: number;
    /**
     * чего ждёт агент в состоянии waiting, словами агента
     */
    waitingFor?: string;
}

export interface AgentHost {
    /**
     * путь к бандлу приложения-хозяина, если его удалось найти
     */
    appPath?: string;
    kind:     AgentHostKind;
    /**
     * имя приложения: «Visual Studio Code», «iTerm2»
     */
    name?: string;
    /**
     * терминал сессии, например /dev/ttys003
     */
    tty?: string;
    /**
     * папка, открытая в окне редактора-хозяина; рабочая директория сессии бывает глубже неё
     */
    workspace?: string;
}

/**
 * ide — редактор с расширением агента; terminal — окно терминала; unknown — хозяин процесса
 * не определён
 */
export type AgentHostKind = "ide" | "terminal" | "unknown";

/**
 * working — агент занят; waiting — ждёт ответа или разрешения человека; idle — ход завершён
 */
export type AgentState = "working" | "waiting" | "idle";

export interface AgentStep {
    /**
     * Unix time, ms
     */
    at:   number;
    kind: AgentStepKind;
    /**
     * у шага tool — над чем работает инструмент, коротко: имя файла, подпись команды, запрос
     */
    target?: string;
    text:    string;
    /**
     * у шага tool — род инструмента: read, edit, write, shell, search, web, agent, plan, ask,
     * skill, mcp, other. Строка, а не перечисление: незнакомый род оболочка показывает общим
     * значком
     */
    tool?: string;
}

/**
 * prompt — запрос человека; tool — вызов инструмента; text — текст агента
 */
export type AgentStepKind = "prompt" | "tool" | "text";

export interface AgentStepsParams {
    /**
     * true — подробная лента для окна сессии: больше шагов, текст длиннее и с переносами строк
     */
    detail?:   boolean;
    sessionId: string;
}

export interface AgentStepsResult {
    /**
     * последние шаги сессии, старые первыми
     */
    steps: AgentStep[];
}

export interface AgentsEventParams {
    /**
     * полный список живых сессий
     */
    sessions: AgentSession[];
}
