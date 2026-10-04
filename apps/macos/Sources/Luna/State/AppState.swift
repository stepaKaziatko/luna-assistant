import Foundation

@MainActor
final class AppState: ObservableObject {
    enum Mode: Equatable {
        case pill
        case input
        case tasks
        case result(taskId: String)
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
    /// Строка списка задач, выбранная с клавиатуры.
    @Published private(set) var selectedTaskId: String?
    @Published private(set) var accessibilityHintHidden = UserDefaults.standard.bool(forKey: hideAccessibilityHintKey)

    var core: CoreClient?

    private var capture: _Concurrency.Task<CapturedContext.Details, Never>?
    /// Сколько занял последний захват контекста — для диагностики.
    private(set) var lastCaptureDuration: Duration?
    private var captureGeneration = 0

    var pillState: PillState {
        PillState.aggregate(tasks: tasks, unseen: unseen, hasProblem: problem != nil)
    }

    /// Задачи в порядке показа в списке: новые сверху.
    var listedTasks: [TaskInfo] {
        tasks.reversed()
    }

    func task(id: String) -> TaskInfo? {
        tasks.first { $0.id == id }
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
        mode = .pill
    }

    func showTasks() {
        selectedTaskId = listedTasks.first?.id
        mode = .tasks
    }

    /// Открывает самый свежий непросмотренный результат, а если таких нет — последнюю задачу.
    func openLastResult() {
        guard let task = tasks.last(where: { unseen.contains($0.id) }) ?? tasks.last else {
            openInput()
            return
        }
        show(task)
    }

    func open(taskId: String) {
        guard let task = task(id: taskId) else { return }
        show(task)
    }

    /// Клик по pill ведёт к тому, что требует внимания: к единственной задаче, к списку или к вводу.
    func pillClicked() {
        let attention = tasks.filter { unseen.contains($0.id) || $0.isActive }
        switch attention.count {
        case 0: openInput()
        case 1: show(attention[0])
        default: showTasks()
        }
    }

    func moveSelection(by offset: Int) {
        let list = listedTasks
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedTaskId } ?? -1
        selectedTaskId = list[min(max(current + offset, 0), list.count - 1)].id
    }

    func openSelectedTask() {
        if let selectedTaskId { open(taskId: selectedTaskId) }
    }

    private func openInput() {
        beginCapture()
        mode = .input
    }

    private func show(_ task: TaskInfo) {
        unseen.remove(task.id)
        mode = .result(taskId: task.id)
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
                let params = TaskSubmitParams(context: captured?.payload, executor: nil, prompt: prompt)
                let response: TaskSubmitResult = try await core.request("task.submit", params)
                // События задачи могли прийти раньше ответа — снимок из ответа их не перезаписывает.
                if task(id: response.task.id) == nil { apply(response.task) }
            } catch {
                draft = prompt
                problem = error.localizedDescription
            }
        }
    }

    func cancel(taskId: String) {
        guard let core else { return }
        _Concurrency.Task {
            let _: EmptyResult? = try? await core.request("task.cancel", TaskCancelParams(taskId: taskId))
        }
    }

    /// Применяет снимок задачи из ответа или уведомления ядра.
    func apply(_ task: TaskInfo) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        let isShown = mode == .result(taskId: task.id)
        if (task.status == .done || task.status == .failed) && !isShown {
            unseen.insert(task.id)
        }
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
