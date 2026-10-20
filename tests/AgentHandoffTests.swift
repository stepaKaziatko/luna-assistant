import Foundation

// «Открыть в…» (LUNA-79): план переноса без окна — какие сессии и пункты, ссылки, автомат
// ожидающего переноса и команда для терминала.

@main
enum AgentHandoffTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let uuid = "0b6f3c2a-5d4e-4f1a-9b8c-7d6e5f4a3b2c"
    static let terminal = "com.apple.Terminal"
    static let vscode = "com.microsoft.VSCode"
    static let desktop = "com.anthropic.claudefordesktop"
    static let allApps = AgentLaunchApps(vscode: true, vscodeExtension: true, terminalHandler: true, claudeDesktop: true)

    static func who(host: String = terminal, cwd: String = "/Users/me/shop/src",
                    projectDir: String = "/Users/me/shop") -> AgentSessionWho {
        AgentSessionWho(project: "shop", agent: "Claude Code", hostBundleId: host, cwd: cwd,
                        tty: "/dev/ttys003", projectDir: projectDir)
    }

    static func items(pill: String = "integration_claude", sessionId: String = uuid,
                      who: AgentSessionWho = who(), phase: AgentPhase = .finished, waiting: Bool = false,
                      apps: AgentLaunchApps = allApps, folderExists: Bool = true) -> [AgentHandoffMenu.Item] {
        AgentHandoffMenu.items(pill: pill, sessionId: sessionId, who: who, phase: phase, waiting: waiting,
                               apps: apps, folderExists: folderExists)
    }

    static func item(_ items: [AgentHandoffMenu.Item], _ action: AgentHandoffMenu.Item.Action) -> AgentHandoffMenu.Item? {
        items.first { $0.action == action }
    }

    static func actions(_ items: [AgentHandoffMenu.Item]) -> [AgentHandoffMenu.Item.Action] { items.map(\.action) }

    /// Что вернёт sh, если вывести строку `printf %s <quoted>`.
    static func shellRoundTrip(_ quoted: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(quoted)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    static func main() {

        // ── какие сессии ─────────────────────────────────────────────────────
        print("Eligible sessions")
        do {
            check("Claude Code in Terminal with a UUID: the button is there", !items().isEmpty)
            check("not Claude Code (Codex, Cursor, Gemini): no button",
                  items(pill: "agent_codex").isEmpty && items(pill: "agent_cursor").isEmpty
                  && items(pill: "agent_gemini").isEmpty)
            check("an id that is not a UUID: no button",
                  items(sessionId: "integration_claude+/Users/me/shop").isEmpty && items(sessionId: "").isEmpty
                  && items(sessionId: "../" + uuid).isEmpty && items(sessionId: uuid + "&x=1").isEmpty
                  && items(sessionId: "0b6f3c2a/5d4e-4f1a-9b8c-7d6e5f4a3b2c").isEmpty)
            check("a session that runs in Claude Desktop: no button (В5)", items(who: who(host: desktop)).isEmpty)
            check("isEligible matches",
                  AgentHandoffPlan.isEligible(pill: "integration_claude", sessionId: uuid, hostBundleId: terminal)
                  && !AgentHandoffPlan.isEligible(pill: "integration_claude", sessionId: uuid, hostBundleId: desktop))
        }

        // ── пункты ───────────────────────────────────────────────────────────
        print("\nMenu items")
        do {
            check("from Terminal: VS Code, Claude Desktop, copy command — in this order",
                  actions(items()) == [.open(.vscode), .open(.claudeDesktop), .copyCommand]
                  && items().allSatisfy(\.isEnabled))
            check("the host app is not offered: from VS Code no «VS Code»",
                  actions(items(who: who(host: vscode))) == [.open(.claudeDesktop), .copyCommand])
            check("not installed: no item",
                  actions(items(apps: AgentLaunchApps(claudeDesktop: true))) == [.open(.claudeDesktop), .copyCommand]
                  && actions(items(apps: AgentLaunchApps(vscode: true, vscodeExtension: true))) == [.open(.vscode), .copyCommand]
                  && actions(items(apps: AgentLaunchApps())) == [.copyCommand])
            check("VS Code without the extension: shown, disabled, says why",
                  item(items(apps: AgentLaunchApps(vscode: true)), .open(.vscode))?.blocked == .noVSCodeExtension)
            let working = items(phase: .working)
            check("the agent is working: both targets disabled with the reason",
                  item(working, .open(.vscode))?.blocked == .agentWorking
                  && item(working, .open(.claudeDesktop))?.blocked == .agentWorking)
            let waiting = items(phase: .finished, waiting: true)
            check("the agent waits for an answer: both targets disabled with the reason",
                  item(waiting, .open(.vscode))?.blocked == .agentWaiting
                  && item(waiting, .open(.claudeDesktop))?.blocked == .agentWaiting)
            check("idle, finished, error: enabled",
                  items(phase: .idle).allSatisfy(\.isEnabled) && items(phase: .error).allSatisfy(\.isEnabled))
            check("copying the command is not blocked by a turn",
                  item(working, .copyCommand)?.isEnabled == true && item(waiting, .copyCommand)?.isEnabled == true)
            for (label, w, exists) in [
                ("no folder at all", who(cwd: "", projectDir: ""), true),
                ("a relative path", who(cwd: "shop", projectDir: "shop"), true),
                ("a `..` segment", who(cwd: "", projectDir: "/Users/me/../shop"), true),
                ("the folder is gone", who(), false),
            ] {
                let list = items(who: w, folderExists: exists)
                check("\(label): «VS Code» disabled, «Claude Desktop» enabled",
                      item(list, .open(.vscode))?.blocked == .folderMissing
                      && item(list, .open(.claudeDesktop))?.isEnabled == true
                      && item(list, .copyCommand)?.blocked == .folderMissing)
            }
            check("the folder is the project root, then cwd",
                  AgentHandoffPlan.folder(of: who()) == "/Users/me/shop"
                  && AgentHandoffPlan.folder(of: who(projectDir: "")) == "/Users/me/shop/src")
        }

        // ── ссылки ───────────────────────────────────────────────────────────
        print("\nLinks")
        do {
            let code = AgentHandoffPlan.make(target: .vscode, pill: "integration_claude", sessionId: uuid, who: who())
            check("VS Code: the project folder, then exactly vscode://anthropic.claude-code/open?session=<uuid>",
                  code?.steps == [.openFolder("/Users/me/shop"),
                                  .openURL(URL(string: "vscode://anthropic.claude-code/open?session=\(uuid)")!)])
            check("VS Code: the folder is AgentJumpPlan.folder(of:)",
                  code?.steps.first == .openFolder(AgentJumpPlan.folder(of: who())!))
            let app = AgentHandoffPlan.make(target: .claudeDesktop, pill: "integration_claude", sessionId: uuid,
                                            who: who(cwd: "", projectDir: ""))
            check("Claude Desktop: exactly claude://resume?session=<uuid>, one step, no folder needed",
                  app?.steps == [.openURL(URL(string: "claude://resume?session=\(uuid)")!)])
            check("VS Code without a folder: no plan",
                  AgentHandoffPlan.make(target: .vscode, pill: "integration_claude", sessionId: uuid,
                                        who: who(cwd: "", projectDir: "")) == nil)
            check("a wrong id or pill: no plan",
                  AgentHandoffPlan.make(target: .claudeDesktop, pill: "integration_claude", sessionId: "abc", who: who()) == nil
                  && AgentHandoffPlan.make(target: .vscode, pill: "agent_cursor", sessionId: uuid, who: who()) == nil)
            check("the schemes are constants of the plan", AgentHandoffPlan.allowedSchemes == ["vscode", "claude"])
            // Ни одно поле сессии не попадает в схему или хост ссылки.
            let hostile = AgentSessionWho(project: "evil://x", agent: "javascript:alert(1)", hostBundleId: "evil",
                                          cwd: "/tmp/evil", tty: "", projectDir: "/tmp/x?session=y#z")
            var schemesOK = true
            for target in AgentHandoffTarget.allCases {
                guard let plan = AgentHandoffPlan.make(target: target, pill: "integration_claude", sessionId: uuid,
                                                       who: hostile) else { continue }
                for case .openURL(let url) in plan.steps {
                    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    schemesOK = schemesOK && AgentHandoffPlan.allowedSchemes.contains(url.scheme ?? "")
                        && ["anthropic.claude-code", "resume"].contains(url.host ?? "")
                        && comps?.queryItems == [URLQueryItem(name: "session", value: uuid)]
                }
            }
            check("session fields never reach the scheme, the host or the query", schemesOK)
        }

        // ── перенос ──────────────────────────────────────────────────────────
        print("\nPending handoff")
        do {
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            let key = "integration_claude|\(uuid)"
            let other = "integration_claude|11111111-2222-3333-4444-555555555555"
            let plan = AgentHandoffPlan.make(target: .vscode, pill: "integration_claude", sessionId: uuid, who: who())!
            let desktopPlan = AgentHandoffPlan.make(target: .claudeDesktop, pill: "integration_claude",
                                                    sessionId: uuid, who: who())!

            var book = AgentHandoffBook()
            book.request(plan, sessionKey: key, hostBundleId: terminal, now: t0)
            check("click: waiting", book.pending?.sessionKey == key && book.pending?.plan == plan
                  && book.pending?.deadline == t0.addingTimeInterval(300))
            check("SessionEnd of another session: nothing",
                  book.event("SessionEnd", sessionKey: other, now: t0 + 10) == .none && book.pending != nil)
            check("Stop, SessionStart, Notification of this session: still waiting",
                  book.event("Stop", sessionKey: key, now: t0 + 11) == .none
                  && book.event("SessionStart", sessionKey: key, now: t0 + 12) == .none
                  && book.event("Notification", sessionKey: key, now: t0 + 13) == .none && book.pending != nil)
            check("SessionEnd of this session: open",
                  book.event("SessionEnd", sessionKey: key, now: t0 + 20) == .open(plan, sessionKey: key)
                  && book.pending == nil)
            check("a second SessionEnd: nothing more", book.event("SessionEnd", sessionKey: key, now: t0 + 21) == .none)

            for name in ["UserPromptSubmit", "PreToolUse"] {
                var b = AgentHandoffBook()
                b.request(plan, sessionKey: key, hostBundleId: terminal, now: t0)
                check("\(name) of this session: cancelled, «continued»",
                      b.event(name, sessionKey: key, now: t0 + 5) == .cancelled(.resumed, sessionKey: key)
                      && b.pending == nil && b.event("SessionEnd", sessionKey: key, now: t0 + 6) == .none)
            }

            var timed = AgentHandoffBook()
            timed.request(plan, sessionKey: key, hostBundleId: terminal, now: t0)
            check("before 5 min: the timer does nothing", timed.expire(now: t0 + 299) == .none && timed.pending != nil)
            check("5 min without SessionEnd: cancelled, «did not close»",
                  timed.expire(now: t0 + 300) == .cancelled(.timedOut, sessionKey: key) && timed.pending == nil)
            var late = AgentHandoffBook()
            late.request(plan, sessionKey: key, hostBundleId: terminal, now: t0)
            check("SessionEnd after the deadline: does not open",
                  late.event("SessionEnd", sessionKey: key, now: t0 + 301) == .cancelled(.timedOut, sessionKey: key))

            var cancelled = AgentHandoffBook()
            cancelled.request(plan, sessionKey: key, hostBundleId: terminal, now: t0)
            check("«Cancel»: taken off without opening",
                  cancelled.cancel() == .cancelled(.byUser, sessionKey: key)
                  && cancelled.event("SessionEnd", sessionKey: key, now: t0 + 1) == .none)
            check("«Cancel» with nothing pending: nothing", cancelled.cancel() == .none)

            var replaced = AgentHandoffBook()
            replaced.request(plan, sessionKey: key, hostBundleId: terminal, now: t0)
            replaced.request(desktopPlan, sessionKey: other, hostBundleId: terminal, now: t0 + 30)
            check("a second click replaces the first: one waits",
                  replaced.pending?.sessionKey == other
                  && replaced.event("SessionEnd", sessionKey: key, now: t0 + 40) == .none
                  && replaced.event("SessionEnd", sessionKey: other, now: t0 + 41) == .open(desktopPlan, sessionKey: other))

            // Сессия пропала из списка по тишине (prune) — событий нет: перенос не исполняется,
            // а по сроку снимается.
            var pruned = AgentHandoffBook()
            pruned.request(plan, sessionKey: key, hostBundleId: terminal, now: t0)
            var sessions = AgentSessionBook()
            sessions.apply(event: "SessionStart", key: AgentSessionKey(pill: "integration_claude", session: uuid),
                           who: who(), now: t0)
            let gone = sessions.snapshot(waits: [:], now: t0 + AgentSessionBook.maxIdleSilence + 60).isEmpty
            check("a session pruned for silence, no SessionEnd: never opens",
                  gone && pruned.expire(now: t0 + 600) == .cancelled(.timedOut, sessionKey: key))
        }

        // ── статус ───────────────────────────────────────────────────────────
        print("\nStatus")
        do {
            let plan = AgentHandoffPlan.make(target: .claudeDesktop, pill: "integration_claude", sessionId: uuid, who: who())!
            let pending = AgentHandoffPending(sessionKey: "k", plan: plan, hostBundleId: terminal, deadline: Date())
            check("every status belongs to its session",
                  AgentHandoffStatus.waiting(pending).sessionKey == "k"
                  && AgentHandoffStatus.opening(.vscode, sessionKey: "k").sessionKey == "k"
                  && AgentHandoffStatus.cancelled(.byUser, sessionKey: "k").sessionKey == "k"
                  && AgentHandoffStatus.appMissing(.vscode, sessionKey: "k").sessionKey == "k"
                  && AgentHandoffStatus.folderMissing(sessionKey: "k").sessionKey == "k"
                  && AgentHandoffStatus.copied(sessionKey: "k").sessionKey == "k")
            check("only waiting is waiting",
                  AgentHandoffStatus.waiting(pending).isWaiting && !AgentHandoffStatus.copied(sessionKey: "k").isWaiting)
        }

        // ── команда для терминала ────────────────────────────────────────────
        print("\nTerminal command")
        do {
            check("exactly cd '<folder>' && claude --resume <uuid>",
                  AgentHandoffPlan.terminalCommand(who: who(), sessionId: uuid)
                  == "cd '/Users/me/shop' && claude --resume \(uuid)")
            check("a single quote is written as '\\''",
                  AgentHandoffPlan.terminalCommand(who: who(projectDir: "/Users/me/it's"), sessionId: uuid)
                  == #"cd '/Users/me/it'\''s' && claude --resume "# + uuid)
            for path in ["/Users/me/my shop", "/Users/me/$HOME", "/Users/me/`whoami`", "/Users/me/a;rm -rf x",
                         "/Users/me/проект", "/Users/me/it's", "/Users/me/a\"b", "/Users/me/*", "/Users/me/a\\b"] {
                check("sh reads back \(path)", shellRoundTrip(AgentHandoffPlan.shellQuote(path)) == path)
            }
            check("a wrong folder: no command",
                  AgentHandoffPlan.terminalCommand(who: who(cwd: "", projectDir: ""), sessionId: uuid) == nil
                  && AgentHandoffPlan.terminalCommand(who: who(cwd: "", projectDir: "shop"), sessionId: uuid) == nil
                  && AgentHandoffPlan.terminalCommand(who: who(cwd: "", projectDir: "/a/../b"), sessionId: uuid) == nil)
            check("a wrong id: no command",
                  AgentHandoffPlan.terminalCommand(who: who(), sessionId: "x; rm -rf ~") == nil
                  && AgentHandoffPlan.terminalCommand(who: who(), sessionId: "") == nil)
        }

        if failures > 0 {
            print("\n\(failures) failure(s)")
            exit(1)
        }
        print("\nAll agent handoff tests passed")
    }
}
