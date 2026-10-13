# Luna: замысел и архитектура

## Откуда

Luna начиналась как ассистент «хоткей → короткий запрос → задача в фоне через CLI исполнителя → карточка с результатом» на собственном ядре (Node, JSON-RPC по stdio) с оболочкой на SwiftPM; история до версии 0.7.0 — в `CHANGELOG.md` и в git до коммита эпика LUNA-54.

12 октября 2026 года проект перешёл на кодовую базу [coucou](https://github.com/Louis-CFM/coucou) (MIT) — открытого macOS-приложения в вырезе MacBook, которое уже умело всё, к чему шла Luna, и больше: сессии десятка агентов по их хукам, подтверждения и ответы на вопросы из острова, чат с несколькими провайдерами, интеграции с сервисами, голос, персонаж, iPhone-приложение. Код перенесён как есть под именем Luna. Имя, иконка, звуки и медиа coucou под отдельной лицензией автора (`LICENSE-ASSETS.md` upstream), поэтому в сборке Luna их нет; персонаж Luna свой, нарисован кодом — см. `LICENSE-COUCOU`.

## Как устроено

- **Одно приложение, без ядра.** Всё — в Xcode-проекте `apps/macos` (XcodeGen). Остров — `NSPanel` без рамки поверх выреза; состояния и переходы — `IslandStateMachine`, содержимое — `IslandViewContent`, окно — `IslandWindowController`. Спецификация с размерами и правилами — `docs/SPEC.md`.
- **Агенты подключаются хуками.** `HookServer` слушает Unix-сокет `~/Library/Application Support/Luna/luna.sock`; скрипт-хук `luna-hook` (Python, генерируется приложением в `~/.claude/luna/`) пересылает события Claude Code в сокет и ждёт решения по запросу разрешения не дольше, чем позволяет CLI; если приложение молчит, хук выходит сразу. Для Codex, Gemini CLI, Copilot, OpenCode, Amp, Hermes и Muse генерируются свои плагины. Какие события и как маршрутизируются в pill — `docs/AGENTS.md`.
- **Pill — единица интерфейса.** Каждая сессия агента, провайдер чата и сервис — pill из `PillCatalog.swift` с устойчивым ID, цветом и категорией; сессии одного агента ведёт `PillSessionRegistry`, очередь подтверждений — `ApprovalQueue`.
- **Персонаж** (`BotEngine`, `LunaStill`, `LunaWardrobe` в `LunaKit`) рисуется на `Canvas` в такт `TimelineView`; когда остров скрыт, ничего не рисуется.
- **Интеграции** — опрашивающие классы `*Poller` с ключами из Keychain; `docs/INTEGRATIONS.md`.
- **Голос** — `Voice/`: wake word «OK Luna» через `SFSpeechRecognizer`, намерения разбирает Claude по ключу пользователя или локальная модель Apple (macOS 26); `docs/VOICE.md`.
- **iPhone** — `Sources/Phone`, `Widgets`, `NotificationContent` и Cloudflare-relay `relay/`: синхронизация через приватную базу CloudKit пользователя; Luna эту часть не собирает — `docs/IPHONE.md`.

## Что дальше

Upstream не отслеживается: код ведётся в этом репозитории самостоятельно. Новые возможности Luna планируются в Cadence Lab, проект `LUNA`.
