import AppKit
import SwiftUI

enum Layout {
    /// Карточки растут в ширину, а не в высоту: остров — полоса под верхним краем экрана.
    static let cardWidth: CGFloat = 720
    /// Поля окна вокруг карточки, чтобы тень не обрезалась.
    static let shadowMargin: CGFloat = 24
    static let resultMaxHeight: CGFloat = 360
    static let taskListMaxHeight: CGFloat = 320
    /// Плитка сессии агента: в блоке под курсором и в сетке агентов.
    static let tileWidth: CGFloat = 166
    static let tileSpacing: CGFloat = 8
    /// Сетка агентов показывает два ряда плиток, остальные прокручиваются.
    static let agentGridMaxHeight: CGFloat = 312
    /// Высота карточки сессии: слева — кто это, справа — лента шагов.
    static let agentCardHeight: CGFloat = 232
    /// Блок под курсором не уже шапки со счётчиками и кнопками.
    static let peekMinWidth: CGFloat = 340
    static let peekDialogWidth: CGFloat = 166
    /// Окно раскрытого острова: вмещает самую высокую карточку с шапкой и подвалом.
    static let expandedPanel = CGSize(width: cardWidth + 2 * shadowMargin, height: resultMaxHeight + 240)
    /// Окно свёрнутого острова: pill с аватарами, счётчиками и подписью.
    static let pillPanel = CGSize(width: 560, height: 52)
}

/// Анимации острова. Рост — пружина с лёгким перелётом, сжатие — без отскока: так остров
/// «выпрыгивает» и спокойно убирается (приём Coucou). При «Уменьшении движения» — короткое растворение.
enum IslandMotion {
    static func resize(growing: Bool, reduced: Bool) -> Animation {
        if reduced { return .easeInOut(duration: 0.15) }
        return growing ? .spring(response: 0.42, dampingFraction: 0.78) : .timingCurve(0.45, 0, 0.2, 1, duration: 0.3)
    }

    /// Новое содержимое проявляется, когда остров уже начал менять форму; старое уходит быстро.
    static func content(reduced: Bool) -> AnyTransition {
        if reduced { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.1)),
            removal: .opacity.animation(.easeIn(duration: 0.12))
        )
    }

    /// Сколько длится сворачивание: после него окно острова можно уменьшить.
    static let collapseDuration: TimeInterval = 0.45
}

/// Общий такт покадровых анимаций острова: аватары, столбики, блики. Все они тикают в одни и те же
/// моменты, поэтому окно перерисовывается один раз на такт, а не по разу на каждую анимацию —
/// от этого зависит, сколько процессора Luna тратит, пока просто висит у края экрана.
enum IslandClock {
    static let fps: Double = 15
    private static let origin = Date()

    /// Такт; `every: 3` — каждый третий, для того, что движется медленно.
    static func schedule(every ticks: Int = 1) -> PeriodicTimelineSchedule {
        .periodic(from: origin, by: Double(ticks) / fps)
    }
}

/// Когда покадровым анимациям есть для кого идти. Каждый кадр — проход отрисовки всего окна,
/// и у острова, который висит на экране весь день, это главная статья расхода процессора.
/// Поэтому свёрнутая шторка оживает ненадолго: по событию, раз в несколько секунд и пока курсор
/// рядом; раскрытый остров анимируется всё время, пока на него смотрят.
@MainActor
final class MotionGate: ObservableObject {
    static let shared = MotionGate()

    /// Экран погас или сеанс пользователя неактивен.
    @Published private(set) var isAsleep = false
    /// Свёрнутая шторка сейчас «живая».
    @Published private(set) var isLively = false

    /// Курсор рядом с островом; сообщает панель.
    var pointerNear = false {
        didSet { if pointerNear != oldValue { update() } }
    }

    static let burstLength: TimeInterval = 1.6
    static let burstPeriod: TimeInterval = 10

    private var burstEnd = Date.distantPast
    private var timer: Timer?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isAsleep = asleep }
            }
        }
        let timer = Timer(timeInterval: Self.burstPeriod, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.burst() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Короткое оживление: что-то произошло или просто пришло время моргнуть.
    func burst() {
        burstEnd = Date().addingTimeInterval(Self.burstLength)
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstLength + 0.05) { [weak self] in self?.update() }
    }

    private func update() {
        let lively = pointerNear || Date() < burstEnd
        if lively != isLively { isLively = lively }
    }
}

