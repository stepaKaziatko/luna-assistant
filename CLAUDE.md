# CLAUDE.md — Luna

Нативное macOS-приложение в вырезе MacBook: показывает сессии ИИ-агентов, даёт подтверждать их запросы и отвечать на вопросы из острова, чат с моделями, интеграции, голос. Код — перенесённый [coucou](https://github.com/Louis-CFM/coucou) (см. [assistant-project.md](assistant-project.md)); запуск и разрешения macOS — [README.md](README.md).

## Где что лежит

| Путь | Что там |
|---|---|
| `apps/macos/project.yml` | Проект для XcodeGen. `Luna.xcodeproj` и `Resources/Info*.plist` из него генерируются и коммитятся; руками не правятся |
| `apps/macos/Sources/App/` | Mac: остров (`IslandWindowController`, `IslandViewContent`, `IslandStateMachine`), хуки агентов и генерируемые плагины (`HookServer.swift`), интеграции (`*Poller.swift`, `*Controller.swift`), настройки, `Voice/` |
| `apps/macos/Sources/LunaKit/` | Общее с iPhone: персонаж (`BotEngine`, `MochiStill`, `MochiWardrobe`), `PillCatalog.swift` — единственный источник правды о pill (ID, цвет, категория), diff, модели |
| `apps/macos/Sources/Phone/`, `Widgets/`, `NotificationContent/` | iPhone-таргеты. Переносятся как есть, не собираются (нужны команда Apple Developer, CloudKit, relay) |
| `tests/`, `scripts/test-*.sh` | Тесты на `swiftc`: скрипт собирает нужные файлы и запускает проверки |
| `docs/` | `SPEC.md` (остров, по-французски), `INTEGRATIONS.md`, `AGENTS.md`, `VOICE.md`, `IPHONE.md` |
| `scripts/`, `apps/macos/scripts/` | Версия и выпуск; сборка бандла, проверка запуска, генерация иконок и звуков |

## Команды

```sh
brew install xcodegen                       # один раз; нужен Xcode 26+
for t in scripts/test-*.sh; do bash "$t"; done   # тесты (работают и на Xcode 16)
cd apps/macos && xcodegen generate          # после правки project.yml — и закоммитить результат
apps/macos/scripts/bundle.sh debug          # build/Luna.app под свою архитектуру
apps/macos/scripts/bundle.sh                # universal-бандл, подпись ad-hoc или LUNA_SIGN_IDENTITY
apps/macos/scripts/smoke.sh                 # бандл запускается и завершается
scripts/check-version.sh                    # версия согласована и описана в CHANGELOG.md
scripts/bump-version.sh minor               # поднять версию (minor | patch | номер) — на этапе слияния
```

Локальный Xcode 16 собирает тесты, но не приложение: код рассчитан на Swift 6.2 (строгая конкурентность, FoundationModels). Полную сборку проверяет CI на раннере `macos-26`.

## Инварианты

- **Swift 6, SwiftUI + AppKit, без сторонних зависимостей.** Персонаж рисуется кодом (`Canvas` + `TimelineView`) — никаких Rive, Lottie и картинок.
- **Секреты — в Keychain**, не на диске и не в git. Никакой телеметрии; сеть — только к сервисам, которые подключил пользователь.
- **Агентов не блокировать.** Хук отвечает сразу, если приложение не отвечает; `~/.claude/settings.json` и файлы хуков других CLI не перезаписываются: резервная копия с датой, слияние, diff — запись только после подтверждения человека.
- **Ни одно разрешение агента и ни одно письмо не уходят без явного клика.**
- **0 % CPU, когда остров скрыт.**
- **Bundle ID `dev.luna.Luna` не меняется:** на него завязаны Keychain, настройки и выданные разрешения macOS.
- **ID pill — контракт** (Keychain, UserDefaults, маршрутизация хуков): существующий ID не переименовывается. Payload-ключи `coucou_agent`, `coucou_kind` — контракт со сторонними агентами, остаются как есть.
- **Существующие экраны не перерисовываются** без явной просьбы; новые следуют стилю приложения.
- **Ничего из LICENSE-ASSETS.md coucou в сборке нет:** имена «Coucou» и «Mochi», их иконка и звуки, медиа из `docs/media` и `design/captures`. Своё: иконки — `apps/macos/scripts/render-icons.swift`, звуки — `render-sounds.py`. Идентификаторы в коде (`LunaKit`, `MochiWardrobe`, `coucou_agent`) — код под MIT, их можно оставлять.
- **Синхронизация с upstream** — по diff с коммитом, записанным в `LICENSE-COUCOU`; структура `apps/macos` совпадает с `NotchBuddy/` в coucou, чтобы патчи переносились.
- **Версия записана в двух местах:** `apps/macos/project.yml` и сгенерированный `apps/macos/Resources/Info.plist`. Меняет её только `scripts/bump-version.sh` — вместе с разделом в `CHANGELOG.md`.

Комментарии в коде, сообщения коммитов и тексты интерфейса для русской локали — на русском; код coucou и его комментарии остаются по-английски, переводить их не нужно.

## Как идёт работа

Задачи ведутся в Cadence Lab, проект `LUNA` (`https://sdlc.food-cart.ru/p/LUNA/board`). Роли и цикл живут там и приезжают агенту при захвате этапа; здесь — только то, что касается репозитория.

- Эпик — это одна ветка, один PR в `main` и один выпуск. Ветка `clab/<ключ эпика>-<короткий-slug>` от свежего `origin/main`, заголовок PR — `<ключ эпика>: <название эпика>`.
- Задача эпика — коммиты в его ветке; сообщение каждого начинается с `<ключ задачи>: `. Своего PR и своего выпуска у задачи нет, задач вне эпика не бывает.
- Ветка, PR и коммиты ищутся по ключам Cadence Lab: `git ls-remote --heads origin "clab/<ключ эпика>-*"`, `gh pr list --state all --head <ветка>`, `git log --grep="^<ключ задачи>: " origin/main..origin/<ветка>`.
- Рабочая копия задачи — `git worktree` в `.worktrees/<ключ задачи>` на локальной ветке `task/<ключ задачи>`, отправка — `git push origin HEAD:<ветка эпика>`; копия эпика (приёмка, слияние) — `.worktrees/<ключ эпика>`. Основная копия стоит на `main`.
- Запушенная история ветки не переписывается; свежий `main` и соседние задачи вливаются merge'ем. В `main` эпик попадает одним squash-коммитом `<ключ эпика>: <название>` со списком задач в теле.
- Слияние эпика, который меняет то, что получает пользователь, — это выпуск версии: перед слиянием версия поднимается в ветке, остальное делает CI.
- Коммиты заканчиваются трейлером `Co-Authored-By: <модель> <noreply@anthropic.com>`.

## CI и релизы

- `.github/workflows/ci.yml` — на каждый PR и push в `main`: проверка версии на Linux; тесты, debug-бандл и smoke на `macos-26` (только если изменение может затронуть приложение).
- `.github/workflows/release.yml` — коммит в `main` с версией, у которой ещё нет тега, собирает `Luna.app` (arm64 + x86_64) на `macos-26`, выкладывает его релизом в публичный `stepaKaziatko/luna-releases` и ставит тег `vX.Y.Z` здесь. Исходники остаются в этом репозитории. Ручной запуск Release собирает бандл без публикации.
- Версия: эпик с новой возможностью — `minor`, только с исправлениями — `patch`. Эпик, которого пользователь не получает (документация, CI, тесты), версию не поднимает и релиза не даёт.
- Заметные пользователю изменения копятся в разделе «Дальше» файла `CHANGELOG.md`; `scripts/bump-version.sh` отдаёт его новой версии, и раздел уходит в заметки публичного релиза.
- Упавший выпуск повторяется перезапуском прогона (`gh run rerun <id> --failed`): тег ставится последним шагом. Публикации нужен секрет `LUNA_RELEASES_TOKEN` — токен с правом Contents на `luna-releases`.
- Публичный репозиторий (`README.md`, `install.sh`, проверка релиза) правится своим PR; версии Luna он не меняет.
