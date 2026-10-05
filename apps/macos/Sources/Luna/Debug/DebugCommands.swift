#if DEBUG
import AppKit

/// Управление панелями из скрипта в debug-сборке — для проверки UI без симуляции нажатий
/// (она требует прав Accessibility). Команда передаётся в `object` уведомления `dev.luna.debug`,
/// см. scripts/debug-command.sh:
///
/// - `toggleInput`, `lastResult`, `tasks`, `agents`, `collapse`, `pillClick` — то же, что хоткеи и клик по pill;
/// - `pointer:island` — «курсор над шторкой», `pointer:away` — в стороне от неё, `pointer:<x>,<y>` — в точке
///   экрана, `pointer:off` — снова настоящий курсор: блок по наведению проверяется без движения мыши;
/// - `click:<dx>,<dy>` — клик по острову; точка — от его верхней середины, x вправо, y вниз;
/// - `settings` — открыть окно настроек, `settingsTab:<general|avatar|sounds>` — выбрать вкладку,
///   `settingsClose` — закрыть, `settingsSnapshot:<путь>` — его PNG;
/// - `set:<настройка>=<значение>` — поменять настройку: `hoverPeek`, `pillAvatars`, `pillText`, `animateAvatars`,
///   `soundsEnabled` (`true`/`false`), `soundVolume` (0…1), `tint`, `accessory`, `sound.<событие>` (имя или пусто);
/// - `agent:<id сессии>` — открыть карточку сессии агента; `agentJump:<id>` — перейти к её окну;
/// - `agentsSet:<json>` — подменить список сессий (массив AgentSession), `agentSteps:<json>` — шаги
///   открытой карточки (массив AgentStep): интерфейс агентов проверяется без живых сессий;
/// - `agentWindow[:<id>]` — окно сессии открытой карточки (или указанной), `agentWindowClose[:<id>]` — закрыть
///   его (без id — последнее), `agentTranscript:<json>` — подменить подробную ленту последнего окна
///   (массив AgentStep), `agentWindowSnapshot:<путь>` — PNG последнего окна сессии;
/// - `hit:<x>,<y>:<путь>` — достаётся ли панели клик в точке экрана (`true`/`false` в файл): прозрачная
///   часть окна острова должна пропускать клики;
/// - `submit:<текст>` — отправить запрос с текущим контекстом;
/// - `cancelSelected` — кнопка отмены у выбранной строки списка задач;
/// - `clearHistory` — клик по кнопке «Очистить историю» в списке задач;
/// - `context:<json>` — подменить захваченный контекст (поля TaskContext; `app` обязателен);
/// - `key:<код клавиши>` и `type:<текст>` — нажатия в открытой панели (`key:48` — Tab,
///   фокус в поле продолжения карточки; `key:36` — ↩); модификаторы — перед кодом через `+`:
///   `key:cmd+51` — ⌘⌫ (также `shift`, `opt`, `ctrl`); после `windowClick` клавиши идут в окно диалога;
/// - `openWindow[:<threadId>]` — «Открыть полностью» у диалога открытой карточки (или указанного);
/// - `closeWindow[:<threadId>]` — закрыть окно диалога карточки (или указанного; без карточки — последнее);
/// - `windowClick[:<threadId>]` — клик в окно диалога (окно становится ключевым);
/// - `windowSnapshot:<путь>` — PNG окна диалога открытой карточки, а без карточки — последнего открытого;
/// - `dump:<путь>` — состояние приложения в JSON (с открытыми окнами и активным приложением);
///   `snapshot:<путь>` — PNG панели;
/// - `quit` — то же, что «Выйти из Luna» в меню.
@MainActor
enum DebugCommands {
    private static var observer: NSObjectProtocol?

    /// Звуки, которые Luna проиграла бы, по порядку: в дампе видно, о чём она сообщила.
    private static var sounds: [String] = []

