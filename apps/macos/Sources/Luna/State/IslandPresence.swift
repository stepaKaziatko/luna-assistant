import Foundation

/// Как Luna ведёт себя в покое.
enum IslandMode: String, CaseIterable, Identifiable {
    /// Мини-шторка у верхнего края экрана постоянно.
    case always
    /// Шторка скрыта и появляется по событию или по вызову пользователя.
    case background

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Всегда"
        case .background: "В фоне"
        }
    }
}

/// Должна ли шторка быть на экране. Часов, окон и курсора внутри нет: время и положение курсора
/// приходят снаружи, как у `HoverIntent`; панель лишь исполняет решение.
///
/// «Всегда» — шторка видна, что бы ни происходило. «В фоне» — по событию шторка показывается на
/// `pause` секунд; пока открыта панель или курсор над шторкой, она держится; закрытие панели
/// убирает её сразу, а курсор, ушедший после паузы, — через `HoverIntent.closeDelay`.
struct IslandPresence {
    /// Сколько шторка остаётся на экране после события.
    static let pause: TimeInterval = 6

    private(set) var mode: IslandMode
    private(set) var isShown: Bool
    private var deadline: TimeInterval = 0
    /// Открыта панель или блок под курсором.
    private var panelOpen = false
    private var pointerInside = false
    /// Когда курсор ушёл с шторки; nil — не уходил с тех пор, как шторка показана.
    private var pointerLeftAt: TimeInterval?

    init(mode: IslandMode) {
        self.mode = mode
        isShown = mode == .always
    }

    /// Нужен ли опрос положения курсора. В «Всегда» — только ради блока под курсором; в «В фоне» —
    /// пока шторка показана (по курсору она удерживается), и скрытая шторка курсора не ждёт.
    static func needsPointerPolling(mode: IslandMode, isShown: Bool, hoverPeek: Bool) -> Bool {
        switch mode {
        case .always: hoverPeek
        case .background: isShown
        }
    }

    /// Пользователь выбрал режим; `mode` — что сейчас открыто. Панель, открытая в этот момент,
    /// шторку удерживает до закрытия.
    mutating func setMode(_ new: IslandMode, panel: AppState.Mode, now: TimeInterval) {
        guard new != mode else { return }
        mode = new
        panelOpen = panel != .pill
        switch new {
        case .always:
            isShown = true
        case .background:
            deadline = now
            isShown = panelOpen
            if !isShown { forgetPointer() }
        }
    }

    /// Случилось событие, о котором Luna сообщает: шторка показывается или остаётся ещё на паузу.
    mutating func event(now: TimeInterval) {
        guard mode == .background else { return }
        isShown = true
        deadline = now + Self.pause
    }

    /// Панель открылась, закрылась или перешла в другую. Закрытие панели убирает шторку без паузы;
    /// уход курсора с блока под курсором — не закрытие: шторка уходит по своему сроку.
    mutating func panelChanged(from old: AppState.Mode, to new: AppState.Mode, now: TimeInterval) {
        panelOpen = new != .pill
        guard mode == .background else { return }
        if panelOpen {
            isShown = true
        } else if old != .peek {
            hide()
        } else {
            evaluate(now: now)
        }
    }

    /// Положение курсора с очередного опроса; заодно проверяется, не вышел ли срок.
    mutating func update(pointerInside inside: Bool, now: TimeInterval) {
        if inside != pointerInside {
            pointerInside = inside
            pointerLeftAt = inside ? nil : now
        }
        evaluate(now: now)
    }

    private mutating func evaluate(now: TimeInterval) {
        guard mode == .background, isShown, !panelOpen, !pointerInside else { return }
        // Курсор ушёл раньше срока — шторка уходит в срок; ушёл позже — через `closeDelay`.
        var due = deadline
        if let left = pointerLeftAt, left > deadline { due = left + HoverIntent.closeDelay }
        if now >= due { hide() }
    }

    private mutating func hide() {
        isShown = false
        forgetPointer()
    }

    private mutating func forgetPointer() {
        pointerInside = false
        pointerLeftAt = nil
    }
}
