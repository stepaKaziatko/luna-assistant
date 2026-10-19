import SwiftUI

// MARK: - Agents on the notch
//
// The right wing of the resting island: one little Luna per agent session with news, the one
// that waits for you first and loudest. And the block under the cursor: counters and a tile for
// the most urgent agents. Both are drawn inside the island's single black figure (`IslandContainer`
// draws the shape; these are only its content), and both are still pictures: no frame-by-frame
// animation and no endless SwiftUI animation. The waiting mini breathes in whole seconds, and only while it
// is on screen (`TimelineView(.periodic)`, off with the screen).
//
// The model is `AgentNotchSummary` (`AgentNotch.swift`), the geometry `AgentPeekLayout`
// (`AgentPeek.swift`); clicks in the block are read by `IslandWindowController` from the same
// layout, so the block takes no focus.

// MARK: - Wing

/// The right wing of the resting island. Replaces the old grid of integration pills.
struct CompactMiniGrid: View {
    @ObservedObject var state: AppState

    var body: some View {
        let cells = state.agentNotch.minis
        let offsets = AgentWing.offsets(count: cells.count)
        ZStack {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                AgentMini(cell: cell, screenOff: state.screenOff)
                    .frame(width: 12, height: 12)
                    .offset(x: offsets[index].x, y: offsets[index].y)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentNotchText.wingLabel(state.agentNotch))
    }
}

/// One cell of the wing: the little Luna of a session in its agent's colour and state, with a
/// mark whose shape (not only its colour) says what it needs; or the "+N" cell.
struct AgentMini: View {
    let cell: AgentNotchCell
    let screenOff: Bool

    var body: some View {
        switch cell {
        case .session(let s): session(s)
        case .more(let n):    more(n)
        }
    }

    private func session(_ s: AgentSessionInfo) -> some View {
        let loud = s.rank == .waiting
        let bodyHex = PillCatalog.definition(for: s.pill)?.color ?? "#C0C4CC"
        return ZStack {
            if loud { WaitingGlow(screenOff: screenOff) }
            LunaStill(state: AgentLook.botState(s), bodyHex: bodyHex, showBadge: false)
                .frame(width: 12 / 0.6, height: 12 / 0.6)
                .frame(width: 12, height: 12, alignment: .center)
                .scaleEffect(loud ? 1.3 : 1)
            if let mark = AgentNotchLook.mark(s) {
                Image(systemName: mark.symbol)
                    .font(.system(size: 7, weight: .black))
                    .foregroundColor(Color(hex: mark.hex))
                    // At the bottom right: the top row of the wing sits against the screen's edge.
                    .offset(x: 6.5, y: 6)
            }
        }
    }

    private func more(_ n: Int) -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.18))
            Text(AgentNotchSummary.moreDigits(n))
                .font(.system(size: n > 9 ? 6.5 : 8, weight: .bold).monospacedDigit())
                .foregroundColor(Color(hex: "#F5F6F8"))
        }
        .frame(width: 12, height: 12)
    }
}

/// The glow behind the mini that waits for you: lit all the time, brighter and dimmer by turns
/// every second. One short animation per second, only while the island rests on screen.
private struct WaitingGlow: View {
    let screenOff: Bool

    var body: some View {
        if screenOff {
            glow(on: false)
        } else {
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 1)) { timeline in
                let on = Int(timeline.date.timeIntervalSinceReferenceDate) % 2 == 0
                glow(on: on)
                    .animation(.easeInOut(duration: 0.6), value: on)
            }
        }
    }

    private func glow(on: Bool) -> some View {
        let orange = Color(hex: AgentLook.waiting)
        return ZStack {
            Circle().fill(orange.opacity(on ? 0.5 : 0.28)).frame(width: 20, height: 20).blur(radius: 3)
            Circle().stroke(orange.opacity(on ? 1 : 0.7), lineWidth: 1.2).frame(width: 17, height: 17)
        }
    }
}

// MARK: - Look

/// Marks, colours and words of the notch, apart from the views.
enum AgentNotchLook {
    struct Mark {
        let symbol: String
        let hex: String
    }

    /// The mark of a mini: a bell for waiting, a triangle for an error, a tick for a finished
    /// turn. Working has none (the blue Luna is enough). Different shapes: colour is not the only sign.
    static func mark(_ s: AgentSessionInfo) -> Mark? {
        switch s.rank {
        case .waiting:        return Mark(symbol: "bell.fill", hex: AgentLook.waiting)
        case .error:          return Mark(symbol: "exclamationmark.triangle.fill", hex: AgentLook.error)
        case .finishedUnseen: return Mark(symbol: "checkmark.circle.fill", hex: AgentLook.finished)
        case .working, .quiet: return nil
        }
    }
}

/// Words of the notch for VoiceOver.
enum AgentNotchText {
    static func wingLabel(_ n: AgentNotchSummary) -> String {
        String(localized: "notch.a11y",
               defaultValue: "Agents: waiting for you \(n.waiting), errors \(n.error), finished \(n.finishedUnseen), working \(n.working)")
    }
}

