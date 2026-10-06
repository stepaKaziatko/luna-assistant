import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum Mode: Equatable {
        case pill
        /// Блок, выехавший из шторки под курсором: агенты и диалоги. Клавиатуру не забирает.
        case peek
        case input
        case tasks
        /// Карточка диалога: все его задачи, внизу — поле продолжения.
        case result(threadId: String)
        /// Сессии агентов, запущенные не Luna: в редакторах и терминалах.
        case agents
        /// Одна сессия: что агент делает сейчас и переход к её окну.
        case agent(sessionId: String)
    }

    @Published private(set) var mode: Mode = .pill {
        didSet {
            guard mode != oldValue else { return }
            presence.panelChanged(from: oldValue, to: mode, now: clock())
            syncPresence()
            modeDidChange(mode)
        }
    }
    /// Режим уже записан, остров ещё не перерисован: панель ставит окно раскрытого острова до первого кадра
    /// роста фигуры. `$mode` для этого не годится — он публикует до записи.
    var modeDidChange: (Mode) -> Void = { _ in }
    @Published var draft = ""
    /// В порядке создания.
    @Published private(set) var tasks: [TaskInfo] = []
    /// Завершённые задачи, результат которых пользователь ещё не открывал.
    @Published private(set) var unseen: Set<String> = []
    /// Неполадка ядра или исполнителя; показывается в панели ввода.
    @Published var problem: String?
    /// Контекст, снятый при последнем вызове панели ввода.
    @Published private(set) var context: CapturedContext?
    /// Диалог, выбранный в списке задач с клавиатуры.
    @Published private(set) var selectedThreadId: String?
    /// Текст поля «Продолжить диалог…» — свой, не общий с черновиком панели ввода.
    @Published var followUpDraft = ""
    /// Модель, которую пользователь выбрал для уточнения в карточке; nil — не менял. «Последний выбор»
    /// панели ввода (`LunaSettings`) он не трогает и живёт, пока не отправлено уточнение или не сменился диалог.
    @Published private(set) var followUpModel: String?
    /// Почему уточнение не отправилось; показывается в карточке под полем.
    @Published private(set) var followUpError: String?
    /// Пока ядро не ответило на отправку уточнения, поле скрыто: второе уточнение ядро отклонит.
    @Published private(set) var isSendingFollowUp = false
    /// Растёт, когда поле продолжения должно получить фокус (`Tab` в карточке).
    @Published private(set) var followUpFocusRequest = 0
    @Published private(set) var accessibilityHintHidden = UserDefaults.standard.bool(forKey: hideAccessibilityHintKey)
    /// Текст поля поиска в списке задач; каждое изменение уходит запросом к ядру.
    @Published var searchQuery = "" {
        didSet { if searchQuery != oldValue { search() } }
    }
    /// Ответ ядра на последний поиск: совпавшие задачи с их диалогами. nil — поиска нет.
    @Published private(set) var searchResults: [TaskInfo]?
    /// Первый клик по «Очистить историю» ждёт подтверждения вторым.
    @Published private(set) var clearConfirming = false
    /// Подсказка или ошибка в списке задач: удаление активного диалога, сбой ядра.
    @Published private(set) var listMessage: String?
    /// Диалоги, открытые в отдельных окнах («Открыть полностью»), в порядке открытия; одно окно на диалог.
    /// Окна живут отдельно от карточки: сворачивание и список задач их не трогают.
    @Published private(set) var openWindows: [String] = []
    /// Повторное «Открыть полностью» у диалога с открытым окном: окно поднимается, второе не создаётся.
    let windowRaised = PassthroughSubject<String, Never>()

    /// Живые сессии агентов в порядке ядра: по проектам, внутри проекта — по времени старта.
    @Published private(set) var agents: [AgentSession] = []
    /// Сессии, закончившие ход, пока пользователь на них не смотрел.
    @Published private(set) var finishedAgents: Set<String> = []
    /// Сессия, выбранная в списке агентов с клавиатуры.
    @Published private(set) var selectedAgentId: String?
    /// Последние шаги сессии открытой карточки агента, старые первыми.
    @Published private(set) var agentSteps: [AgentStep] = []
    /// Сессии, открытые в отдельных окнах, в порядке открытия; одно окно на сессию.
    @Published private(set) var agentWindows: [String] = []
    /// Подробные ленты сессий, открытых в окнах.
    @Published private(set) var agentTranscripts: [String: [AgentStep]] = [:]
    /// Последнее известное состояние сессий, открытых в окнах: окно переживает конец сессии.
    @Published private(set) var agentWindowSessions: [String: AgentSession] = [:]
    /// Повторное «В окне» у сессии с открытым окном: окно поднимается, второе не создаётся.
    let agentWindowRaised = PassthroughSubject<String, Never>()
    /// Размер видимой части острова — тело фигуры без плеч; по нему панель знает, что на экране.
    @Published var islandSize = IslandLayout.make(
        notchWidth: IslandPlacement.unplaced.notch.notchWidth, barHeight: IslandPlacement.unplaced.notch.barHeight
    ).body
    /// Где стоит остров: вырез и полоса его экрана, поправка на округление окна. Выставляет панель при расстановке.
    @Published var islandPlacement = IslandPlacement.unplaced {
        didSet { if islandPlacement.notch.hasNotch != oldValue.notch.hasNotch { syncFullscreen() } }
    }
    /// Экран острова показывает полноэкранное приложение. Определяется только на экране с вырезом
    /// (`FullscreenWatch`), в debug-сборке подменяется командой `fullscreen:`; выставляет панель.
    @Published var screenFullscreen = false {
        didSet { if screenFullscreen != oldValue { syncFullscreen() } }
    }
    /// Естественные ширины крыльев pill; замеряет `PillView`.
    @Published var pillWings = PillWings()
    /// Сдвиг тела острова от середины выреза (у pill — разница крыльев, у раскрытого — 0). Выставляет `RootView`
    /// вместе с `islandSize`: панель опрашивает рамку острова на каждом движении курсора, и пересчитывать
    /// раскладку там незачем.
    @Published var islandBodyOffset: CGFloat = 0
    /// Должна ли шторка быть на экране: в «Всегда» — да, в «В фоне» — по событию и пока открыта панель.
    /// Решает `IslandPresence`; панель исполняет.
    @Published private(set) var islandShown: Bool
    /// Остров на экране в полной силе: его выставляет панель, когда окно уже показано, а убирает — когда
    /// начинает прятать. От него зависят плавное появление и скрытие.
    @Published var islandPresented: Bool

    let settings: LunaSettings
    var core: CoreRequesting?
    /// Переход к окну сессии; в тестах подменяется.
    var jump: (AgentSession) -> Void = AgentJump.open
    /// Звук события; настройки звука проверяет проигрыватель. Без него (тесты) Luna молчит.
    /// Из логики состояния его зовёт только `notify`.
    var playSound: (SoundEvent) -> Void = { _ in }
    /// Время для отсчёта паузы шторки; в тестах подменяется.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Открывает окно настроек.
    var showSettings: () -> Void = {}
    /// Событие, на которое свёрнутая шторка отзывается коротким оживлением аватаров.
    var enliven: () -> Void = {}

    private var capture: _Concurrency.Task<CapturedContext.Details, Never>?
    /// Сколько занял последний захват контекста — для диагностики.
    private(set) var lastCaptureDuration: Duration?
    private var captureGeneration = 0
    /// Ответ на поиск, пришедший после ответа на более новый запрос, отбрасывается.
    private var searchGeneration = 0
    private var stepsGeneration = 0
    private var transcriptGenerations: [String: Int] = [:]
    /// Первый список сессий — не новость: о том, что было до запуска Luna, звук не сообщает.
    private var agentsLoaded = false
    private var presence: IslandPresence
    private var presenceSubscription: AnyCancellable?

    init(settings: LunaSettings? = nil) {
        let settings = settings ?? LunaSettings()
        self.settings = settings
        presence = IslandPresence(mode: settings.islandMode)
        islandShown = presence.isShown
        islandPresented = presence.isShown
        // Переключение действует сразу. `$islandMode` публикует значение до записи, поэтому берём пришедшее.
        presenceSubscription = settings.$islandMode.dropFirst().removeDuplicates().sink { [weak self] mode in
            MainActor.assumeIsolated { self?.setIslandMode(mode) }
        }
    }

    // MARK: - Показ шторки

    /// Событие, о котором Luna сообщает: звук (его решает проигрыватель по настройкам) и показ шторки
    /// в режиме «В фоне». Список событий один — `SoundEvent`; настройки звука на показ не влияют.
    func notify(_ event: SoundEvent) {
        playSound(event)
        presence.event(now: clock())
        syncPresence()
    }

    /// Очередной опрос курсора: над шторкой он или нет.
    func pointerMoved(overIsland inside: Bool) {
        presence.update(pointerInside: inside, now: clock())
        syncPresence()
    }

    private func setIslandMode(_ mode: IslandMode) {
        presence.setMode(mode, panel: self.mode, now: clock())
        syncPresence()
    }

    /// Крылья свёрнутого острова не раскрываются: экран с вырезом показывает полноэкранное приложение.
    var wingsSuppressed: Bool {
        CollapsedIsland.wingsSuppressed(hasNotch: islandPlacement.notch.hasNotch, fullscreen: screenFullscreen)
    }

    /// Что видно у свёрнутого острова: скрыт, покой или крылья.
    var collapsedIsland: CollapsedIsland {
        CollapsedIsland.make(
            shown: islandShown, hasNotch: islandPlacement.notch.hasNotch, fullscreen: screenFullscreen,
            hasEvents: pillPresentation != nil
        )
    }

    private func syncFullscreen() {
        presence.setOverFullscreen(wingsSuppressed)
        syncPresence()
    }

    private func syncPresence() {
        if islandShown != presence.isShown { islandShown = presence.isShown }
    }

    var pillState: PillState {
        PillState.aggregate(tasks: tasks, unseen: unseen, hasProblem: problem != nil)
    }

    var agentsSummary: AgentsSummary {
        AgentsSummary(sessions: agents, finished: finishedAgents)
    }

    /// Что показывает развёрнутая шторка; nil — показывать нечего.
    var pillPresentation: PillPresentation? {
        PillPresentation.make(tasks: pillState, taskProgress: tasks.last { $0.isActive }?.progress, agents: agentsSummary)
    }

    /// Что показывают крылья свёрнутого острова; nil — крыльев нет: показывать нечего или остров стоит
    /// над полноэкранным приложением (`wingsSuppressed`).
    var shownPillPresentation: PillPresentation? {
        wingsSuppressed ? nil : pillPresentation
    }

    /// Раскладка свёрнутого острова: крылья вокруг выреза, когда они видны, иначе покой.
    var pillLayout: IslandLayout {
        let notch = islandPlacement.notch
        let wings = shownPillPresentation == nil ? PillWings() : pillWings
        return IslandLayout.make(notchWidth: notch.notchWidth, barHeight: notch.barHeight, left: wings.left, right: wings.right)
    }

    /// Счётчики шторки и блока под курсором.
    var statusChips: [StatusChip] {
        StatusChip.make(tasks: tasks, unseen: unseen, hasProblem: problem != nil, agents: agentsSummary)
    }

    /// Диалоги блока под курсором: самые свежие.
    var peekDialogs: [Dialog] {
        Array(Dialog.group(tasks).prefix(Self.peekDialogLimit))
    }

    static let peekDialogLimit = 4

    /// Плитки сессий блока под курсором: не больше двух рядов.
    var peekAgents: (shown: [AgentSession], hidden: Int) {
        AgentsSummary.peek(agents, finished: finishedAgents, limit: 2 * Self.agentColumns)
    }

    func agent(id: String) -> AgentSession? {
        agents.first { $0.id == id }
    }

    /// Сессия открытой карточки агента.
    var shownAgentId: String? {
        if case .agent(let sessionId) = mode { sessionId } else { nil }
    }

    /// Диалоги в порядке показа в списке: новые сверху. При поиске — найденные; задачи, которые
    /// уже известны оболочке, показываются в свежем состоянии, вместе с новыми задачами их диалогов.
    var listedDialogs: [Dialog] {
        guard let searchResults else { return Dialog.group(tasks) }
        let threads = Set(searchResults.map(\.threadId))
        let known = tasks.filter { threads.contains($0.threadId) }
        let knownIds = Set(known.map(\.id))
        return Dialog.group(known + searchResults.filter { !knownIds.contains($0.id) })
    }

    /// Поиск идёт: в поле есть что-то кроме пробелов.
    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// «Очистить историю» — при пустом поиске и хотя бы одном диалоге без активной задачи.
    var canClearHistory: Bool {
        !isSearching && Dialog.group(tasks).contains { $0.activeTask == nil }
    }

    func task(id: String) -> TaskInfo? {
        tasks.first { $0.id == id }
    }

    func dialog(threadId: String) -> Dialog? {
        let thread = tasks.filter { $0.threadId == threadId }
        return thread.isEmpty ? nil : Dialog.group(thread).first
    }

    /// Диалог открытой карточки.
    var shownThreadId: String? {
        if case .result(let threadId) = mode { threadId } else { nil }
    }

    // MARK: - Панели

    /// Повторное нажатие хоткея при открытой панели закрывает её.
    func toggleInput() {
        if mode == .input {
            collapse()
        } else {
            openInput()
        }
    }

    func toggleTasks() {
        if mode == .tasks {
            collapse()
        } else {
            showTasks()
        }
    }

    func toggleLastResult() {
        if case .result = mode {
            collapse()
        } else {
            openLastResult()
        }
    }

    func collapse() {
        resetList()
        mode = .pill
    }

    /// Курсор задержался над шторкой. Раскрытую карточку блок не подменяет.
    func openPeek() {
        if mode == .pill { mode = .peek }
    }

    /// Курсор ушёл с блока.
    func closePeek() {
        if mode == .peek { collapse() }
    }

    func openSettings() {
        collapse()
        showSettings()
    }

    /// Список открывается с пустым поиском, без подсказок и неподтверждённой очистки.
    func showTasks() {
        resetList()
        selectedThreadId = listedDialogs.first?.threadId
        mode = .tasks
    }

    private func resetList() {
        searchQuery = ""
        clearConfirming = false
        listMessage = nil
    }

    /// Открывает самый свежий непросмотренный результат, а если таких нет — последнюю задачу.
    func openLastResult() {
        guard let task = tasks.last(where: { unseen.contains($0.id) }) ?? tasks.last else {
            openInput()
            return
        }
        show(threadId: task.threadId)
    }

    func open(threadId: String) {
        // Найденный диалог мог быть не загружен: его задачи вливаются как история, без «непросмотренных».
        if let found = searchResults?.filter({ $0.threadId == threadId }), !found.isEmpty {
            tasks = TaskHistory.merge(current: tasks, listed: found)
        }
        guard dialog(threadId: threadId) != nil else { return }
        show(threadId: threadId)
    }

    /// Клик по pill ведёт к тому, что требует внимания: к единственному диалогу или агенту,
    /// к списку или к вводу. Порядок тот же, что у pill: сначала то, что ждёт человека.
    func pillClicked() {
        var attention: [String] = []
        for task in tasks where (unseen.contains(task.id) || task.isActive) && !attention.contains(task.threadId) {
            attention.append(task.threadId)
        }
        let summary = agentsSummary
        let calling = summary.waiting + summary.finished
        if case .error = pillState, !attention.isEmpty {
            attention.count == 1 ? show(threadId: attention[0]) : showTasks()
        } else if !calling.isEmpty {
            calling.count == 1 ? openAgent(id: calling[0].id) : showAgents()
        } else if !attention.isEmpty {
            attention.count == 1 ? show(threadId: attention[0]) : showTasks()
        } else if !agents.isEmpty {
            showAgents()
        } else {
            openInput()
        }
    }

    func moveSelection(by offset: Int) {
        let list = listedDialogs
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.threadId == selectedThreadId } ?? -1
        selectedThreadId = list[min(max(current + offset, 0), list.count - 1)].threadId
    }

    func openSelectedTask() {
        if let selectedThreadId { open(threadId: selectedThreadId) }
    }

    // MARK: - Агенты

    func toggleAgents() {
        switch mode {
        case .agents, .agent: collapse()
        default: showAgents()
        }
    }

    /// Список открывается на сессии, которая зовёт человека, а если таких нет — на первой.
    func showAgents() {
        resetList()
        let summary = agentsSummary
        if selectedAgentId.flatMap(agent(id:)) == nil || !summary.waiting.isEmpty {
            selectedAgentId = (summary.waiting.first ?? summary.finished.first ?? agents.first)?.id
        }
        mode = .agents
    }

    func openAgent(id: String) {
        guard agent(id: id) != nil else { return }
        finishedAgents.remove(id)
        selectedAgentId = id
        if shownAgentId != id { agentSteps = [] }
        mode = .agent(sessionId: id)
        refreshAgentSteps()
    }

    /// Сколько плиток в ряду сетки агентов.
    static let agentColumns = 4

    func moveAgentSelection(by offset: Int) {
        guard !agents.isEmpty else { return }
        let current = agents.firstIndex { $0.id == selectedAgentId } ?? -1
        selectedAgentId = agents[min(max(current + offset, 0), agents.count - 1)].id
    }

    /// Выбор на ряд ниже или выше. Под плиткой неполного последнего ряда пусто — выбор встаёт
    /// на последнюю плитку; за края сетки он не уходит.
    func moveAgentSelection(byRows rows: Int) {
        guard !agents.isEmpty else { return }
        guard let current = agents.firstIndex(where: { $0.id == selectedAgentId }) else {
            selectedAgentId = agents[0].id
            return
        }
        let last = agents.count - 1
        var target = current + rows * Self.agentColumns
        if target > last, current / Self.agentColumns < last / Self.agentColumns { target = last }
        if (0...last).contains(target) { selectedAgentId = agents[target].id }
    }

    /// Поднимает окно, в котором идёт сессия; остров сворачивается — дальше пользователь работает там.
    func jumpToAgent(id: String) {
        guard let session = agent(id: id) else { return }
        finishedAgents.remove(id)
        collapse()
        jump(session)
    }

    /// Клавиши списка и карточки агента: в них нет полей ввода, все нажатия — команды.
    func handleAgentKey(keyCode: UInt16, command: Bool) -> Bool {
        switch (mode, keyCode, command) {
        case (.agents, 124, false): moveAgentSelection(by: 1)
        case (.agents, 123, false): moveAgentSelection(by: -1)
        case (.agents, 125, false): moveAgentSelection(byRows: 1)
        case (.agents, 126, false): moveAgentSelection(byRows: -1)
        case (.agents, 36, false), (.agents, 76, false):
            if let selectedAgentId { openAgent(id: selectedAgentId) }
        case (.agents, 36, true), (.agents, 76, true):
            if let selectedAgentId { jumpToAgent(id: selectedAgentId) }
        case (.agents, 53, _): collapse()
        case (.agent(let id), 36, _), (.agent(let id), 76, _): jumpToAgent(id: id)
        // Пробел — как у «Быстрого просмотра»: то же самое, но в окне.
        case (.agent(let id), 49, false): openAgentWindow(id: id)
        case (.agent, 53, _), (.agent, 123, false), (.agent, 51, false): showAgents()
        default: return false
        }
        return true
    }

    /// Применяет полный список сессий из ответа или уведомления ядра.
    func applyAgents(_ sessions: [AgentSession]) {
        let previous = Dictionary(agents.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        // Один звук на список: тот, кто зовёт человека, важнее закончившего ход.
        var cue: SoundEvent?
        for session in sessions {
            let before = previous[session.id]
            // Открытая карточка сессии видна сразу — ни новостью, ни поводом для звука она не становится.
            let isShown = shownAgentId == session.id
            if session.state != .idle {
                finishedAgents.remove(session.id)
                if session.state == .waiting, before != .waiting, agentsLoaded, !isShown { cue = .attention }
            } else if let before, before != .idle, !isShown {
                finishedAgents.insert(session.id)
                cue = cue ?? .finished
            }
        }
        agentsLoaded = true
        if let cue { notify(cue) }
        if previous != Dictionary(sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first }) { enliven() }
        let live = Set(sessions.map(\.id))
        finishedAgents.formIntersection(live)
        let changed = shownAgentId.flatMap { id in sessions.first { $0.id == id } } != shownAgentId.flatMap(agent(id:))
        // Окна сессий следуют за своими сессиями; у завершившейся остаётся последнее состояние.
        for session in sessions where agentWindows.contains(session.id) && agentWindowSessions[session.id] != session {
            agentWindowSessions[session.id] = session
            refreshAgentTranscript(session.id)
        }
        agents = sessions

        if let selectedAgentId, !live.contains(selectedAgentId) { self.selectedAgentId = sessions.first?.id }
        if let shownAgentId {
            // Сессия открытой карточки завершилась — возвращаемся к списку.
            if !live.contains(shownAgentId) { showAgents() } else if changed { refreshAgentSteps() }
        }
    }

    /// Шаги запрашиваются при открытии карточки и при каждом изменении её сессии.
    private func refreshAgentSteps() {
        guard let sessionId = shownAgentId, let core else { return }
        stepsGeneration += 1
        let generation = stepsGeneration
        _Concurrency.Task {
            let params = AgentStepsParams(detail: nil, sessionId: sessionId)
            guard let response: AgentStepsResult = try? await core.request("agents.steps", params),
                  generation == stepsGeneration, shownAgentId == sessionId else { return }
            agentSteps = response.steps
        }
    }

    // MARK: - Окна сессий

    /// Сессия в отдельном окне: подробная лента рядом с работой. Остров сворачивается — окно его заменяет.
    func openAgentWindow(id: String) {
        guard let session = agent(id: id) else { return }
        finishedAgents.remove(id)
        if agentWindows.contains(id) {
            agentWindowRaised.send(id)
        } else {
            agentWindowSessions[id] = session
            agentWindows.append(id)
            refreshAgentTranscript(id)
        }
        collapse()
    }

    func closeAgentWindow(id: String) {
        agentWindows.removeAll { $0 == id }
        agentTranscripts[id] = nil
        agentWindowSessions[id] = nil
        transcriptGenerations[id] = nil
    }

    /// Подробная лента запрашивается при открытии окна и при каждом изменении его сессии.
    private func refreshAgentTranscript(_ sessionId: String) {
        guard let core else { return }
        let generation = (transcriptGenerations[sessionId] ?? 0) + 1
        transcriptGenerations[sessionId] = generation
        _Concurrency.Task {
            let params = AgentStepsParams(detail: true, sessionId: sessionId)
            guard let response: AgentStepsResult = try? await core.request("agents.steps", params),
                  transcriptGenerations[sessionId] == generation, agentWindows.contains(sessionId) else { return }
            agentTranscripts[sessionId] = response.steps
        }
    }

    // MARK: - Окна «Открыть полностью»

    func openWindow(threadId: String) {
        guard dialog(threadId: threadId) != nil else { return }
        if openWindows.contains(threadId) {
            windowRaised.send(threadId)
        } else {
            openWindows.append(threadId)
        }
    }

    func closeWindow(threadId: String) {
        openWindows.removeAll { $0 == threadId }
    }

    /// Выбор модели уточнения у диалога: модель точки продолжения и то, что пользователь поменял.
    func followUpChoice(for dialog: Dialog) -> FollowUpModelChoice {
        FollowUpModelChoice(pointModel: dialog.continuationPoint?.model, selection: followUpModel)
    }

    /// Выбор в элементе у поля продолжения. Модель точки — то же, что «не менял».
    func selectFollowUpModel(_ model: String?) {
        guard let threadId = shownThreadId, let point = dialog(threadId: threadId)?.continuationPoint else { return }
        followUpModel = model == FollowUpModelChoice(pointModel: point.model, selection: nil).shown ? nil : model
    }

    /// `Tab` в карточке: фокус в поле продолжения, если диалог можно продолжить.
    func focusFollowUp() -> Bool {
        guard let shownThreadId, dialog(threadId: shownThreadId)?.continuationPoint != nil else { return false }
        followUpFocusRequest += 1
        return true
    }

    private func openInput() {
        beginCapture()
        mode = .input
    }

    private func show(threadId: String) {
        unseen.subtract(tasks.filter { $0.threadId == threadId }.map(\.id))
        if shownThreadId != threadId {
            // Набранное уточнение принадлежит своему диалогу.
            followUpDraft = ""
            followUpError = nil
            followUpModel = nil
        }
        mode = .result(threadId: threadId)
    }

    // MARK: - Контекст

    /// Приложение известно сразу; страница и выделение дочитываются, пока панель уже на экране.
    private func beginCapture() {
        captureGeneration += 1
        let generation = captureGeneration
        guard let target = ContextCapture.frontmostApp() else {
            context = nil
            capture = nil
            return
        }
        context = CapturedContext(app: target.app)
        let pending = _Concurrency.Task { await ContextCapture.details(for: target) }
        capture = pending
        let started = ContinuousClock.now
        _Concurrency.Task {
            let details = await pending.value
            lastCaptureDuration = ContinuousClock.now - started
            // Панель могли вызвать заново, пока шёл захват.
            if generation == captureGeneration { context?.details = details }
        }
    }

    func dismissSource() {
        context?.sourceDismissed = true
    }

    func dismissSelection() {
        context?.selectionDismissed = true
    }

    /// Разрешения, которых не хватило последнему захвату, кроме подсказок, скрытых пользователем.
    var captureIssues: [CaptureIssue] {
        (context?.details.issues ?? []).filter { $0 != .accessibility || !accessibilityHintHidden }
    }

    func resolve(_ issue: CaptureIssue) {
        switch issue {
        case .accessibility: AccessibilityProbe.requestTrust()
        case .automation: AccessibilityProbe.openSettings(pane: "Privacy_Automation")
        }
    }

    func hideAccessibilityHint() {
        accessibilityHintHidden = true
        UserDefaults.standard.set(true, forKey: Self.hideAccessibilityHintKey)
    }

    private static let hideAccessibilityHintKey = "hideAccessibilityHint"

    // MARK: - Задачи

    /// Модель, на которой уйдёт следующий вопрос: предвыбор панели ввода (последний выбор, иначе умолчание из настроек); nil — «Модель CLI».
    var selectedModel: String? { settings.model(for: ExecutorId.claudeCode.rawValue) }

    func submit() {
        submit(model: selectedModel)
    }

    /// `model` — значение для `TaskSubmitParams.model`; nil — поле не передаётся.
    func submit(model: String?) {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard let core else {
            problem = problem ?? CoreClientError.notRunning.localizedDescription
            return
        }
        var captured = context
        let pending = capture
        draft = ""
        collapse()

        _Concurrency.Task {
            do {
                // Быстрая отправка может обогнать захват; он ограничен таймаутами, поэтому дожидаемся.
                if let pending, captured != nil { captured?.details = await pending.value }
                let params = TaskSubmitParams(context: captured?.payload, executor: nil, followUpOf: nil, model: model, prompt: prompt)
                let response: TaskSubmitResult = try await core.request("task.submit", params)
                // События задачи могли прийти раньше ответа — снимок из ответа их не перезаписывает.
                if task(id: response.task.id) == nil { apply(response.task) }
            } catch {
                draft = prompt
                problem = error.localizedDescription
            }
        }
    }

    /// Отправляет уточнение к диалогу открытой карточки. Карточка остаётся открытой и показывает
    /// новую задачу диалога; контекст заново не снимается — диалог о том, с чего начался.
    func submitFollowUp() {
        let prompt = followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSendingFollowUp,
              let threadId = shownThreadId,
              let point = dialog(threadId: threadId)?.continuationPoint else { return }
        guard let core else {
            followUpError = CoreClientError.notRunning.localizedDescription
            return
        }
        let model = FollowUpModelChoice(pointModel: point.model, selection: followUpModel).requestModel
        followUpDraft = ""
        followUpError = nil
        isSendingFollowUp = true

        _Concurrency.Task {
            defer { isSendingFollowUp = false }
            do {
                let params = TaskSubmitParams(context: nil, executor: nil, followUpOf: point.id, model: model, prompt: prompt)
                let response: TaskSubmitResult = try await core.request("task.submit", params)
                if task(id: response.task.id) == nil { apply(response.task) }
                followUpModel = nil
            } catch {
                // Набранный текст не теряется; пока шёл запрос, пользователь мог начать новый.
                if followUpDraft.isEmpty { followUpDraft = prompt }
                followUpError = error.localizedDescription
            }
        }
    }

    /// Отмена из строки списка: отменяется выполняющаяся задача диалога.
    func cancel(threadId: String) {
        if let active = dialog(threadId: threadId)?.activeTask { cancel(taskId: active.id) }
    }

    func cancel(taskId: String) {
        guard let core else { return }
        _Concurrency.Task {
            let _: EmptyResult? = try? await core.request("task.cancel", TaskCancelParams(taskId: taskId))
        }
    }

    // MARK: - Поиск, удаление и очистка

    /// Запрос к ядру — в фоне; пока ответа нет, в списке прежние строки.
    private func search() {
        searchGeneration += 1
        let generation = searchGeneration
        clearConfirming = false
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            selectedThreadId = listedDialogs.first?.threadId
            return
        }
        guard let core else {
            listMessage = problem ?? CoreClientError.notRunning.localizedDescription
            return
        }
        _Concurrency.Task {
            do {
                let response: TaskListResult = try await core.request("task.list", TaskListParams(query: query))
                guard generation == searchGeneration else { return }
                searchResults = response.tasks
                listMessage = nil
                selectedThreadId = listedDialogs.first?.threadId
            } catch {
                guard generation == searchGeneration else { return }
                listMessage = "Поиск не удался: \(error.localizedDescription)"
            }
        }
    }

    /// `⌘⌫` в списке: диалог выбранной строки удаляется целиком, без подтверждения.
    func deleteSelected() {
        guard let threadId = selectedThreadId, let dialog = listedDialogs.first(where: { $0.threadId == threadId }) else { return }
        guard dialog.activeTask == nil else {
            listMessage = "Сначала отмените задачу"
            return
        }
        guard let core else {
            listMessage = problem ?? CoreClientError.notRunning.localizedDescription
            return
        }
        listMessage = nil
        _Concurrency.Task {
            do {
                let response: TaskDeleteResult = try await core.request("task.delete", TaskDeleteParams(taskId: dialog.last.id))
                removeDeleted(response.deleted)
            } catch {
                listMessage = "Не удалось удалить: \(error.localizedDescription)"
            }
        }
    }

    /// Первый клик — подтверждение, второй — удаление всех диалогов без активных задач.
    func clearHistory() {
        guard clearConfirming else {
            clearConfirming = true
            return
        }
        clearConfirming = false
        guard let core else {
            listMessage = problem ?? CoreClientError.notRunning.localizedDescription
            return
        }
        listMessage = nil
        _Concurrency.Task {
            do {
                let response: TaskClearResult = try await core.request("task.clear", NoParams())
                removeDeleted(response.deleted)
            } catch {
                listMessage = "Не удалось удалить: \(error.localizedDescription)"
            }
        }
    }

    /// Убирает ровно то, что удалило ядро; выбор переходит на соседнюю строку.
    func removeDeleted(_ ids: [String]) {
        let deleted = Set(ids)
        guard !deleted.isEmpty else { return }
        let before = listedDialogs
        let index = before.firstIndex { $0.threadId == selectedThreadId } ?? 0
        tasks = TaskHistory.removing(deleted, from: tasks)
        unseen.subtract(deleted)
        searchResults = searchResults.map { TaskHistory.removing(deleted, from: $0) }
        // Окно удалённого диалога закрывается само; окна остальных остаются.
        openWindows.removeAll { dialog(threadId: $0) == nil }
        let after = listedDialogs
        if !after.contains(where: { $0.threadId == selectedThreadId }) {
            selectedThreadId = after.isEmpty ? nil : after[min(index, after.count - 1)].threadId
        }
    }

    /// Клавиши списка задач. Перехватываются раньше поля поиска: стрелки и ↩ не двигают курсор
    /// в поле, `esc` сначала очищает поиск, `⌘⌫` удаляет диалог, а не текст до начала строки.
    func handleListKey(keyCode: UInt16, command: Bool) -> Bool {
        guard mode == .tasks else { return false }
        switch (keyCode, command) {
        case (125, false): moveSelection(by: 1)
        case (126, false): moveSelection(by: -1)
        case (36, false), (76, false): openSelectedTask()
        case (53, _):
            if searchQuery.isEmpty { collapse() } else { searchQuery = "" }
        case (51, true): deleteSelected()
        default: return false
        }
        return true
    }

    /// Применяет снимок задачи из ответа или уведомления ядра.
    func apply(_ task: TaskInfo) {
        let before = self.task(id: task.id)?.status
        if before != task.status { enliven() }
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        // Задача диалога, открытого в карточке, видна сразу — непросмотренной она не становится.
        let isShown = mode == .result(threadId: task.threadId)
        if (task.status == .done || task.status == .failed) && !isShown {
            unseen.insert(task.id)
            // Повторное событие о той же завершённой задаче второй раз не звучит.
            if before != task.status { notify(task.status == .done ? .done : .failure) }
        }
    }

    /// Вливает историю задач после запуска. Задачи истории уже не новость: pill остаётся спокойным.
    func applyHistory(_ listed: [TaskInfo]) {
        tasks = TaskHistory.merge(current: tasks, listed: listed)
    }

    func apply(_ hello: HelloResult) {
        let missing = hello.executors.filter { !$0.available }
        problem = missing.isEmpty ? nil : "Claude Code не найден — установите CLI и выполните вход."
    }

    func coreStopped(status: Int32) {
        core = nil
        problem = "Ядро остановилось (код \(status)). Перезапустите Luna."
    }

    #if DEBUG
    /// Подменяет захваченный контекст — для проверки сценариев без системных разрешений.
    func debugSetContext(_ context: CapturedContext?) {
        captureGeneration += 1
        capture = nil
        self.context = context
    }

    /// Подменяет шаги открытой карточки агента — для проверки интерфейса без ядра.
    func debugSetAgentSteps(_ steps: [AgentStep]) {
        stepsGeneration += 1
        agentSteps = steps
    }

    /// Подменяет подробную ленту окна сессии.
    func debugSetAgentTranscript(_ steps: [AgentStep], sessionId: String) {
        transcriptGenerations[sessionId] = (transcriptGenerations[sessionId] ?? 0) + 1
        agentTranscripts[sessionId] = steps
    }
    #endif
}

private struct EmptyResult: Decodable {}
