import Foundation

/// Отсчёт задержек по положению курсора: блок раскрывается, когда курсор задержался над шторкой,
/// и убирается, когда ушёл и не вернулся. Случайный пролёт мимо ничего не раскрывает,
/// промах мимо края на долю секунды — не закрывает. Часов внутри нет: время приходит снаружи.
struct HoverIntent {
    enum Action: Equatable {
        case open
        case close
    }

    static let openDelay: TimeInterval = 0.15
    static let closeDelay: TimeInterval = 0.4

    private var inside = false
    private var since: TimeInterval?
    /// На текущее пребывание внутри или снаружи действие уже выдано.
    private var fired = true

    /// Вызывается с каждым опросом курсора; действие выдаётся один раз на каждое пересечение границы.
    mutating func update(inside now: Bool, at time: TimeInterval) -> Action? {
        if now != inside || since == nil {
            // До первого пересечения границы действий нет: курсор снаружи — обычное состояние.
            fired = since == nil && !now
            inside = now
            since = time
        }
        guard !fired, let since, time - since >= (inside ? Self.openDelay : Self.closeDelay) else { return nil }
        fired = true
        return inside ? .open : .close
    }
}
