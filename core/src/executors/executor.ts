import type { ApprovalKind, ExecutorId, ExecutorStatus, PermissionLevel, TaskError } from "../rpc/protocol.gen.ts";

/** Что исполнитель собирается сделать и ждёт ответа человека; ничего специфичного для конкретного CLI. */
export interface PauseRequest {
  /** Инструмент исполнителя, как он его называет: «Write». */
  tool: string;
  kind: ApprovalKind;
  /** Одна строка о действии: «Записать файл». */
  summary: string;
  /** Над чем действие: абсолютный путь к файлу; у `shell` — текст команды целиком, без обрезки и правок. */
  target?: string;
  /** Подробности многострочным текстом; длинное уже обрезано с пометкой. */
  detail?: string;
}

/** Нормализованные события исполнителя; ядро превращает их в task.* для shell. */
export type ExecutorEvent =
  | { type: "session"; sessionId: string }
  /** Точная модель, на которой работает исполнитель; приходит, когда он её сообщил. */
  | { type: "model"; model: string }
  | { type: "progress"; text: string }
  /**
   * Исполнитель остановился и ждёт человека. `kind: "approval"` — разрешить или отклонить действие
   * (`respond(true|false)`); вопрос с вариантами ответа появится отдельным видом. Поток продолжается
   * после ответа; до него исполнитель стоит.
   */
  | { type: "pause"; kind: "approval"; request: PauseRequest; respond: (allow: boolean) => void }
  /**
   * Исполнитель получил содержимое из сети (открыл страницу, искал в вебе) — оно недоверенное.
   * Приходит не позже первой паузы, которая за ним следует; с этого момента запись и команды в задаче
   * запрещены (assistant-project.md §3.7). Достаточно одного события на запуск.
   */
  | { type: "web" }
  | { type: "done"; result: string }
  | { type: "failed"; error: TaskError };

export interface ExecutorRequest {
  /** Тело запроса: <context> + <task>; у уточнения — только <task>; при повторной отправке переписки — <context> первой задачи, <history> и <task>. */
  prompt: string;
  /** Требования к формату ответа; исполнитель сам решает, как их передать модели. */
  formatRules: string;
  cwd: string;
  signal: AbortSignal;
  /** Модель для этой задачи в терминах исполнителя; не задана — его модель по умолчанию. */
  model?: string;
  /** Уточнение: продолжить сессию исполнителя, в которой выполнялась прежняя задача диалога. */
  resume?: { sessionId: string };
  /**
   * Уровень разрешений, выбранный человеком в настройках Luna; всегда один из `permissionLevels`
   * исполнителя. Что спрашивать на уровне, решает исполнитель (его CLI), но больше выбранного он
   * не даёт. Ядро передаёт итоговое значение: не выбран — `manual`.
   */
  permission: PermissionLevel;
  /**
   * Только чтение: исполнитель обязан не давать модели ни записи, ни команд — независимо от
   * остальных полей запроса, в том числе уровня разрешений. Не умеет — задача падает,
   * а не идёт с записью. Ставит ядро, когда диалог касался веба (см. `tasks/web.ts`).
   */
  readOnly?: boolean;
}

export interface Executor {
  readonly id: ExecutorId;
  /**
   * Уровни разрешений, которые исполнитель поддерживает; набор статичен и не зависит от установки
   * CLI. Ядро сверяет с ним `task.submit` и отдаёт его в `status()`. Новый уровень — значение
   * `PermissionLevel` и ветка в адаптере исполнителя.
   */
  readonly permissionLevels: readonly PermissionLevel[];
  status(): Promise<ExecutorStatus>;
  /** Поток завершается после done/failed либо молча — при отмене через signal. */
  run(request: ExecutorRequest): AsyncIterable<ExecutorEvent>;
}
