# Luna

Десктопный ИИ-ассистент для macOS: глобальный хоткей → короткий запрос → задача выполняется в фоне через Claude Code → результат в карточке, без кражи фокуса. Замысел, архитектура и этапы — в [assistant-project.md](assistant-project.md).

Сейчас реализованы **фазы 1–2**: хоткеи, pill, панель ввода с захватом контекста (приложение, URL и заголовок страницы, выделенный текст), фоновые параллельные задачи с прогрессом, список задач, карточка результата. Исполнитель один — Claude Code.

## Структура

| Путь | Что там |
|---|---|
| [apps/macos/](apps/macos/) | Shell: Swift, SwiftUI + AppKit (`NSPanel`), пакет SwiftPM |
| [core/](core/) | Ядро: TypeScript/Node — очередь задач, адаптеры исполнителей, JSON-RPC на stdio |
| [protocol/](protocol/) | JSON Schema протокола shell ↔ core и генерация типов для TS и Swift |

## Требования

- macOS 14+, Xcode 16+
- Node.js 22.18+
- [Claude Code](https://claude.com/claude-code) с выполненным входом (`claude` → `/login`)

## Установка готовой сборки

Сборки выкладываются в публичный репозиторий [luna-releases](https://github.com/stepaKaziatko/luna-releases):

```sh
curl -fsSL https://raw.githubusercontent.com/stepaKaziatko/luna-releases/main/install.sh | sh
```

## Запуск из исходников

```sh
npm install
apps/macos/scripts/bundle.sh       # ядро + shell → apps/macos/build/Luna.app (arm64 + x86_64)
open apps/macos/build/Luna.app
```

| Действие | Хоткей |
|---|---|
| Панель ввода (с захватом контекста) | `⌥ Space` |
| Последний результат | `⌥ ⇧ Space` |
| Список задач | `⌥ ⌘ Space` |

Выход — через значок луны в строке меню.

### Разрешения macOS

Контекст снимается в момент вызова панели и показывается чипами под полем ввода; любой чип можно убрать перед отправкой.

| Что | Откуда | Разрешение |
|---|---|---|
| Приложение | активное приложение | не нужно |
| URL и заголовок страницы | Safari и браузеры на Chromium (Chrome, Arc, Brave, Edge…) | «Автоматизация»: macOS спросит при первом вызове панели над браузером |
| Выделенный текст, заголовок окна | Accessibility API; если приложение выделение не отдаёт — `⌘C` с восстановлением буфера обмена | «Универсальный доступ»: чип «Выделение: дать доступ» в панели ввода |

Разрешения macOS выдаёт приложению-бандлу, поэтому запускать Luna нужно через `Luna.app`. При `swift run` запросы будут от имени терминала.

Бандл подписывается ad-hoc, и после пересборки macOS может попросить выдать права заново. Чтобы они сохранялись, подпишите постоянным сертификатом: `LUNA_SIGN_IDENTITY="…" apps/macos/scripts/bundle.sh`.

## Разработка

```sh
npm test            # тесты ядра (node:test, фикстуры вывода CLI)
npm run typecheck
npm run generate    # после правки protocol/schema
cd apps/macos && swift test
```

Переменные окружения ядра: `LUNA_CLAUDE_MODEL` (значение для `--model`), `LUNA_CLAUDE_BIN` (путь к `claude`), `LUNA_DATA_DIR` (вместо `~/Library/Application Support/Luna`). Для shell: `LUNA_NODE`, `LUNA_CORE_ENTRY`. Бандлу они передаются так: `open --env LUNA_CLAUDE_MODEL=sonnet apps/macos/build/Luna.app`.

Debug-сборкой (`scripts/bundle.sh debug`) можно управлять из скрипта — открывать панели, нажимать клавиши, подменять контекст, снимать состояние и картинку панели: [apps/macos/scripts/debug-command.sh](apps/macos/scripts/debug-command.sh), команды описаны в [DebugCommands.swift](apps/macos/Sources/Luna/Debug/DebugCommands.swift).

Инварианты кода, порядок работы над задачами (Cadence Lab, проект `LUNA`), CI и выпуск версий — в [CLAUDE.md](CLAUDE.md).
