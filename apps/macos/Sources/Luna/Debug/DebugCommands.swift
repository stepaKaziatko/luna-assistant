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
///   `settingsClose` — закрыть, `settingsSnapshot:<путь>` — его PNG, `settingsModelDraft:<текст>` — набрать
///   в поле «Добавить» раздела «Модели» (подсветка некорректной строки видна на снимке);
/// - `set:<настройка>=<значение>` — поменять настройку: `islandMode` (`always`/`background`), `hoverPeek`, `pillAvatars`, `pillText`, `animateAvatars`,
///   `soundsEnabled` (`true`/`false`), `soundVolume` (0…1), `tint`, `accessory`, `sound.<событие>` (имя или пусто),
///   `model` — выбор модели Claude Code в панели ввода (значение из списка; чужое — выбор стёрт; пусто — явная «Модель CLI»,
///   она запоминается, пока задано умолчание),
///   `defaultModel` — модель по умолчанию из настроек (как выбор в разделе «Модели»; пусто или чужое — «Модель CLI»;
///   реальная смена стирает выбор панели),
///   `models` — список моделей через запятую, как правка в настройках: имена проверяются, повторы убираются,
///   пусто — встроенный список,
///   `followUpModel` — выбор модели в поле продолжения открытой карточки (как клик по пункту меню; пусто — «Модель CLI»,
///   у диалога с моделью такого пункта нет; модель точки продолжения — то же, что «не менял»);
///   Шторка в режиме «В фоне»: `dump` показывает `panel.isVisible` (окно на экране; после ухода шторки
///   становится `false` через полсекунды, когда доиграет анимация), `panel.pointerPolling` и `motion.timer`;
/// - `agent:<id сессии>` — открыть карточку сессии агента; `agentJump:<id>` — перейти к её окну;
/// - `agentsSet:<json>` — подменить список сессий (массив AgentSession; поле `model` — подпись модели в карточке и окне),
///   `agentSteps:<json>` — шаги
///   открытой карточки (массив AgentStep): интерфейс агентов проверяется без живых сессий;
/// - `agentWindow[:<id>]` — окно сессии открытой карточки (или указанной), `agentWindowClose[:<id>]` — закрыть
///   его (без id — последнее), `agentTranscript:<json>` — подменить подробную ленту последнего окна
///   (массив AgentStep), `agentWindowSnapshot:<путь>` — PNG последнего окна сессии;
/// - `islandMenu:<путь>` — заголовки меню, которое открывает правый клик по шторке (по строке на пункт,
///   разделитель — пустая строка); `rightClick:<dx>,<dy>:<путь>` — сам правый клик по острову: меню раскрывается
///   на секунду, в это время состояние пишется в файл (как `dump`, `panel.menuOpen` — `true`), и меню закрывается;
/// - `settingsKey:<модификаторы+код>` — нажатие клавиши в окне настроек (`settingsKey:cmd+12` — ⌘Q);
/// - `hit:<x>,<y>:<путь>` — достаётся ли панели клик в точке экрана (`true`/`false` в файл): прозрачная
///   часть окна острова должна пропускать клики;
/// - `notch:<ширина>,<высота>` — подменить геометрию экрана острова: вырез заданной ширины по середине экрана,
///   полоса заданной высоты; `notch:none[,<высота строки меню>]` — экран без выреза (без высоты —
///   `NSStatusBar.system.thickness`); `notch:off` — снова настоящая. Остров переставляется тем же путём,
///   что и при смене параметров экрана;
/// - `submit:<текст>` — отправить запрос с текущим контекстом и выбранной в панели моделью;
///   `submitModel:<модель>:<текст>` — то же с указанной моделью в обход списка (проверка ответа ядра на плохое значение);
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
///   корневое `island` — размер тела фигуры острова (без плеч);
///   в `panel`: `frame` — рамка окна острова, `island` — рамка тела фигуры без плеч (по ней ловятся наведение
///   и клики), `notch` — геометрия экрана острова (`width` — ширина выреза, 0 — выреза нет; `bar` — высота
///   полосы; `center` — середина выреза по x; `override` — подменена ли командой `notch:`), `screen` — рамка
///   этого экрана; всё в координатах экрана; `wings` — раскладка pill: `left` и `right` — ширины крыльев,
///   `gap` — промежуток над вырезом (без выреза — 0), `offset` — сдвиг середины тела от середины выреза;
///   в покое крылья — запас покоя; `correction` — поправка на округление окна (`center` − середина окна);
///   `clipped` — сколько раз с запуска тело острова с плечами получило размер (начало роста или сжатия),
///   не помещавшийся в окно: фигура обрезалась бы окном; должно быть 0;
///   `snapshot:<путь>` — PNG панели;
/// - `quit` — то же, что «Выйти из Luna» в меню.
///
/// Перед командой можно поставить `@<pid>:` — её выполнит только процесс с этим pid. Так проверка выхода
/// не гасит чужую debug-сборку: уведомление получают все запущенные.
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
            guard var command = notification.object as? String else { return }
            if command.hasPrefix("@") {
                let target = command.dropFirst().prefix { $0 != ":" }
                guard target == String(ProcessInfo.processInfo.processIdentifier) else { return }
                command = String(command.dropFirst(target.count + 2))
            }
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
        case "notch":
            let fields = argument.split(separator: ",").map(String.init)
            switch fields.first {
            case "off": panels.debugSetNotch(nil)
            case "none":
                let height = fields.count > 1 ? Double(fields[1]).map { CGFloat($0) } : nil
                panels.debugSetNotch(.flat(barHeight: height))
            default:
                let numbers = fields.compactMap(Double.init)
                if numbers.count == 2 { panels.debugSetNotch(.notch(width: numbers[0], barHeight: numbers[1])) }
            }
        case "click":
            let numbers = argument.split(separator: ",").compactMap { Double($0) }
            if numbers.count == 2 { panels.debugClick(dx: numbers[0], dy: numbers[1]) }
        case "settings": state.openSettings()
        case "settingsTab": settings.debugSelect(tab: argument)
        case "settingsModelDraft": settings.debugSetModelDraft(argument)
        case "settingsClose": settings.debugClose()
        case "settingsKey":
            if let (keyCode, modifiers) = keyStroke(argument) {
                settings.debugKeyDown(keyCode: keyCode, characters: keyCharacters[keyCode] ?? "", modifiers: modifiers)
            }
        case "islandMenu":
            try? panels.debugMenuTitles.joined(separator: "\n").write(toFile: argument, atomically: true, encoding: .utf8)
        case "rightClick":
            let fields = argument.split(separator: ":", maxSplits: 1)
            let numbers = fields.first?.split(separator: ",").compactMap { Double($0) } ?? []
            guard fields.count == 2, numbers.count == 2 else { return }
            panels.debugRightClick(dx: numbers[0], dy: numbers[1], after: 1) {
                writeDump(to: String(fields[1]), state: state, panels: panels, windows: windows, settings: settings)
            }
        case "settingsSnapshot":
            try? settings.debugSnapshot()?.write(to: URL(fileURLWithPath: argument))
        case "set":
            let fields = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if fields.count == 2 {
                if fields[0] == "followUpModel" { state.selectFollowUpModel(fields[1].isEmpty ? nil : fields[1]) }
                else { set(fields[0], to: fields[1], in: state.settings) }
            }
        case "submitModel":
            let fields = argument.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2 else { return }
            state.draft = fields[1]
            state.submit(model: fields[0])
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
            guard let (keyCode, modifiers) = keyStroke(argument) else { return }
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
            writeDump(to: argument, state: state, panels: panels, windows: windows, settings: settings)
        case "snapshot":
            try? panels.debugSnapshot()?.write(to: URL(fileURLWithPath: argument))
        case "quit":
            NSApp.terminate(nil)
        default: break
        }
    }

    private static func writeDump(
        to path: String, state: AppState, panels: PanelController, windows: DialogWindows, settings: SettingsWindow
    ) {
        let dump = Dump(
            state: state, panel: panels.debugPanelInfo, windows: windows.debugWindows,
            agentWindows: windows.debugAgentWindows, settingsVisible: settings.debugIsVisible, sounds: sounds
        )
        try? JSONEncoder.pretty.encode(dump).write(to: URL(fileURLWithPath: path))
    }

    /// «cmd+shift+51» — код клавиши и модификаторы; nil, если запись не разобралась.
    private static func keyStroke(_ text: String) -> (UInt16, NSEvent.ModifierFlags)? {
        var names = text.split(separator: "+").map(String.init)
        guard let keyCode = names.popLast().flatMap(UInt16.init) else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for name in names {
            switch name {
            case "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            default: return nil
            }
        }
        return (keyCode, modifiers)
    }

    private static func set(_ name: String, to value: String, in settings: LunaSettings) {
        switch name {
        case "islandMode": if let mode = IslandMode(rawValue: value) { settings.islandMode = mode }
        case "hoverPeek": settings.hoverPeek = value == "true"
        case "pillAvatars": settings.pillAvatars = value == "true"
        case "pillText": settings.pillText = value == "true"
        case "animateAvatars": settings.animateAvatars = value == "true"
        case "soundsEnabled": settings.soundsEnabled = value == "true"
        case "soundVolume": if let volume = Double(value) { settings.soundVolume = min(1, max(0, volume)) }
        case "tint": if let tint = AvatarTint(rawValue: value) { settings.tint = tint }
        case "accessory": if let accessory = AvatarAccessory(rawValue: value) { settings.accessory = accessory }
        case "model": settings.setModel(value.isEmpty ? nil : value, for: ExecutorId.claudeCode.rawValue)
        case "defaultModel": settings.setDefaultModel(value.isEmpty ? nil : value, for: ExecutorId.claudeCode.rawValue)
        case "models":
            settings.setModels(value.split(separator: ",", omittingEmptySubsequences: false).map(String.init), for: ExecutorId.claudeCode.rawValue)
        default:
            if name.hasPrefix("sound."), let event = SoundEvent(rawValue: String(name.dropFirst(6))) {
                settings.setSound(value.isEmpty ? nil : value, for: event)
            }
        }
    }

    /// Символы, которые оконный сервер кладёт в событие для клавиш: esc, ↩, ↓, ↑, Tab, ⌫, «a», «c» и «q» (для ⌘A, ⌘C, ⌘Q).
    private static let keyCharacters: [UInt16: String] = [
        53: "\u{1B}", 36: "\r", 125: "\u{F701}", 126: "\u{F700}", 48: "\t", 51: "\u{7F}", 0: "a", 8: "c", 12: "q",
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
        /// Модель, на которой уйдёт уточнение открытой карточки: выбранная или модель точки продолжения; пусто — «Модель CLI».
        let followUpModel: String
        /// Пункты меню выбора модели у поля продолжения: группы между разделителями, название пункта.
        let followUpMenu: [[String]]
        let dialogs: [DialogDump]
        let unseen: [String]
        let pill: String
        /// Фраза развёрнутого pill; nil — pill свёрнут в полоску.
        let pillText: String?
        /// Счётчики шторки: род и число.
        let chips: [String]
        /// Размер видимой части острова — тело фигуры без плеч.
        let island: String
        let agents: [AgentSession]
        let finishedAgents: [String]
        let selectedAgentId: String?
        let agentSteps: Int
        /// Настройки пользователя и окно настроек. `model` — предвыбор панели ввода (последний выбор, иначе умолчание;
        /// пусто — «Модель CLI»), `defaultModel` — умолчание из настроек (пусто — «Модель CLI»).
        let settings: [String: String]
        /// Действующий список моделей панели ввода и поля продолжения.
        let models: [String]
        /// Какую модель показывают задачам: `TaskInfo.model` по id задачи.
        let taskModels: [String: String]
        let settingsVisible: Bool
        /// Какие звуки Luna проиграла бы с запуска, по порядку.
        let sounds: [String]
        let problem: String?
        let accessibilityTrusted: Bool
        let captureMs: Int?
        let panel: [String: String]
        /// Таймер оживлений шторки: заведён, только пока шторка показана.
        let motion: [String: String]
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
            let shownDialog = state.shownThreadId.flatMap { state.dialog(threadId: $0) }
            let choice = shownDialog.map(state.followUpChoice)
            followUpModel = choice?.shown ?? ""
            followUpMenu = choice?.sections(models: state.settings.models(for: ExecutorId.claudeCode.rawValue)).map { $0.map(\.title) } ?? []
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
                "islandMode": state.settings.islandMode.rawValue,
                "hoverPeek": String(state.settings.hoverPeek),
                "pillAvatars": String(state.settings.pillAvatars),
                "pillText": String(state.settings.pillText),
                "animateAvatars": String(state.settings.animateAvatars),
                "soundsEnabled": String(state.settings.soundsEnabled),
                "soundVolume": String(state.settings.soundVolume),
                "tint": state.settings.tint.rawValue,
                "accessory": state.settings.accessory.rawValue,
            ]
            values["model"] = state.selectedModel ?? ""
            values["defaultModel"] = state.settings.defaultModel(for: ExecutorId.claudeCode.rawValue) ?? ""
            for event in SoundEvent.allCases { values["sound.\(event.rawValue)"] = state.settings.sound(for: event) ?? "" }
            settings = values
            models = state.settings.models(for: ExecutorId.claudeCode.rawValue)
            taskModels = Dictionary(uniqueKeysWithValues: state.tasks.compactMap { task in task.model.map { (task.id, $0) } })
            self.settingsVisible = settingsVisible
            self.sounds = sounds
            problem = state.problem
            accessibilityTrusted = AccessibilityProbe.isTrusted
            captureMs = state.lastCaptureDuration.map { Int($0 / .milliseconds(1)) }
            self.panel = panel
            motion = ["timer": String(MotionGate.shared.isScheduling)]
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
