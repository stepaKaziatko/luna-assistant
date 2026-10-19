import Foundation

/// What `holdsCompact` reads in the cases below.
@MainActor
final class IslandHolder { var on = false }

@main
enum IslandHoverTests {
    @MainActor
    static func main() async throws {
        // Off (default): hovering only peeks, as before.
        let off = IslandStateMachine()
        off.mouseEntered()
        precondition(off.state == .petit)

        // On: hovering a hidden island opens it, leaving folds it after the short delay.
        let on = machine()
        on.mouseEntered()
        precondition(on.state == .home && on.openedByHover)
        on.mouseLeft()
        precondition(on.state == .home)        // folds after the grace period, not at once
        try await waitFor(.petit, on, timeout: 5)
        precondition(!on.openedByHover)

        // Coming back before the delay keeps it open.
        let back = machine()
        back.mouseEntered()
        back.mouseLeft()
        back.mouseEntered()
        try await Task.sleep(for: .milliseconds(600))   // well past the 0.3 s grace period
        precondition(back.state == .home)

        // A click inside turns it into a normal open island: the auto-close delay applies.
        let clicked = machine()
        clicked.homeToPetitDelay = 3
        clicked.mouseEntered()
        clicked.userInteracted()
        clicked.mouseLeft()
        try await Task.sleep(for: .milliseconds(600))   // past the hover grace, far from 3 s
        precondition(clicked.state == .home)
        clicked.homeToPetitDelay = 0.05
        try await waitFor(.petit, clicked, timeout: 5)

        // A pending approval holds the island: hover never opens or folds it on its own.
        let held = machine()
        held.isHeldOpen = { true }
        held.mouseEntered()
        precondition(held.state == .home && !held.openedByHover)
        held.mouseLeft()
        try await Task.sleep(for: .milliseconds(600))
        precondition(held.state == .home)

        // An island opened by an alert keeps the normal delay even with hover on.
        let alert = machine()
        alert.homeToPetitDelay = 3
        alert.openedExternally()
        alert.mouseEntered()
        alert.mouseLeft()
        try await Task.sleep(for: .milliseconds(600))
        precondition(alert.state == .home)

        // ── Notch held by news (waiting, error, unseen finish) ───────────────────
        // (a) a hold keeps the compact island from falling to hidden on its timer.
        let hold = IslandHolder()
        let keep = plain()
        keep.holdsCompact = { hold.on }
        hold.on = true
        keep.mouseEntered()
        keep.mouseLeft()
        precondition(keep.state == .petit)
        try await Task.sleep(for: .milliseconds(400))      // eight times the 0.05 s hide delay
        precondition(keep.state == .petit, "held compact island must not hide")

        // (b) the hold ends: one fresh hide timer, and the island hides once.
        hold.on = false
        keep.holdChanged()
        precondition(keep.state == .petit)                 // not at once: the usual delay first
        try await waitFor(.hidden, keep, timeout: 5)
        var hides = 0
        keep.onTransition = { _, to in if to == .hidden { hides += 1 } }
        keep.holdChanged()                                  // nothing changed: no second timer, no second hide
        try await Task.sleep(for: .milliseconds(300))
        precondition(hides == 0)

        // (b2) a change that is not the end of a hold does not restart the timer endlessly.
        let steady = plain()
        steady.petitToHiddenDelay = 0.25
        steady.mouseEntered(); steady.mouseLeft()
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(40))
            steady.holdChanged()                            // agents' steps change constantly
        }
        try await waitFor(.hidden, steady, timeout: 5)

        // (b3) a hold that begins while the timer runs stops that hide.
        let late = plain()
        let lateHold = IslandHolder()
        late.holdsCompact = { lateHold.on }
        late.petitToHiddenDelay = 0.2
        late.mouseEntered(); late.mouseLeft()
        lateHold.on = true
        late.holdChanged()
        try await Task.sleep(for: .milliseconds(450))
        precondition(late.state == .petit)

        // (c) a hold does not stand in the way of collapse, click and external opening.
        let free = plain()
        let freeHold = IslandHolder(); freeHold.on = true
        free.holdsCompact = { freeHold.on }
        free.click()
        precondition(free.state == .home)
        free.collapse()
        precondition(free.state == .petit)
        free.click()
        precondition(free.state == .home)
        free.collapse()
        free.openedExternally()
        precondition(free.state == .home)
        free.collapse()
        precondition(free.state == .petit)

        // (c2) the pointer on the island while a hold ends: the exit, not the end of the hold, starts the timer.
        let over = plain()
        let overHold = IslandHolder(); overHold.on = true
        over.holdsCompact = { overHold.on }
        over.mouseEntered()
        overHold.on = false
        over.holdChanged()
        try await Task.sleep(for: .milliseconds(300))
        precondition(over.state == .petit)
        over.mouseLeft()
        try await waitFor(.hidden, over, timeout: 5)

        // (d) opening on hover is as before, with or without a hold.
        let hoverHold = machine()
        let hh = IslandHolder(); hh.on = true
        hoverHold.holdsCompact = { hh.on }
        hoverHold.mouseEntered()
        precondition(hoverHold.state == .home && hoverHold.openedByHover)

        // (e) reveal() from hidden makes one transition and starts the timer; a held island does not repeat it.
        let reveal = plain()
        let rh = IslandHolder(); rh.on = true
        reveal.holdsCompact = { rh.on }
        var peeks = 0
        reveal.onTransition = { _, to in if to == .petit { peeks += 1 } }
        reveal.reveal()
        reveal.reveal()
        try await Task.sleep(for: .milliseconds(300))
        precondition(reveal.state == .petit && peeks == 1, "held island: one reveal, no hiding, no second reveal")

        print("Island open on hover and held notch: 14 cases passed")
    }

    /// A compact island that hides fast, for the held-notch cases.
    @MainActor
    private static func plain() -> IslandStateMachine {
        let m = IslandStateMachine()
        m.petitToHiddenDelay = 0.05
        return m
    }

    @MainActor
    private static func machine() -> IslandStateMachine {
        let m = IslandStateMachine()
        m.openOnHover = true
        m.hoverCloseDelay = 0.3
        return m
    }

    @MainActor
    private static func waitFor(_ s: IslandStateMachine.State, _ m: IslandStateMachine, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while m.state != s && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(m.state == s, "state \(m.state) after \(timeout) s, expected \(s)")
    }
}
