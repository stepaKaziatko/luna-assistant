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

## Уведомления (core → shell)

`task.started`, `task.progress`, `task.done`, `task.failed`, `task.cancelled` — у всех params `TaskEventParams`: полный снимок задачи. Shell обновляет задачу по `id`, не полагаясь на порядок событий.

Когда stdin закрывается, core отменяет активные задачи и завершается.
