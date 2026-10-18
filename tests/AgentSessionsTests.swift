import Foundation

@main
enum AgentSessionsTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let claude = "integration_claude"
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    static func key(_ session: String, pill: String = claude) -> AgentSessionKey {
        AgentSessionKey(pill: pill, session: session)
    }

    static func who(_ project: String, agent: String = "Claude Code", host: String = "") -> AgentSessionWho {
        AgentSessionWho(project: project, agent: agent, hostBundleId: host)
    }

    static func info(_ book: AgentSessionBook, _ k: AgentSessionKey,
                     waits: [AgentSessionKey: AgentWait] = [:], now: Date) -> AgentSessionInfo? {
        book.snapshot(waits: waits, now: now).first { $0.key == k }
    }

    static func main() {

        // ── Claude Code: a turn from start to end ───────────────────────────────
        print("\nClaude Code turn")
        do {
            var b = AgentSessionBook()
            let k = key("a")
            b.apply(event: "SessionStart", key: k, who: who("luna"), now: at(0))
            check("SessionStart: idle", info(b, k, now: at(1))?.phase == .idle)

            b.apply(event: "UserPromptSubmit", key: k, who: who("luna"), step: "Fix the bug", now: at(2))
            var i = info(b, k, now: at(3))
            check("UserPromptSubmit: working", i?.phase == .working)
            check("prompt is a step", i?.steps.last == AgentStep(kind: .prompt, text: "Fix the bug"))

            let tools: [(String, AgentStepKind)] = [
                ("Read", .read), ("Edit", .edit), ("MultiEdit", .edit), ("Write", .edit),
                ("apply_patch", .edit), ("Bash", .shell), ("Grep", .search), ("Glob", .search),
                ("WebFetch", .web), ("WebSearch", .web), ("Task", .agent), ("spawn_agent", .agent),
                ("TodoWrite", .plan), ("update_plan", .plan), ("mcp__x__y", .mcp),
                ("Whatever", .other), ("", .other),
            ]
            for (n, (tool, kind)) in tools.enumerated() {
                var bb = AgentSessionBook()
                bb.apply(event: "PreToolUse", key: k, who: who("luna"), tool: tool, step: "step",
                         now: at(Double(10 + n)))
                let s = info(bb, k, now: at(30))
                check("PreToolUse \(tool.isEmpty ? "(empty)" : tool) → \(kind)",
                      s?.phase == .working && s?.steps.last?.kind == kind)
            }

            b.apply(event: "PostToolUse", key: k, who: who("luna"), tool: "Read", now: at(4))
            i = info(b, k, now: at(5))
            check("PostToolUse keeps working and adds no step", i?.phase == .working && i?.steps.count == 1)

            b.apply(event: "PostToolUseFailure", key: k, who: who("luna"), tool: "Bash", step: "⚠ failed", now: at(6))
            i = info(b, k, now: at(7))
            check("PostToolUseFailure: failure step", i?.steps.last?.kind == .failure)

            let long = String(repeating: "word ", count: 60) + "\n\nnext line"
            b.apply(event: "Stop", key: k, who: who("luna"), finalText: long, now: at(20))
            i = info(b, k, now: at(21))
            check("Stop: finished", i?.phase == .finished)
            check("finalLine is one short line",
                  i?.finalLine.map { !$0.contains("\n") && $0.count <= AgentSessionBook.maxTextLength } == true)
            check("finished is unseen", i?.finishedUnseen == true)

            b.apply(event: "StopFailure", key: k, who: who("luna"), now: at(22))
            check("StopFailure: error", info(b, k, now: at(23))?.phase == .error)

            b.apply(event: "UserPromptSubmit", key: k, who: who("luna"), step: "again", now: at(30))
            i = info(b, k, now: at(31))
            check("new prompt: working again, green gone, answer cleared",
                  i?.phase == .working && i?.finishedUnseen == false && i?.finalLine == nil)

            b.apply(event: "Interrupt", key: k, who: who("luna"), now: at(40))
            check("Interrupt: idle", info(b, k, now: at(41))?.phase == .idle)

            b.apply(event: "SessionEnd", key: k, who: who("luna"), now: at(50))
            check("SessionEnd removes the session", b.snapshot(now: at(51)).isEmpty)
        }

        // ── steps: five at most, newest last ────────────────────────────────────
        print("\nSteps")
        do {
            var b = AgentSessionBook()
            let k = key("a")
            for n in 1...9 {
                b.apply(event: "PreToolUse", key: k, who: who("luna"), tool: "Read", step: "step \(n)", now: at(Double(n)))
            }
            let steps = info(b, k, now: at(10))?.steps ?? []
            check("at most five", steps.count == AgentSessionBook.maxSteps)
            check("newest last", steps.last?.text == "step 9" && steps.first?.text == "step 5")
        }

        // ── two sessions behind one pill ────────────────────────────────────────
        print("\nTwo sessions behind one pill")
        do {
            var b = AgentSessionBook()
            let a = key("a"), c = key("b")
            b.apply(event: "UserPromptSubmit", key: a, who: who("luna"), step: "A", now: at(0))
            b.apply(event: "UserPromptSubmit", key: c, who: who("lokil"), step: "B", now: at(1))
            b.apply(event: "PreToolUse", key: a, who: who("luna"), tool: "Read", step: "A reads", now: at(2))
            b.apply(event: "Stop", key: a, who: who("luna"), finalText: "done", now: at(3))
            let list = b.snapshot(now: at(4))
            check("two tiles with their own projects",
                  list.count == 2 && Set(list.map(\.who.project)) == ["luna", "lokil"])
            check("A's Stop leaves B working", info(b, c, now: at(4))?.phase == .working)
            check("A finished", info(b, a, now: at(4))?.phase == .finished)
            check("steps are not shared",
                  info(b, c, now: at(4))?.steps.map(\.text) == ["B"]
                  && info(b, a, now: at(4))?.steps.map(\.text) == ["A", "A reads"])
            b.apply(event: "SessionEnd", key: a, who: who("luna"), now: at(5))
            check("A's end leaves B", b.snapshot(now: at(6)).map(\.key) == [c])
        }

        // ── other agents ────────────────────────────────────────────────────────
        print("\nCodex, Gemini, a third-party agent")
        do {
            var b = AgentSessionBook()
            let codex = key("cx", pill: "agent_codex")
            b.apply(event: "UserPromptSubmit", key: codex, who: who("luna", agent: "Codex", host: "com.apple.Terminal"),
                    step: "go", now: at(0))
            let gem = key("g1", pill: "agent_gemini")
            // The relay renames Gemini's BeforeTool / AfterAgent to PreToolUse / Stop.
            b.apply(event: "PreToolUse", key: gem, who: who("gemini", agent: "Gemini CLI"),
                    tool: "Bash", step: "Runs", now: at(1))
            b.apply(event: "Stop", key: gem, who: who("gemini", agent: "Gemini CLI"), finalText: "ok", now: at(2))
            let demo = key("d1", pill: "agent_demo")
            b.apply(event: "SessionStart", key: demo, who: who("demo", agent: "demo"), now: at(3))
            let list = b.snapshot(now: at(4))
            check("three tiles", list.count == 3)
            check("Codex tile", info(b, codex, now: at(4))?.who.agent == "Codex"
                  && info(b, codex, now: at(4))?.who.hostBundleId == "com.apple.Terminal")
            check("Gemini finished", info(b, gem, now: at(4))?.phase == .finished)
            check("third-party agent: project is the agent's name",
                  info(b, demo, now: at(4))?.who.project == "demo")
            check("a missing host keeps the known one", {
                var bb = b
                bb.apply(event: "PostToolUse", key: codex, who: who("luna", agent: "Codex"), now: at(5))
                return info(bb, codex, now: at(6))?.who.hostBundleId == "com.apple.Terminal"
            }())
        }

        // ── unknown sessions ────────────────────────────────────────────────────
        print("\nUnknown sessions")
        do {
            var b = AgentSessionBook()
            let k = key("ghost")
            b.apply(event: "Stop", key: k, who: who("luna"), finalText: "x", now: at(0))
            b.apply(event: "StopFailure", key: k, who: who("luna"), now: at(1))
            b.apply(event: "Interrupt", key: k, who: who("luna"), now: at(2))
            b.apply(event: "SessionEnd", key: k, who: who("luna"), now: at(3))
            b.apply(event: "SubagentStop", key: k, who: who("luna"), step: "done", now: at(4))
            b.apply(event: "PreToolUse", key: k, who: who("luna"), tool: "AskUserQuestion", now: at(5))
            check("Stop, StopFailure, Interrupt, SessionEnd, subagent, AskUserQuestion create no tile",
                  b.snapshot(now: at(6)).isEmpty)
            b.apply(event: "PreToolUse", key: k, who: who("luna"), tool: "Read", step: "r", now: at(7))
            check("a tool call starts one", b.snapshot(now: at(8)).count == 1)

            // Each event on its own session: one after another on a single key, a later
            // SessionEnd would hide a tile that an earlier event wrongly created.
            for (n, event) in ["Stop", "StopFailure", "Interrupt", "SessionEnd", "SubagentStop"].enumerated() {
                var one = AgentSessionBook()
                one.apply(event: event, key: key("ghost-\(n)"), who: who("luna"), finalText: "x",
                          message: "?", now: at(0))
                check("\(event) of a session never heard of creates no tile", one.snapshot(now: at(1)).isEmpty)
            }
        }

        // ── since: the moment the phase changed ─────────────────────────────────
        print("\nSince")
        do {
            let k = key("s")
            var b = AgentSessionBook()
            b.apply(event: "UserPromptSubmit", key: k, who: who("luna"), step: "go", now: at(0))
            b.apply(event: "Stop", key: k, who: who("luna"), finalText: "done", now: at(100))
            b.apply(event: "Notification", key: k, who: who("luna"), message: "hi", now: at(500))
            check("since is the moment the turn ended, not of the later event",
                  info(b, k, now: at(600))?.since == at(100))
        }

        // ── silence ─────────────────────────────────────────────────────────────
        print("\nSilence")
        do {
            let k = key("a")
            var b = AgentSessionBook()
            b.apply(event: "PreToolUse", key: k, who: who("luna"), tool: "Read", step: "r", now: at(0))
            check("working inside the turn window",
                  info(b, k, now: at(AgentSessionBook.maxTurnSilence - 1))?.phase == .working)
            check("30 min without an event: no longer working",
                  info(b, k, now: at(AgentSessionBook.maxTurnSilence + 1))?.phase == .idle)
            check("still shown before 2 h",
                  info(b, k, now: at(AgentSessionBook.maxIdleSilence - 1)) != nil)
            check("gone after 2 h, without any new event",
                  info(b, k, now: at(AgentSessionBook.maxIdleSilence + 1)) == nil)

            var f = AgentSessionBook()
            f.apply(event: "UserPromptSubmit", key: k, who: who("luna"), step: "p", now: at(0))
            f.apply(event: "Stop", key: k, who: who("luna"), finalText: "x", now: at(10))
            check("finished tile shown before 2 h", info(f, k, now: at(3600)) != nil)
            check("finished tile gone after 2 h", info(f, k, now: at(10 + AgentSessionBook.maxIdleSilence + 1)) == nil)

            var e = AgentSessionBook()
            e.apply(event: "UserPromptSubmit", key: k, who: who("luna"), step: "p", now: at(0))
            e.apply(event: "StopFailure", key: k, who: who("luna"), now: at(1))
            check("error tile gone after 2 h", info(e, k, now: at(AgentSessionBook.maxIdleSilence + 5)) == nil)

            check("12 h cap", info(b, k, now: at(AgentSessionBook.maxSilence + 1)) == nil)

            // A silent sibling is dropped at the next event of another session, too.
            var p = AgentSessionBook()
            p.apply(event: "PreToolUse", key: k, who: who("luna"), tool: "Read", step: "r", now: at(0))
            p.apply(event: "PreToolUse", key: key("b"), who: who("lokil"), tool: "Read", step: "r",
                    now: at(AgentSessionBook.maxIdleSilence + 100))
            check("pruned by a later event", p.snapshot(now: at(AgentSessionBook.maxIdleSilence + 101)).map(\.key) == [key("b")])
        }

        // ── waiting ─────────────────────────────────────────────────────────────
        print("\nWaiting for you")
        do {
            var b = AgentSessionBook()
            let a = key("a"), c = key("b")
            b.apply(event: "UserPromptSubmit", key: a, who: who("luna"), step: "A", now: at(0))
            b.apply(event: "UserPromptSubmit", key: c, who: who("lokil"), step: "B", now: at(1))

            check("nobody waits without a request", b.snapshot(now: at(2)).allSatisfy { $0.wait == nil })

            let waits: [AgentSessionKey: AgentWait] = [c: .permission(tool: "Bash")]
            var list = b.snapshot(waits: waits, now: at(2))
            check("permission: reason with the tool", list.first { $0.key == c }?.wait == .permission(tool: "Bash"))
            check("the waiting tile comes first though it appeared later", list.first?.key == c)
            check("the other does not wait", list.first { $0.key == a }?.wait == nil)

            list = b.snapshot(now: at(3))
            check("request taken off the queue: waiting gone with no reset call",
                  list.allSatisfy { $0.wait == nil })

            list = b.snapshot(waits: [a: .question], now: at(4))
            check("question: reason", list.first { $0.key == a }?.wait == .question && list.first?.key == a)
            list = b.snapshot(waits: [c: .question], now: at(4))
            check("question displaced to another session: the first no longer waits",
                  list.first { $0.key == a }?.wait == nil && list.first { $0.key == c }?.wait == .question)

            let w = b.snapshot(waits: [a: .question], now: at(5))
            check("a waiting session is working, not idle", w.first?.phase == .working)
        }

        do {
            var b = AgentSessionBook()
            let a = key("a")
            b.apply(event: "PermissionRequest", key: a, who: who("luna"), now: at(0))
            check("a request starts a tile for a session heard of first through it",
                  info(b, a, waits: [a: .permission(tool: "Edit")], now: at(1))?.wait == .permission(tool: "Edit"))
            check("a waiting session is kept past the idle window", {
                var bb = AgentSessionBook()
                bb.apply(event: "PermissionRequest", key: a, who: who("luna"), now: at(0))
                return info(bb, a, waits: [a: .question], now: at(AgentSessionBook.maxIdleSilence + 10)) != nil
            }())
        }

        // ── order ───────────────────────────────────────────────────────────────
        print("\nOrder")
        do {
            var b = AgentSessionBook()
            let idle = key("idle"), work1 = key("work1"), work2 = key("work2"),
                done = key("done"), err = key("err"), seen = key("seen"), wait = key("wait")
            b.apply(event: "SessionStart", key: idle, who: who("i"), now: at(0))
            b.apply(event: "UserPromptSubmit", key: work1, who: who("w1"), step: "x", now: at(1))
            b.apply(event: "UserPromptSubmit", key: seen, who: who("s"), step: "x", now: at(2))
            b.apply(event: "Stop", key: seen, who: who("s"), finalText: "x", now: at(3))
            b.markFinishedSeen()
            b.apply(event: "UserPromptSubmit", key: done, who: who("d"), step: "x", now: at(4))
            b.apply(event: "Stop", key: done, who: who("d"), finalText: "x", now: at(5))
            b.apply(event: "UserPromptSubmit", key: err, who: who("e"), step: "x", now: at(6))
            b.apply(event: "StopFailure", key: err, who: who("e"), now: at(7))
            b.apply(event: "UserPromptSubmit", key: work2, who: who("w2"), step: "x", now: at(8))
            b.apply(event: "UserPromptSubmit", key: wait, who: who("wt"), step: "x", now: at(9))

            let order = b.snapshot(waits: [wait: .permission(tool: "Bash")], now: at(10)).map(\.key)
            check("waiting > error > finished(unseen) > working > the rest",
                  order == [wait, err, done, work1, work2, idle, seen])

            let before = b.snapshot(now: at(10)).map(\.key)
            b.apply(event: "PreToolUse", key: work2, who: who("w2"), tool: "Read", step: "r", now: at(11))
            b.apply(event: "PreToolUse", key: work1, who: who("w1"), tool: "Read", step: "r", now: at(12))
            check("new events do not reorder tiles inside a group", b.snapshot(now: at(13)).map(\.key) == before)
        }

        // ── summary ─────────────────────────────────────────────────────────────
        print("\nSummary")
        do {
            var b = AgentSessionBook()
            let w = key("w"), r = key("r"), d = key("d"), e = key("e"), i = key("i")
            b.apply(event: "UserPromptSubmit", key: w, who: who("w"), step: "x", now: at(0))
            b.apply(event: "UserPromptSubmit", key: r, who: who("r"), step: "x", now: at(0))
            b.apply(event: "UserPromptSubmit", key: d, who: who("d"), step: "x", now: at(0))
            b.apply(event: "Stop", key: d, who: who("d"), finalText: "x", now: at(1))
            b.apply(event: "UserPromptSubmit", key: e, who: who("e"), step: "x", now: at(0))
            b.apply(event: "StopFailure", key: e, who: who("e"), now: at(1))
            b.apply(event: "SessionStart", key: i, who: who("i"), now: at(0))

            let list = b.snapshot(waits: [w: .question], now: at(2))
            let s = AgentsSummary(list)
            check("waiting 1, working 1, finished 1, errors 1",
                  s.waiting == 1 && s.working == 1 && s.finished == 1 && s.errors == 1)
            check("counters match the tiles", s.total == list.count - 1)
            check("empty summary", AgentsSummary([]).total == 0)
        }

        // ── seen ────────────────────────────────────────────────────────────────
        print("\nFinished: seen")
        do {
            var b = AgentSessionBook()
            let k = key("a")
            b.apply(event: "UserPromptSubmit", key: k, who: who("luna"), step: "x", now: at(0))
            b.apply(event: "Stop", key: k, who: who("luna"), finalText: "x", now: at(1))
            check("unseen after Stop", info(b, k, now: at(2))?.finishedUnseen == true)
            check("markFinishedSeen reports a change", b.markFinishedSeen())
            check("seen: no more highlight, still finished",
                  info(b, k, now: at(3))?.finishedUnseen == false && info(b, k, now: at(3))?.phase == .finished)
            check("nothing left to mark", !b.markFinishedSeen())
            b.apply(event: "UserPromptSubmit", key: k, who: who("luna"), step: "y", now: at(4))
            b.apply(event: "Stop", key: k, who: who("luna"), finalText: "y", now: at(5))
            check("a new turn that ends is news again", info(b, k, now: at(6))?.finishedUnseen == true)
            b.apply(event: "UserPromptSubmit", key: k, who: who("luna"), step: "z", now: at(7))
            check("a new turn returns the phase to working", info(b, k, now: at(8))?.phase == .working
                  && info(b, k, now: at(8))?.finishedUnseen == false)
        }

        // ── equatable snapshot ──────────────────────────────────────────────────
        print("\nEquatable snapshot")
        do {
            var b = AgentSessionBook()
            let k = key("a")
            b.apply(event: "PreToolUse", key: k, who: who("luna"), tool: "Read", step: "r", now: at(0))
            let one = b.snapshot(now: at(1))
            b.apply(event: "PostToolUse", key: k, who: who("luna"), tool: "Read", now: at(5))
            check("an event that changes nothing visible gives an equal snapshot", b.snapshot(now: at(6)) == one)
            b.apply(event: "PreToolUse", key: k, who: who("luna"), tool: "Edit", step: "e", now: at(7))
            check("a new step gives a different one", b.snapshot(now: at(8)) != one)
            check("time passing alone changes nothing", b.snapshot(now: at(9)) == b.snapshot(now: at(100)))
        }

        // ── notifications ───────────────────────────────────────────────────────
        print("\nNotification")
        do {
            var b = AgentSessionBook()
            let k = key("a")
            b.apply(event: "UserPromptSubmit", key: k, who: who("luna"), step: "x", now: at(0))
            b.apply(event: "Notification", key: k, who: who("luna"), message: "Claude is waiting for your input", now: at(1))
            check("a plain notification does not move the phase or add a step",
                  info(b, k, now: at(2))?.phase == .working && info(b, k, now: at(2))?.steps.count == 1)
            b.apply(event: "Notification", key: k, who: who("luna"), message: "Which one do you prefer?", now: at(3))
            check("a question-like notification becomes a step",
                  info(b, k, now: at(4))?.steps.last?.kind == .message)
            b.apply(event: "Notification", key: k, who: who("luna"), message: "5-hour rate limit reached", now: at(5))
            check("rate limit is a flag, not an error", info(b, k, now: at(6))?.rateLimited == true
                  && info(b, k, now: at(6))?.phase == .working)
            b.apply(event: "UserPromptSubmit", key: k, who: who("luna"), step: "n", now: at(7))
            check("the flag clears on the next prompt", info(b, k, now: at(8))?.rateLimited == false)
        }

        // ── keys and hosts ──────────────────────────────────────────────────────
        print("\nKeys and hosts")
        do {
            check("anonymous sessions in two projects stay apart",
                  AgentSessionKey.make(pill: claude, sessionId: "unknown", cwd: "/a")
                  != AgentSessionKey.make(pill: claude, sessionId: "", cwd: "/b"))
            check("a named session keeps its id",
                  AgentSessionKey.make(pill: claude, sessionId: "s1", cwd: "/a").session == "s1")
            check("VS Code is the default host of the Claude pill",
                  AgentHost.bundleId(pill: claude, reported: "") == AgentHost.vsCode)
            check("Cursor is the host of the Cursor pill",
                  AgentHost.bundleId(pill: "agent_cursor", reported: "") == AgentHost.cursor)
            check("a reported bundle id wins",
                  AgentHost.bundleId(pill: claude, reported: "dev.warp.Warp-Stable") == "dev.warp.Warp-Stable")
            check("an unknown agent has no default host",
                  AgentHost.bundleId(pill: "agent_gemini", reported: "").isEmpty)
        }

        print(failures == 0 ? "\nAll agent session checks passed" : "\n\(failures) check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
