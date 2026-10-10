import AppKit
import SwiftUI

/// Счётчики шторки: значок и число на каждое состояние — вместо фразы.
struct StatusChips: View {
    let chips: [StatusChip]
    /// Кегль счётчиков; в шторке на низкой строке меню — меньше.
    var fontSize: CGFloat = 11

    var body: some View {
        HStack(spacing: 9) {
            ForEach(chips) { chip in
                HStack(spacing: 3) {
                    glyph(chip.kind)
                    Text("\(chip.count)")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .foregroundStyle(chip.kind.color)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
                .help(chip.title)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(chip.title)
            }
        }
        .font(.system(size: fontSize, weight: .semibold))
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: chips)
    }

    @ViewBuilder
    private func glyph(_ kind: StatusChip.Kind) -> some View {
        switch kind {
        case .failure: Image(systemName: "exclamationmark.triangle.fill")
        case .attention: Image(systemName: "hand.raised.fill")
        case .success: Image(systemName: "checkmark.circle.fill")
        case .working: ActivityBars()
        }
    }
}

extension StatusChip {
    /// Что значит счётчик — для подсказки и VoiceOver.
    var title: String {
        switch kind {
        case .failure: "Ошибок: \(count)"
        case .attention: "Ждут вас: \(count)"
        case .success: "Готово: \(count)"
        case .working: "В работе: \(count)"
        }
    }
}

extension StatusChip.Kind {
    var color: Color {
        switch self {
        case .failure: .red
        case .attention: .orange
        case .success: .green
        case .working: .white
        }
    }
}

/// Три столбика, которые ходят вверх-вниз, пока идёт работа.
struct ActivityBars: View {
    private var motion = Motion()

    var body: some View {
        Group {
            if motion.isStill {
                bars(at: 0.4)
            } else {
                TimelineView(IslandClock.schedule()) { bars(at: $0.date.timeIntervalSinceReferenceDate) }
            }
        }
        .frame(width: 11, height: 10)
    }

    private func bars(at time: TimeInterval) -> some View {
        Canvas { context, size in
            let width = size.width / 5
            for index in 0..<3 {
                let level = 0.35 + 0.65 * abs(sin(time * 3.1 + Double(index) * 1.1))
                let height = size.height * level
                let bar = CGRect(x: CGFloat(index) * 2 * width, y: size.height - height, width: width, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: width / 2), with: .foreground)
            }
        }
    }
}

/// Превью работы: последние шаги сессии значками, свежий справа. Новый шаг въезжает справа
/// и сдвигает прежние; у работающего агента текущий шаг пульсирует.
struct ActivityTrail: View {
    /// Старые первыми.
    let steps: [AgentStep]
    let isLive: Bool
    let tint: Color

    static let limit = 5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let items = Array(AgentStep.identified(steps).suffix(Self.limit))
        HStack(spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                glyph(item.step, age: items.count - 1 - index)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .scale(scale: 0.5).combined(with: .opacity)
                    ))
            }
        }
        .frame(height: Self.side, alignment: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: items.map(\.id))
        .accessibilityHidden(true)
    }

    private static let side: CGFloat = 20

    private func glyph(_ step: AgentStep, age: Int) -> some View {
        let isCurrent = age == 0
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Image(systemName: step.symbol)
            .font(.system(size: 9.5, weight: .semibold))
            // Чем старше шаг, тем он бледнее: взгляд идёт к свежему.
            .foregroundStyle(.white.opacity(isCurrent ? 1 : max(0.3, 0.62 - 0.1 * Double(age))))
            .frame(width: Self.side, height: Self.side)
            .background(isCurrent ? AnyShapeStyle(tint.opacity(0.3)) : AnyShapeStyle(.white.opacity(0.06)), in: shape)
            .overlay {
                if isCurrent, isLive {
                    Pulse(low: 0.15, period: 1.6) { shape.strokeBorder(tint, lineWidth: 1) }
                } else if isCurrent {
                    shape.strokeBorder(tint.opacity(isLive ? 0.8 : 0.35), lineWidth: 1)
                }
            }
    }
}

/// Плитка сессии агента: аватар, проект, превью работы и пара слов о том, что происходит.
/// Клик — карточка сессии, значок приложения-хозяина — переход к её окну.
struct AgentTile: View {
    let session: AgentSession
    let isFinished: Bool
    var isSelected = false
    /// Сетка агентов показывает и заголовок сессии; блоку под курсором хватает проекта.
    var showsTitle = false

    @EnvironmentObject private var state: AppState
    @State private var isHovered = false

    private var look: AvatarLook { .session(session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                MoonAvatar(look: look, mood: session.mood(finished: isFinished), size: 40)
                Spacer(minLength: 4)
                jumpButton
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if showsTitle {
                    Text(session.displayTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ActivityTrail(steps: session.trail ?? [], isLive: session.state == .working, tint: look.lit)
            caption
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(10)
        .frame(width: Layout.tileWidth, alignment: .leading)
        .background(.white.opacity(isSelected ? 0.13 : isHovered ? 0.09 : 0.05), in: shape)
        .overlay { border }
        .contentShape(Rectangle())
        .onTapGesture { state.openAgent(id: session.id) }
        .onHover { isHovered = $0 }
        .help(session.displayTitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.project), \(session.displayTitle): \(session.statusLine)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    @ViewBuilder
    private var caption: some View {
        switch session.approval != nil ? AgentState.waiting : session.state {
        case .working:
            ShimmerText(text: session.tileCaption)
        case .waiting:
            Text(session.tileCaption).foregroundStyle(.orange)
        case .idle:
            Text(AgentStatusLine.ago(session.updatedAt))
                .foregroundStyle(isFinished ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
    }

    /// Рамка говорит то же, что значок аватара: оранжевая зовёт человека, зелёная — ход завершён.
    @ViewBuilder
    private var border: some View {
        if session.state == .waiting || session.approval != nil {
            Pulse(high: 0.95) { shape.strokeBorder(.orange, lineWidth: 1) }
        } else if isFinished {
            shape.strokeBorder(.green.opacity(0.45), lineWidth: 1)
        } else if isSelected {
            shape.strokeBorder(.white.opacity(0.28), lineWidth: 1)
        }
    }

    private var jumpButton: some View {
        Button(action: { state.jumpToAgent(id: session.id) }) {
            HostIcon(host: session.host, size: 17)
                .padding(3)
                .background(.white.opacity(isHovered ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.host.jumpTitle)
        .accessibilityLabel(session.host.jumpTitle)
    }
}

/// Значок приложения, в окне которого идёт сессия; хозяин без бандла — терминал или папка.
struct HostIcon: View {
    let host: AgentHost
    var size: CGFloat = 16

    var body: some View {
        if let path = host.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: host.kind == .terminal ? "terminal" : "folder")
                .font(.system(size: size * 0.68, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}
