# Фикстуры вывода Claude Code

Вывод `claude -p --output-format stream-json --verbose`, Claude Code 2.1.181.

| Файл | Происхождение |
|---|---|
| `success.jsonl` | Реальный запуск: чтение README через `Read` и ответ. Пути обезличены. |
| `not-logged-in.jsonl` | Реальный запуск с пустым `CLAUDE_CONFIG_DIR` (CLI не авторизован). |
| `session-not-found.jsonl` | Реальный запуск `claude -p --resume <случайный uuid>`: сессии нет, CLI отвечает одной строкой `result` (`error_during_execution`, `errors: ["No conversation found…"]`), к модели не обращается, код выхода 1. |
| `resume-success.jsonl` | Реальный запуск уточнения на `sonnet`: задача «запомни число 417», затем `--resume <её сессия>` с вопросом «какое число я называл?» — записан поток уточнения. CLI вернул тот же `session_id`. Пути обезличены. |
| `invalid-model.jsonl` | Реальный запуск с несуществующей моделью: `claude -p … --model no-such-model-x`. `init` называет это же имя, затем служебное сообщение (`model: "<synthetic>"`, `error: "model_not_found"`) и `result` — `subtype: success`, `is_error: true`, `api_error_status: 404`; токены не тратятся. Путь, плагины и `request_id` обезличены. |
| `approval-allow.jsonl`, `approval-deny.jsonl` | **Не вывод CLI, а его запросы к мосту подтверждений** (`core/src/executors/claude-code/bridge.ts`): строки MCP JSON-RPC, которые Claude Code шлёт серверу из `--mcp-config` — `initialize`, `notifications/initialized`, `tools/list`, `tools/call` инструмента `approve` с `{tool_name, input, tool_use_id}`. Сняты реальным запуском через ядро на `sonnet` (`LUNA_BRIDGE_TRACE`): задача «создай файл hello.txt с текстом hi», в первом прогоне человек разрешил, во втором отклонил — запросы одинаковы, различается ответ ядра. Путь к файлу задачи обезличен. |
| `rate-limit.synthetic.jsonl` | **Синтетика**: собрана по образцу `not-logged-in.jsonl`, реальный отказ по лимиту снять не удалось. Заменить настоящим выводом при первой возможности. |

При обновлении CLI — переснять и прогнать `npm test`.
