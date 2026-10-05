import SwiftUI

/// Свёрнутый остров. Без дел — тонкая полоска; когда есть что показать — Luna, счётчики состояний
/// и аватары сессий агентов. Чёрную фигуру под содержимым рисует остров (`RootView`).
struct PillView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: LunaSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let presentation = state.pillPresentation {
            status(presentation)
        } else {
            Color.clear.frame(width: 44, height: 6)
        }
    }

    /// Счётчики говорят, сколько чего; фраза о главном событии — по настройке, а VoiceOver читает её всегда.
    private func status(_ presentation: PillPresentation) -> some View {
        HStack(spacing: 8) {
            MoonAvatar(look: settings.lunaLook, mood: presentation.mood, size: 22)
            StatusChips(chips: state.statusChips)
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
            if settings.pillAvatars, !presentation.sessions.isEmpty {
                avatars(presentation.sessions)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.leading, 9)
        .padding(.trailing, 11)
        .frame(height: 28)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: presentation.text)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: settings.pillText)
        .environment(\.ambientMotion, true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.text)
    }

    private func avatars(_ sessions: [AgentSession]) -> some View {
        HStack(spacing: 2) {
            ForEach(sessions.prefix(PillPresentation.avatarLimit), id: \.id) { session in
                MoonAvatar(look: .session(session), mood: session.mood(finished: state.finishedAgents.contains(session.id)), size: 20)
                    .transition(.scale(scale: 0.01).combined(with: .opacity))
            }
            if sessions.count > PillPresentation.avatarLimit {
                Text("+\(sessions.count - PillPresentation.avatarLimit)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
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
