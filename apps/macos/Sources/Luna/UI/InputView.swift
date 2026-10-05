import SwiftUI

struct InputView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: LunaSettings
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MoonAvatar(look: settings.lunaLook, mood: .listening, size: 26)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 7 }
                TextField("Спросите что-нибудь…", text: $state.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(state.submit)
            }
            .font(.system(size: 17))

            if hasChips { ContextChips() }

            HStack {
                if let problem = state.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else {
                    Text("Claude Code")
                }
                Spacer()
                Text("↩ отправить · esc закрыть")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: Layout.cardWidth)
        .onAppear { focused = true }
    }

    private var hasChips: Bool {
        state.context?.payload != nil || !state.captureIssues.isEmpty
    }
}
