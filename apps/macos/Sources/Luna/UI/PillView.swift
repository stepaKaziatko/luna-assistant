import SwiftUI

/// Свёрнутый остров. Без дел — покой: тело чуть шире выреза (на экране без выреза — псевдо-остров), пустое.
/// Когда есть что показать, из выреза вырастают крылья: слева Luna и фраза, справа счётчики и аватары сессий,
/// между ними — промежуток шириной с вырез, чтобы ничего не пряталось под камерой. Раскладку считает
/// `IslandLayout` (`AppState.pillLayout`); чёрную фигуру под содержимым рисует остров (`RootView`).
struct PillView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: LunaSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = state.pillLayout
        Group {
            if let presentation = state.shownPillPresentation {
                wings(presentation, layout: layout)
            } else {
                Color.clear
            }
        }
        .frame(width: layout.body.width, height: layout.body.height)
    }

    /// Счётчики говорят, сколько чего; фраза о главном событии — по настройке, а VoiceOver читает её всегда.
    private func wings(_ presentation: PillPresentation, layout: IslandLayout) -> some View {
        HStack(spacing: 0) {
            measured(\.left) { leftWing(presentation, layout: layout) }
                .frame(width: layout.leftWing, alignment: .trailing)
            Color.clear.frame(width: layout.gap)
            measured(\.right) { rightWing(presentation, layout: layout) }
                .frame(width: layout.rightWing, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium))
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: presentation.text)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: settings.pillText)
        .environment(\.ambientMotion, true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.text)
    }

    /// Левое крыло: Luna и фраза.
    private func leftWing(_ presentation: PillPresentation, layout: IslandLayout) -> some View {
        HStack(spacing: 8) {
            MoonAvatar(look: settings.lunaLook, mood: presentation.mood, size: layout.lunaAvatar)
            if settings.pillText {
                Text(presentation.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(color(presentation.tone))
                    .frame(maxWidth: 220)
                    // Новая строка выезжает снизу, как в бегущей ленте.
                    .id(presentation.text)
                    .transition(reduceMotion ? .opacity : .push(from: .bottom))
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 8)
        .frame(height: layout.rowHeight)
    }

    /// Правое крыло: счётчики и аватары сессий; нечего показать — крыло пустое, в нём только запас.
    @ViewBuilder
    private func rightWing(_ presentation: PillPresentation, layout: IslandLayout) -> some View {
        let chips = state.statusChips
        let showAvatars = settings.pillAvatars && !presentation.sessions.isEmpty
        if !chips.isEmpty || showAvatars {
            HStack(spacing: 8) {
                if !chips.isEmpty { StatusChips(chips: chips, fontSize: layout.chipFont) }
                if showAvatars { avatars(presentation.sessions, size: layout.sessionAvatar) }
            }
            .padding(.leading, 8)
            .padding(.trailing, 11)
            .frame(height: layout.rowHeight)
        }
    }

    /// Крыло в естественную ширину; её замер уходит в раскладку. Пустое крыло — ширина 0.
    private func measured<Content: View>(
        _ side: WritableKeyPath<PillWings, CGFloat>, @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack { content() }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if state.pillWings[keyPath: side] != width { state.pillWings[keyPath: side] = width }
            }
    }

    private func avatars(_ sessions: [AgentSession], size: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(sessions.prefix(PillPresentation.avatarLimit), id: \.id) { session in
                MoonAvatar(look: .session(session), mood: session.mood(finished: state.finishedAgents.contains(session.id)), size: size)
                    .transition(.scale(scale: 0.01).combined(with: .opacity))
            }
            if sessions.count > PillPresentation.avatarLimit {
                Text("+\(sessions.count - PillPresentation.avatarLimit)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    // Крыло замеряется в естественную ширину и ставится в неё же; без этого надпись при
                    // раскладке получает меньше своей ширины, переносится и не рисуется вовсе.
                    .fixedSize()
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: sessions.map(\.id))
    }

    private func color(_ tone: PillPresentation.Tone) -> Color {
        switch tone {
        case .neutral: .white
        case .attention: .orange
        case .success: .green
        case .failure: .red
        }
    }
}
