import Foundation

@main
enum AgentPeekTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    static func ctx(over: Bool = true, resting: Bool = true, sessions: Int = 2, onHover: Bool = false,
                    dragging: Bool = false, listening: Bool = false, request: Bool = false) -> AgentPeekPolicy.Context {
        AgentPeekPolicy.Context(pointerOver: over, restingCompact: resting, sessions: sessions,
                                openOnHover: onHover, dragging: dragging, listening: listening,
                                requestPending: request)
    }

    static func main() {

        // ── when the block is allowed ───────────────────────────────────────────
        print("\nAllowed")
        do {
            check("compact, a session, no hover-open: allowed", AgentPeekPolicy.allowed(ctx()))
            check("not resting (hidden or open): not allowed", !AgentPeekPolicy.allowed(ctx(resting: false)))
            check("no sessions: not allowed", !AgentPeekPolicy.allowed(ctx(sessions: 0)))
            check("one quiet session is enough", AgentPeekPolicy.allowed(ctx(sessions: 1)))
            check("open on hover: not allowed", !AgentPeekPolicy.allowed(ctx(onHover: true)))
            check("dragging Luna: not allowed", !AgentPeekPolicy.allowed(ctx(dragging: true)))
            check("voice mode: not allowed", !AgentPeekPolicy.allowed(ctx(listening: true)))
            check("a request card waits: not allowed", !AgentPeekPolicy.allowed(ctx(request: true)))
        }

        // ── show delay ──────────────────────────────────────────────────────────
        print("\nShow after 450 ms")
        do {
            var p = AgentPeekPolicy()
            check("first tick on the island: not yet", !p.update(ctx(), now: at(0)) && !p.visible)
            check("449 ms: not yet", !p.update(ctx(), now: at(0.449)) && !p.visible)
            check("450 ms: grows", p.update(ctx(), now: at(0.45)) && p.visible)
            check("stays while the pointer is on it", !p.update(ctx(), now: at(5)) && p.visible)
        }
        do {
            var p = AgentPeekPolicy()
            p.update(ctx(), now: at(0))
            p.update(ctx(over: false), now: at(0.3))
            p.update(ctx(), now: at(0.4))
            check("a pass-by resets the delay", !p.update(ctx(), now: at(0.8)) && !p.visible)
            check("a fresh 450 ms from the new entry", p.update(ctx(), now: at(0.86)) && p.visible)
        }
        do {
            var p = AgentPeekPolicy()
            p.update(ctx(over: false), now: at(0))
            check("the pointer never came: nothing", !p.update(ctx(over: false), now: at(10)) && !p.visible)
            var q = AgentPeekPolicy()
            q.update(ctx(onHover: true), now: at(0))
            check("open on hover: never shows", !q.update(ctx(onHover: true), now: at(3)) && !q.visible)
            var r = AgentPeekPolicy()
            r.update(ctx(sessions: 0), now: at(0))
            check("no sessions: never shows", !r.update(ctx(sessions: 0), now: at(3)) && !r.visible)
        }

        // ── hide delay ──────────────────────────────────────────────────────────
        print("\nHide after 500 ms")
        do {
            var p = AgentPeekPolicy()
            p.update(ctx(), now: at(0)); p.update(ctx(), now: at(0.5))
            precondition(p.visible)
            check("pointer left: still there at first", !p.update(ctx(over: false), now: at(1)) && p.visible)
            check("499 ms away: still there", !p.update(ctx(over: false), now: at(1.499)) && p.visible)
            check("500 ms away: folds", p.update(ctx(over: false), now: at(1.5)) && !p.visible)
        }
        do {
            var p = AgentPeekPolicy()
            p.update(ctx(), now: at(0)); p.update(ctx(), now: at(0.5))
            p.update(ctx(over: false), now: at(1))
            p.update(ctx(), now: at(1.3))
            check("back within 500 ms: stays", !p.update(ctx(over: false), now: at(1.7)) && p.visible)
            check("and the 500 ms count from the new exit", p.update(ctx(over: false), now: at(2.2)) && !p.visible)
        }

        // ── immediate hide ──────────────────────────────────────────────────────
        print("\nImmediate hide")
        func shown() -> AgentPeekPolicy {
            var p = AgentPeekPolicy()
            p.update(ctx(), now: at(0)); p.update(ctx(), now: at(0.5))
            precondition(p.visible)
            return p
        }
        do {
            var p = shown()
            check("the island opened: gone at once", p.update(ctx(resting: false), now: at(1)) && !p.visible)
            var q = shown()
            check("the last session ended: gone at once", q.update(ctx(sessions: 0), now: at(1)) && !q.visible)
            var r = shown()
            check("voice mode: gone at once", r.update(ctx(listening: true), now: at(1)) && !r.visible)
            var s = shown()
            check("a request card: gone at once", s.update(ctx(request: true), now: at(1)) && !s.visible)
            var d = shown()
            check("Luna dragged: gone at once", d.update(ctx(dragging: true), now: at(1)) && !d.visible)
        }
        do {
            var p = shown()
            p.dismiss()
            check("a click: gone at once", !p.visible)
            check("the pointer still there: it does not come back", !p.update(ctx(), now: at(3)) && !p.visible)
            check("even after the delay", !p.update(ctx(), now: at(9)) && !p.visible)
            p.update(ctx(over: false), now: at(10))
            p.update(ctx(), now: at(11))
            check("after the pointer left, a new entry counts again", p.update(ctx(), now: at(11.45)) && p.visible)
        }
        do {
            // the island opened by the click and folded again with the pointer still on it
            var p = shown()
            p.dismiss()
            p.update(ctx(resting: false), now: at(1))
            check("expanded with the pointer on it: nothing", !p.visible)
            check("folded with the pointer still on it: no block until it leaves",
                  !p.update(ctx(), now: at(2)) && !p.update(ctx(), now: at(3)) && !p.visible)
            p.update(ctx(over: false), now: at(4))
            p.update(ctx(), now: at(5))
            check("then it works again", p.update(ctx(), now: at(5.5)) && p.visible)
        }

        // ── layout ──────────────────────────────────────────────────────────────
        print("\nLayout")
        do {
            let strips: [CGFloat] = [24, 32, 38]
            let notches: [CGFloat] = [184, 192, 200, 220]
            var allOk = true
            for strip in strips {
                for nw in notches {
                    let resting = nw + 160
                    for cells in 1...4 {
                        let l = AgentPeekLayout(stripHeight: strip, restingWidth: resting, cells: cells)
                        if l.width < resting || l.width > 400 { allOk = false }
                        if l.height > AgentPeekLayout.maxHeight || l.height > 560 || l.width > 720 { allOk = false }
                    }
                }
                // the no-notch bar (80 + 160 wide)
                let bar = AgentPeekLayout(stripHeight: strip, restingWidth: 240, cells: 4)
                if bar.width < 240 || bar.width > 400 || bar.height > AgentPeekLayout.maxHeight { allOk = false }
            }
            check("width: not narrower than the figure, not wider than 400; height ≤ 170, inside the 720 × 560 panel",
                  allOk)
            let h1 = AgentPeekLayout(stripHeight: 32, restingWidth: 344, cells: 1).height
            let h2 = AgentPeekLayout(stripHeight: 32, restingWidth: 344, cells: 2).height
            let h3 = AgentPeekLayout(stripHeight: 32, restingWidth: 344, cells: 3).height
            let h4 = AgentPeekLayout(stripHeight: 32, restingWidth: 344, cells: 4).height
            check("one row for 1 and 2 tiles, two rows for 3 and 4", h1 == h2 && h3 == h4 && h3 > h2)
            check("a row is a tile and a gap", h3 - h2 == AgentPeekLayout.tileHeight + AgentPeekLayout.gap)
        }
        do {
            let l = AgentPeekLayout(stripHeight: 32, restingWidth: 344, cells: 4)
            check("the block lies under the strip", l.blockArea.minY == 32 && l.counterRow.minY >= 32)
            check("tiles lie under the counters, inside the figure",
                  (0..<4).allSatisfy { l.tileFrame($0).minY >= l.counterRow.maxY
                      && l.tileFrame($0).maxX <= l.width && l.tileFrame($0).maxY <= l.height })
            check("tiles do not overlap", (0..<4).allSatisfy { i in (0..<4).allSatisfy { j in
                i == j || !l.tileFrame(i).intersects(l.tileFrame(j)) } })
            check("the button is inside the counter row", l.counterRow.contains(l.allAgentsButton))
        }
        do {
            let l = AgentPeekLayout(stripHeight: 32, restingWidth: 344, cells: 3)
            check("a tile is hit by its middle", (0..<3).allSatisfy { i in
                let f = l.tileFrame(i); return l.hit(at: CGPoint(x: f.midX, y: f.midY)) == .tile(i) })
            let b = l.allAgentsButton
            check("the button is hit", l.hit(at: CGPoint(x: b.midX, y: b.midY)) == .allAgents)
            check("the strip is not the block: a click there is a click on the island",
                  l.hit(at: CGPoint(x: 172, y: 10)) == nil && !l.blockArea.contains(CGPoint(x: 172, y: 10)))
            check("the gap between tiles hits nothing but is the block",
                  l.hit(at: CGPoint(x: l.width / 2, y: l.tileFrame(0).midY)) == nil
                  && l.blockArea.contains(CGPoint(x: l.width / 2, y: l.tileFrame(0).midY)))
            check("outside the figure hits nothing", l.hit(at: CGPoint(x: -1, y: 60)) == nil
                  && l.hit(at: CGPoint(x: 100, y: l.height + 1)) == nil)
            check("an empty cell of the last row hits nothing",
                  l.hit(at: CGPoint(x: l.tileFrame(3).midX, y: l.tileFrame(3).midY)) == nil)
        }
        do {
            // the strip is the resting island: the block never moves what is in the strip
            let a = AgentPeekLayout(stripHeight: 32, restingWidth: 344, cells: 1)
            let b = AgentPeekLayout(stripHeight: 32, restingWidth: 344, cells: 4)
            check("the strip does not depend on the tiles", a.stripHeight == b.stripHeight && a.blockArea.minY == b.blockArea.minY)
            check("cells are clamped to 1…4",
                  AgentPeekLayout(stripHeight: 32, restingWidth: 344, cells: 9).height == b.height
                  && AgentPeekLayout(stripHeight: 32, restingWidth: 344, cells: 0).height == a.height)
        }

        print(failures == 0 ? "\nAll agent peek checks passed" : "\n\(failures) check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
