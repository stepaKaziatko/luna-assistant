import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum Mode: Equatable {
        case pill
        case input
        case tasks
        /// Карточка диалога: все его задачи, внизу — поле продолжения.
        case result(threadId: String)
    }

    @Published private(set) var mode: Mode = .pill
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

    var core: CoreRequesting?

    private var capture: _Concurrency.Task<CapturedContext.Details, Never>?
    /// Сколько занял последний захват контекста — для диагностики.
    private(set) var lastCaptureDuration: Duration?
    private var captureGeneration = 0
    /// Ответ на поиск, пришедший после ответа на более новый запрос, отбрасывается.
    private var searchGeneration = 0

    var pillState: PillState {
        PillState.aggregate(tasks: tasks, unseen: unseen, hasProblem: problem != nil)
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

    /// Клик по pill ведёт к тому, что требует внимания: к единственному диалогу, к списку или к вводу.
    func pillClicked() {
        var attention: [String] = []
        for task in tasks where (unseen.contains(task.id) || task.isActive) && !attention.contains(task.threadId) {
            attention.append(task.threadId)
        }
        switch attention.count {
        case 0: openInput()
        case 1: show(threadId: attention[0])
        default: showTasks()
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

    func submit() {
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
                let params = TaskSubmitParams(context: captured?.payload, executor: nil, followUpOf: nil, prompt: prompt)
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
        followUpDraft = ""
        followUpError = nil
        isSendingFollowUp = true

        _Concurrency.Task {
            defer { isSendingFollowUp = false }
            do {
                let params = TaskSubmitParams(context: nil, executor: nil, followUpOf: point.id, prompt: prompt)
                let response: TaskSubmitResult = try await core.request("task.submit", params)
                if task(id: response.task.id) == nil { apply(response.task) }
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
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        // Задача диалога, открытого в карточке, видна сразу — непросмотренной она не становится.
        let isShown = mode == .result(threadId: task.threadId)
        if (task.status == .done || task.status == .failed) && !isShown {
            unseen.insert(task.id)
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
    #endif
}

private struct EmptyResult: Decodable {}
