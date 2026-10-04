import SwiftUI

struct PillView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Button(action: state.pillClicked) {
            content
                // Idle-pill совсем тонкий — область клика делаем больше видимой части.
                .frame(minWidth: 72, minHeight: 14, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Luna")
    }

    @ViewBuilder
    private var content: some View {
        switch state.pillState {
        case .idle:
            Color.black
                .frame(width: 44, height: 6)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6))
        case .running(let count):
            label(count == 1 ? (runningProgress ?? "Думаю…") : "Задач в работе: \(count)") {
                ProgressView().controlSize(.mini)
            }
        case .done(let count):
            label(count == 1 ? "Готово" : "Готово: \(count)") { dot(.green) }
        case .error:
            label("Ошибка") { dot(.red) }
        }
    }

    private var runningProgress: String? {
        state.tasks.last { $0.isActive }?.progress
    }

    private func label(_ text: String, @ViewBuilder indicator: () -> some View) -> some View {
        HStack(spacing: 6) {
            indicator()
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .frame(maxWidth: 300)
        .fixedSize()
        .hangingCard(radius: 12)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}