    static func install(state: AppState, panels: PanelController, windows: DialogWindows, settings: SettingsWindow) {
        let play = state.playSound
        state.playSound = { event in
            sounds.append(event.rawValue)
            play(event)
        }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.luna.debug"), object: nil, queue: .main
        ) { notification in
            guard let command = notification.object as? String else { return }
            MainActor.assumeIsolated { run(command, state: state, panels: panels, windows: windows, settings: settings) }
        }
    }

    private static func run(
        _ command: String, state: AppState, panels: PanelController, windows: DialogWindows, settings: SettingsWindow
    ) {
        let parts = command.split(separator: ":", maxSplits: 1)
        let argument = parts.count > 1 ? String(parts[1]) : ""
        /// Диалог для команд окна: из аргумента, иначе открытой карточки, иначе последнего открытого окна.
        var windowThread: String? {
            argument.isEmpty ? state.shownThreadId ?? state.openWindows.last : argument
        }

        switch parts.first.map(String.init) {
        case "toggleInput": state.toggleInput()
        case "lastResult": state.toggleLastResult()
        case "tasks": state.toggleTasks()
        case "agents": state.toggleAgents()
        case "agent": state.openAgent(id: argument)
        case "agentJump": state.jumpToAgent(id: argument)
        case "agentsSet":
            if let sessions = try? JSONDecoder().decode([AgentSession].self, from: Data(argument.utf8)) {
                state.applyAgents(sessions)
            }
        case "agentSteps":
            if let steps = try? JSONDecoder().decode([AgentStep].self, from: Data(argument.utf8)) {
                state.debugSetAgentSteps(steps)
            }
        case "agentWindow":
            if let id = argument.isEmpty ? state.shownAgentId : argument { state.openAgentWindow(id: id) }
        case "agentWindowClose":
            if let id = argument.isEmpty ? state.agentWindows.last : argument { state.closeAgentWindow(id: id) }
        case "agentTranscript":
            if let id = state.agentWindows.last,
               let steps = try? JSONDecoder().decode([AgentStep].self, from: Data(argument.utf8)) {
                state.debugSetAgentTranscript(steps, sessionId: id)
            }
        case "agentWindowSnapshot":
            if let id = state.agentWindows.last {
                try? windows.debugAgentSnapshot(sessionId: id)?.write(to: URL(fileURLWithPath: argument))
            }
        case "hit":
            let fields = argument.split(separator: ":", maxSplits: 1)
            let numbers = fields.first?.split(separator: ",").compactMap { Double($0) } ?? []
            guard fields.count == 2, numbers.count == 2 else { return }
            let receives = panels.debugReceivesClick(at: NSPoint(x: numbers[0], y: numbers[1]))
            try? String(receives).write(toFile: String(fields[1]), atomically: true, encoding: .utf8)
        case "pointer":
            let numbers = argument.split(separator: ",").compactMap { Double($0) }
            switch argument {
            case "island": panels.debugPointer = panels.debugIslandPoint
            case "away": panels.debugPointer = NSPoint(x: panels.debugIslandPoint.x, y: panels.debugIslandPoint.y - 2000)
            case "off": panels.debugPointer = nil
            default: if numbers.count == 2 { panels.debugPointer = NSPoint(x: numbers[0], y: numbers[1]) }
            }
        case "click":
            let numbers = argument.split(separator: ",").compactMap { Double($0) }
            if numbers.count == 2 { panels.debugClick(dx: numbers[0], dy: numbers[1]) }
        case "settings": state.openSettings()
        case "settingsTab": settings.debugSelect(tab: argument)
        case "settingsClose": settings.debugClose()
        case "settingsSnapshot":
            try? settings.debugSnapshot()?.write(to: URL(fileURLWithPath: argument))
        case "set":
            let fields = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if fields.count == 2 { set(fields[0], to: fields[1], in: state.settings) }
        case "collapse": state.collapse()
        case "pillClick": state.pillClicked()
        case "submit":
            state.draft = argument
            state.submit()
        case "cancelSelected":
            if let threadId = state.selectedThreadId { state.cancel(threadId: threadId) }
        case "clearHistory":
            state.clearHistory()
        case "context":
            guard let context = try? JSONDecoder().decode(TaskContext.self, from: Data(argument.utf8)),
                  let app = context.app else { return }
            let details = CapturedContext.Details(url: context.url, title: context.title, selection: context.selection)
            state.debugSetContext(CapturedContext(app: app, details: details))
        case "key":
            var names = argument.split(separator: "+").map(String.init)
            guard let keyCode = names.popLast().flatMap(UInt16.init) else { return }
            var modifiers: NSEvent.ModifierFlags = []
            for name in names {
                switch name {
                case "cmd": modifiers.insert(.command)
                case "shift": modifiers.insert(.shift)
                case "opt": modifiers.insert(.option)
                case "ctrl": modifiers.insert(.control)
                default: return
                }
            }
            // Клавиши уходят в ключевое окно: в окно диалога после клика по нему, иначе в панель.
            let characters = keyCharacters[keyCode] ?? ""
            if !windows.debugKeyDown(keyCode: keyCode, characters: characters, modifiers: modifiers) {
                panels.debugKeyDown(keyCode: keyCode, characters: characters, modifiers: modifiers)
            }
        case "type":
            for character in argument { panels.debugKeyDown(keyCode: 0, characters: String(character)) }
        case "openWindow":
            if let threadId = windowThread { state.openWindow(threadId: threadId) }
        case "closeWindow":
            if let threadId = windowThread { state.closeWindow(threadId: threadId) }
        case "windowClick":
            if let threadId = windowThread { windows.debugClick(threadId: threadId) }
        case "windowSnapshot":
            if let threadId = state.shownThreadId ?? state.openWindows.last {
                try? windows.debugSnapshot(threadId: threadId)?.write(to: URL(fileURLWithPath: argument))
            }
        case "dump":
            let dump = Dump(
                state: state, panel: panels.debugPanelInfo, windows: windows.debugWindows,
                agentWindows: windows.debugAgentWindows, settingsVisible: settings.debugIsVisible, sounds: sounds
            )
            try? JSONEncoder.pretty.encode(dump)
                .write(to: URL(fileURLWithPath: argument))
        case "snapshot":
            try? panels.debugSnapshot()?.write(to: URL(fileURLWithPath: argument))
        case "quit":
            NSApp.terminate(nil)
        default: break
        }
    }

    private static func set(_ name: String, to value: String, in settings: LunaSettings) {
        switch name {
        case "hoverPeek": settings.hoverPeek = value == "true"
        case "pillAvatars": settings.pillAvatars = value == "true"
        case "pillText": settings.pillText = value == "true"
        case "animateAvatars": settings.animateAvatars = value == "true"
        case "soundsEnabled": settings.soundsEnabled = value == "true"
        case "soundVolume": if let volume = Double(value) { settings.soundVolume = min(1, max(0, volume)) }
        case "tint": if let tint = AvatarTint(rawValue: value) { settings.tint = tint }
        case "accessory": if let accessory = AvatarAccessory(rawValue: value) { settings.accessory = accessory }
        default:
            if name.hasPrefix("sound."), let event = SoundEvent(rawValue: String(name.dropFirst(6))) {
                settings.setSound(value.isEmpty ? nil : value, for: event)
            }
        }
    }

    /// Символы, которые оконный сервер кладёт в событие для клавиш: esc, ↩, ↓, ↑, Tab, ⌫, «a» и «c» (для ⌘A, ⌘C).
    private static let keyCharacters: [UInt16: String] = [
        53: "\u{1B}", 36: "\r", 125: "\u{F701}", 126: "\u{F700}", 48: "\t", 51: "\u{7F}", 0: "a", 8: "c",
    ]

    /// Диалог глазами списка задач и карточки.
    private struct DialogDump: Encodable {
        let threadId: String
        let title: String
        let taskIds: [String]
        let followUps: Int
        /// К какой задаче уйдёт уточнение; nil — поля продолжения нет.
        let continuationPoint: String?

        init(_ dialog: Dialog) {
            threadId = dialog.threadId
            title = dialog.title
            taskIds = dialog.tasks.map(\.id)
            followUps = dialog.followUpCount
            continuationPoint = dialog.continuationPoint?.id
        }
    }

    private struct Dump: Encodable {
        let mode: String
        let draft: String
        let context: TaskContext?
        let issues: [String]
        let selectedThreadId: String?
        /// Поле поиска списка задач; `searchResults` — сколько задач в последнем ответе поиска.
        let searchQuery: String
        let searchResults: Int?
        let clearConfirming: Bool
        let canClearHistory: Bool
        let listMessage: String?
        let followUpDraft: String
        let followUpError: String?
        let dialogs: [DialogDump]
        let unseen: [String]
        let pill: String
        /// Фраза развёрнутого pill; nil — pill свёрнут в полоску.
        let pillText: String?
        /// Счётчики шторки: род и число.
        let chips: [String]
        /// Размер видимой части острова.
        let island: String
        let agents: [AgentSession]
        let finishedAgents: [String]
        let selectedAgentId: String?
        let agentSteps: Int
        /// Настройки пользователя и окно настроек.
        let settings: [String: String]
        let settingsVisible: Bool
        /// Какие звуки Luna проиграла бы с запуска, по порядку.
        let sounds: [String]
        let problem: String?
        let accessibilityTrusted: Bool
        let captureMs: Int?
        let panel: [String: String]
        /// Окна «Открыть полностью»: диалог, рамка, видимость, ключевое ли.
        let windows: [DialogWindows.DebugWindow]
        /// Окна сессий агентов; `threadId` у них — id сессии. `agentTranscripts` — сколько шагов в ленте каждого.
        let agentWindows: [DialogWindows.DebugWindow]
        let agentTranscripts: [String: Int]
        /// Bundle id активного приложения: окна и панели Luna не должны его менять.
        let frontmostApp: String?
        let tasks: [TaskInfo]

        @MainActor
        init(
            state: AppState, panel: [String: String], windows: [DialogWindows.DebugWindow],
            agentWindows: [DialogWindows.DebugWindow], settingsVisible: Bool, sounds: [String]
        ) {
            mode = String(describing: state.mode)
            draft = state.draft
            context = state.context?.payload
            issues = state.captureIssues.map { String(describing: $0) }
            selectedThreadId = state.selectedThreadId
            searchQuery = state.searchQuery
            searchResults = state.searchResults?.count
            clearConfirming = state.clearConfirming
            canClearHistory = state.canClearHistory
            listMessage = state.listMessage
            followUpDraft = state.followUpDraft
            followUpError = state.followUpError
            dialogs = state.listedDialogs.map(DialogDump.init)
            unseen = state.unseen.sorted()
            pill = String(describing: state.pillState)
            pillText = state.pillPresentation?.text
            chips = state.statusChips.map { "\($0.kind.rawValue):\($0.count)" }
            island = NSStringFromSize(state.islandSize)
            agents = state.agents
            finishedAgents = state.finishedAgents.sorted()
            selectedAgentId = state.selectedAgentId
            agentSteps = state.agentSteps.count
            var values = [
                "hoverPeek": String(state.settings.hoverPeek),
                "pillAvatars": String(state.settings.pillAvatars),
                "pillText": String(state.settings.pillText),
                "animateAvatars": String(state.settings.animateAvatars),
                "soundsEnabled": String(state.settings.soundsEnabled),
                "soundVolume": String(state.settings.soundVolume),
                "tint": state.settings.tint.rawValue,
                "accessory": state.settings.accessory.rawValue,
            ]
            for event in SoundEvent.allCases { values["sound.\(event.rawValue)"] = state.settings.sound(for: event) ?? "" }
            settings = values
            self.settingsVisible = settingsVisible
            self.sounds = sounds
            problem = state.problem
            accessibilityTrusted = AccessibilityProbe.isTrusted
            captureMs = state.lastCaptureDuration.map { Int($0 / .milliseconds(1)) }
            self.panel = panel
            self.windows = windows
            self.agentWindows = agentWindows
            agentTranscripts = state.agentTranscripts.mapValues(\.count)
            frontmostApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            tasks = state.tasks
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
#endif
