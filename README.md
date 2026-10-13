# Luna

Luna живёт в вырезе MacBook (на мониторе без выреза — в полоске у верхнего края) и присматривает за сессиями ИИ-агентов: Claude Code, Codex, Gemini CLI, Cursor, Copilot CLI, OpenCode, Amp, Hermes и других. Из острова можно разрешить или отклонить запрос агента, ответить на его вопрос, перейти к его терминалу, поговорить с моделью, бросить файл, следить за GitHub, Vercel, Stripe и другими сервисами — не отрываясь от работы. В острове — маленький персонаж, который рисуется кодом, дышит, моргает и следит за курсором.

Код — перенесённый проект [coucou](https://github.com/Louis-CFM/coucou) Луи Райе (MIT); имя, иконка, звуки и персонаж у Luna свои. Подробности — в [LICENSE-COUCOU](LICENSE-COUCOU) и [assistant-project.md](assistant-project.md).

## Что умеет

- **Сессии агентов в острове.** Каждая сессия — своя «таблетка» (pill) с аватаром: что агент читает, правит и запускает, шаг за шагом; правки файлов с `+N −M`, по клику — полный diff. Закончил — персонаж радуется. Сторонний агент может завести себе pill, пометив payload хука `luna_agent` ([docs/AGENTS.md](docs/AGENTS.md)).
- **Разрешения и вопросы.** Запросы Claude Code и Codex на разрешение приходят в остров с кнопками Allow / Deny / Always; вопросы `AskUserQuestion` — с вариантами ответа. Ничего не разрешается без клика.
- **Переход к терминалу** сессии одной командой.
- **Чат** с Claude, Gemini, OpenAI или локальной моделью (Ollama, LM Studio) по своему ключу; диктовка в чат; лимиты плана Claude и Codex в шапке.
- **Интеграции:** GitHub (PR, ревью, CI), Vercel, Stripe, Resend, n8n, Notion, Cal.com, Apple Music, Spotify, Apple Mail, курсы криптовалют — у каждой свой цветной персонаж.
- **Файл на остров** — персонаж «проглатывает» его, дальше вопрос по файлу или письмо.
- **Персонаж на рабочем столе**, гардероб и сезонные наряды, окно поверх любого приложения как контекст для Claude.
- **«OK Luna»** — голосовое управление с Claude в роли мозга: распознавание речи на Mac, в Anthropic уходит только текст.
- **Еженедельный отчёт** по понедельникам: время, сессии, файлы, строки, команды.
- **Хоткеи** (настраиваются в Settings → Shortcuts): `⌃⌥Space` чат, `⌃⌥A` к ожидающему запросу, `⌃⌥T` терминал агента, `⌃⌥[` / `⌃⌥]` соседняя pill, `⌃⌥M` звук, `⌃⌥D` персонаж на стол, `⌃⌥G` гардероб.
- **Десять языков** интерфейса, никакой телеметрии, ключи — в Keychain.
- **iPhone-приложение** (исходники в `apps/macos/Sources/Phone`): Live Activity, виджеты, подтверждения по Face ID. Luna его не собирает: нужны платная программа Apple Developer, свой контейнер CloudKit и relay для APNs — см. [docs/IPHONE.md](docs/IPHONE.md).

## Установка готовой сборки

Сборки выкладываются в публичный репозиторий [luna-releases](https://github.com/stepaKaziatko/luna-releases):

```sh
curl -fsSL https://raw.githubusercontent.com/stepaKaziatko/luna-releases/main/install.sh | sh
```

Luna подписана ad-hoc, без нотаризации: при первом запуске macOS спросит подтверждение (Finder → правый клик → «Открыть»).

## Требования

- macOS 15 или новее. На MacBook с вырезом остров встаёт в вырез; на остальных Mac — полоска у верхнего края.
- Для сборки из исходников: Xcode 26 или новее (код на Swift 6.2, часть функций — на SDK macOS 26) и [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- Агенты подключаются хуками: Luna предлагает добавить свой хук в `~/.claude/settings.json` (и аналоги у других CLI) и показывает diff перед записью. Файл без подтверждения не меняется.

## Запуск из исходников

```sh
apps/macos/scripts/bundle.sh           # universal-бандл → apps/macos/build/Luna.app
apps/macos/scripts/bundle.sh debug     # быстрая сборка под свою архитектуру
open apps/macos/build/Luna.app
```

Или в Xcode: `cd apps/macos && xcodegen && open Luna.xcodeproj`, схема `Luna`.

Тесты — скрипты `scripts/test-*.sh`: каждый компилирует нужные файлы `swiftc` и запускает проверки из `tests/`, Xcode-проект им не нужен.

## Разрешения macOS

Luna просит их по мере надобности и работает без них в урезанном виде:

| Разрешение | Зачем |
|---|---|
| Автоматизация (Apple Events) | перейти к окну терминала, управлять Музыкой и Spotify, отправить письмо через Mail |
| Универсальный доступ | заголовок активного окна, когда его прикрепляют как контекст |
| Микрофон и распознавание речи | диктовка в чат и «OK Luna» |
| Контакты | адрес получателя, когда письмо просят голосом |

## Где что лежит

| Путь | Что там |
|---|---|
| `apps/macos/project.yml` | Описание Xcode-проекта для XcodeGen; `Luna.xcodeproj` из него генерируется |
| `apps/macos/Sources/App/` | Mac-приложение: остров, хуки агентов (`HookServer.swift`), интеграции, настройки, голос (`Voice/`) |
| `apps/macos/Sources/LunaKit/` | Общее с iPhone: персонаж (`BotEngine`), каталог pill (`PillCatalog`), diff, модели |
| `apps/macos/Sources/Phone/`, `Widgets/`, `NotificationContent/` | iPhone-приложение, виджеты и карточка уведомления |
| `apps/macos/Resources/` | `Localizable.xcstrings`, звуки, энтайтлменты, сгенерированные Info.plist |
| `apps/macos/scripts/` | Сборка бандла, проверка запуска, генерация иконок и звуков |
| `tests/`, `scripts/test-*.sh` | Тесты и скрипты их запуска |
| `relay/` | Cloudflare Worker для пушей Live Activity на iPhone |
| `docs/` | Спецификация острова, интеграции, агенты, голос, iPhone (по-английски и по-французски, из coucou) |
| `scripts/` | Версия, выпуск, публикация релиза |

## Выпуск

Версия хранится в `apps/macos/project.yml` и в `apps/macos/Resources/Info.plist`; поднимает её `scripts/bump-version.sh`, забирая заметки из раздела «Дальше» в `CHANGELOG.md`. Коммит в `main` с ещё не выпущенной версией собирает `Luna.app` (arm64 + x86_64) и выкладывает релиз в `luna-releases`.
