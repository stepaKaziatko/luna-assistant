import Foundation

// MARK: - Тексты сбоев чата по подписке
//
// Каждый сбой — понятное сообщение в карточке-заметке, без падения. Для сбоев, которые лечит
// ключ API (нет CLI, не вошёл, лимит), к сообщению добавляется подсказка про ключ.
// Ключи локализации — `chat.cli.*` в Localizable.xcstrings; значения по умолчанию — английские.

enum ChatCLIMessages {
    /// Сбой, после которого уместно предложить ключ API.
    static func suggestsAPIKey(_ error: ClaudeCLIError) -> Bool {
        switch error {
        case .notFound, .notLoggedIn, .rateLimited, .unavailable: true
        default: false
        }
    }

    static func text(for error: ClaudeCLIError, hasAPIKey: Bool, locale: Locale = .current) -> String {
        let base: String
        switch error {
        case .notFound:
            base = String(localized: "chat.cli.error.not-found",
                          defaultValue: "Claude Code not found. Install the CLI, run `claude` and sign in with /login.")
        case .notLoggedIn:
            base = String(localized: "chat.cli.error.not-logged-in",
                          defaultValue: "Claude Code is not signed in. In Terminal: `claude auth login`.")
        case .rateLimited(let resetsAt):
            if let resetsAt {
                let time = resetsAt.formatted(.dateTime.hour().minute().locale(locale))
                base = String(localized: "chat.cli.error.rate-limit-at",
                              defaultValue: "Subscription limit reached, resets at \(time).")
            } else {
                base = String(localized: "chat.cli.error.rate-limit",
                              defaultValue: "Subscription limit reached.")
            }
        case .api(let message):
            base = String(localized: "chat.cli.error.api",
                          defaultValue: "Claude Code error: \(ChatCLIMessages.clip(message))")
        case .timeout:
            base = String(localized: "chat.cli.error.timeout",
                          defaultValue: "Claude Code did not answer in time and was stopped.")
        case .failed(let status, let tail):
            if tail.isEmpty {
                base = String(localized: "chat.cli.error.failed-code",
                              defaultValue: "Claude Code stopped unexpectedly (code \(Int(status))).")
            } else {
                base = String(localized: "chat.cli.error.failed",
                              defaultValue: "Claude Code stopped unexpectedly: \(ChatCLIMessages.clip(tail))")
            }
        case .empty:
            base = String(localized: "chat.cli.error.empty",
                          defaultValue: "Claude Code returned an empty answer.")
        case .cancelled:
            base = ""
        case .unavailable:
            base = String(localized: "chat.cli.error.unavailable",
                          defaultValue: "Claude Code chat is not available in this build.")
        case .projectFolderMissing(let path):
            base = String(localized: "chat.cli.error.project-missing",
                          defaultValue: "Project folder not found: \(path)")
        case .projectFolderNoAccess(let path):
            base = String(localized: "chat.cli.error.project-no-access",
                          defaultValue: "No access to the project folder: \(path)")
        }
        guard suggestsAPIKey(error) else { return base }
        let hint = hasAPIKey
            ? String(localized: "chat.cli.hint.switch-to-key", defaultValue: "You can switch to your API key.")
            : String(localized: "chat.cli.hint.add-key", defaultValue: "Or add an API key in Settings → Chat.")
        return base + " " + hint
    }

    /// Сообщение CLI обрезается: в карточку-заметку длинный текст не помещается.
    static func clip(_ text: String, limit: Int = 400) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    // Предложение вместо «API key missing», когда Claude Code готов.
    static var offerClaudeCode: String {
        String(localized: "chat.cli.offer.text",
               defaultValue: "No API key. Answer through Claude Code with your subscription?")
    }
    static var offerClaudeCodeButton: String {
        String(localized: "chat.cli.offer.button", defaultValue: "Use Claude Code")
    }
    static var useAPIKeyButton: String {
        String(localized: "chat.cli.use-key.button", defaultValue: "Answer with API key")
    }
    static var subscriptionWord: String {
        String(localized: "chat.cli.subscription", defaultValue: "subscription")
    }
}
