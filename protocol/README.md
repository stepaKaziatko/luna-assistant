# Протокол shell ↔ core

JSON-RPC 2.0 поверх stdio дочернего процесса: одно сообщение — одна строка JSON. Shell запускает core и пишет запросы в его stdin; ответы и уведомления приходят из stdout. stderr ядра — только диагностика.

Типы полезной нагрузки описаны в [schema/protocol.schema.json](schema/protocol.schema.json) и генерируются в оба потребителя:

```
npm run generate   # → core/src/rpc/protocol.gen.ts, apps/macos/Sources/Luna/Protocol/Protocol.gen.swift
```

Сгенерированные файлы хранятся в репозитории; руками их не правят.

## Запросы (shell → core)

| Метод | params | result |
|---|---|---|
| `core.hello` | — | `HelloResult` |
| `task.submit` | `TaskSubmitParams` | `TaskSubmitResult` |
| `task.cancel` | `TaskCancelParams` | `{}` |
| `task.list` | — | `TaskListResult` |

`TaskSubmitParams.context` — то, что shell снял в момент вызова панели (`TaskContext`: приложение, URL, заголовок, выделение). Core его нормализует: оставляет известные поля, делает однострочными `app`, `url` и `title`, ограничивает длину.

### Диалог

Уточнение — новая задача того же диалога: `task.submit` с `TaskSubmitParams.followUpOf` — id задачи, которую оно продолжает. Исполнитель продолжает свою прежнюю сессию в прежней рабочей директории; в промпт идёт только текст уточнения, экран заново не захватывается. Вместе с `followUpOf` поля `context` и `executor` не передаются.

`TaskInfo.threadId` — id первой задачи диалога; у задачи без уточнений он равен её `id`. У уточнения — `threadId` и `executor` продолжаемой задачи.

Продолжить можно только последнюю задачу диалога со статусом `done` и с `sessionId`: после неё в диалоге могут быть лишь `failed` и `cancelled`, кроме `failed` с видом `session_not_found` (сессия исполнителя не сохранилась — такой диалог не продолжается), и в диалоге нет задачи `queued` или `running`. Иначе — ошибка `InvalidParams`.

## Уведомления (core → shell)

`task.started`, `task.progress`, `task.done`, `task.failed`, `task.cancelled` — у всех params `TaskEventParams`: полный снимок задачи. Shell обновляет задачу по `id`, не полагаясь на порядок событий.

Когда stdin закрывается, core отменяет активные задачи и завершается.
