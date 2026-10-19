import Foundation

// MARK: - Preview page of an agent: what it shows
//
// The page is one more view over the queues `HookServer` already owns (permission requests, the
// one held question), not a queue of its own. The decisions the page takes — which request of
// its session it may answer, when to tell that the request is gone, why a session has no
// buttons — are pure functions here, tested without a window (`scripts/test-agent-preview.sh`).

enum AgentPreviewLogic {

    // MARK: Which request

    /// What the page offers for its session right now.
    enum Request: Equatable {
        /// A permission request at the head of the queue: Deny / Allow / Always.
        case approval(AgentRequest)
        /// The question the app holds for this session.
        case question(id: UUID)
        /// A permission request that is not at the head: shown, not answerable. The order of
        /// answers is the queue's, and the page does not change it.
        case queued(AgentRequest)
        case none

        /// Whether buttons are shown.
        var isAnswerable: Bool {
            switch self {
            case .approval, .question: return true
            case .queued, .none:       return false
            }
        }

        /// The id a surface answers with; nil when nothing can be answered.
        var answerId: UUID? {
            switch self {
            case .approval(let r): return r.id
            case .question(let id): return id
            case .queued, .none: return nil
            }
        }
    }

    /// The request of the session `sessionKey` (`AgentSessionKey.id`).
    /// - Parameters:
    ///   - requests: the permission requests in queue order.
    ///   - questionOwner/questionId: the held question and who asks it, nil when none is held.
    static func request(sessionKey: String, requests: [AgentRequest],
                        questionOwner: String?, questionId: UUID?) -> Request {
        let mine = requests.filter { $0.sessionKey == sessionKey }
        if let head = mine.first(where: { $0.isHead }) { return .approval(head) }
        if let owner = questionOwner, owner == sessionKey, let id = questionId { return .question(id: id) }
        if let first = mine.first { return .queued(first) }
        return .none
    }

    // MARK: A request that went away

    enum Notice: Equatable {
        /// Answered somewhere else (the terminal, the card), timed out, or the agent hung up.
        case requestGone
        /// A newer question displaced this one: it went back to its terminal.
        case handedToTerminal
    }

    /// What to tell when the request on the page changed. `answeredHere` is the id this page
    /// answered itself: its own answer is not news.
    /// `questionOwnerNow` is who holds the question now (nil when none).
    static func notice(old: Request, new: Request, answeredHere: UUID?,
                       sessionKey: String, questionOwnerNow: String?) -> Notice? {
        func id(_ r: Request) -> UUID? {
            switch r {
            case .approval(let a), .queued(let a): return a.id
            case .question(let q): return q
            case .none: return nil
            }
        }
        guard let oldId = id(old), oldId != id(new) else { return nil }
        if oldId == answeredHere { return nil }
        if case .question = old, let owner = questionOwnerNow, owner != sessionKey {
            return .handedToTerminal
        }
        return .requestGone
    }

    // MARK: No buttons

    /// Why a session that does not wait for anything has no way to be answered here.
    enum NoCards: Equatable {
        /// A terminal session while "cards from the terminal" is off in Settings.
        case terminalCardsOff
        /// An agent whose questions and requests Luna does not take at all.
        case observedOnly
    }

    /// Pills whose requests Luna takes (the card shows them).
    private static let carded: Set<String> = [
        "integration_claude", "agent_cursor", "agent_codex",
        "agent_copilot", "agent_muse", "agent_hermes",
    ]

    static func noCards(pill: String, hostBundleId: String, terminalCardsEnabled: Bool) -> NoCards? {
        guard carded.contains(pill) else { return .observedOnly }
        // Claude Code in a terminal: asks itself unless the setting is on.
        let editorHost = hostBundleId.isEmpty || AgentEditors.editor(bundleId: hostBundleId) != nil
        if pill == "integration_claude", !editorHost, !terminalCardsEnabled { return .terminalCardsOff }
        return nil
    }

    // MARK: Text

    /// The last component of a folder, nil when the folder is empty or says nothing new next
    /// to the project name already shown.
    static func folderName(cwd: String, project: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" || name == project ? nil : name
    }
}
