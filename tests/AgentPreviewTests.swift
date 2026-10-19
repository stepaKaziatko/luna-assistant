import Foundation

@main
enum AgentPreviewTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    typealias Logic = AgentPreviewLogic

    static let a = "integration_claude|sess-a"
    static let b = "agent_codex|sess-b"

    static func req(_ session: String, position: Int, total: Int, tool: String = "Bash",
                    command: String = "ls", pill: String = "integration_claude", id: UUID = UUID()) -> AgentRequest {
        AgentRequest(id: id, sessionKey: session, pill: pill, tool: tool, command: command,
                     position: position, total: total)
    }

    static func main() {

        // ── which request the page offers ───────────────────────────────────────
        print("\nRequest of a session")
        do {
            let ra = req(a, position: 1, total: 2), rb = req(b, position: 2, total: 2)
            check("the head of the queue is answerable on its session",
                  Logic.request(sessionKey: a, requests: [ra, rb], questionOwner: nil, questionId: nil) == .approval(ra))
            let queued = Logic.request(sessionKey: b, requests: [ra, rb], questionOwner: nil, questionId: nil)
            check("a request that is not the head is read only (№2 of 2)",
                  queued == .queued(rb) && !queued.isAnswerable && queued.answerId == nil
                  && rb.position == 2 && rb.total == 2 && !rb.isHead)
            check("the head is answerable by its id",
                  Logic.request(sessionKey: a, requests: [ra, rb], questionOwner: nil, questionId: nil).answerId == ra.id)
            // After the head is answered, the next one gets its buttons.
            let rb1 = req(b, position: 1, total: 1, id: rb.id)
            check("when the head is answered the next request becomes the head",
                  Logic.request(sessionKey: b, requests: [rb1], questionOwner: nil, questionId: nil) == .approval(rb1))
            check("a session with nothing pending has no request",
                  Logic.request(sessionKey: "x|y", requests: [ra, rb], questionOwner: nil, questionId: nil) == .none)

            let qid = UUID()
            let q = Logic.request(sessionKey: a, requests: [], questionOwner: a, questionId: qid)
            check("the question of its owner is answerable", q == .question(id: qid) && q.isAnswerable && q.answerId == qid)
            check("the question of another session is not shown",
                  Logic.request(sessionKey: b, requests: [], questionOwner: a, questionId: qid) == .none)
            check("an owner without an id has no question",
                  Logic.request(sessionKey: a, requests: [], questionOwner: a, questionId: nil) == .none)
            check("a head request wins over a question of the same session",
                  Logic.request(sessionKey: a, requests: [ra], questionOwner: a, questionId: qid) == .approval(ra))
        }

        // ── a request went away ─────────────────────────────────────────────────
        print("\nNotice")
        do {
            let ra = req(a, position: 1, total: 1)
            let qid = UUID()
            check("a request taken elsewhere: 'already gone'",
                  Logic.notice(old: .approval(ra), new: .none, answeredHere: nil, sessionKey: a, questionOwnerNow: nil) == .requestGone)
            check("an answer given here is no news",
                  Logic.notice(old: .approval(ra), new: .none, answeredHere: ra.id, sessionKey: a, questionOwnerNow: nil) == nil)
            check("a question answered here is no news",
                  Logic.notice(old: .question(id: qid), new: .none, answeredHere: qid, sessionKey: a, questionOwnerNow: nil) == nil)
            check("a question that vanished (terminal, timeout): 'already gone'",
                  Logic.notice(old: .question(id: qid), new: .none, answeredHere: nil, sessionKey: a, questionOwnerNow: nil) == .requestGone)
            check("a question displaced by a newer one of another session: 'went to the terminal'",
                  Logic.notice(old: .question(id: qid), new: .none, answeredHere: nil, sessionKey: a, questionOwnerNow: b) == .handedToTerminal)
            check("a queued request that vanished: 'already gone'",
                  Logic.notice(old: .queued(req(b, position: 2, total: 2)), new: .none, answeredHere: nil,
                               sessionKey: b, questionOwnerNow: nil) == .requestGone)
            check("a queued request that reached the head is the same request: no news",
                  Logic.notice(old: .queued(req(b, position: 2, total: 2, id: ra.id)),
                               new: .approval(req(b, position: 1, total: 1, id: ra.id)),
                               answeredHere: nil, sessionKey: b, questionOwnerNow: nil) == nil)
            check("nothing before, nothing now: no news",
                  Logic.notice(old: .none, new: .none, answeredHere: nil, sessionKey: a, questionOwnerNow: nil) == nil)
            check("a request that appeared is no news",
                  Logic.notice(old: .none, new: .approval(ra), answeredHere: nil, sessionKey: a, questionOwnerNow: nil) == nil)
        }

        // ── a session without buttons ───────────────────────────────────────────
        print("\nNo buttons")
        do {
            check("Claude Code in a terminal with the setting off: terminal cards are off",
                  Logic.noCards(pill: "integration_claude", hostBundleId: "com.apple.Terminal", terminalCardsEnabled: false) == .terminalCardsOff
                  && Logic.noCards(pill: "integration_claude", hostBundleId: "dev.warp.Warp-Stable", terminalCardsEnabled: false) == .terminalCardsOff)
            check("with the setting on a terminal session has cards",
                  Logic.noCards(pill: "integration_claude", hostBundleId: "com.apple.Terminal", terminalCardsEnabled: true) == nil)
            check("Claude Code in VS Code always has cards",
                  Logic.noCards(pill: "integration_claude", hostBundleId: "com.microsoft.VSCode", terminalCardsEnabled: false) == nil
                  && Logic.noCards(pill: "integration_claude", hostBundleId: "", terminalCardsEnabled: false) == nil)
            check("Cursor and Codex have cards",
                  Logic.noCards(pill: "agent_cursor", hostBundleId: "com.todesktop.230313mzl4w4u92", terminalCardsEnabled: false) == nil
                  && Logic.noCards(pill: "agent_codex", hostBundleId: "com.apple.Terminal", terminalCardsEnabled: false) == nil)
            for pill in ["agent_gemini", "agent_antigravity", "agent_opencode", "agent_amp", "agent_claude_desktop"] {
                check("\(pill) is only shown", Logic.noCards(pill: pill, hostBundleId: "", terminalCardsEnabled: true) == .observedOnly)
            }
        }

        // ── text ────────────────────────────────────────────────────────────────
        print("\nFolder name")
        do {
            check("the last component of the folder", Logic.folderName(cwd: "/Users/me/api", project: "Gemini CLI") == "api")
            check("nothing new next to the same project name", Logic.folderName(cwd: "/Users/me/shop", project: "shop") == nil)
            check("no folder, no name", Logic.folderName(cwd: "", project: "shop") == nil
                  && Logic.folderName(cwd: "/", project: "shop") == nil)
        }

        print(failures == 0 ? "\nAll agent preview checks passed" : "\n\(failures) check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
