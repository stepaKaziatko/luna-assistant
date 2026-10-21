import SwiftUI

// MARK: - История чатов: иконки на странице запроса, список, пометки (LUNA-76)
//
// Логика — в ChatHistory.swift (без окна, под тестами). Здесь только вид. Список — всплывающее
// окно над островом, как выбор модели и проекта (решение человека В2): остров — неактивирующая
// панель, приложение пользователя остаётся активным.

/// Иконка истории в строке чипов страницы запроса.
struct ChatHistoryButton: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isPresented.toggle() }
        } label: {
            ChatChipIcon(systemName: "clock.arrow.circlepath")
        }
        .buttonStyle(.plain)
        .help(String(localized: "chat.history.button.help", defaultValue: "Chat history"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ChatHistoryListView(state: state, isPresented: $isPresented)
                .frame(width: 300)
        }
    }
}

/// «+» — новый чат, то же, что ⌘K. На пустой странице неактивна.
struct NewChatButton: View {
    @ObservedObject var state: AppState

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .islandNewConversation, object: nil)
        } label: {
            ChatChipIcon(systemName: "plus")
        }
        .buttonStyle(.plain)
        .disabled(state.chatHistory.isEmpty)
        .opacity(state.chatHistory.isEmpty ? 0.45 : 1)
        .help(String(localized: "chat.history.new.help", defaultValue: "New chat ⌘K"))
    }
}

/// Иконка в стиле чипов модели и проекта.
struct ChatChipIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(Color(hex: "#7B8089"))
            .frame(width: 14, height: 14)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
            .contentShape(Capsule())
    }
}

/// Список прошлых чатов: новые сверху, открытый отмечен, корзина по наведению.
struct ChatHistoryListView: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "chat.history.title", defaultValue: "Chats"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "#8A8F98"))
            if state.chatHistoryEntries.isEmpty {
                Text(String(localized: "chat.history.empty", defaultValue: "Your chats with Luna will appear here."))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8A8F98"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(state.chatHistoryEntries) { entry in
                            ChatHistoryRow(entry: entry, isOpen: entry.id == state.chatOpen.chatID && !state.chatHistory.isEmpty,
                                           open: { choose(entry.id) },
                                           delete: { state.deleteHistoryChat(entry.id) })
                        }
                    }
                }
                .frame(maxHeight: 290)
            }
            if !state.chatHistoryEnabled {
                Text(String(localized: "chat.history.disabled",
                            defaultValue: "History is off: new chats are not saved. Turn it on in Settings → Chat."))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#5C6370"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(hex: "#16171B"))
        .onAppear { state.loadChatHistory() }
    }

    private func choose(_ id: UUID) {
        state.openHistoryChat(id)
        isPresented = false
        SoundEngine.shared.play("blip")
    }
}

private struct ChatHistoryRow: View {
    let entry: ChatHistoryEntry
    let isOpen: Bool
    let open: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    private var provider: ChatProvider? { ChatProvider(rawValue: entry.provider) }

    private var detail: String {
        let when = Self.relative.localizedString(for: entry.updated, relativeTo: Date())
        var parts = [when, provider?.displayName ?? entry.provider]
        if let project = entry.projectName, !project.isEmpty { parts.append(project) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let accent = Color(hex: provider?.accentHex ?? "#8A8F98")
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 8) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.system(size: 12))
                            .foregroundColor(isOpen ? accent : Color(hex: "#C8CDD4"))
                            .lineLimit(1)
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#5C6370"))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.source ?? "")
            if hovering {
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#8A8F98"))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "chat.history.delete.help", defaultValue: "Delete chat"))
            } else if isOpen {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(accent)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isOpen ? accent.opacity(0.1) : (hovering ? Color.white.opacity(0.04) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

/// Пометки над полем ввода у чата из истории. Кнопка меняет источник — только по клику.
struct ChatHistoryNoticeBanner: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(state.chatNotices.enumerated()), id: \.offset) { _, notice in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9.5))
                        .foregroundColor(Color(hex: "#8A8F98"))
                    Text(Self.text(notice, current: state.chatProvider))
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(hex: "#9CA1AA"))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if case .sourceDiffers(_, let switchTo, _) = notice, let provider = ChatProvider(rawValue: switchTo) {
                        Button {
                            state.continueChat(with: provider)
                            SoundEngine.shared.play("blip")
                        } label: {
                            Text(String(localized: "chat.history.notice.switch",
                                        defaultValue: "Continue with \(provider.displayName)"))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(Color(hex: provider.accentHex))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.06))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
    }

    /// «Anthropic API», «Claude Code», «Ollama» — как в подписи под ответом.
    static func sourceName(_ provider: ChatProvider) -> String {
        provider.isCLI || provider.isLocal ? provider.displayName : "\(provider.displayName) API"
    }

    static func text(_ notice: ChatHistoryNotice, current: ChatProvider) -> String {
        switch notice {
        case .sourceDiffers(let chatSource, _, let newCLISession):
            let now = sourceName(current)
            let base = String(localized: "chat.history.notice.source",
                              defaultValue: "This chat went through \(chatSource). \(now) is selected now.")
            guard newCLISession else { return base }
            return base + " " + String(localized: "chat.history.notice.new-session",
                                       defaultValue: "Claude Code will start a new session, without the earlier context.")
        case .projectUnavailable(let name):
            return String(localized: "chat.history.notice.project",
                          defaultValue: "Project “\(name)” is not available — the next question starts a new Claude Code conversation without the earlier context.")
        }
    }
}