// MARK: - Block under the cursor

/// The content of the block: it lies under the strip of the resting island, inside the same
/// black figure. Drawn from `AgentPeekLayout`; it has no buttons (the controller reads the
/// clicks from the layout), only VoiceOver actions.
struct AgentPeekView: View {
    @ObservedObject var state: AppState

    var body: some View {
        let layout = state.agentPeekLayout
        let notch = state.agentNotch
        let now = Date()
        ZStack(alignment: .topLeading) {
            counters(layout, notch)
            allAgents(layout)
            ForEach(Array(notch.tiles.prefix(AgentNotchSummary.maxTiles).enumerated()), id: \.element.id) { index, cell in
                let frame = layout.tileFrame(index)
                PeekTile(cell: cell, hovered: state.agentsPeekHover == index, now: now,
                         open: { state.openAgent(id: $0) }, openAll: { state.openAgentsPage() })
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY - layout.stripHeight)
            }
        }
        .frame(width: layout.width, height: layout.height - layout.stripHeight, alignment: .topLeading)
        .foregroundColor(Color(hex: "#F5F6F8"))
    }

    private func counters(_ layout: AgentPeekLayout, _ n: AgentNotchSummary) -> some View {
        let row = layout.counterRow
        return HStack(spacing: 10) {
            counter(n.waiting, AgentLook.waiting, "bell.fill",
                    String(localized: "agents.summary.waiting", defaultValue: "Waiting for you"))
            counter(n.error, AgentLook.error, "exclamationmark.triangle.fill",
                    String(localized: "agents.summary.errors", defaultValue: "Errors"))
            counter(n.finishedUnseen, AgentLook.finished, "checkmark.circle.fill",
                    String(localized: "agents.summary.finished", defaultValue: "Finished"))
            counter(n.working, AgentLook.working, "bolt.fill",
                    String(localized: "agents.summary.working", defaultValue: "Working"))
            Spacer(minLength: 0)
        }
        .frame(width: row.width - AgentPeekLayout.allAgentsWidth - 6, height: row.height, alignment: .leading)
        .offset(x: row.minX, y: row.minY - layout.stripHeight)
    }

    private func counter(_ count: Int, _ hex: String, _ symbol: String, _ title: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10))
            Text("\(count)").font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundColor(count > 0 ? Color(hex: hex) : Color(hex: "#4B4F57"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(count)")
    }

    private func allAgents(_ layout: AgentPeekLayout) -> some View {
        let r = layout.allAgentsButton
        return HStack(spacing: 3) {
            Text(String(localized: "peek.all", defaultValue: "All agents"))
                .font(.system(size: 10, weight: .semibold))
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
        }
        .foregroundColor(Color(hex: "#B0B5BE"))
        .frame(width: r.width, height: r.height)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .offset(x: r.minX, y: r.minY - layout.stripHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "peek.all", defaultValue: "All agents"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { state.openAgentsPage() }
    }
}

/// One tile of the block: Luna in the colour of the agent, the project and the status line; a
/// frame by rank like the tile of the Agents page, but lighter and still.
private struct PeekTile: View {
    let cell: AgentNotchCell
    let hovered: Bool
    let now: Date
    let open: (String) -> Void
    let openAll: () -> Void

    var body: some View {
        switch cell {
        case .session(let s): session(s)
        case .more(let n):    more(n)
        }
    }

    private func session(_ s: AgentSessionInfo) -> some View {
        let accent = AgentLook.accentHex(s).map { Color(hex: $0) }
        let bodyHex = PillCatalog.definition(for: s.pill)?.color ?? "#C0C4CC"
        let status = AgentLook.status(s, now: now)
        return HStack(spacing: 6) {
            LunaStill(state: AgentLook.botState(s), bodyHex: bodyHex)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.who.project)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                Text(status)
                    .font(.system(size: 9.5, weight: s.wait == nil ? .regular : .semibold))
                    .foregroundColor(accent ?? Color(hex: "#8E939C"))
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background(accent: accent, rank: s.rank))
        .opacity(s.rank == .quiet ? 0.7 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(s.who.project), \(s.who.agent), \(status)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(s.id) }
    }

    private func more(_ n: Int) -> some View {
        Text("+\(n)")
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundColor(Color(hex: "#B0B5BE"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background(accent: nil, rank: .quiet))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "peek.more.a11y", defaultValue: "\(n) more agents"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openAll() }
    }

    private func background(accent: Color?, rank: AgentRank) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(hex: hovered ? "#1B1C20" : "#141518"))
            if let accent, rank == .waiting {
                RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.16))
            }
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent.map { $0.opacity(rank == .working ? 0.35 : 0.95) } ?? Color.white.opacity(0.05),
                        lineWidth: rank == .waiting ? 2 : (accent == nil ? 1 : 1.5))
        }
    }
}
