import AppKit

/// Следит, показывает ли экран острова полноэкранное приложение. Окна спрашиваются только по смене Space
/// и активного приложения и только когда у экрана острова есть вырез: таймера и постоянного опроса нет.
/// Разрешение на запись экрана не нужно: уровень, владелец и рамка окон доступны без него. Окна узнать
/// не удалось — полноэкранного режима нет.
@MainActor
final class FullscreenWatch {
    /// Записи списка окон; nil — список не получен. В тестах подменяется.
    typealias WindowSource = () -> [[String: Any]]?

    /// Экран острова, о котором спрашивать: рамка в координатах списка окон и высота полосы. nil — спрашивать
    /// не о чем: остров ещё не стоял или у его экрана нет выреза.
    var target: () -> (screen: CGRect, barHeight: CGFloat)? = { nil }
    /// Значение поменялось.
    var onChange: (Bool) -> Void = { _ in }

    private(set) var isFullscreen = false
    /// Сколько раз с запуска спрошен список окон: в `dump:` видно, что без выреза окна не запрашиваются.
    private(set) var queries = 0

    private let source: WindowSource
    private var pending: [DispatchWorkItem] = []
    private var observers: [NSObjectProtocol] = []

    /// Когда после смены Space проверка повторяется: событие приходит, пока окна и обои ещё доезжают
    /// на место. Серия отменяется следующим событием.
    static let settleDelays: [TimeInterval] = stride(from: 0.25, through: 2.5, by: 0.25).map { $0 }

    init(source: @escaping WindowSource = FullscreenWatch.systemWindows) {
        self.source = source
    }

    /// Подписка на смену Space и активного приложения.
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        })
    }

    /// Space сменился: проверка сразу и серией повторов, пока он встаёт на место.
    func spaceChanged() {
        cancelPending()
        guard target() != nil else { return update(false) }
        check()
        pending = Self.settleDelays.map { delay in
            let work = DispatchWorkItem { [weak self] in self?.check() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    /// Одна проверка: у экрана острова нет выреза — окна не спрашиваются, полноэкранного режима нет.
    func check() {
        guard let target = target() else {
            cancelPending()
            return update(false)
        }
        queries += 1
        let own = Int(ProcessInfo.processInfo.processIdentifier)
        guard let list = source(), !list.isEmpty else { return update(false) }
        let windows = list.compactMap { ScreenWindow(info: $0, ownPID: own) }
        update(FullscreenDetection.isFullscreen(
            windows: windows, screen: target.screen, menuBarHeight: target.barHeight,
            desktopIconLevel: Int(CGWindowLevelForKey(.desktopIconWindow))
        ))
    }

    /// Экран острова сменился или поменялась его геометрия: полноэкранного режима нет до следующего события.
    func reset() {
        cancelPending()
        update(false)
    }

    private func cancelPending() {
        pending.forEach { $0.cancel() }
        pending = []
    }

    private func update(_ value: Bool) {
        guard value != isFullscreen else { return }
        isFullscreen = value
        onChange(value)
    }

    /// Единственное место, где Luna спрашивает список окон системы.
    nonisolated static func systemWindows() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    }
}
