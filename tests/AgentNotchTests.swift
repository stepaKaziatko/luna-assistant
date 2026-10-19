import Foundation

@main
enum AgentNotchTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A session in a given state. `n` orders the appearance (firstSeen).
    static func session(_ id: String, pill: String = "integration_claude",
                        phase: AgentPhase = .idle, wait: AgentWait? = nil,
                        unseen: Bool = false, n: Int = 0) -> AgentSessionInfo {
        AgentSessionInfo(
            key: AgentSessionKey(pill: pill, session: id),
            who: AgentSessionWho(project: id, agent: "Claude Code"),
            phase: phase, wait: wait, steps: [], finalLine: nil,
            since: t0, firstSeen: t0.addingTimeInterval(TimeInterval(n)),
            finishedUnseen: unseen && phase == .finished, rateLimited: false)
    }

    static func waiting(_ id: String, n: Int = 0) -> AgentSessionInfo { session(id, phase: .working, wait: .question, n: n) }
    static func failed(_ id: String, n: Int = 0) -> AgentSessionInfo { session(id, phase: .error, n: n) }
    static func done(_ id: String, n: Int = 0) -> AgentSessionInfo { session(id, phase: .finished, unseen: true, n: n) }
    static func seen(_ id: String, n: Int = 0) -> AgentSessionInfo { session(id, phase: .finished, unseen: false, n: n) }
    static func busy(_ id: String, n: Int = 0) -> AgentSessionInfo { session(id, phase: .working, n: n) }
    static func idle(_ id: String, n: Int = 0) -> AgentSessionInfo { session(id, phase: .idle, n: n) }

    static func ids(_ cells: [AgentNotchCell]) -> [String] {
        cells.map { cell in
            switch cell {
            case .session(let s): return s.key.session
            case .more(let n):    return "+\(n)"
            }
        }
    }

    static func main() {

        // ── counts by rank ──────────────────────────────────────────────────────
        print("\nCounts")
        do {
            // waiting, error, finished(unseen), working, finished(seen), idle, waiting+working at once
            let list = [waiting("w", n: 0), failed("e", n: 1), done("d", n: 2), busy("b", n: 3),
                        seen("s", n: 4), idle("i", n: 5), session("ww", phase: .working, wait: .permission(tool: "Bash"), n: 6)]
            let s = AgentNotchSummary(list)
            check("waiting counts both waiting sessions, the working one that waits is not counted twice",
                  s.waiting == 2 && s.working == 1)
            check("error 1, finished-unseen 1", s.error == 1 && s.finishedUnseen == 1)
            check("a seen finished turn and an open idle session are quiet", s.quiet == 2)
            check("quiet is not news", s.newsCount == 5 && s.total == 7)
            check("empty list", AgentNotchSummary([]).total == 0 && AgentNotchSummary([]).dominant == nil)
        }

        // ── dominant ────────────────────────────────────────────────────────────
        print("\nDominant")
        do {
            let w = waiting("w"), e = failed("e"), d = done("d"), b = busy("b")
            check("all four: waiting wins", AgentNotchSummary([b, d, e, w]).dominant == .waiting)
            check("no waiting: error wins", AgentNotchSummary([b, d, e]).dominant == .error)
            check("no waiting, no error: finished wins", AgentNotchSummary([b, d]).dominant == .finishedUnseen)
            check("only work: working", AgentNotchSummary([b]).dominant == .working)
            check("waiting over work alone", AgentNotchSummary([b, w]).dominant == .waiting)
            check("error over finished alone", AgentNotchSummary([d, e]).dominant == .error)
            check("only quiet sessions: nil", AgentNotchSummary([seen("s"), idle("i")]).dominant == nil)
            check("nobody: nil", AgentNotchSummary([]).dominant == nil)
            check("lead is the first of the dominant kind",
                  AgentNotchSummary([b, waiting("w2", n: 5), w]).lead?.key.session == "w")
            check("a session that waits while it works is waiting", AgentNotchSummary([w]).lead?.rank == .waiting)
        }

        // ── seen is quiet ───────────────────────────────────────────────────────
        print("\nSeen turns")
        do {
            let s = AgentNotchSummary([seen("a"), done("b")])
            check("a seen turn is out of the counts", s.finishedUnseen == 1 && s.quiet == 1)
            check("a seen turn is not a mini", ids(s.minis) == ["b"])
            check("a seen turn is a tile of the block", ids(s.tiles) == ["b", "a"])
            check("only seen turns: no minis, notch not held",
                  AgentNotchSummary([seen("a")]).minis.isEmpty && !AgentNotchSummary([seen("a")]).holdsNotch)
        }

        // ── minis ───────────────────────────────────────────────────────────────
        print("\nMinis")
        do {
            func working(_ n: Int) -> [AgentSessionInfo] { (0..<n).map { busy("m\($0)", n: $0) } }
            check("0 sessions: 0 cells", AgentNotchSummary([]).minis.isEmpty)
            check("1 session: 1 cell", AgentNotchSummary(working(1)).minis.count == 1)
            check("4 sessions: 4 cells, no +N", ids(AgentNotchSummary(working(4)).minis) == ["m0", "m1", "m2", "m3"])
            check("5 sessions: three minis and +2", ids(AgentNotchSummary(working(5)).minis) == ["m0", "m1", "m2", "+2"])
            check("9 sessions: three minis and +6", ids(AgentNotchSummary(working(9)).minis) == ["m0", "m1", "m2", "+6"])
            check("quiet sessions never become minis",
                  AgentNotchSummary([idle("i"), seen("s"), busy("b")]).minis.count == 1)
            check("quiet sessions do not count towards +N",
                  ids(AgentNotchSummary(working(4) + [idle("i"), seen("s")]).minis) == ["m0", "m1", "m2", "m3"])
            // the display order of the Agents page: rank, then order of appearance
            let mixed = [busy("b1", n: 0), done("d1", n: 1), failed("e1", n: 2), waiting("w1", n: 3), busy("b2", n: 4)]
            check("minis follow the page: waiting, error, finished, working",
                  ids(AgentNotchSummary(mixed).minis) == ["w1", "e1", "d1", "b1", "b2"].prefix(3) + ["+2"])
            let sorted = mixed.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.firstSeen < $1.firstSeen }
            check("the same list given in page order gives the same minis",
                  ids(AgentNotchSummary(sorted).minis) == ids(AgentNotchSummary(mixed).minis))
            check("urgent ones survive the cut",
                  ids(AgentNotchSummary(working(6) + [waiting("w", n: 99)]).minis).first == "w")
            // one mini is one session, not one pill
            let twoOfOne = [busy("s1", n: 0), busy("s2", n: 1)]
            check("two sessions of one pill are two minis", AgentNotchSummary(twoOfOne).minis.count == 2)
            check("more digits", AgentNotchSummary.moreDigits(2) == "2" && AgentNotchSummary.moreDigits(9) == "9"
                  && AgentNotchSummary.moreDigits(10) == "9+" && AgentNotchSummary.moreDigits(40) == "9+")
        }

        // ── tiles of the block ──────────────────────────────────────────────────
        print("\nTiles")
        do {
            let few = [busy("b", n: 0), idle("i", n: 1), seen("s", n: 2)]
            check("up to four: every session, the quiet ones too, in page order",
                  ids(AgentNotchSummary(few).tiles) == ["b", "i", "s"])
            let four = few + [done("d", n: 3)]
            check("exactly four: all four", AgentNotchSummary(four).tiles.count == 4
                  && !ids(AgentNotchSummary(four).tiles).contains { $0.hasPrefix("+") })
            let many = [idle("i1", n: 0), idle("i2", n: 1), busy("b", n: 2), done("d", n: 3), failed("e", n: 4), waiting("w", n: 5)]
            check("more than four: three most urgent and +3", ids(AgentNotchSummary(many).tiles) == ["w", "e", "d", "+3"])
            check("seven sessions: +4", ids(AgentNotchSummary((0..<7).map { busy("x\($0)", n: $0) }).tiles) == ["x0", "x1", "x2", "+4"])
            check("no sessions: no tiles", AgentNotchSummary([]).tiles.isEmpty)
        }

        // ── wing geometry ───────────────────────────────────────────────────────
        print("\nWing")
        do {
            check("a place for every count 0…4", (0...4).allSatisfy { AgentWing.offsets(count: $0).count == $0 })
            check("more than four are clamped", AgentWing.offsets(count: 9).count == 4)
            check("one mini sits in the middle", AgentWing.offsets(count: 1) == [CGPoint(x: 0, y: 0)])
            let all = (1...4).flatMap { AgentWing.offsets(count: $0) }
            check("every cell stays inside the 28 × 28 box (12 pt cells)",
                  all.allSatisfy { abs($0.x) + 6 <= 14 && abs($0.y) + 6 <= 14 })
            check("cells of a wing do not overlap", (1...4).allSatisfy { n in
                let o = AgentWing.offsets(count: n)
                return o.indices.allSatisfy { i in o.indices.allSatisfy { j in
                    i == j || hypot(o[i].x - o[j].x, o[i].y - o[j].y) >= 12 } } })
            check("cell identity: sessions by key, the rest cell apart",
                  AgentNotchCell.more(3).id == "more" && AgentNotchCell.session(busy("x")).id == busy("x").id
                  && AgentNotchCell.session(busy("x")).id != AgentNotchCell.session(busy("y")).id)
        }

        // ── hold and log ────────────────────────────────────────────────────────
        print("\nHold and log")
        do {
            check("waiting holds the notch", AgentNotchSummary([waiting("w")]).holdsNotch)
            check("error holds the notch", AgentNotchSummary([failed("e")]).holdsNotch)
            check("an unseen finished turn holds the notch", AgentNotchSummary([done("d")]).holdsNotch)
            check("work alone does not hold the notch", !AgentNotchSummary([busy("b"), busy("c")]).holdsNotch)
            check("log line", AgentNotchSummary([waiting("w"), failed("e"), done("d"), busy("b"), busy("c"), idle("i")]).logLine
                  == "notch: waiting=1 error=1 finished=1 working=2 minis=4")
            check("log line of nobody", AgentNotchSummary([]).logLine == "notch: waiting=0 error=0 finished=0 working=0 minis=0")
        }

        print(failures == 0 ? "\nAll agent notch checks passed" : "\n\(failures) check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