extension EnvironmentValues {
    /// Содержимое свёрнутой шторки: анимируется не всё время, а когда `MotionGate` разрешает.
    @Entry var ambientMotion = false
}

/// Стоят ли покадровые анимации: «Уменьшение движения», настройка пользователя, погасший экран
/// или пауза между оживлениями свёрнутой шторки.
@MainActor
struct Motion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ambientMotion) private var ambient
    @EnvironmentObject private var settings: LunaSettings
    @ObservedObject private var gate = MotionGate.shared

    var isStill: Bool {
        reduceMotion || !settings.animateAvatars || gate.isAsleep || (ambient && !gate.isLively)
    }
}

/// Мерцание в общем такте острова. Непрерывная анимация SwiftUI перерисовывала бы окно
/// с частотой экрана всё время, пока мерцающее на виду.
struct Pulse<Content: View>: View {
    var low: Double = 0.3
    var high: Double = 1
    var period: Double = 1.8
    @ViewBuilder let content: () -> Content

    private var motion = Motion()

    init(low: Double = 0.3, high: Double = 1, period: Double = 1.8, @ViewBuilder content: @escaping () -> Content) {
        self.low = low
        self.high = high
        self.period = period
        self.content = content
    }

    var body: some View {
        if motion.isStill {
            content().opacity(low + (high - low) * 0.7)
        } else {
            TimelineView(IslandClock.schedule()) { timeline in
                let phase = (sin(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / period) + 1) / 2
                content().opacity(low + (high - low) * phase)
            }
        }
    }
}

/// Остров: одна чёрная фигура у верхнего края экрана, которая меняет размер под содержимое.
/// Содержимое режимов сменяется внутри неё; фигура перетекает из pill в карточку и обратно.
struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Размер фигуры; следует за размером содержимого текущего режима.
    @State private var size = CGSize(width: 44, height: 6)

    var body: some View {
        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .overlay(shape.strokeBorder(.white.opacity(isNub ? 0 : 0.08)))
                .shadow(color: .black.opacity(isNub ? 0 : 0.35), radius: 12, y: 4)
                .frame(width: size.width, height: size.height)

            ZStack(alignment: .top) {
                content
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)

            if state.mode == .pill {
                // Свёрнутый остров тонкий — область клика делаем больше видимой части.
                Color.clear
                    .frame(width: max(size.width, 72), height: max(size.height, 14))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: state.pillClicked)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.default, value: state.mode)
        .onExitCommand { state.collapse() }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch state.mode {
        case .pill:
            PillView().islandContent(resize)
        case .peek:
            PeekView().islandContent(resize)
        case .input:
            InputView().islandContent(resize)
        case .tasks:
            TaskListView().islandContent(resize)
        case .result(let threadId):
            ResultView(threadId: threadId).islandContent(resize)
        case .agents:
            AgentsView().islandContent(resize)
        case .agent(let sessionId):
            // Переход между сессиями — тоже смена содержимого.
            AgentDetailView(sessionId: sessionId).id(sessionId).islandContent(resize)
        }
    }

    /// Свёрнутый остров без дел — тонкая полоска.
    private var isNub: Bool { size.height < 12 }

    /// Верхние углы прямые — остров «свисает» с края экрана; нижние скруглены.
    private var shape: UnevenRoundedRectangle {
        let radius: CGFloat = state.mode == .pill ? min(13, size.height) : 20
        return UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
    }

    private func resize(_ new: CGSize) {
        guard new != size, new.width > 0, new.height > 0 else { return }
        let growing = new.width * new.height > size.width * size.height
        withAnimation(IslandMotion.resize(growing: growing, reduced: reduceMotion)) { size = new }
        state.islandSize = new
    }
}

private extension View {
    /// Содержимое режима: занимает свой естественный размер, сообщает его острову и сменяется переходом.
    func islandContent(_ resize: @escaping (CGSize) -> Void) -> some View {
        modifier(IslandContent(resize: resize))
    }
}

private struct IslandContent: ViewModifier {
    let resize: (CGSize) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { resize($0) }
            .transition(IslandMotion.content(reduced: reduceMotion))
    }
}
