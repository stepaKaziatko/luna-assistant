import Foundation
import Darwin

@main
enum AgentJumpTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let claude = "integration_claude"
    static let uuid = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    static let uuidLower = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

    static let vsCode = "com.microsoft.VSCode"
    static let cursor = "com.todesktop.230313mzl4w4u92"

    static func who(host: String, cwd: String = "/Users/me/shop", tty: String = "",
                    project: String = "shop", agent: String = "Claude Code") -> AgentSessionWho {
        AgentSessionWho(project: project, agent: agent, hostBundleId: host, cwd: cwd, tty: tty)
    }

    static func plan(_ w: AgentSessionWho) -> AgentJumpPlan.Action {
        AgentJumpPlan.make(pill: claude, sessionId: uuid, who: w).action
    }

    static func plan(_ pill: String, session: String = uuid, _ w: AgentSessionWho) -> AgentJumpPlan.Action {
        AgentJumpPlan.make(pill: pill, sessionId: session, who: w).action
    }

    static func link(_ action: AgentJumpPlan.Action) -> String? {
        if case .editor(_, _, let url) = action { return url?.absoluteString }
        return nil
    }

    static func main() {

        // ── the plan by host ────────────────────────────────────────────────────
        print("\nPlan by host")
        do {
            let editors: [(String, String)] = [
                (vsCode, "vscode"), ("com.microsoft.VSCodeInsiders", "vscode-insiders"),
                ("com.vscodium", "vscodium"), ("com.vscodium.codium", "vscodium"),
                ("com.exafunction.windsurf", "windsurf"),
            ]
            for (bundle, scheme) in editors {
                let a = plan(who(host: bundle))
                check("\(bundle): folder and the link of the extension",
                      a == .editor(bundleId: bundle, folder: "/Users/me/shop",
                                   sessionLink: URL(string: "\(scheme)://anthropic.claude-code/open?session=\(uuid)")))
            }
            check("Cursor: the folder only, no link (its two agents cannot be told apart)",
                  plan("agent_cursor", who(host: cursor))
                  == .editor(bundleId: cursor, folder: "/Users/me/shop", sessionLink: nil))
            check("Terminal with a tty: the tab",
                  plan(who(host: "com.apple.Terminal", tty: "/dev/ttys003"))
                  == .terminalTab(.terminal, tty: "/dev/ttys003", folder: "/Users/me/shop"))
            check("iTerm2 with a tty: the tab",
                  plan(who(host: "com.googlecode.iterm2", tty: "/dev/ttys012"))
                  == .terminalTab(.iTerm, tty: "/dev/ttys012", folder: "/Users/me/shop"))
            check("Terminal without a tty: activate",
                  plan(who(host: "com.apple.Terminal"))
                  == .activate(bundleId: "com.apple.Terminal", folder: "/Users/me/shop"))
            check("Terminal with a tty that is not a device: activate",
                  plan(who(host: "com.apple.Terminal", tty: "/dev/null"))
                  == .activate(bundleId: "com.apple.Terminal", folder: "/Users/me/shop"))
            for id in ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "com.mitchellh.ghostty",
                       "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
                       "dev.zed.Zed", "com.cmuxterm.app", "com.stablyai.orca"] {
                check("\(id) is a known terminal and is only activated",
                      ClaudeHost.isTerminal(bundleId: id)
                      && plan(who(host: id, tty: "/dev/ttys003"))
                      == .activate(bundleId: id, folder: "/Users/me/shop"))
            }
            check("Terminal.app and iTerm2 are known terminals too",
                  ClaudeHost.isTerminal(bundleId: "com.apple.Terminal")
                  && ClaudeHost.isTerminal(bundleId: "com.googlecode.iterm2"))
            check("an unknown host with a folder: the folder in Finder",
                  plan("agent_gemini", session: "s1", who(host: "", agent: "Gemini CLI"))
                  == .revealFolder("/Users/me/shop"))
            check("no host and no folder: unavailable",
                  plan("agent_gemini", who(host: "", cwd: "")) == .unavailable
                  && !AgentJumpPlan.make(pill: "agent_gemini", sessionId: "s", who: who(host: "", cwd: "")).isAvailable)
            check("an editor with no folder is still opened",
                  plan(who(host: vsCode, cwd: ""))
                  == .editor(bundleId: vsCode, folder: nil,
                             sessionLink: URL(string: "vscode://anthropic.claude-code/open?session=\(uuid)")))
            check("a relative folder is dropped",
                  plan(who(host: "dev.warp.Warp-Stable", cwd: "shop"))
                  == .activate(bundleId: "dev.warp.Warp-Stable", folder: nil))
            check("a folder of a third-party agent is kept although its tile carries the agent's name",
                  plan("agent_gemini", who(host: "com.apple.Terminal", cwd: "/Users/me/api",
                                           project: "Gemini CLI", agent: "Gemini CLI"))
                  == .activate(bundleId: "com.apple.Terminal", folder: "/Users/me/api"))
        }

        // ── the link: whitelist and session id ─────────────────────────────────
        print("\nSession link")
        do {
            check("the id is taken as it is, upper or lower case",
                  link(plan(who(host: vsCode))) == "vscode://anthropic.claude-code/open?session=\(uuid)"
                  && link(plan(claude, session: uuidLower, who(host: vsCode)))
                  == "vscode://anthropic.claude-code/open?session=\(uuidLower)")
            let bad = [
                "3F2504E0-4F89-41D3-9A0C-0305E82C3301&x=1", "3F2504E0-4F89-41D3-9A0C-0305E82C330 ",
                "3F2504E0-4F89-41D3-9A0C-0305E82C3301;", "3F2504E0-4F89-41D3-9A0C-0305E82C330\"",
                "3F2504E0-4F89-41D3-9A0C-0305E82C330G", "3F2504E04F8941D39A0C0305E82C3301",
                "3F2504E0-4F89-41D3-9A0C", "", "unknown", "integration_claude+/Users/me/shop",
                "../../etc/passwd", "3F2504E0-4F89-41D3-9A0C-0305E82C3301\n",
            ]
            for id in bad {
                check("session id \(id.debugDescription) gives no link, the folder is still opened",
                      plan(claude, session: id, who(host: vsCode))
                      == .editor(bundleId: vsCode, folder: "/Users/me/shop", sessionLink: nil))
            }
            // Schemes outside the whitelist never make a link, whatever the editor says.
            for scheme in ["javascript", "file", "http", "https", "VSCODE", "vscode ", "vscodex", "x-man-page", ""] {
                let u = AgentJumpPlan.sessionLink(editor: AgentEditors.Editor(name: "x", scheme: scheme),
                                                  pill: claude, sessionId: uuid)
                check("scheme \(scheme.debugDescription) is not opened", u == nil)
            }
            for scheme in AgentEditors.allowedSchemes {
                let u = AgentJumpPlan.sessionLink(editor: AgentEditors.Editor(name: "x", scheme: scheme),
                                                  pill: claude, sessionId: uuid)
                check("scheme \(scheme) is on the list", u?.scheme == scheme && u?.host == "anthropic.claude-code")
            }
            check("every editor of the table uses a scheme from the list",
                  ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
                   "com.vscodium.codium", cursor, "com.exafunction.windsurf"]
                    .allSatisfy { AgentEditors.editor(bundleId: $0).map { AgentEditors.allowedSchemes.contains($0.scheme) } == true })
            for pill in ["agent_codex", "agent_copilot", "agent_gemini", "agent_muse", "agent_cursor", "agent_hermes"] {
                check("\(pill) has no tab to link to",
                      link(plan(pill, who(host: vsCode))) == nil)
            }
            check("a session made of pill and folder is not an id",
                  AgentSessionKey.make(pill: claude, sessionId: "unknown", cwd: "/a").session.contains("+")
                  && link(plan(claude, session: AgentSessionKey.make(pill: claude, sessionId: "unknown", cwd: "/a").session,
                               who(host: vsCode))) == nil)
        }

        // ── LUNA-68: папка проекта и шаги перехода в редактор ─────────────────
        print("\nProject folder and editor steps")
        do {
            // События сессии: project_dir=/p, cwd=/p, затем cwd=/p/.worktrees/X/apps.
            var book = AgentSessionBook()
            let key = AgentSessionKey(pill: claude, session: uuid)
            let t = Date(timeIntervalSince1970: 1_800_000_000)
            book.apply(event: "SessionStart", key: key,
                       who: AgentSessionWho(project: "p", agent: "Claude Code", hostBundleId: vsCode, cwd: "/p", projectDir: "/p"),
                       now: t)
            book.apply(event: "PreToolUse", key: key,
                       who: AgentSessionWho(project: "apps", agent: "Claude Code", hostBundleId: vsCode,
                                            cwd: "/p/.worktrees/X/apps", projectDir: "/p"),
                       tool: "Bash", step: "cd", now: t.addingTimeInterval(1))
            if let s = book.snapshot(now: t.addingTimeInterval(2)).first {
                check("the folder of the plan is the project root, not the last cwd",
                      AgentJumpPlan.make(pill: s.pill, sessionId: s.key.session, who: s.who).action
                      == .editor(bundleId: vsCode, folder: "/p",
                                 sessionLink: URL(string: "vscode://anthropic.claude-code/open?session=\(uuid)")))
            } else {
                check("the session is in the book", false)
            }
            // Без project_dir: cwd первого события.
            var noDir = AgentSessionBook()
            noDir.apply(event: "UserPromptSubmit", key: key,
                        who: AgentSessionWho(project: "p", agent: "Claude Code", hostBundleId: vsCode, cwd: "/p"),
                        step: "x", now: t)
            noDir.apply(event: "PreToolUse", key: key,
                        who: AgentSessionWho(project: "sub", agent: "Claude Code", hostBundleId: vsCode, cwd: "/p/sub"),
                        tool: "Bash", step: "cd", now: t.addingTimeInterval(1))
            if let s = noDir.snapshot(now: t.addingTimeInterval(2)).first {
                check("without project_dir the folder is the cwd of the first event",
                      AgentJumpPlan.make(pill: s.pill, sessionId: s.key.session, who: s.who).action
                      == .editor(bundleId: vsCode, folder: "/p",
                                 sessionLink: URL(string: "vscode://anthropic.claude-code/open?session=\(uuid)")))
            }
            // project_dir проходит ту же проверку, что папка.
            for bad in ["p", "relative/dir", "/a\nb", "/a\u{0}b", "~/p"] {
                let w = AgentSessionWho(project: "p", agent: "Claude Code", hostBundleId: vsCode,
                                        cwd: "/fallback", projectDir: bad)
                check("project_dir \(bad.debugDescription) is dropped, the cwd is taken",
                      AgentJumpPlan.folder(of: w) == "/fallback")
            }
            check("a valid project_dir wins over the cwd",
                  AgentJumpPlan.folder(of: AgentSessionWho(project: "p", agent: "a", cwd: "/p/sub", projectDir: "/p")) == "/p")
            check("no folder at all: nil",
                  AgentJumpPlan.folder(of: AgentSessionWho(project: "p", agent: "a")) == nil)

            let link = URL(string: "vscode://anthropic.claude-code/open?session=\(uuid)")!
            check("editor not running: the folder only, no link",
                  AgentJumpPlan.editorSteps(folder: "/p", link: link, editorRunning: false) == [.openFolder("/p")])
            check("editor running and a link: the folder, then the link",
                  AgentJumpPlan.editorSteps(folder: "/p", link: link, editorRunning: true)
                  == [.openFolder("/p"), .openSessionLink(link)])
            check("no link: the folder only",
                  AgentJumpPlan.editorSteps(folder: "/p", link: nil, editorRunning: true) == [.openFolder("/p")])
            check("no folder, editor running, a link: the link alone",
                  AgentJumpPlan.editorSteps(folder: nil, link: link, editorRunning: true) == [.openSessionLink(link)])
            check("no folder, editor not running: the app only, no link",
                  AgentJumpPlan.editorSteps(folder: nil, link: link, editorRunning: false) == [.activateApp])
            check("nothing at all: the app only",
                  AgentJumpPlan.editorSteps(folder: nil, link: nil, editorRunning: true) == [.activateApp])
            // Шага «новая сессия» нет: любая ссылка в шагах — ссылка на ту же сессию.
            let all = [true, false].flatMap { running in
                [("/p" as String?), nil].flatMap { f in
                    [link as URL?, nil].map { AgentJumpPlan.editorSteps(folder: f, link: $0, editorRunning: running) } } }
            check("no branch opens anything but the folder, the session link or the app",
                  all.allSatisfy { $0.allSatisfy { step in
                      switch step {
                      case .openFolder(let f): return f == "/p"
                      case .openSessionLink(let u): return u == link
                      case .activateApp: return true
                      }
                  } })

            check("link ready: the editor is in front and its top window changed",
                  AgentJumpPlan.linkReady(editorFrontmost: true, topWindowBefore: 10, topWindowNow: 11)
                  && AgentJumpPlan.linkReady(editorFrontmost: true, topWindowBefore: nil, topWindowNow: 11))
            check("link not ready: the editor is not in front",
                  !AgentJumpPlan.linkReady(editorFrontmost: false, topWindowBefore: 10, topWindowNow: 11))
            check("link not ready: the same window is still on top (the wait limit sends it)",
                  !AgentJumpPlan.linkReady(editorFrontmost: true, topWindowBefore: 10, topWindowNow: 10)
                  && !AgentJumpPlan.linkReady(editorFrontmost: true, topWindowBefore: 10, topWindowNow: nil))
            check("the wait limit is at most 1.5 s", AgentJumpPlan.linkWaitLimit > 0 && AgentJumpPlan.linkWaitLimit <= 1.5)
        }

        // ── tty and folder checks ───────────────────────────────────────────────
        print("\nChecks")
        do {
            for ok in ["/dev/ttys003", "/dev/ttys0", "/dev/ttys9999", "/dev/ttys12"] {
                check("tty \(ok) passes", AgentJumpPlan.validTTY(ok) == ok)
            }
            for bad in ["/dev/ttys", "/dev/null", "/dev/ttys003\"; do shell script \"x\"", "", "/dev/ttys00003",
                        "/dev/tty", "ttys003", "/dev/ttys003 ", "/dev/ttys00a", "/dev/ttyp1", "/dev/ttys-1",
                        "/dev/ttys003\n"] {
                check("tty \(bad.debugDescription) is refused", AgentJumpPlan.validTTY(bad) == nil)
            }
            check("a folder is an absolute path", AgentJumpPlan.validFolder("/Users/me/shop") == "/Users/me/shop")
            check("a relative path is not a folder", AgentJumpPlan.validFolder("shop") == nil
                  && AgentJumpPlan.validFolder("") == nil && AgentJumpPlan.validFolder("~/shop") == nil)
            check("control characters are refused", AgentJumpPlan.validFolder("/a\nb") == nil
                  && AgentJumpPlan.validFolder("/a\u{0}b") == nil)
        }

        // ── AppleScript ─────────────────────────────────────────────────────────
        print("\nAppleScript")
        do {
            let t = AgentTerminalScript.source(for: .terminal, tty: "/dev/ttys003")
            let i = AgentTerminalScript.source(for: .iTerm, tty: "/dev/ttys012")
            check("Terminal: selects the tab with the tty",
                  t?.contains("com.apple.Terminal") == true && t?.contains("tty of t is \"/dev/ttys003\"") == true
                  && t?.contains("set selected of t to true") == true)
            check("iTerm2: selects the session with the tty",
                  i?.contains("com.googlecode.iterm2") == true && i?.contains("tty of s is \"/dev/ttys012\"") == true
                  && i?.contains("select s") == true)
            check("an invalid tty gives no script at all",
                  AgentTerminalScript.source(for: .terminal, tty: "/dev/ttys003\"; do shell script \"rm\"") == nil
                  && AgentTerminalScript.source(for: .iTerm, tty: "") == nil
                  && AgentTerminalScript.source(for: .terminal, tty: "/dev/null") == nil)
            // Nothing of the session but the tty gets into a script.
            let w = who(host: "com.apple.Terminal", cwd: "/Users/me/secret-project", tty: "/dev/ttys003",
                        project: "secret-project")
            if case .terminalTab(let term, let tty, _) = plan(w) {
                let s = AgentTerminalScript.source(for: term, tty: tty) ?? ""
                check("the script carries no folder, project or session id",
                      !s.contains("secret") && !s.contains("Users") && !s.contains(uuid))
            } else {
                check("Terminal plan has a tab", false)
            }
            check("outcome: no permission", AgentTerminalScript.outcome(errorNumber: -1743, result: nil) == .noPermission)
            check("outcome: other errors", AgentTerminalScript.outcome(errorNumber: -600, result: nil) == .failed(-600)
                  && AgentTerminalScript.outcome(errorNumber: -1, result: "selected") == .failed(-1))
            check("outcome: selected", AgentTerminalScript.outcome(errorNumber: nil, result: "selected") == .selected)
            check("outcome: tab not found is not an error",
                  AgentTerminalScript.outcome(errorNumber: nil, result: "notfound") == .tabNotFound
                  && AgentTerminalScript.outcome(errorNumber: nil, result: nil) == .tabNotFound
                  && AgentTerminalScript.outcome(errorNumber: nil, result: "") == .tabNotFound)
        }

        // ── the terminal of a hook's sender ─────────────────────────────────────
        print("\nProcessTTY")
        do {
            // hook(100) → agent(90) → shell(80, on a pty) → login(70)
            let table: [Int32: ProcessTTY.Entry] = [
                100: .init(parent: 90, terminal: nil),
                90:  .init(parent: 80, terminal: nil),
                80:  .init(parent: 70, terminal: 5),
                70:  .init(parent: 1, terminal: 5),
            ]
            let names: [Int32: String] = [5: "ttys003", 6: "console", 7: "ttys0007x"]
            func tty(_ pid: Int32, _ t: [Int32: ProcessTTY.Entry]) -> String? {
                ProcessTTY.tty(from: pid, entry: { t[$0] }, name: { names[$0] })
            }
            check("the nearest process with a terminal gives the tty", tty(100, table) == "/dev/ttys003")
            check("a hook that has its own terminal gives it",
                  tty(80, table) == "/dev/ttys003")
            check("no process with a terminal: nil (a hook of a GUI app)",
                  tty(100, [100: .init(parent: 90, terminal: nil), 90: .init(parent: 1, terminal: nil)]) == nil)
            check("a terminal that is not a pty (the console) is skipped",
                  tty(100, [100: .init(parent: 90, terminal: 6), 90: .init(parent: 80, terminal: 5), 80: .init(parent: 1, terminal: nil)])
                  == "/dev/ttys003")
            check("a name that is not a valid tty is skipped",
                  tty(100, [100: .init(parent: 1, terminal: 7)]) == nil)
            check("a missing process ends the walk", tty(100, [:]) == nil)
            check("a loop in the table ends the walk",
                  tty(100, [100: .init(parent: 90, terminal: nil), 90: .init(parent: 100, terminal: nil)]) == nil)
            var deep: [Int32: ProcessTTY.Entry] = [:]
            for n in 100..<140 { deep[Int32(n)] = .init(parent: Int32(n) + 1, terminal: nil) }
            deep[140] = .init(parent: 1, terminal: 5)
            check("the walk stops at its depth limit", tty(100, deep) == nil)

            // The real process table: this process, its parent.
            let me = ProcessTTY.systemEntry(getpid())
            check("the process table knows this process and its parent",
                  me?.parent == getppid())
            check("a pid that does not exist is nil", ProcessTTY.systemEntry(2_000_000_000) == nil)

            // A real pty: a child on its own terminal, as an agent in a Terminal tab.
            var master: Int32 = 0
            let child = forkpty(&master, nil, nil, nil)
            if child == 0 {
                var argv: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("20"), nil]
                execv("/bin/sleep", &argv)
                _exit(1)
            }
            if child > 0 {
                // Give the child a moment to take its terminal.
                var found: String? = nil
                for _ in 0..<50 {
                    found = ProcessTTY.tty(from: child)
                    if found != nil { break }
                    usleep(40_000)
                }
                let expected = String(cString: ptsname(master))
                check("the real tty of a child on a pty is its slave device", found == expected)
                kill(child, SIGKILL)
                var status: Int32 = 0
                waitpid(child, &status, 0)
                close(master)
            } else {
                check("forkpty", false)
            }

            // The pid of the peer of a socket pair is this process.
            var fds: [Int32] = [0, 0]
            if socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 {
                check("the peer pid of a socket is read", ProcessTTY.peerPID(of: fds[0]) == getpid())
                close(fds[0]); close(fds[1])
            }
        }

        print(failures == 0 ? "\nAll agent jump checks passed" : "\n\(failures) check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
