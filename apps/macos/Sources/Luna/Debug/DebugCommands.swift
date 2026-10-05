#if DEBUG
import AppKit

/// Управление панелями из скрипта в debug-сборке — для проверки UI без симуляции нажатий
/// (она требует прав Accessibility). Команда передаётся в `object` уведомления `dev.luna.debug`,
/// см. scripts/debug-command.sh:
///
/// - `toggleInput`, `lastResult`, `tasks`, `collapse`, `pillClick` — то же, что хоткеи и клик по pill;
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

    static func install(state: AppState, panels: PanelController, windows: DialogWindows) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.luna.debug"), object: nil, queue: .main
        ) { notification in
            guard let command = notification.object as? String else { return }
            MainActor.assumeIsolated { run(command, state: state, panels: panels, windows: windows) }
        }
    }

    private static func run(_ command: String, state: AppState, panels: PanelController, windows: DialogWindows) {
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
            try? JSONEncoder.pretty.encode(Dump(state: state, panel: panels.debugPanelInfo, windows: windows.debugWindows))
                .write(to: URL(fileURLWithPath: argument))
        case "snapshot":
            try? panels.debugSnapshot()?.write(to: URL(fileURLWithPath: argument))
        case "quit":
            NSApp.terminate(nil)
        default: break
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
        let problem: String?
        let accessibilityTrusted: Bool
        let captureMs: Int?
        let panel: [String: String]
        /// Окна «Открыть полностью»: диалог, рамка, видимость, ключевое ли.
        let windows: [DialogWindows.DebugWindow]
        /// Bundle id активного приложения: окна и панели Luna не должны его менять.
        let frontmostApp: String?
        let tasks: [TaskInfo]

        @MainActor
        init(state: AppState, panel: [String: String], windows: [DialogWindows.DebugWindow]) {
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
            problem = state.problem
            accessibilityTrusted = AccessibilityProbe.isTrusted
            captureMs = state.lastCaptureDuration.map { Int($0 / .milliseconds(1)) }
            self.panel = panel
            self.windows = windows
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
