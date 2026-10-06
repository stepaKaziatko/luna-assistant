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
    /// Самая высокая карточка — диалог: поля, шапка, прокрутка до `resultMaxHeight`, поле продолжения
    /// в четыре строки, ошибка в две строки, подпись с кнопками и промежутки между ними.
    static let tallestCard: CGFloat = resultMaxHeight + 2 * 16 + 24 + 96 + 32 + 28 + 4 * 12
    /// Окно раскрытого острова. В ширину — карточка с плечами и тенью по бокам, но не уже окна pill у самого
    /// широкого выреза; в высоту — самая высокая полоса, самая высокая карточка под ней и тень снизу.
    /// Окно ставится до первого кадра роста и не меняется, пока фигура растёт и сжимается внутри него.
    static let expandedPanel = CGSize(
        width: max(
            cardWidth + 2 * IslandShape.shoulderSize + 2 * shadowMargin,
            pillPanelWidth(notchWidth: IslandLayout.maxNotchWidth)
        ),
        height: (ExpandedIsland.maxBarHeight + tallestCard + shadowMargin).rounded(.up)
    )

    /// Окно свёрнутого острова: вырез, два крыла наибольшей ширины и два плеча; без выреза — строка из двух
    /// крыльев и плечи. Высотой с полосу: тени у свёрнутого острова нет.
    static func pillPanel(for notch: NotchGeometry) -> CGSize {
        CGSize(width: pillPanelWidth(notchWidth: notch.notchWidth), height: notch.barHeight)
    }

    private static func pillPanelWidth(notchWidth: CGFloat) -> CGFloat {
        (notchWidth + 2 * IslandLayout.maxWing + 2 * IslandShape.shoulderSize).rounded(.up)
    }
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

    /// Шторка появляется и прячется в режиме «В фоне». Появление — как рост острова, уход — как сжатие;
    /// при «Уменьшении движения» — растворение.
    static func presence(appearing: Bool, reduced: Bool) -> Animation {
        resize(growing: appearing, reduced: reduced)
    }
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
    /// Шторка на экране. Скрытой оживлять некого: таймер снят, `burst()` ничего не делает.
    private(set) var isActive = true

    /// Заведён ли таймер оживлений.
    var isScheduling: Bool { timer != nil }

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
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.burstPeriod, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.burst() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Шторка скрыта или показана. Скрытая — без таймера и без вспышек; показанная — снова с таймером
    /// и одной вспышкой, чтобы появившаяся шторка ожила.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            startTimer()
            burst()
        } else {
            timer?.invalidate()
            timer = nil
            burstEnd = .distantPast
            pointerNear = false
            update()
        }
    }

    /// Короткое оживление: что-то произошло или просто пришло время моргнуть.
    func burst() {
        guard isActive else { return }
        burstEnd = Date().addingTimeInterval(Self.burstLength)
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstLength + 0.05) { [weak self] in self?.update() }
    }

    private func update() {
        let lively = isActive && (pointerNear || Date() < burstEnd)
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
/// Фигура — продолжение выреза (`IslandShape`): чисто чёрная, без обводки, плечами уходит в строку меню.
struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Размер тела фигуры; следует за размером содержимого текущего режима.
    @State private var size = IslandLayout.make(
        notchWidth: IslandPlacement.unplaced.notch.notchWidth, barHeight: IslandPlacement.unplaced.notch.barHeight
    ).body
    /// Сдвиг тела от середины окна по x: поправка на округление окна и несимметричные крылья pill.
    @State private var offset: CGFloat = 0
    /// Естественный размер содержимого раскрытого режима: по нему тело пересчитывается, когда меняется полоса.
    @State private var expandedContent: CGSize?
    /// Последний замер содержимого раскрытых режимов, в том числе уходящего: если режим вернули, пока его
    /// содержимое ещё уходило, SwiftUI возвращает тот же вид, и нового замера не будет.
    @State private var measured: [(mode: AppState.Mode, size: CGSize)] = []

    var body: some View {
        ZStack(alignment: .top) {
            if state.mode != .pill {
                cardShadow
            }

            shape
                .fill(.black)
                .frame(width: size.width, height: size.height)

            ZStack(alignment: .top) {
                content
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)

            if state.mode == .pill {
                // Клик ловится по всей фигуре — тело, крылья и плечи: плечи чёрные, окно забирает клик и там.
                // Рамка шире тела на плечи, контур — та же фигура; вне контура клик сюда не доходит вовсе.
                Color.clear
                    .frame(width: size.width + 2 * shape.shoulder, height: size.height)
                    .contentShape(shape)
                    .onTapGesture(perform: state.pillClicked)
            }
        }
        .offset(x: offset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Появление и уход шторки в режиме «В фоне»: съезжает от края и растворяется; при
        // «Уменьшении движения» — только растворение.
        .opacity(state.islandPresented ? 1 : 0)
        .offset(y: state.islandPresented || reduceMotion ? 0 : -size.height)
        .animation(
            IslandMotion.presence(appearing: state.islandPresented, reduced: reduceMotion), value: state.islandPresented
        )
        .animation(.default, value: state.mode)
        .onChange(of: targetOffset, initial: true) { _, new in
            withAnimation(IslandMotion.resize(growing: isGrowingOffset, reduced: reduceMotion)) { offset = new }
        }
        // Остров встал на другой экран или поменялась полоса: раскрытое тело — по новой полосе.
        .onChange(of: state.islandPlacement.notch) { _, notch in
            guard state.mode != .pill, let content = expandedContent else { return }
            resize(ExpandedIsland.body(content: content, notch: notch))
        }
        // Режим вернули раньше, чем его содержимое успело уйти: SwiftUI отменяет уход и возвращает прежний вид,
        // его размер не менялся — замера не будет. Тело берёт размер сразу: pill — из раскладки, раскрытый режим —
        // из последнего замера его содержимого. Вид, вставленный заново, сообщит размер сам и поправит его.
        .onChange(of: state.mode) { _, mode in
            if mode == .pill {
                resize(state.pillLayout.body)
            } else if let content = measured.last(where: { $0.mode == mode })?.size {
                expandedContent = content
                resize(ExpandedIsland.body(content: content, notch: state.islandPlacement.notch))
            }
        }
        .onChange(of: bodyOffset, initial: true) { _, new in
            if state.islandBodyOffset != new { state.islandBodyOffset = new }
        }
        .onExitCommand { state.collapse() }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        let mode = state.mode
        switch mode {
        case .pill:
            PillView().islandContent { resize($0, from: mode) }
        case .peek:
            PeekView().islandContent(top: barHeight) { resizeExpanded($0, from: mode) }
        case .input:
            InputView().islandContent(top: barHeight) { resizeExpanded($0, from: mode) }
        case .tasks:
            TaskListView().islandContent(top: barHeight) { resizeExpanded($0, from: mode) }
        case .result(let threadId):
            ResultView(threadId: threadId).islandContent(top: barHeight) { resizeExpanded($0, from: mode) }
        case .agents:
            AgentsView().islandContent(top: barHeight) { resizeExpanded($0, from: mode) }
        case .agent(let sessionId):
            // Переход между сессиями — тоже смена содержимого.
            AgentDetailView(sessionId: sessionId).id(sessionId).islandContent(top: barHeight) { resizeExpanded($0, from: mode) }
        }
    }

    /// Полоса у верхнего края экрана острова: вырез или строка меню. В раскрытых режимах она — верх тела,
    /// содержимое начинается под ней.
    private var barHeight: CGFloat {
        state.islandPlacement.notch.barHeight
    }

    /// Тень раскрытой карточки — снизу и по бокам. В полосе и над строкой меню её нет, а ниже полосы она
    /// нарастает от нуля по градиенту маски: резкой линии по нижней кромке строки меню нет.
    /// Свёрнутому острову тень не нужна.
    private var cardShadow: some View {
        shape
            .fill(.black)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: barHeight)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.shadowFade)
                    Color.black
                }
                .padding(.horizontal, -Layout.shadowMargin)
                .padding(.bottom, -Layout.shadowMargin)
            }
    }

    /// На какой высоте под полосой тень по бокам доходит до полной силы.
    private static let shadowFade: CGFloat = 24

    /// Верх прямой и уходит плечами в строку меню; низ скруглён (`IslandShape.bottomRadius`).
    private var shape: IslandShape {
        IslandShape(width: size.width, height: size.height, bottomRadius: IslandShape.bottomRadius(collapsed: state.mode == .pill))
    }

    /// Сдвиг тела от середины выреза: у pill — на разницу крыльев.
    private var bodyOffset: CGFloat {
        state.mode == .pill ? state.pillLayout.bodyOffset : 0
    }

    /// Куда должно встать тело в окне: на середину выреза с поправкой на округление окна и со сдвигом тела.
    private var targetOffset: CGFloat {
        state.islandPlacement.correction + bodyOffset
    }

    /// Сдвиг идёт той же пружиной, что и размер: крылья вырастают — рост, втягиваются — сжатие.
    private var isGrowingOffset: Bool {
        state.mode != .pill || state.shownPillPresentation != nil
    }

    /// Размер сообщает содержимое текущего режима. Уходящее содержимое, пока растворяется, тоже может
    /// сообщить размер (у карточки диалога высота доезжает за прокруткой) — его не слушаем: иначе свёрнутый
    /// остров остался бы размером с карточку, а после уменьшения окна обрезался бы им.
    private func resize(_ new: CGSize, from mode: AppState.Mode) {
        guard mode == state.mode else { return }
        resize(new)
    }

    /// Содержимое раскрытого режима сообщило свой размер: тело — полоса и содержимое под ней.
    private func resizeExpanded(_ content: CGSize, from mode: AppState.Mode) {
        remember(content, for: mode)
        guard mode == state.mode else { return }
        expandedContent = content
        resize(ExpandedIsland.body(content: content, notch: state.islandPlacement.notch))
    }

    /// Замер запоминается и для уходящего содержимого: вернётся режим — тело встанет по нему. Режимов с диалогами
    /// и сессиями может быть сколько угодно, поэтому хранятся только последние.
    private func remember(_ content: CGSize, for mode: AppState.Mode) {
        if measured.last?.mode == mode, measured.last?.size == content { return }
        measured.removeAll { $0.mode == mode }
        measured.append((mode, content))
        if measured.count > Self.measuredLimit { measured.removeFirst() }
    }

    private static let measuredLimit = 8

    private func resize(_ new: CGSize) {
        guard new != size, new.width > 0, new.height > 0 else { return }
        let growing = new.width * new.height > size.width * size.height
        withAnimation(IslandMotion.resize(growing: growing, reduced: reduceMotion)) {
            size = new
            offset = targetOffset
        }
        state.islandSize = new
    }
}

private extension View {
    /// Содержимое режима: занимает свой естественный размер, сообщает его острову и сменяется переходом.
    /// `top` — отступ сверху: у раскрытых режимов это полоса выреза. Отступ уходит и приходит вместе
    /// с содержимым, поэтому уходящая карточка не прыгает в полосу, пока растворяется.
    func islandContent(top: CGFloat = 0, _ resize: @escaping (CGSize) -> Void) -> some View {
        modifier(IslandContent(top: top, resize: resize))
    }
}

private struct IslandContent: ViewModifier {
    let top: CGFloat
    let resize: (CGSize) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { resize($0) }
            .padding(.top, top)
            .transition(IslandMotion.content(reduced: reduceMotion))
    }
}
