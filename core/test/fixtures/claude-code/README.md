# Фикстуры вывода Claude Code

Вывод `claude -p --output-format stream-json --verbose`, Claude Code 2.1.181.

| Файл | Происхождение |
|---|---|
| `success.jsonl` | Реальный запуск: чтение README через `Read` и ответ. Пути обезличены. |
| `not-logged-in.jsonl` | Реальный запуск с пустым `CLAUDE_CONFIG_DIR` (CLI не авторизован). |
| `rate-limit.synthetic.jsonl` | **Синтетика**: собрана по образцу `not-logged-in.jsonl`, реальный отказ по лимиту снять не удалось. Заменить настоящим выводом при первой возможности. |

При обновлении CLI — переснять и прогнать `npm test`.
