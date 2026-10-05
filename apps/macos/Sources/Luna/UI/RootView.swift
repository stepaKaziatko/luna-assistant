import SwiftUI

enum Layout {
    static let cardWidth: CGFloat = 640
    /// Поля окна вокруг карточки, чтобы тень не обрезалась.
    static let shadowMargin: CGFloat = 24
    static let resultMaxHeight: CGFloat = 420
    static let taskListMaxHeight: CGFloat = 400
}

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            switch state.mode {
            case .pill:
                PillView()
            case .input:
                InputView()
            case .tasks:
                TaskListView()
            case .result(let threadId):
                ResultView(threadId: threadId)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand { state.collapse() }
        .environment(\.colorScheme, .dark)
    }
}

/// Карточка, «свисающая» с верхнего края экрана: верхние углы прямые, нижние скруглены.
struct HangingCard: ViewModifier {
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(Color.black, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
    }
}

extension View {
    func hangingCard(radius: CGFloat = 18) -> some View {
        modifier(HangingCard(radius: radius))
    }
}
